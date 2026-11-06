--!strict
--[[
	MovementController
	The Last of Us movement feel: a heavy, deliberate walk, a limited
	sprint that burns stamina, crouch-walking, prone crawling, and
	contextual vault/climb over low obstacles.

	Design notes:
	* Walk speed is intentionally slow (14). TLoU is about weight, not
	  speed. Sprint is a burst, not a travel mode.
	* Stamina is predicted locally and reconciled by the server so the
	  bar feels instant but cannot be cheated.
	* Crouch and prone no longer touch the Humanoid. On R6 the Humanoid's
	  HipHeight must stay at 0 - raising it lifts the whole character off
	  the floor. Instead the *animator* lowers the torso, so the silhouette
	  drops while the physics stays honest. That also means the crouch
	  pose replicates to every client for free.
	* Vaulting detects a ledge in front of the player and plays a short
	  arc over it instead of the Roblox default mantle.

	Every state change is mirrored onto the character as an attribute.
	Attributes replicate automatically, so the animator on every other
	client can pose this character without any custom networking.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Net = require(Shared.Net)

local State = require(script.Parent.State)

local MovementController = {}

local player = Players.LocalPlayer
local M = Config.Movement

-- Input snapshot -------------------------------------------------------
local input = {
	sprintHeld = false,
	crouchHeld = false,
	leanLeft = false,
	leanRight = false,
}

-- Runtime --------------------------------------------------------------
local lastDrainAt = 0
local stateSyncAccumulator = 0
local STATE_SYNC_INTERVAL = 1 / 20

local vaultConnection: RBXScriptConnection?
local leanTarget = 0
local currentLean = 0

local function isMoving(): boolean
	local humanoid = State.humanoid
	if not humanoid then
		return false
	end
	return humanoid.MoveDirection.Magnitude > 0.1
end

local function canSprint(): boolean
	return State.stance == "Stand"
		and not State.exhausted
		and State.grounded
		and not State.vaulting
		and not State.aiming
end

--- Mirrors the current state onto the character so every client's animator
--- can read it without extra remote traffic. Only writes on change: an
--- attribute assignment is cheap but still replicates, and this runs every
--- frame.
local published: { [string]: any } = {}

local function publishAttribute(character: Model, name: string, value: any)
	if published[name] ~= value then
		published[name] = value
		character:SetAttribute(name, value)
	end
end

local function publishAttributes()
	local character = State.character
	if not character then
		return
	end
	publishAttribute(character, "Stance", State.stance)
	publishAttribute(character, "Sprinting", State.sprinting)
	publishAttribute(character, "Aiming", State.aiming)
	publishAttribute(character, "Vaulting", State.vaulting)
	-- Quantised: lean is a continuously moving float, and replicating it
	-- every frame for a cosmetic camera shift is not worth the traffic.
	publishAttribute(character, "Lean", math.floor(currentLean * 20 + 0.5) / 20)
end

--- Sends the authoritative-ish state to the server (throttled).
local function syncState()
	Net.toServer("StateUpdate", {
		stance = State.stance,
		sprinting = State.sprinting,
		lean = currentLean,
		stamina = State.stamina,
	})
end

local function applyStanceToHumanoid()
	local humanoid = State.humanoid
	if not humanoid then
		return
	end

	if State.downed then
		humanoid.WalkSpeed = 0
		return
	end

	local speed = M.WalkSpeed
	if State.stance == "Crouch" then
		speed = M.CrouchSpeed
	elseif State.stance == "Prone" then
		speed = M.ProneSpeed
	elseif State.sprinting then
		speed = M.SprintSpeed
	end

	-- Aiming slows you down to a steady walk.
	if State.aiming and State.stance == "Stand" then
		speed = math.min(speed, M.WalkSpeed * 0.7)
	end

	humanoid.WalkSpeed = speed
	-- R6 keeps HipHeight at 0; the animator supplies the crouch and prone
	-- drop so the character never floats.
	humanoid.HipHeight = 0
end

--- Tries to find a vaultable ledge directly in front of the player.
local function findVaultTarget(): (Vector3?, number)
	local root = State.rootPart
	local humanoid = State.humanoid
	if not root or not humanoid then
		return nil, 0
	end

	local origin = root.Position
	local look = root.CFrame.LookVector

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { State.character :: any }
	params.IgnoreWater = true

	local forwardHit = workspace:Raycast(origin + Vector3.new(0, 1, 0), look * 3, params)
	if not forwardHit then
		return nil, 0
	end

	local downHit = workspace:Raycast(
		forwardHit.Position + look * 0.6 + Vector3.new(0, 6, 0),
		Vector3.new(0, -14, 0),
		params
	)
	if not downHit then
		return nil, 0
	end

	local height = downHit.Position.Y - origin.Y
	if height < M.VaultMinHeight or height > M.VaultMaxHeight then
		return nil, 0
	end

	local clearance = workspace:Raycast(downHit.Position + Vector3.new(0, 3, 0), Vector3.new(0, 5, 0), params)
	if clearance then
		return nil, 0
	end

	return downHit.Position + look * 2.2, height
end

--- Animated vault: a short arc from the current position to the landing.
local function startVault(landing: Vector3, height: number)
	local root = State.rootPart
	local humanoid = State.humanoid
	if not root or not humanoid or State.vaulting then
		return
	end

	State.vaulting = true
	publishAttributes()
	-- Physics state stops the Humanoid from fighting the root CFrame we set
	-- every frame; we hand control back on landing.
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	local startPosition = root.Position
	local duration = math.clamp(height / M.VaultSpeed, 0.25, 0.6)
	local elapsed = 0

	if vaultConnection then
		vaultConnection:Disconnect()
	end

	vaultConnection = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / duration, 0, 1)

		if not root.Parent then
			vaultConnection:Disconnect()
			vaultConnection = nil
			State.vaulting = false
			return
		end

		local flat = startPosition:Lerp(landing, alpha)
		local arc = math.sin(alpha * math.pi) * math.max(height * 0.6, 1.5)
		local target = Vector3.new(flat.X, flat.Y + arc, flat.Z)

		local current = root.CFrame
		root.CFrame = CFrame.new(target) * (current - current.Position)

		if alpha >= 1 then
			vaultConnection:Disconnect()
			vaultConnection = nil
			State.vaulting = false
			publishAttributes()
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end)
end

--- Central per-frame movement update.
local function update(dt: number)
	local humanoid = State.humanoid
	if not humanoid or not State.character or not State.character.Parent then
		return
	end

	State.grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	State.moveSpeed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed

	-- Stamina ---------------------------------------------------------
	local draining = false
	if State.sprinting and isMoving() then
		State.stamina -= M.StaminaDrainSprint * dt
		draining = true
		lastDrainAt = os.clock()
	elseif os.clock() - lastDrainAt > M.StaminaRegenDelay then
		State.stamina += M.StaminaRegen * dt
	end
	State.stamina = math.clamp(State.stamina, 0, M.MaxStamina)

	if State.stamina <= M.ExhaustedThreshold then
		State.exhausted = true
	elseif State.stamina > M.MaxStamina * 0.35 then
		State.exhausted = false
	end

	-- Sprint gating ---------------------------------------------------
	if State.sprinting and not canSprint() then
		State.sprinting = false
	end
	if not input.sprintHeld and State.sprinting then
		State.sprinting = false
	end

	-- Lean ------------------------------------------------------------
	leanTarget = 0
	if input.leanLeft and not input.leanRight then
		leanTarget = -1
	elseif input.leanRight and not input.leanLeft then
		leanTarget = 1
	end
	currentLean += (leanTarget - currentLean) * math.min(1, M.LeanSpeed * dt)
	State.lean = currentLean

	applyStanceToHumanoid()
	publishAttributes()

	-- Throttled server sync -------------------------------------------
	stateSyncAccumulator += dt
	if stateSyncAccumulator >= STATE_SYNC_INTERVAL then
		stateSyncAccumulator = 0
		syncState()
	end
end

-- Input handling -------------------------------------------------------
local function bindInput()
	-- Take over the jump key entirely so we can decide between vaulting
	-- over a ledge and a normal jump. Binding at a high priority sinks
	-- Roblox's default jump action before it can run.
	ContextActionService:BindActionAtPriority("TLoUJump", function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if State.stance ~= "Stand" or State.vaulting or State.downed then
			return Enum.ContextActionResult.Sink
		end
		local landing, height = findVaultTarget()
		if landing and height then
			startVault(landing, height)
			return Enum.ContextActionResult.Sink
		end
		if State.grounded and State.humanoid then
			State.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, 3000, Enum.KeyCode.Space)

	UserInputService.InputBegan:Connect(function(inputObject, processed)
		if processed then
			return
		end

		if inputObject.KeyCode == Config.Keys.Sprint then
			input.sprintHeld = true
			if canSprint() then
				State.sprinting = true
			end
		elseif inputObject.KeyCode == Config.Keys.Crouch then
			input.crouchHeld = true
			if State.stance == "Stand" then
				State.setStance("Crouch")
			elseif State.stance == "Crouch" then
				State.setStance("Stand")
			end
		elseif inputObject.KeyCode == Config.Keys.Prone then
			if State.stance == "Prone" then
				State.setStance("Crouch")
			else
				State.setStance("Prone")
			end
		elseif inputObject.KeyCode == Config.Keys.LeanLeft then
			input.leanLeft = true
		elseif inputObject.KeyCode == Config.Keys.LeanRight then
			input.leanRight = true
		end
	end)

	UserInputService.InputEnded:Connect(function(inputObject)
		if inputObject.KeyCode == Config.Keys.Sprint then
			input.sprintHeld = false
			State.sprinting = false
		elseif inputObject.KeyCode == Config.Keys.Crouch then
			input.crouchHeld = false
		elseif inputObject.KeyCode == Config.Keys.LeanLeft then
			input.leanLeft = false
		elseif inputObject.KeyCode == Config.Keys.LeanRight then
			input.leanRight = false
		end
	end)
end

function MovementController.init()
	bindInput()

	RunService.Heartbeat:Connect(update)

	-- Bind to the local character as it spawns.
	local function onCharacter(character: Model)
		State.character = character
		State.humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		State.rootPart = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		State.head = character:WaitForChild("Head", 5) :: BasePart?

		State.stamina = M.MaxStamina
		State.setStance("Stand")
		State.sprinting = false

		if State.humanoid then
			State.humanoid.UseJumpPower = true
			State.humanoid.JumpPower = M.JumpPower
			-- Facing is camera-driven, so auto-rotate stays off.
			State.humanoid.AutoRotate = false
			State.humanoid.WalkSpeed = M.WalkSpeed
			State.humanoid.HipHeight = 0
		end

		publishAttributes()
		State.Signals.CharacterChanged:Fire(character)
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end

	-- Keep the replicated attributes in step with aiming, which is toggled
	-- by the weapon controller.
	State.Signals.EquippedChanged:Connect(publishAttributes)
end

return MovementController
