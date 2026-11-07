--!strict
--[[
	Bootstrap (server)
	----------------------------------------------------------------------------
	Wires the whole game together in the correct order:

		1. create the remote-event layer
		2. build the world
		3. populate loot and grass-aware systems
		4. start the gameplay services
		5. spawn the initial infected population

	Re-running (e.g. pressing Play again in Studio) is safe: the world builder
	destroys any previously generated world first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)

local WorldBuilder = require(script.Parent.WorldBuilder)
local NoiseBus = require(script.Parent.NoiseBus)
local StealthService = require(script.Parent.StealthService)
local InventoryService = require(script.Parent.InventoryService)
local InteractionService = require(script.Parent.InteractionService)
local CombatService = require(script.Parent.CombatService)
local ZombieService = require(script.Parent.ZombieService)

local function configurePlayers()
	for _, player in Players:GetPlayers() do
		player.CharacterWalkSpeed = Config.Movement.WalkSpeed
	end
	Players.PlayerAdded:Connect(function(player)
		player.CharacterWalkSpeed = Config.Movement.WalkSpeed
		player.CharacterJumpPower = Config.Movement.JumpPower
		player.CharacterAutoLoads = true
		player.CameraMode = Enum.CameraMode.Classic
	end)

	-- Apply to existing characters too.
	local function apply(player: Player, character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			humanoid.WalkSpeed = Config.Movement.WalkSpeed
			humanoid.UseJumpPower = true
			humanoid.JumpPower = Config.Movement.JumpPower
			humanoid.BreakJointsOnDeath = false
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			apply(player, character)
		end)
		if player.Character then
			apply(player, player.Character)
		end
	end)
	for _, player in Players:GetPlayers() do
		if player.Character then
			apply(player, player.Character)
		end
	end
end

local function main()
	Net.initServer()
	configurePlayers()

	if Config.World.BuildOnStart then
		print("[LastStand] building world...")
		WorldBuilder.build()
	end

	StealthService.refreshWorld()
	InteractionService.populateLoot()

	StealthService.start()
	InventoryService.start()
	InteractionService.start()
	CombatService.start()
	ZombieService.start()

	ZombieService.spawnInitialPopulation()

	print(("[LastStand] ready - %d infected active"):format(ZombieService.count()))
	local _ = NoiseBus
end

main()
