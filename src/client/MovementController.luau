--!strict
--[[
	MovementController
	----------------------------------------------------------------------------
	Client-authoritative locomotion. The default Roblox control module is
	disabled and replaced with this controller so we get:

		* smooth acceleration/deceleration instead of instant WalkSpeed changes
		* a stamina system that gates sprinting
		* crouch / prone stances with proper hitbox resizing
		* parkour: mantling onto ledges and vaulting over waist-high obstacles
		  while sprinting, each with its own animation and a hard movement lock
		* camera-relative movement so W always goes "up the screen"

	The character is moved with Humanoid:Move() plus a manual WalkSpeed ramp;
	Jump is triggered via the humanoid so the engine's own physics handles it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)

local ClientState = require(script.Parent.ClientState)

local MovementController = {}

local M = Config.Movement
local player = Players.LocalPlayer

local controller = {
	humanoid = nil :: Humanoid?,
	root = nil :: BasePart?,
	camera = workspace.CurrentCamera,
	speed = 0,
	verticalVelocity = 0,
	lastGrounded = true,
	airborneTime = 0,
	wasJumping = false,
	regenDelay = 0,
	lockUntil = 0,
	lastMantle = 0,
	jumpHeld = false,
}

local actions = {
	forward = 0,
	backward = 0,
	left = 0,
	right = 0,
	sprint = false,
	crouch = false,
	prone = false,
	jump = false,
}

-- ------------------------------------------------------------------- stance --

local function applyStance(stance: string)
	local humanoid = controller.humanoid
	if not humanoid then
		return
	end
	ClientState.stance = stance
	if stance == "Crouch" then
		humanoid.HipHeight = 1.05
		humanoid.WalkSpeed = M.CrouchSpeed
	elseif stance == "Prone" then
		humanoid.HipHeight = 0.45
		humanoid.WalkSpeed = M.ProneSpeed
	else
		humanoid.HipHeight = 2.0
	end
	if ClientState.animator then
		ClientState.animator:setStance(stance)
	end
	Net.fireServer("RequestStance", stance)
	ClientState.notify()
end

function MovementController.setStance(stance: string)
	if ClientState.isLocked() and stance ~= ClientState.stance then
		return
	end
	applyStance(stance)
end

function MovementController.toggleCrouch()
	if ClientState.stance == "Crouch" then
		applyStance("Stand")
	else
		applyStance("Crouch")
	end
end

function MovementController.toggleProne()
	if ClientState.stance == "Prone" then
		applyStance("Stand")
	else
		applyStance("Prone")
	end
end

-- ------------------------------------------------------------------ stamina --

local function updateStamina(dt: number)
	local stamina = ClientState.stamina
	local moving = controller.speed > 1.5
	local wantSprint = actions.sprint and moving and ClientState.stance == "Stand"
	local grounded = controller.humanoid and controller.humanoid.FloorMaterial ~= Enum.Material.Air

	if ClientState.exhausted and stamina > M.ExhaustedRecover then
		ClientState.exhausted = false
	end

	if wantSprint and grounded and not ClientState.exhausted and stamina > 0 then
		ClientState.sprinting = true
		stamina = math.max(0, stamina - M.SprintDrain * dt)
		controller.regenDelay = M.RegenDelay
		if stamina <= M.ExhaustedThreshold then
			ClientState.exhausted = true
		end
	else
		ClientState.sprinting = false
		controller.regenDelay = math.max(0, controller.regenDelay - dt)
		if controller.regenDelay <= 0 then
			stamina = math.min(M.StaminaMax, stamina + M.RegenRate * dt)
		end
	end

	ClientState.stamina = stamina
	if ClientState.sprinting ~= actions._lastSprint then
		actions._lastSprint = ClientState.sprinting
		Net.fireServer("RequestSprint", ClientState.sprinting)
	end
end

function MovementController.consumeStamina(amount: number)
	ClientState.stamina = math.max(0, ClientState.stamina - amount)
	controller.regenDelay = M.RegenDelay
	if ClientState.stamina <= M.ExhaustedThreshold then
		ClientState.exhausted = true
	end
end

-- ------------------------------------------------------------------- parkour --

--[[
	Probes for a ledge in front of the character. Returns
		(ledgePosition, mantleHeight, isVaultable)
	or nil when there is nothing climbable ahead.
]]
local function probeLedge(): (Vector3?, number, boolean)
	local root = controller.root
	local humanoid = controller.humanoid
	if not root or not humanoid then
		return nil, 0, false
	end

	local moveDir = humanoid.MoveDirection
	local dir = if moveDir.Magnitude > 0.05 then moveDir.Unit else root.CFrame.LookVector
	dir = Vector3.new(dir.X, 0, dir.Z).Unit

	local ignore: { Instance } = {}
	local character = ClientState.character
	if character then
		table.insert(ignore, character)
	end

	-- Probe at three heights to find the ledge lip.
	local baseY = root.Position.Y
	local heights = { 0.5, 1.5, 2.6, 3.8, 5.0, 6.0 }
	local contactHeight: number? = nil
	for _, h in heights do
		local from = Vector3.new(root.Position.X, baseY + h, root.Position.Z)
		local result = Util.raycast(from, dir * M.MantleReach, ignore)
		if result then
			contactHeight = h
			break
		end
	end
	if not contactHeight then
		return nil, 0, false
	end

	-- Now find where the top surface is by casting down just past the wall.
	local aheadX = root.Position.X + dir.X * (M.MantleReach + 0.6)
	local aheadZ = root.Position.Z + dir.Z * (M.MantleReach + 0.6)
	local downOrigin = Vector3.new(aheadX, baseY + M.MantleHeightMax + 2, aheadZ)
	local down = Util.raycastDown(downOrigin, M.MantleHeightMax + 8, ignore)
	if not down then
		return nil, 0, false
	end

	local ledgeY = down.Position.Y
	local climb = ledgeY - baseY
	if climb < M.MantleHeightMin or climb > M.MantleHeightMax then
		return nil, 0, false
	end

	-- Confirm there is headroom on top of the ledge.
	local clearance = Util.raycastDown(
		Vector3.new(aheadX, ledgeY + 6, aheadZ),
		5.2,
		ignore
	)
	if clearance then
		return nil, 0, false
	end

	local target = Vector3.new(aheadX, ledgeY + 0.2, aheadZ)
	return target, climb, climb <= M.VaultMaxHeight
end

local function startParkour(kind: string, target: Vector3, duration: number)
	local root = controller.root
	local humanoid = controller.humanoid
	if not root or not humanoid then
		return
	end

	ClientState.lock("parkour")
	controller.lockUntil = os.clock() + duration
	controller.lastMantle = os.clock()

	local startCF = root.CFrame
	local startPos = root.Position
	local endPos = target
	local peak = math.max(startPos.Y, endPos.Y) + (if kind == "Vault" then 2.4 else 1.2)

	-- Freeze physics during the scripted move.
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false

	local clip = if kind == "Vault" then "Vault" else "Mantle"
	if ClientState.animator then
		ClientState.animator:play(clip, { duration = duration, priority = 30 })
	end
	Net.fireServer("RequestParkour", kind, target)

	local elapsed = 0
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = Util.clamp(elapsed / duration, 0, 1)
		-- Ease in-out for the horizontal travel and a smooth arc vertically.
		local eased = alpha * alpha * (3 - 2 * alpha)
		local arc = math.sin(alpha * math.pi)
		local pos = startPos:Lerp(endPos, eased)
		pos = Vector3.new(pos.X, pos.Y + (peak - math.max(startPos.Y, endPos.Y)) * arc, pos.Z)
		root.CFrame = CFrame.lookAt(pos, Vector3.new(pos.X, pos.Y, pos.Z) + startCF.LookVector)
		if alpha >= 1 then
			connection:Disconnect()
			root.CFrame = CFrame.lookAt(endPos, endPos + startCF.LookVector)
			ClientState.unlock("parkour")
			humanoid.WalkSpeed = M.WalkSpeed
			humanoid.AutoRotate = not ClientState.aiming
			controller.speed = 0
		end
	end)
end

function MovementController.tryParkour()
	local now = os.clock()
	if now - controller.lastMantle < M.ParkourCooldown then
		return false
	end
	if ClientState.isLocked() then
		return false
	end
	local target, _climb, vaultable = probeLedge()
	if not target then
		return false
	end
	local running = controller.speed > 14
	if not vaultable and ClientState.stance ~= "Stand" then
		return false
	end
	if not vaultable and ClientState.stamina < M.MantleCost then
		return false
	end
	MovementController.consumeStamina(if vaultable then M.MantleCost * 0.5 else M.MantleCost)
	startParkour(if vaultable and running then "Vault" else "Mantle", target,
		if vaultable and running then M.VaultDuration else M.MantleDuration)
	return true
end

-- ------------------------------------------------------------------- movement --

local function updateMovement(dt: number)
	local humanoid = controller.humanoid
	local root = controller.root
	if not humanoid or not root then
		return
	end
	if ClientState.isLocked() then
		humanoid:Move(Vector3.zero, false)
		controller.speed = 0
		return
	end

	local moveInput = Vector3.zero
	local camera = workspace.CurrentCamera
	local camLook = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude < 0.01 then
		flatLook = Vector3.new(0, 0, -1)
	end
	flatLook = flatLook.Unit
	local camRight = Vector3.new(-flatLook.Z, 0, flatLook.X)

	if actions.forward > 0 then
		moveInput += flatLook
	end
	if actions.backward > 0 then
		moveInput -= flatLook
	end
	if actions.right > 0 then
		moveInput += camRight
	end
	if actions.left > 0 then
		moveInput -= camRight
	end

	local moving = moveInput.Magnitude > 0.01
	if moving then
		moveInput = moveInput.Unit
	end

	-- Determine the target speed for the current stance + intent.
	local targetSpeed: number
	if ClientState.stance == "Prone" then
		targetSpeed = M.ProneSpeed
	elseif ClientState.stance == "Crouch" then
		targetSpeed = M.CrouchSpeed
	elseif ClientState.sprinting then
		targetSpeed = M.SprintSpeed
	else
		targetSpeed = M.WalkSpeed
	end
	if not moving then
		targetSpeed = 0
	end

	-- Ramp the speed so acceleration and braking feel weighty.
	local ramp = if targetSpeed > controller.speed then M.SpeedAccel else M.SpeedDecel
	controller.speed = Util.damp(controller.speed, targetSpeed, ramp, dt)
	if math.abs(controller.speed - targetSpeed) < 0.1 then
		controller.speed = targetSpeed
	end

	humanoid.WalkSpeed = math.max(controller.speed, 0.01)
	humanoid:Move(moveInput, false)

	-- Facing. The engine's own auto-rotate produces the smoothest turn, so it
	-- stays on while the character is travelling. When aiming (or standing
	-- still while aiming) we take over and rotate the torso toward the camera,
	-- which is what gives the "strafe while aiming" feel.
	local aiming = ClientState.aiming
	humanoid.AutoRotate = not aiming
	if aiming then
		local face = flatLook
		if not moving and camLook.Magnitude > 0.01 then
			face = Vector3.new(camLook.X, 0, camLook.Z)
			if face.Magnitude < 0.01 then
				face = flatLook
			end
			face = face.Unit
		end
		local desired = CFrame.lookAt(root.Position, root.Position + face)
		local current = root.CFrame
		local alpha = 1 - math.exp(-14 * dt)
		local blended = current:Lerp(desired, alpha)
		-- Rotation only: the position comes from the physics solver, so we never
		-- fight it.
		root.CFrame = CFrame.new(current.Position) * (blended - blended.Position)
	end

	if ClientState.animator then
		ClientState.animator:setMotion(controller.speed, moving)
	end
end

--[[
	Auto-parkour: when sprinting into an obstacle, try to vault. Also runs the
	"press Space near a ledge" mantle.
]]
local function updateParkour(dt: number)
	local humanoid = controller.humanoid
	if not humanoid or ClientState.isLocked() then
		return
	end

	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local moving = controller.speed > 3

	-- Blocked while running -> auto vault.
	if moving and controller.speed > 12 and grounded then
		local root = controller.root
		if root then
			local moveDir = humanoid.MoveDirection
			if moveDir.Magnitude > 0.1 then
				local ignore: { Instance } = {}
				if ClientState.character then
					table.insert(ignore, ClientState.character)
				end
				local from = root.Position + Vector3.new(0, 1.2, 0)
				local result = Util.raycast(from, moveDir.Unit * 2.6, ignore)
				if result then
					MovementController.tryParkour()
				end
			end
		end
	end
	local _ = dt
end

--[[
	Detects landing so the landing-absorb clip plays on touchdown.
]]
local function updateAirborne(dt: number)
	local humanoid = controller.humanoid
	if not humanoid then
		return
	end
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if not grounded then
		controller.airborneTime += dt
		if controller.airborneTime > 0.18 and ClientState.animator then
			if controller.airborneTime < 0.6 then
				ClientState.animator:play("Jump", { duration = 0.5, priority = 20 })
			else
				ClientState.animator:play("Fall", { duration = 0.6, priority = 20 })
			end
		end
	elseif not controller.lastGrounded and controller.airborneTime > 0.25 then
		if ClientState.animator then
			ClientState.animator:play("Land", { duration = 0.4, priority = 22 })
		end
		controller.airborneTime = 0
	end
	controller.lastGrounded = grounded
end

-- -------------------------------------------------------------------- input --

local function bindInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or ClientState.isLocked() then
			return
		end
		if input.KeyCode == Config.Keys.Sprint then
			actions.sprint = true
		elseif input.KeyCode == Config.Keys.Crouch then
			MovementController.toggleCrouch()
		elseif input.KeyCode == Config.Keys.Prone then
			MovementController.toggleProne()
		elseif input.KeyCode == Config.Keys.SwapShoulder then
			ClientState.shoulderSide = -ClientState.shoulderSide
			local Camera = ClientState.sibling("CameraController")
			if Camera then
				Camera.swapShoulder()
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Config.Keys.Sprint then
			actions.sprint = false
		end
	end)
end

--[[
	Polls the WASD state directly from the engine each frame; this is more
	reliable than tracking key events and matches what the default control module
	does internally.
]]
local function pollMoveKeys(): (number, number, number, number)
	local f, b, l, r = 0, 0, 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		f = 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		b = 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		l = 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		r = 1
	end
	return f, b, l, r
end

-- --------------------------------------------------------------------- start --

function MovementController.start()
	local character = player.Character or player.CharacterAdded:Wait()
	ClientState.setCharacter(character)

	player.CharacterAdded:Connect(function(newCharacter)
		ClientState.setCharacter(newCharacter)
		ClientState.stamina = M.StaminaMax
		ClientState.exhausted = false
		applyStance("Stand")
		task.wait(0.1)
		controller.humanoid = newCharacter:FindFirstChildOfClass("Humanoid")
		controller.root = newCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if controller.humanoid then
			controller.humanoid.AutoRotate = false
			controller.humanoid.UseJumpPower = true
			controller.humanoid.JumpPower = M.JumpPower
		end
		if ClientState.animator then
			ClientState.animator:refresh()
		end
	end)

	controller.humanoid = character:FindFirstChildOfClass("Humanoid")
	controller.root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if controller.humanoid then
		controller.humanoid.AutoRotate = false
		controller.humanoid.UseJumpPower = true
		controller.humanoid.JumpPower = M.JumpPower
	end

	bindInput()

	RunService.RenderStepped:Connect(function(dt)
		if not ClientState.isAlive() then
			return
		end
		local f, b, l, r = pollMoveKeys()
		actions.forward, actions.backward, actions.left, actions.right = f, b, l, r

		updateStamina(dt)
		updateMovement(dt)
		updateParkour(dt)
		updateAirborne(dt)

		-- Track grass / visibility locally for the HUD. The server recomputes
		-- this authoritatively for the AI; this is display only.
		local root = controller.root
		if root then
			local volumes = CollectionService:GetTagged("Grass")
			local inGrass = false
			for _, volume in volumes do
				if volume:IsA("BasePart") and volume.Parent then
					local lp = volume.CFrame:PointToObjectSpace(root.Position)
					local half = volume.Size * 0.5
					if math.abs(lp.X) <= half.X and math.abs(lp.Z) <= half.Z and math.abs(lp.Y) <= half.Y then
						inGrass = true
						break
					end
				end
			end
			ClientState.inGrass = inGrass
		end
	end)

	-- Jump / parkour are handled on a separate input hook so they can run even
	-- when the default control module would otherwise consume Space.
	UserInputService.JumpRequest:Connect(function()
		if ClientState.isLocked() then
			return
		end
		local humanoid = controller.humanoid
		if not humanoid then
			return
		end
		if MovementController.tryParkour() then
			return
		end
		if humanoid.FloorMaterial ~= Enum.Material.Air and ClientState.stamina > 5 then
			MovementController.consumeStamina(M.JumpCost)
			humanoid.Jump = true
			if ClientState.sprinting and controller.root then
				local root = controller.root
				root.AssemblyLinearVelocity = root.AssemblyLinearVelocity
					+ root.CFrame.LookVector * M.RunJumpBoost
			end
		end
	end)
end

return MovementController
