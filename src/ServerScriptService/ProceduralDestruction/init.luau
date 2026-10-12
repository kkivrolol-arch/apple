-- Discord: theonlykivro | Roblox: Kivro_lol
--!strict
--[[
	ProceduralDestruction (demo-sized): server-authoritative, physics-driven destruction for plain Parts.
	Touched -> impact energy (0.5*m*v^2 along the contact normal) -> damage the part and its neighbours -> when health
	runs out the part is cut: a cube-shaped crater becomes loose debris, the rest becomes up to six anchored slabs.
	Trust model: there is no client input path at all, so there is nothing for a client to forge.
	Usage: require + start(); tag Parts "Destructible" (or register()); tag projectiles "DestructionImpactor" and make
	them server-owned (SetNetworkOwner(nil)) so their pre-contact velocity can be sampled and trusted.
	Limits: only Block Parts are cut (others launch whole); slabs are plain scenery; no structural support.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- durability: energy a reference-volume part absorbs before breaking; minEnergy: weaker hits are ignored outright;
-- fragment: debris edge length (studs); lifetime: debris seconds; launch: debris speed multiplier.
export type Profile = { durability: number, minEnergy: number, fragment: number, lifetime: number, launch: number }
export type Hit = { position: Vector3?, direction: Vector3?, radius: number? }
export type DestroyInfo = { part: BasePart, material: string, position: Vector3, debris: { BasePart }, remnants: { BasePart } }
type Impact = { position: Vector3, direction: Vector3, speed: number, energy: number, radius: number, impactor: BasePart? }

-- Every tunable number lives here (exposed as Destruction.config, so callers can change it without editing the module).
local config = {
	tag = "Destructible", -- CollectionService tag that registers Parts
	impactorTag = "DestructionImpactor", -- projectiles whose pre-contact velocity is sampled every physics step
	debrisGroup = "DestructionDebris", -- collision group: debris does not collide with itself
	defaultMaterial = "Wood",
	materials = {
		Glass = { durability = 2500, minEnergy = 400, fragment = 1.0, lifetime = 6, launch = 1.3 },
		Wood = { durability = 9000, minEnergy = 1500, fragment = 1.6, lifetime = 10, launch = 0.9 },
		Brick = { durability = 22000, minEnergy = 4000, fragment = 1.4, lifetime = 12, launch = 0.8 },
		Concrete = { durability = 45000, minEnergy = 8000, fragment = 2.2, lifetime = 14, launch = 0.6 },
		Metal = { durability = 90000, minEnergy = 15000, fragment = 2.5, lifetime = 16, launch = 0.5 },
	} :: { [string]: Profile },
	materialMap = { -- Enum.Material -> profile name
		[Enum.Material.Glass] = "Glass", [Enum.Material.Wood] = "Wood", [Enum.Material.WoodPlanks] = "Wood",
		[Enum.Material.Plastic] = "Wood", [Enum.Material.Brick] = "Brick", [Enum.Material.Concrete] = "Concrete",
		[Enum.Material.Metal] = "Metal",
	} :: { [Enum.Material]: string },
	referenceVolume = 16, volumeExponent = 0.67, -- bigger parts are tougher, sub-linearly
	minSpeed = 10, -- approach speed (studs/s) under which contact is a nudge, not an impact
	maxSpeed = 220, maxMass = 400, -- clamps so a glitched velocity or mass cannot yield unbounded energy
	restitution = 0.5, -- assumed bounce when undoing the solver for untracked parts
	cooldown = 0.15, -- seconds before the same impactor can hit the same part again
	baseRadius = 2.5, maxRadius = 8, -- crater half-extent: exactly lethal hit .. hardest hit
	minFragment = 0.75, minSlab = 0.5, -- hard floors on debris edge and slab thickness
	maxPerBreak = 24, maxDebris = 200, -- instance safeguards: pieces per break, pieces alive (oldest evicted first)
	maxBreaksPerFrame = 2, -- breaks are queued and spread over frames
	launchTransfer = 0.6, minLaunch = 4, maxLaunch = 90, scatter = 0.25, -- debris launch model
}
export type Config = typeof(config)

local Destructible = {}
Destructible.__index = Destructible
type Fields = {
	part: BasePart,
	material: string,
	profile: Profile,
	maxHealth: number,
	health: number,
	state: "Intact" | "Queued" | "Destroyed", -- one forward-only path, so a part breaks at most once
	nextAt: number, -- with lastImpactor: the same impactor is not counted twice for one blow
	lastImpactor: BasePart?,
	impact: Impact?, -- the blow that emptied its health, kept for the cut
	connections: { RBXScriptConnection },
}
export type Destructible = typeof(setmetatable({} :: Fields, Destructible))

local registry: { [BasePart]: Destructible } = {}
local queue: { Destructible } = {}
local debris: { BasePart } = {}
local approach: { [BasePart]: Vector3 } = {} -- pre-contact velocity of tracked impactors, refreshed each physics step
local connections: { RBXScriptConnection } = {}
local overlap = OverlapParams.new()
local rng = Random.new()
local debrisFolder: Folder? = nil
local started = false
local destroyedEvent = Instance.new("BindableEvent") -- engine-native event with deferred delivery

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	local m = v.Magnitude
	return if m > 1e-4 and m < math.huge then v / m else fallback -- never NaN
end

-- Closest point of an oriented box to a world point: clamp in the box's own frame, then map back. Touched carries
-- no contact data, so this approximates the contact; it also gives exact distances for splash falloff.
local function closestPoint(cf: CFrame, size: Vector3, point: Vector3): Vector3
	local half = size * 0.5
	return cf:PointToWorldSpace(cf:PointToObjectSpace(point):Max(-half):Min(half))
end

-- Crater radius grows with how far the energy exceeds the part's health.
local function radiusFor(energy: number, maxHealth: number): number
	return math.clamp(config.baseRadius * math.sqrt(math.max(energy / maxHealth, 1)), config.baseRadius, config.maxRadius)
end

-- True when this call queued the break; later hits see Queued/Destroyed and return early (no duplicate breaks).
function Destructible.applyDamage(self: Destructible, amount: number, impact: Impact): boolean
	if self.state ~= "Intact" then
		return false
	end
	self.health -= amount
	if self.health > 0 then
		return false
	end
	self.state, self.impact = "Queued", impact
	table.insert(queue, self)
	return true
end

-- Idempotent: safe from Destroying, unregister(), stop() and the break itself, in any order.
function Destructible.cleanup(self: Destructible)
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	self.state = "Destroyed"
	if registry[self.part] == self then
		registry[self.part] = nil
	end
end

-- Strength is kinetic energy using only the speed along the contact normal (sliding never breaks anything).
-- Touched fires after the solver resolved the contact, so the live velocity is already post-bounce (measured in
-- Studio: 60 studs/s reads about -30). Tracked parts carry the true pre-contact velocity; others get the bounce undone.
local function measure(d: Destructible, other: BasePart, root: BasePart): Impact?
	local contact = closestPoint(d.part.CFrame, d.part.Size, other.Position)
	local live = root.AssemblyLinearVelocity
	local normal = unitOr(other.Position - contact, unitOr(-live, Vector3.yAxis))
	local away = live:Dot(normal)
	local velocity: Vector3 = approach[root]
		or (if away > 0 then live - (1 + 1 / config.restitution) * away * normal else live)
	local speed = math.clamp(-velocity:Dot(normal), 0, config.maxSpeed)
	if speed < config.minSpeed then
		return nil
	end
	local energy = 0.5 * math.min(root.AssemblyMass, config.maxMass) * speed * speed
	local radius = radiusFor(energy, d.maxHealth)
	return { position = contact, direction = unitOr(velocity, -normal), speed = speed, energy = energy, radius = radius, impactor = root }
end

-- Spreads one impact over the structure: the engine's spatial query (restricted to registered parts) picks
-- candidates, then the exact oriented-box distance sets the falloff damage.
local function applyImpact(impact: Impact, primary: Destructible)
	local list: { Instance } = {}
	for part in registry do
		table.insert(list, part)
	end
	overlap.FilterDescendantsInstances = list
	local found = workspace:GetPartBoundsInRadius(impact.position, impact.radius, overlap)
	if not table.find(found, primary.part) then
		table.insert(found, primary.part) -- the touched part always takes part
	end
	for _, candidate in found do
		local d = registry[candidate]
		if d and d.state == "Intact" then
			local distance = (closestPoint(candidate.CFrame, candidate.Size, impact.position) - impact.position).Magnitude
			local damage = impact.energy * (1 - (distance / impact.radius) ^ 2)
			if distance <= impact.radius and (d == primary or damage >= d.profile.minEnergy) then
				-- Stamp splash victims too, so their own Touched from this impactor is not counted twice.
				d.nextAt, d.lastImpactor = os.clock() + config.cooldown, impact.impactor
				d:applyDamage(damage, impact)
			end
		end
	end
end

local function handleTouched(self: Destructible, other: BasePart)
	-- Cheapest filters first. Debris is never an impactor, which rules out chain reactions.
	if self.state ~= "Intact" or other.Anchored or not other.CanCollide or other.CollisionGroup == config.debrisGroup then
		return
	end
	local root: BasePart? = other.AssemblyRootPart -- nil if `other` died before this deferred event ran
	if root == nil or root.Anchored then
		return
	end
	-- The cooldown is per impactor: a character's many limbs count once, but a different projectile is a new blow.
	if root == self.lastImpactor and os.clock() < self.nextAt then
		return
	end
	local impact = measure(self, other, root)
	if impact and impact.energy >= self.profile.minEnergy then
		applyImpact(impact, self)
	end
end

function Destructible.new(part: BasePart): Destructible
	local named = part:GetAttribute("DestructionMaterial") -- per-Part override of the Enum.Material lookup
	local name = if typeof(named) == "string" and config.materials[named]
		then named
		else config.materialMap[part.Material] or config.defaultMaterial
	local profile = config.materials[name]
	local override = part:GetAttribute("Durability") -- per-Part override of the profile's durability
	local base = if typeof(override) == "number" and override > 0 then override else profile.durability
	local size = part.Size
	local maxHealth = base * math.clamp((size.X * size.Y * size.Z / config.referenceVolume) ^ config.volumeExponent, 0.1, 50)
	local fields: Fields = {
		part = part, material = name, profile = profile, maxHealth = maxHealth, health = maxHealth,
		state = "Intact", nextAt = 0, connections = {},
	}
	local self: Destructible = setmetatable(fields, Destructible)
	table.insert(self.connections, part.Touched:Connect(function(other)
		handleTouched(self, other)
	end))
	table.insert(self.connections, part.Destroying:Connect(function()
		self:cleanup()
	end))
	return self
end

local function makePiece(source: BasePart, cf: CFrame, lo: Vector3, hi: Vector3): Part
	local piece = Instance.new("Part")
	piece.Size = hi - lo
	piece.CFrame = cf * CFrame.new((lo + hi) * 0.5)
	piece.Material, piece.Color = source.Material, source.Color
	piece.Transparency, piece.Reflectance = source.Transparency, source.Reflectance
	piece.TopSurface, piece.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	return piece
end

-- Splits a part into remnants (anchored slabs) and fragments (the crater cut into a grid); the last result says
-- whether the original part itself is reused as the only fragment.
--   crater   = a cube around the impact point clipped to the part (a loose part shatters entirely)
--   remnants = part minus crater as at most six disjoint boxes (two X slabs, then Z and Y slabs limited to the
--              crater's X range), which keeps the instance count tiny
local function carve(d: Destructible, impact: Impact): ({ BasePart }, { BasePart }, boolean)
	local part = d.part
	local cf, half = part.CFrame, part.Size * 0.5
	if not (part:IsA("Part") and part.Shape == Enum.PartType.Block) then
		return {}, { part }, true -- no honest way to cut a ball or mesh into boxes: launch it whole
	end
	local lo, hi = -half, half
	if part.Anchored then
		local centre = cf:PointToObjectSpace(impact.position):Max(-half):Min(half)
		local reach = Vector3.one * math.min(impact.radius, config.maxRadius)
		lo, hi = (centre - reach):Max(-half), (centre + reach):Min(half)
	end
	local slabs = {
		{ -half, Vector3.new(lo.X, half.Y, half.Z) },
		{ Vector3.new(hi.X, -half.Y, -half.Z), half },
		{ Vector3.new(lo.X, -half.Y, -half.Z), Vector3.new(hi.X, half.Y, lo.Z) },
		{ Vector3.new(lo.X, -half.Y, hi.Z), Vector3.new(hi.X, half.Y, half.Z) },
		{ Vector3.new(lo.X, -half.Y, lo.Z), Vector3.new(hi.X, lo.Y, hi.Z) },
		{ Vector3.new(lo.X, hi.Y, lo.Z), Vector3.new(hi.X, half.Y, hi.Z) },
	}
	local remnants: { BasePart } = {}
	local thinnest = part.Size:Min(Vector3.one * config.minSlab) -- per axis, so a part thinner than minSlab keeps its slabs
	for _, slab in slabs do
		local e = slab[2] - slab[1]
		if e.X >= thinnest.X and e.Y >= thinnest.Y and e.Z >= thinnest.Z then
			local piece = makePiece(part, cf, slab[1], slab[2])
			piece.Name, piece.Anchored, piece.CollisionGroup = part.Name, true, part.CollisionGroup
			piece.CanCollide, piece.CanTouch, piece.CanQuery = part.CanCollide, part.CanTouch, part.CanQuery
			table.insert(remnants, piece)
		end
	end
	local size = hi - lo
	local target = math.max(d.profile.fragment, config.minFragment)
	local nx = math.max(1, math.round(size.X / target))
	local ny = math.max(1, math.round(size.Y / target))
	local nz = math.max(1, math.round(size.Z / target))
	while nx * ny * nz > config.maxPerBreak do -- coarsen the axis with the most cells until the grid fits
		if nx >= ny and nx >= nz then
			nx -= 1
		elseif ny >= nz then
			ny -= 1
		else
			nz -= 1
		end
	end
	if nx * ny * nz == 1 and #remnants == 0 then
		return remnants, { part }, true -- nothing left to cut: the whole part becomes one flying chunk
	end
	local fragments: { BasePart } = {}
	local step = Vector3.new(size.X / nx, size.Y / ny, size.Z / nz)
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			for k = 0, nz - 1 do
				local cellLo = lo + Vector3.new(i * step.X, j * step.Y, k * step.Z)
				table.insert(fragments, makePiece(part, cf, cellLo, cellLo + step))
			end
		end
	end
	return remnants, fragments, false
end

-- Debris direction blends the impactor's travel direction, "away from the impact" and a small random cone; speed
-- falls off with distance from the crater centre. Delivered with ApplyImpulse (impulse = mass * dv) and clamped.
local function launch(piece: BasePart, impact: Impact, profile: Profile, inherited: Vector3)
	local offset = piece.Position - impact.position
	local falloff = 1 / (1 + (offset.Magnitude / impact.radius) ^ 2)
	local blend = impact.direction + unitOr(offset, rng:NextUnitVector()) * 0.5 + rng:NextUnitVector() * config.scatter
	local speed = impact.speed * config.launchTransfer * profile.launch * falloff
	speed = math.clamp(speed, config.minLaunch, config.maxLaunch)
	piece.AssemblyLinearVelocity = inherited -- a shattering crate keeps the momentum it already had
	piece:ApplyImpulse(unitOr(blend, Vector3.yAxis) * speed * piece.AssemblyMass)
	piece.AssemblyAngularVelocity = rng:NextUnitVector() * math.min(speed * 0.5, 12)
end

local function executeBreak(d: Destructible)
	local part, impact = d.part, d.impact :: Impact
	local valid = d.state == "Queued" and part.Parent ~= nil
	d:cleanup() -- from here the part can no longer be damaged, queued or looked up
	if not valid then
		return
	end
	local inherited = if part.Anchored then Vector3.zero else part.AssemblyLinearVelocity
	local remnants, fragments, reused = carve(d, impact)
	for _, slab in remnants do
		slab.Parent = part.Parent -- slabs go back where the original lived
	end
	if reused then
		part:RemoveTag(config.tag) -- a reused original is debris now, not a destructible
	end
	for _, piece in fragments do
		-- No Touched/query traffic from debris, and a collision group so pile-ups skip debris-vs-debris work.
		piece.Anchored, piece.CanTouch, piece.CanQuery = false, false, false
		piece.CollisionGroup = config.debrisGroup
		piece.Parent = debrisFolder or workspace
		table.insert(debris, piece)
		Debris:AddItem(piece, d.profile.lifetime) -- the engine removes it after its lifetime
		if piece:CanSetNetworkOwnership() then
			piece:SetNetworkOwner(nil) -- server-simulated: client-owned debris could be steered by an exploiter
		end
		launch(piece, impact, d.profile, inherited)
	end
	-- Global cap: forget every piece the engine already removed (expiry, falling out of the world), wherever it sits in
	-- the list, then evict the oldest live pieces while still over the cap.
	for i = #debris, 1, -1 do
		if debris[i].Parent == nil then
			table.remove(debris, i)
		end
	end
	while #debris > config.maxDebris do
		(table.remove(debris, 1) :: BasePart):Destroy()
	end
	if not reused then
		part:Destroy() -- last, so the structure never has a hole for a frame
	end
	destroyedEvent:Fire({
		part = part, material = d.material, position = impact.position, debris = fragments, remnants = remnants,
	} :: DestroyInfo)
end

-- Touched is dispatched between PreSimulation and PostSimulation of a step, after contact resolution (verified in
-- Studio), so sampling in PreSimulation records exactly the velocity that entered the step. Only characters and
-- tagged impactors are tracked, which bounds the cost by player count rather than by the size of the world.
local function track(part: Instance?)
	local root = if part and part:IsA("BasePart") then part.AssemblyRootPart else nil -- nil while a character spawns
	if root then
		approach[root] = root.AssemblyLinearVelocity
	end
end

local function sampleImpactors()
	table.clear(approach)
	for _, player in Players:GetPlayers() do
		track(player.Character and player.Character.PrimaryPart)
	end
	for _, tagged in CollectionService:GetTagged(config.impactorTag) do
		track(tagged)
	end
end

-- Breaks are drained a few per frame; the rest wait in the queue instead of spiking the frame.
local function onHeartbeat()
	for _ = 1, config.maxBreaksPerFrame do
		local d = table.remove(queue, 1)
		if d == nil then
			break
		end
		local ok, err = pcall(executeBreak :: (Destructible) -> any, d)
		if not ok then
			warn(`[Destruction] break failed, part left as is: {err}`)
			d:cleanup()
		end
	end
end

local Destruction = {}
Destruction.config = config
Destruction.Destroyed = destroyedEvent.Event :: RBXScriptSignal<DestroyInfo>

local function registerPart(part: BasePart): Destructible?
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part:IsA("Terrain") or not part:IsDescendantOf(workspace) then
		return nil
	end
	local d = registry[part] or Destructible.new(part)
	registry[part] = d
	return d
end

function Destruction.start()
	if started then
		return
	end
	started = true
	if not PhysicsService:IsCollisionGroupRegistered(config.debrisGroup) then
		PhysicsService:RegisterCollisionGroup(config.debrisGroup)
	end
	PhysicsService:CollisionGroupSetCollidable(config.debrisGroup, config.debrisGroup, false)
	overlap.FilterType, overlap.MaxParts = Enum.RaycastFilterType.Include, 64
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "DestructionDebris", workspace
	debrisFolder = folder
	table.insert(connections, RunService.PreSimulation:Connect(sampleImpactors))
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))
	table.insert(connections, CollectionService:GetInstanceAddedSignal(config.tag):Connect(registerPart :: any))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(config.tag):Connect(function(instance)
		Destruction.unregister(instance :: BasePart)
	end))
	for _, tagged in CollectionService:GetTagged(config.tag) do
		registerPart(tagged :: BasePart)
	end
end

-- Disconnects everything, forgets every part and removes all debris. World geometry is left untouched.
function Destruction.stop()
	if not started then
		return
	end
	started = false
	for _, connection in connections do
		connection:Disconnect()
	end
	for _, d in registry do
		d:cleanup()
	end
	table.clear(connections)
	table.clear(queue)
	table.clear(debris)
	if debrisFolder then
		debrisFolder:Destroy()
		debrisFolder = nil
	end
end

function Destruction.register(part: BasePart): Destructible?
	Destruction.start() -- registering implies the system should be running
	return registerPart(part)
end

function Destruction.unregister(part: BasePart): boolean
	local d = Destruction.get(part)
	if d then
		d:cleanup()
	end
	return d ~= nil
end

-- Read-only view of a part's state (health, maxHealth, state, material); nil if unregistered.
function Destruction.get(part: BasePart): Destructible?
	return if typeof(part) == "Instance" then registry[part] else nil
end

local function okVector(v: any): boolean -- an optional hit field: absent, or a Vector3 with only finite components
	return v == nil or (typeof(v) == "Vector3" and v.Magnitude < math.huge) -- NaN/infinity make the magnitude non-finite
end

-- Explicit server-side hits: speed is derived from the energy and a nominal 10-unit mass. Nil for a malformed call
-- (bad energy, a hit that is not a table, a position/direction that is not a finite Vector3, a NaN or non-number
-- radius), so nothing invalid ever reaches the cut. The radius is clamped to [0.1, maxRadius].
local function explicitImpact(d: Destructible, energy: number, hit: Hit?): Impact?
	local h: any = if hit == nil then {} else hit
	if not (type(energy) == "number" and energy > 0 and energy < math.huge and type(h) == "table") then
		return nil
	end
	local position, direction, radius = h.position, h.direction, h.radius
	if not (okVector(position) and okVector(direction)) or (radius ~= nil and (type(radius) ~= "number" or radius ~= radius)) then
		return nil
	end
	return {
		position = position or d.part.Position,
		direction = if direction then unitOr(direction, Vector3.zero) else Vector3.zero,
		speed = math.min(math.sqrt(2 * energy / 10), config.maxSpeed),
		energy = energy,
		radius = math.clamp(radius or radiusFor(energy, d.maxHealth), 0.1, config.maxRadius),
	}
end

-- Subtracts exactly `amount` from health (no noise gate). True if it queued the break; false, state untouched, for an
-- unregistered part or any invalid argument.
function Destruction.damage(part: BasePart, amount: number, hit: Hit?): boolean
	local d = Destruction.get(part)
	local impact = if d then explicitImpact(d, amount, hit) else nil
	return d ~= nil and impact ~= nil and d:applyDamage(amount, impact)
end

-- Forces a registered part to break now, whatever its remaining health.
function Destruction.destroy(part: BasePart, hit: Hit?): boolean
	local d = Destruction.get(part)
	local impact = if d then explicitImpact(d, math.min(d.maxHealth, 1e9), hit) else nil -- 1e9 keeps an infinite Durability finite
	return d ~= nil and impact ~= nil and d:applyDamage(math.max(d.health, 0), impact)
end

return Destruction
