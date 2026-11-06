--!strict
--[[
	CameraController
	Over-the-shoulder third-person camera in the TLoU style:
	* The camera sits offset to the right of the character, tight and low.
	* Aiming pulls it closer over the shoulder and narrows the FOV.
	* Sprinting widens the FOV slightly for a sense of urgency.
	* Walking adds a subtle vertical bob and a lateral sway driven by
	  movement, plus inertia lag when you turn the camera quickly.
	* Recoil is a spring that kicks the camera up and back, then recovers.
	* Leaning shifts the camera sideways so you can peek around cover.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Util = require(Shared.Util)

local State = require(script.Parent.State)

local CameraController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local Config_Camera = Config.Camera

-- Orbit state
local yaw = 0
local pitch = 0
local currentShoulder = Config_Camera.ShoulderOffset
local currentFOV = Config_Camera.FOV

-- Bob / sway
local bobPhase = 0
local swayOffset = Vector2.new(0, 0)
local smoothedMove = Vector2.new(0, 0)

-- Recoil spring
local recoilPitch = 0
local recoilYaw = 0
local recoilPitchVelocity = 0
local recoilYawVelocity = 0

-- Camera shake
local shakeTime = 0
local shakeIntensity = 0

local lastMouseDelta = Vector2.new(0, 0)

local function isMoving(): boolean
	local humanoid = State.humanoid
	if not humanoid then
		return false
	end
	return humanoid.MoveDirection.Magnitude > 0.1
end

--- Adds an impulse to the recoil spring.
local function addRecoil(pitchKick: number, yawKick: number)
	recoilPitchVelocity -= pitchKick
	recoilYawVelocity += yawKick
end

--- Camera shake impulse (explosions, heavy hits).
local function addShake(intensity: number, duration: number)
	shakeIntensity = math.max(shakeIntensity, intensity)
	shakeTime = math.max(shakeTime, duration)
end

local function updateSpring(dt: number)
	local stiffness = Config_Camera.RecoilRecovery
	local damping = 2 * math.sqrt(stiffness) * 0.6

	-- Critically-damped-ish spring toward zero.
	local pitchAccel = -stiffness * recoilPitch - damping * recoilPitchVelocity
	local yawAccel = -stiffness * recoilYaw - damping * recoilYawVelocity

	recoilPitchVelocity += pitchAccel * dt
	recoilYawVelocity += yawAccel * dt

	recoilPitch += recoilPitchVelocity * dt
	recoilYaw += recoilYawVelocity * dt

	recoilPitch = math.clamp(recoilPitch, -Config_Camera.MaxRecoil, Config_Camera.MaxRecoil)
	recoilYaw = math.clamp(recoilYaw, -Config_Camera.MaxRecoil, Config_Camera.MaxRecoil)

	State.recoil = Vector2.new(recoilPitch, recoilYaw)
end

local function update(dt: number)
	local character = State.character
	local root = State.rootPart
	local humanoid = State.humanoid
	if not character or not root or not humanoid then
		return
	end

	local mouseDelta = UserInputService:GetMouseDelta()
	lastMouseDelta = mouseDelta

	-- Free look: mouse drives yaw/pitch directly, the character follows
	-- the camera's yaw when moving.
	yaw -= mouseDelta.X * 0.0025
	pitch -= mouseDelta.Y * 0.0025
	pitch = math.clamp(pitch, math.rad(Config_Camera.MinPitch), math.rad(Config_Camera.MaxPitch))

	updateSpring(dt)

	-- Shoulder offset lerps between hip and aim positions.
	local targetShoulder = State.aiming and Config_Camera.AimOffset or Config_Camera.ShoulderOffset
	currentShoulder = currentShoulder:Lerp(targetShoulder, Util.damp(dt, 9))

	-- FOV lerps between the three states.
	local targetFOV = Config_Camera.FOV
	if State.aiming then
		targetFOV = Config_Camera.AimFOV
	elseif State.sprinting then
		targetFOV = Config_Camera.SprintFOV
	end
	currentFOV += (targetFOV - currentFOV) * Util.damp(dt, Config_Camera.FOVLerp)
	camera.FieldOfView = currentFOV

	-- Movement-driven bob and sway.
	local moving = isMoving()
	local speedFactor = State.moveSpeed / Config.Movement.SprintSpeed
	if moving and State.grounded then
		bobPhase += dt * Config_Camera.BobFrequency * (0.6 + speedFactor)
	else
		bobPhase += dt * Config_Camera.BobFrequency * 0.25
	end

	local bobVertical = 0
	local bobHorizontal = 0
	if moving and State.grounded then
		bobVertical = math.sin(bobPhase * 2) * Config_Camera.BobAmplitude * (0.5 + speedFactor)
		bobHorizontal = math.cos(bobPhase) * Config_Camera.BobAmplitude * 0.6 * (0.5 + speedFactor)
	end

	-- Sway from mouse movement (weapon/camera inertia).
	local swayTarget = Vector2.new(
		-mouseDelta.X * Config_Camera.SwayAmount * 0.01,
		mouseDelta.Y * Config_Camera.SwayAmount * 0.01
	)
	swayOffset = swayOffset:Lerp(swayTarget, Util.damp(dt, Config_Camera.SwaySmoothing))

	-- Lean shift.
	local leanShift = State.lean * Config.Movement.LeanOffset
	local leanRoll = -State.lean * math.rad(Config.Movement.LeanAngle)

	-- Shake.
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

	-- Assemble the camera CFrame.
	local subjectPosition = root.Position + Vector3.new(0, 1.6, 0)
	local orbit = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)

	local right = orbit.RightVector
	local up = orbit.UpVector
	local back = orbit.LookVector

	local offset = currentShoulder
	local basePosition = subjectPosition
		+ right * (offset.X + leanShift + bobHorizontal)
		+ up * (offset.Y + bobVertical)
		+ back * -offset.Z

	-- Pull the camera back along its look vector so it sits behind.
	local distance = State.aiming and 3.2 or 4.2
	local desiredPosition = basePosition - back * distance

	-- Camera collision: keep the camera out of walls.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local collision = workspace:Raycast(subjectPosition, desiredPosition - subjectPosition, params)
	if collision then
		desiredPosition = collision.Position + collision.Normal * 0.4
	end

	local swayRotation = CFrame.Angles(
		math.rad(swayOffset.Y),
		math.rad(swayOffset.X),
		leanRoll
	)

	local finalPosition = desiredPosition + shakeOffset
	local lookRotation = CFrame.fromEulerAnglesYXZ(
		pitch + recoilPitch,
		yaw + recoilYaw,
		leanRoll + math.rad(swayOffset.X * 0.5)
	)

	camera.CFrame = CFrame.new(finalPosition) * lookRotation
	camera.Focus = CFrame.new(subjectPosition)

	-- Rotate the character to face the camera. Strafe is kept while
	-- aiming so you can backpedal, and rotation is suspended during a
	-- vault because the vault owns the root CFrame.
	if not State.vaulting then
		local flatLook = Vector3.new(back.X, 0, back.Z)
		if flatLook.Magnitude > 0.01 then
			local currentRoot = root.CFrame
			local desiredYaw = math.atan2(-flatLook.X, -flatLook.Z)
			local currentYaw = select(2, currentRoot:ToEulerAnglesYXZ())
			local alpha = Util.damp(dt, State.aiming and 18 or 12)
			local newYaw = currentYaw + math.atan2(math.sin(desiredYaw - currentYaw), math.cos(desiredYaw - currentYaw)) * alpha
			root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, newYaw, 0)
		end
	end
end

function CameraController.init()
	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = Config_Camera.FOV

	-- Disable only Roblox's default camera script. The rest of the
	-- PlayerModule (control module) must stay alive or WASD movement and
	-- jumping stop working.
	local cameraScript = player.PlayerScripts:FindFirstChild("CameraScript")
	if cameraScript and cameraScript:IsA("BaseScript") then
		cameraScript.Disabled = true
	end

	-- Lock the mouse so the crosshair drives the view, the way an
	-- over-the-shoulder shooter expects.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	-- Re-assert the lock whenever focus returns to the window.
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

	-- Keep the yaw aligned with the character on spawn.
	State.Signals.CharacterChanged:Connect(function(character)
		local root = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		if root then
			local look = root.CFrame.LookVector
			yaw = math.atan2(-look.X, -look.Z)
			pitch = 0
		end
	end)
end

function CameraController.addRecoilImpulse(pitchKick: number, yawKick: number)
	addRecoil(pitchKick, yawKick)
end

return CameraController
