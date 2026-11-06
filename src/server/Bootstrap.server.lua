--!strict
--[[
	Bootstrap (ServerScriptService)
	Wires the server services in dependency order and disables the
	default Roblox character controls that would fight our movement
	controller (camera-relative sprint, the built-in shift-to-sprint).

	Put this in ServerScriptService as a Script. It requires the sibling
	"Modules" folder placed next to it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Net = require(Shared.Net)
local Config = require(Shared.Config)
local Weapons = require(Shared.Weapons)

local Modules = script.Parent:WaitForChild("Modules")
local CombatService = require(Modules:WaitForChild("CombatService"))
local MovementService = require(Modules:WaitForChild("MovementService"))
local InventoryService = require(Modules:WaitForChild("InventoryService"))
local RigService = require(Modules:WaitForChild("RigService"))

-- Turn off Roblox's default movement conveniences that conflict with ours.
StarterPlayer.EnableMouseLockOption = false
StarterPlayer.CharacterWalkSpeed = Config.Movement.WalkSpeed
StarterPlayer.CharacterJumpPower = Config.Movement.JumpPower
StarterPlayer.CameraMode = Enum.CameraMode.Classic
-- The pack animates and controls the character itself, so Roblox's
-- auto-loaded character appearance (R15 avatars, layered clothing) is off.
StarterPlayer.LoadCharacterAppearance = false

-- Start the services. RigService goes first: it guarantees an R6 body
-- before anything else looks at the character's parts.
RigService.init()
InventoryService.init()
MovementService.init()
CombatService.init()

-- We run our own health model (so players enter a "downed" state instead
-- of dying instantly). Give the Humanoid a huge pool so only our explicit
-- kill call can ever trigger Died, and hide the default health bar.
local StarterGui = game:GetService("StarterGui")
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

local HUMAN_DUMMY_HEALTH = 1e6

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if humanoid then
			humanoid.MaxHealth = HUMAN_DUMMY_HEALTH
			humanoid.Health = HUMAN_DUMMY_HEALTH
			humanoid.BreakJointsOnDeath = false
			humanoid.HealthDisplayDistance = 0
			humanoid.NameDisplayDistance = 0
		end
		task.wait(0.5)
		Net.toPlayer(player, "Health", Config.Combat.MaxHealth, false)
	end)
end)

-- Simple visual: dropped weapons stay in the world briefly on death.
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if not humanoid then
			return
		end
		humanoid.Died:Connect(function()
			if Config.Inventory.DropOnDeath then
				local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					local model = Instance.new("Model")
					model.Name = "DroppedWeapon"
					model.Parent = workspace
					local drop = Instance.new("Part")
					drop.Size = Vector3.new(1.5, 0.4, 0.4)
					drop.Color = Color3.fromRGB(40, 40, 44)
					drop.Material = Enum.Material.Metal
					drop.CanCollide = true
					drop.CFrame = root.CFrame * CFrame.new(0, 0, -2)
					drop.Parent = model
					model.PrimaryPart = drop
					task.delay(30, function()
						model:Destroy()
					end)
				end
			end
		end)
	end)
end)

print("[TLoU] Server mechanics online.")
