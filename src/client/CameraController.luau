--!strict
--[[
	CameraController
	----------------------------------------------------------------------------
	A fully scripted over-the-shoulder camera.

		* mouse-look with independent yaw/pitch (the character turns to face the
		  movement direction, the camera does not drag the character around)
		* a lateral shoulder offset that glides between right and left when you
		  press the swap key - no snap, it eases with a smooth-damp spring
		* spring-arm collision so the camera pulls in instead of clipping walls
		* recoil that kicks the pitch and recovers
		* aim mode that tightens the FOV and pulls the camera closer
		* head-look offsets forwarded to the animator so the character's head
		  follows where you are looking

	Because the camera is Scriptable, the default Roblox camera scripts leave it
	alone entirely.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Util = require(ReplicatedStorage.Shared.Util)

local ClientState = require(script.Parent.ClientState)

local CameraController = {}

local C = Config.Camera

local state = {
	yaw = 0,
	pitch = 0,
	shoulder = C.RightShoulderOffset,
	shoulderTarget = C.RightShoulderOffset,
	shoulderVelocity = 0,
	positionVelocity = Vector3.zero,
	currentPos = Vector3.zero,
	recoilPitch = 0,
	recoilYaw = 0,
	distance = C.Distance,
	bobTime = 0,
	initialised = false,
}

local SENSITIVITY = 0.0022

-- ---------------------------------------------------------------- public API --

function CameraController.swapShoulder()
	state.shoulderTarget = -state.shoulderTarget
	ClientState.shoulderSide = if state.shoulderTarget > 0 then 1 else -1
end

--[[
	Adds a recoil impulse. `kick` is in degrees of upward pitch, `yaw` in
	degrees of horizontal drift.
]]
function CameraController.addRecoil(kick: number, yaw: number)
	state.recoilPitch += kick
	state.recoilYaw += (math.random() - 0.5) * 2 * yaw
end

--[[
	The world-space direction the camera is looking, used by the weapon system so
	shots go exactly where the reticle points.
]]
function CameraController.getLookDirection(): Vector3
	local camera = workspace.CurrentCamera
	if camera then
		return camera.CFrame.LookVector
	end
	return Vector3.new(0, 0, -1)
end

function CameraController.getAimOrigin(): Vector3
	local camera = workspace.CurrentCamera
	local root = ClientState.root
	if camera then
		-- Cast from the camera so the crosshair is truthful, but never from
		-- inside the character.
		local origin = camera.CFrame.Position + camera.CFrame.LookVector * 1.2
		if root and (origin - root.Position).Magnitude < 1.5 then
			origin = root.Position + Vector3.new(0, 1.6, 0) + camera.CFrame.LookVector * 2
		end
		return origin
	end
	return root and root.Position or Vector3.zero
end

--[[
	0..1 yaw/pitch normalised values for the animator's head aim.
]]
function CameraController.getHeadAim(): (number, number)
	return Util.clamp(state.yaw / math.pi, -1, 1), Util.clamp(state.pitch / math.rad(80), -1, 1)
end

-- ------------------------------------------------------------------- update --

local function updateRotation(dt: number)
	local delta = UserInputService:GetMouseDelta()
	state.yaw -= delta.X * SENSITIVITY
	state.pitch -= delta.Y * SENSITIVITY
	state.pitch = math.clamp(state.pitch, math.rad(C.MinPitch), math.rad(C.MaxPitch))

	-- Recoil recovery: spring the impulse back to zero.
	local recovery = math.exp(-C.RecoilRecoverSpeed * 8 * dt)
	state.recoilPitch *= recovery
	state.recoilYaw *= recovery
	if math.abs(state.recoilPitch) < 0.0001 then
		state.recoilPitch = 0
	end
	if math.abs(state.recoilYaw) < 0.0001 then
		state.recoilYaw = 0
	end
end

local function updateShoulder(dt: number)
	state.shoulder, state.shoulderVelocity = Util.smoothDamp(
		state.shoulder,
		state.shoulderTarget,
		state.shoulderVelocity,
		C.SwapTime * 0.35,
		dt
	)
end

local function updateCamera(dt: number)
	local camera = workspace.CurrentCamera
	local root = ClientState.root
	local humanoid = ClientState.humanoid
	if not camera or not root or not humanoid then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	-- Desired distance and height depend on aim state and stance.
	local aiming = ClientState.aiming
	local stance = ClientState.stance
	local baseDistance = if aiming then C.AimDistance else C.Distance
	if stance == "Prone" then
		baseDistance *= 0.85
	elseif stance == "Crouch" then
		baseDistance *= 0.92
	end
	state.distance = Util.damp(state.distance, baseDistance, 6, dt)

	local height = if aiming then C.AimShoulderHeight else C.ShoulderHeight
	if stance == "Prone" then
		height = 0.9
	elseif stance == "Crouch" then
		height *= 0.78
	end

	-- Camera bob tied to ground speed, disabled while aiming.
	local horizontal = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	state.bobTime += dt * C.BobSpeed * (horizontal / Config.Movement.WalkSpeed)
	local bob = 0
	if not aiming and horizontal > 1 then
		bob = math.sin(state.bobTime) * C.BobAmount * math.clamp(horizontal / 12, 0, 1)
	end

	-- Pivot: just above the character's shoulders.
	local pivot = root.Position + Vector3.new(0, height + bob, 0)

	-- Orientation from yaw/pitch, with recoil layered on.
	local pitch = state.pitch + math.rad(state.recoilPitch)
	local yaw = state.yaw + math.rad(state.recoilYaw)
	local rotation = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local lookDir = rotation.LookVector
	local rightDir = rotation.RightVector

	-- The lateral offset is applied in the camera's own space so it stays
	-- "over the shoulder" no matter which way you look.
	local desired = pivot + rightDir * state.shoulder - lookDir * state.distance

	-- Spring-arm collision: pull the camera in if something is between the
	-- pivot and the desired position.
	local ignore: { Instance } = {}
	if ClientState.character then
		table.insert(ignore, ClientState.character)
	end
	local toCamera = desired - pivot
	local hit = Util.raycast(pivot, toCamera, ignore)
	if hit and hit.Instance and hit.Instance.CanCollide then
		local safeDist = math.max(1.2, hit.Distance - C.CollisionPadding)
		desired = pivot + toCamera.Unit * safeDist
	end

	-- Smooth the position with a critically damped spring, but snap the first
	-- frame so the camera does not fly in from the origin.
	if not state.initialised then
		state.currentPos = desired
		state.initialised = true
	else
		state.currentPos, state.positionVelocity = Util.smoothDampVec3(
			state.currentPos,
			desired,
			state.positionVelocity,
			C.PositionSmooth,
			dt
		)
	end

	camera.CFrame = CFrame.lookAt(state.currentPos, state.currentPos + lookDir)
	camera.Focus = CFrame.new(pivot)

	-- FOV blend for aim mode.
	local targetFOV = if aiming then C.AimFOV else C.FOV
	camera.FieldOfView = Util.damp(camera.FieldOfView, targetFOV, 1 / C.FOVSmooth, dt)

	-- Forward head-look to the animator.
	if ClientState.animator then
		local yawN, pitchN = CameraController.getHeadAim()
		ClientState.animator:setHeadAim(yawN, pitchN)
	end
end

function CameraController.start()
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = C.FOV
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	-- Re-lock the mouse if something (a UI) unlocks it.
	UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			task.defer(function()
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			end)
		end
	end)

	RunService:BindToRenderStep("LastStandCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		if not ClientState.isAlive() then
			return
		end
		updateRotation(dt)
		updateShoulder(dt)
		updateCamera(dt)
	end)
end

return CameraController
