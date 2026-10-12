-- Discord: theonlykivro | Roblox: Kivro_lol
--!strict
-- DEMO: press E to drop the hanging block onto the wall. Delete this file with the rest of the demo.
local UserInputService = game:GetService("UserInputService")
local remote = game:GetService("ReplicatedStorage"):WaitForChild("DropBlock") :: RemoteEvent

print("[Demo] press E to drop the block")
UserInputService.InputBegan:Connect(function(input, typing)
	if not typing and input.KeyCode == Enum.KeyCode.E then
		remote:FireServer()
	end
end)
