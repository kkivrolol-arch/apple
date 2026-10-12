-- Discord: theonlykivro | Roblox: Kivro_lol
--!strict
-- DEMO: releases the hanging block when a player presses E (see DropOnE.client). The client sends nothing but "E was
-- pressed", so the only thing a forged request can do is release the block once, which is exactly what E does.
local remote = game:GetService("ReplicatedStorage"):WaitForChild("DropBlock") :: RemoteEvent
local block = workspace:WaitForChild("DestructionTest"):WaitForChild("TestShot") :: BasePart

remote.OnServerEvent:Connect(function()
	if not block.Anchored then
		return -- already dropped
	end
	block.Anchored = false
	block:SetNetworkOwner(nil) -- keep it server-simulated, so its impact is measured from server physics
end)
