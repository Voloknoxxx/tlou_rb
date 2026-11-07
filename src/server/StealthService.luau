--!strict
--[[
	StealthService
	----------------------------------------------------------------------------
	Authoritative per-player concealment state. The client reports its stance and
	whether it is sprinting (cheap, and it is not worth a round trip to detect);
	the server independently computes grass containment from the world geometry,
	which is the part that actually matters for balance.

	Outputs, exposed to the zombie AI:
		state.stance        "Stand" | "Crouch" | "Prone"
		state.inGrass       boolean
		state.sprinting     boolean
		state.visibility    0..1  (1 = fully exposed)
		state.noiseRadius   studs
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net)
local Stealth = require(ReplicatedStorage.Shared.Stealth)

local NoiseBus = require(script.Parent.NoiseBus)

local StealthService = {}

export type PlayerState = {
	player: Player,
	stance: string,
	sprinting: boolean,
	inGrass: boolean,
	visibility: number,
	noiseRadius: number,
	lastNoise: number,
	root: BasePart?,
	noiseClock: number,
}

local states: { [Player] : PlayerState } = {}
local grassVolumes: { BasePart } = {}

local function collectGrass()
	grassVolumes = {}
	for _, inst in CollectionService:GetTagged("Grass") do
		if inst:IsA("BasePart") then
			table.insert(grassVolumes, inst)
		end
	end
end

--[[
	Point-in-box test against every grass volume. The clumps are few hundred
	anchored parts so a linear scan with a cheap AABB rejection is plenty fast.
]]
local function isInGrass(position: Vector3): boolean
	for _, volume in grassVolumes do
		if not volume.Parent then
			continue
		end
		local localPos = volume.CFrame:PointToObjectSpace(position)
		local half = volume.Size * 0.5
		if math.abs(localPos.X) <= half.X and math.abs(localPos.Z) <= half.Z then
			local y = position.Y - volume.Position.Y
			if math.abs(y) <= half.Y then
				return true
			end
		end
	end
	return false
end

function StealthService.getState(player: Player): PlayerState?
	return states[player]
end

function StealthService.getStateForCharacter(character: Model): PlayerState?
	for _, state in states do
		if state.player.Character == character then
			return state
		end
	end
	return nil
end

function StealthService.setStance(player: Player, stance: string)
	local state = states[player]
	if state then
		state.stance = stance
	end
end

function StealthService.setSprinting(player: Player, sprinting: boolean)
	local state = states[player]
	if state then
		state.sprinting = sprinting
	end
end

local function onPlayerAdded(player: Player)
	states[player] = {
		player = player,
		stance = "Stand",
		sprinting = false,
		inGrass = false,
		visibility = 1,
		noiseRadius = 0,
		lastNoise = 0,
		root = nil,
		noiseClock = 0,
	}
end

local function onPlayerRemoving(player: Player)
	states[player] = nil
end

--[[
	Rebuilds grass volumes once the world builder has finished. Called explicitly
	by the bootstrap after WorldBuilder.build().
]]
function StealthService.refreshWorld()
	collectGrass()
end

local accumulator = 0

local function step(dt: number)
	accumulator += dt
	if accumulator < 0.1 then
		return
	end
	accumulator = 0

	for _, state in states do
		local character = state.player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			state.root = nil
			continue
		end
		state.root = root
		state.inGrass = isInGrass(root.Position)

		local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
		state.noiseRadius = Stealth.noiseRadius(state.stance, speed, state.inGrass)
		state.visibility = Stealth.visibilityScore(state.stance, state.inGrass, state.sprinting)

		-- Emit footstep noise on a cadence tied to speed.
		if speed > 1.5 then
			state.noiseClock += dt
			local cadence = if state.sprinting then 0.34 else 0.52
			if state.noiseClock >= cadence and state.noiseRadius > 0 then
				state.noiseClock = 0
				NoiseBus.emit(root.Position, state.noiseRadius, "Footstep", root, state.player)
			end
		end
	end
end

function StealthService.start()
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Client reports stance + sprint; server trusts stance (it only affects
	-- stealth and animation) but clamps it to the known set.
	Net.onServerEvent("RequestStance", function(player: Player, stance: any)
		local value = Net.validString(stance, 12)
		if value ~= "Stand" and value ~= "Crouch" and value ~= "Prone" then
			return
		end
		StealthService.setStance(player, value)
	end)

	Net.onServerEvent("RequestSprint", function(player: Player, on: any)
		local value = Net.validBool(on)
		if value ~= nil then
			StealthService.setSprinting(player, value)
		end
	end)

	RunService.Heartbeat:Connect(step)
	collectGrass()
end

return StealthService
