--!strict
--[[
	CameraController
	The Last of Us camera: a tight over-the-shoulder third person that the
	mouse drives directly.

	How it behaves
	--------------
	* The camera orbits a pivot above the character's root. Mouse X turns the
	  orbit; mouse Y pitches it. The body yaws to follow the orbit, with a
	  little lag so turns have weight.
	* The camera sits offset to the character's right shoulder, and pulls in
	  tighter over the shoulder when aiming.
	* Sprinting widens the FOV; aiming narrows it.
	* Recoil is a spring that kicks the aim up and back, then recovers.
	* Leaning shifts the camera sideways so you can peek around cover.
	* Collision pulls the camera in so it never ends up inside a wall.

	Because the body follows the camera, the character's own animator sees a
	real turn rate every frame - which is what drives turn-in-place stepping.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Util = require(Shared.Util)
local AnimationSystem = require(Shared.AnimationSystem)

local State = require(script.Parent.State)

local CameraController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local C = Config.Camera

-- Orbit state ----------------------------------------------------------
local yaw = 0
local pitch = 0
local currentShoulder = C.ShoulderOffset
local currentDistance = C.Distance
local currentFOV = C.FOV

-- Bob / sway -----------------------------------------------------------
local bobPhase = 0
local swayOffset = Vector2.new(0, 0)

-- Recoil spring --------------------------------------------------------
local recoilPitch = 0
local recoilYaw = 0
local recoilPitchVelocity = 0
local recoilYawVelocity = 0

-- Shake ----------------------------------------------------------------
local shakeTime = 0
local shakeIntensity = 0

-- Body follow ----------------------------------------------------------
-- The body's yaw lags the camera slightly. The difference between the two
-- is the turn rate the animator uses to decide when to step in place.
local bodyYaw = 0

local function updateSpring(dt: number)
	local stiffness = C.RecoilRecovery
	local damping = 2 * math.sqrt(stiffness) * 0.6

	recoilPitchVelocity += (-stiffness * recoilPitch - damping * recoilPitchVelocity) * dt
	recoilYawVelocity += (-stiffness * recoilYaw - damping * recoilYawVelocity) * dt

	recoilPitch = math.clamp(recoilPitch + recoilPitchVelocity * dt, -C.MaxRecoil, C.MaxRecoil)
	recoilYaw = math.clamp(recoilYaw + recoilYawVelocity * dt, -C.MaxRecoil, C.MaxRecoil)

	State.recoil = Vector2.new(recoilPitch, recoilYaw)
end

local function addRecoil(pitchKick: number, yawKick: number)
	recoilPitchVelocity -= pitchKick
	recoilYawVelocity += yawKick
end

local function addShake(intensity: number, duration: number)
	shakeIntensity = math.max(shakeIntensity, intensity)
	shakeTime = math.max(shakeTime, duration)
end

local function update(dt: number)
	local character = State.character
	local root = State.rootPart
	local humanoid = State.humanoid
	if not character or not root or not humanoid then
		return
	end

	-- Mouse drives the orbit -------------------------------------------
	local mouseDelta = UserInputService:GetMouseDelta()
	yaw -= mouseDelta.X * 0.0025
	pitch = math.clamp(
		pitch - mouseDelta.Y * 0.0025,
		math.rad(C.MinPitch),
		math.rad(C.MaxPitch)
	)

	updateSpring(dt)

	-- Pose targets ------------------------------------------------------
	local targetShoulder = State.aiming and C.AimOffset or C.ShoulderOffset
	currentShoulder = currentShoulder:Lerp(targetShoulder, Util.damp(dt, 9))

	local targetDistance = State.aiming and C.AimDistance or C.Distance
	currentDistance += (targetDistance - currentDistance) * Util.damp(dt, 8)

	local targetFOV = C.FOV
	if State.aiming then
		targetFOV = C.AimFOV
	elseif State.sprinting then
		targetFOV = C.SprintFOV
	end
	currentFOV += (targetFOV - currentFOV) * Util.damp(dt, C.FOVLerp)
	camera.FieldOfView = currentFOV

	-- Movement bob ------------------------------------------------------
	local moving = humanoid.MoveDirection.Magnitude > 0.1
	local speedFactor = math.clamp(State.moveSpeed / math.max(Config.Movement.SprintSpeed, 1), 0, 1)
	if moving and State.grounded then
		bobPhase += dt * C.BobFrequency * (0.6 + speedFactor)
	else
		bobPhase += dt * C.BobFrequency * 0.25
	end

	local bobVertical = 0
	local bobHorizontal = 0
	if moving and State.grounded then
		bobVertical = math.sin(bobPhase * 2) * C.BobAmplitude * (0.5 + speedFactor)
		bobHorizontal = math.cos(bobPhase) * C.BobAmplitude * 0.6 * (0.5 + speedFactor)
	end

	-- Sway from mouse movement (camera inertia) -------------------------
	local swayTarget = Vector2.new(
		-mouseDelta.X * C.SwayAmount * 0.01,
		mouseDelta.Y * C.SwayAmount * 0.01
	)
	swayOffset = swayOffset:Lerp(swayTarget, Util.damp(dt, C.SwaySmoothing))

	-- Lean shift --------------------------------------------------------
	local leanShift = State.lean * Config.Movement.LeanOffset
	local leanRoll = -State.lean * math.rad(Config.Movement.LeanAngle)

	-- Shake -------------------------------------------------------------
	local shakeOffset = Vector3.new(0, 0, 0)
	if shakeTime > 0 then
		shakeTime -= dt
		local decay = math.clamp(shakeTime / 0.3, 0, 1)
		shakeOffset = Vector3.new(
			(math.random() - 0.5) * shakeIntensity * decay * 0.5,
			(math.random() - 0.5) * shakeIntensity * decay * 0.5,
			0
		)
		if shakeTime <= 0 then
			shakeIntensity = 0
		end
	end

	-- The pivot sits above the root, near the eyes. Prone and crouch lower
	-- it so the framing matches the body.
	local pivotHeight = C.PivotHeight
	if State.stance == "Crouch" then
		pivotHeight -= 0.5
	elseif State.stance == "Prone" then
		pivotHeight -= 1.0
	end
	local subjectPosition = root.Position + Vector3.new(0, pivotHeight, 0)

	local orbit = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local right = orbit.RightVector
	local up = orbit.UpVector
	local back = orbit.LookVector

	local offset = currentShoulder
	local basePosition = subjectPosition
		+ right * (offset.X + leanShift + bobHorizontal)
		+ up * (offset.Y + bobVertical)

	local desiredPosition = basePosition - back * currentDistance

	-- Collision: keep the camera out of geometry ------------------------
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local collision = workspace:Raycast(subjectPosition, desiredPosition - subjectPosition, params)
	if collision then
		local safe = (collision.Position - subjectPosition).Magnitude - 0.3
		safe = math.max(safe, C.MinDistance)
		desiredPosition = subjectPosition - back * safe
	end

	local finalPosition = desiredPosition + shakeOffset
	local lookRotation = CFrame.fromEulerAnglesYXZ(
		pitch + recoilPitch,
		yaw + recoilYaw,
		leanRoll + math.rad(swayOffset.X * 0.5)
	)

	camera.CFrame = CFrame.new(finalPosition) * lookRotation
	camera.Focus = CFrame.new(subjectPosition)

	-- Turn the body toward the camera -----------------------------------
	-- The body chases the camera's yaw with a short lag. That lag is the
	-- turn rate the animator sees, and it is what makes turning in place
	-- step the feet instead of sliding.
	if not State.vaulting and not State.downed then
		-- While moving, the body snaps around faster so a strafe reads as a
		-- strafe rather than as a slow pirouette.
		local boost = moving and 1.8 or 1
		bodyYaw = AnimationSystem.bodyTurn(bodyYaw, yaw, State.aiming, dt, boost)
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, bodyYaw, 0)
	end
end

function CameraController.init()
	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = C.FOV

	-- Disable only Roblox's default camera script. The rest of the
	-- PlayerModule (the control module) must stay alive or WASD movement
	-- and jumping stop working.
	local cameraScript = player.PlayerScripts:FindFirstChild("CameraScript")
	if cameraScript and cameraScript:IsA("BaseScript") then
		cameraScript.Disabled = true
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	UserInputService.WindowFocused:Connect(function()
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end)

	RunService:BindToRenderStep("TLoUCamera", Enum.RenderPriority.Camera.Value + 1, update)

	State.Signals.Fired:Connect(function(pitchKick, yawKick)
		addRecoil(pitchKick, yawKick)
	end)
	State.Signals.Shake:Connect(function(intensity, duration)
		addShake(intensity, duration)
	end)

	State.Signals.CharacterChanged:Connect(function(character)
		local root = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		if root then
			local look = root.CFrame.LookVector
			yaw = math.atan2(-look.X, -look.Z)
			pitch = 0
			bodyYaw = yaw
		end
	end)
end

function CameraController.addRecoilImpulse(pitchKick: number, yawKick: number)
	addRecoil(pitchKick, yawKick)
end

return CameraController
