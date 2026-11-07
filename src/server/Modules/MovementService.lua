--!strict
--[[
	MovementService
	Server half of the movement system. The client owns the feel (sprint,
	crouch, lean, vault), but the server validates the expensive parts and
	keeps an authoritative record of each player's stance so other systems
	(stealth, noise, combat) can read it.

	Validation strategy: we never reject a stance outright, we just clamp
	it to what the player's current stats allow (e.g. no sprinting while
	exhausted, no proning in mid-air).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Net = require(Shared.Net)

local MovementService = {}

export type Stance = "Stand" | "Crouch" | "Prone"

export type MoveState = {
	stance: Stance,
	sprinting: boolean,
	lean: number, -- -1 left .. 1 right
	exhausted: boolean,
	stamina: number,
}

-- player -> authoritative state
local states: { [Player]: MoveState } = {}

local STANCE_SPEEDS = {
	Stand = Config.Movement.WalkSpeed,
	Crouch = Config.Movement.CrouchSpeed,
	Prone = Config.Movement.ProneSpeed,
}

local function defaultState(): MoveState
	return {
		stance = "Stand",
		sprinting = false,
		lean = 0,
		exhausted = false,
		stamina = Config.Movement.MaxStamina,
	}
end

function MovementService.init()
	Net.get("StateUpdate").OnServerEvent:Connect(function(player: Player, payload)
		MovementService.handleState(player, payload)
	end)

	local function registerPlayer(player: Player)
		states[player] = states[player] or defaultState()
		player.CharacterAdded:Connect(function(character)
			MovementService.applyToCharacter(player, character)
		end)
		if player.Character then
			MovementService.applyToCharacter(player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(registerPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		registerPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	-- Periodic stamina reconciliation and movement noise emission. The
	-- client predicts stamina for responsiveness; the server is the source
	-- of truth and gently corrects drift. Movement noise is emitted here
	-- because it depends on the authoritative stance, not on client claims.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for player, state in pairs(states) do
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					local drain = 0
					if state.sprinting and humanoid.MoveDirection.Magnitude > 0.1 then
						drain = Config.Movement.StaminaDrainSprint * 0.5
					end
					state.stamina = math.clamp(state.stamina - drain + (drain == 0 and Config.Movement.StaminaRegen * 0.5 or 0), 0, Config.Movement.MaxStamina)
					state.exhausted = state.stamina <= Config.Movement.ExhaustedThreshold
					if state.exhausted and state.sprinting then
						state.sprinting = false
					end

					-- Movement noise: how loud the player currently is.
					if humanoid.MoveDirection.Magnitude > 0.1 and humanoid.FloorMaterial ~= Enum.Material.Air then
						local radius
						if state.stance == "Prone" then
							radius = Config.Combat.Noise.Prone
						elseif state.stance == "Crouch" then
							radius = Config.Combat.Noise.Crouch
						elseif state.sprinting then
							radius = Config.Combat.Noise.Sprint
						else
							radius = Config.Combat.Noise.Walk
						end
						if radius > 0 then
							local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
							if root then
								Net.toAll("Noise", root.Position, radius, player.UserId)
							end
						end
					end
				end
			end
		end
	end)
end

function MovementService.applyToCharacter(player: Player, character: Model)
	local state = states[player] or defaultState()
	states[player] = state

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then
		return
	end

	-- The character's facing is driven by the camera controller, so the
	-- Humanoid's own auto-rotate must stay off to avoid the two fighting
	-- each other.
	humanoid.UseJumpPower = true
	humanoid.JumpPower = Config.Movement.JumpPower
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = MovementService.speedFor(state)
end

function MovementService.speedFor(state: MoveState): number
	local base = STANCE_SPEEDS[state.stance] or Config.Movement.WalkSpeed
	if state.stance == "Stand" and state.sprinting and not state.exhausted then
		base = Config.Movement.SprintSpeed
	end
	return base
end

function MovementService.handleState(player: Player, payload)
	if typeof(payload) ~= "table" then
		return
	end
	local state = states[player]
	if not state then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	-- A downed player is frozen until revived or dead. CombatService marks
	-- the character with a "Downed" attribute so this module does not need
	-- a direct dependency on it.
	if character:GetAttribute("Downed") then
		humanoid.WalkSpeed = 0
		return
	end

	local requested = payload.stance
	if requested == "Stand" or requested == "Crouch" or requested == "Prone" then
		-- Cannot go prone in mid-air; fall back to crouch.
		if requested == "Prone" and humanoid.FloorMaterial == Enum.Material.Air then
			requested = "Crouch"
		end
		state.stance = requested
	end

	if typeof(payload.lean) == "number" then
		state.lean = math.clamp(payload.lean, -1, 1)
	end

	local wantsSprint = payload.sprinting == true
	state.sprinting = wantsSprint
		and state.stance == "Stand"
		and not state.exhausted
		and humanoid.MoveDirection.Magnitude > 0.1

	-- The owning client drives WalkSpeed (it predicts stance changes every
	-- frame). We only clamp here so a modified client cannot move faster
	-- than its stance allows. Writing the exact value would fight the
	-- client's per-frame update and cause visible speed jitter.
	local maxSpeed = MovementService.speedFor(state)
	if humanoid.WalkSpeed > maxSpeed + 1 then
		humanoid.WalkSpeed = maxSpeed
	end
end

function MovementService.getState(player: Player): MoveState?
	return states[player]
end

function MovementService.setStamina(player: Player, value: number)
	local state = states[player]
	if state then
		state.stamina = math.clamp(value, 0, Config.Movement.MaxStamina)
		state.exhausted = state.stamina <= Config.Movement.ExhaustedThreshold
	end
end

return MovementService
