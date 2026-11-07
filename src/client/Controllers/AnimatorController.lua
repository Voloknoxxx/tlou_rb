--!strict
--[[
	AnimatorController
	Applies the AnimationSystem's poses to real R6 rigs.

	Motor6D.Transform does not replicate, so every client has to run the
	same maths for every character it can see. This controller therefore
	tracks *all* characters in the workspace, not just the local one:

	* Speed and turn rate are derived from each character's own parts, which
	  every client can see, so remote characters animate correctly with no
	  extra network traffic. Deriving speed from real displacement (rather
	  than Humanoid.WalkSpeed) is also what keeps the feet from skating.
	* The richer states (stance, aiming, vaulting, downed, sprinting) are
	  broadcast as attributes on the character, which replicate for free.

	The local player is animated exactly like everyone else, so there is no
	special case that can drift out of sync.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local R6Rig = require(Shared.R6Rig)
local AnimationSystem = require(Shared.AnimationSystem)

local State = require(script.Parent.State)

local AnimatorController = {}

local player = Players.LocalPlayer
local ANIM = Config.Animation

type Tracked = {
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	anim: any,
	weights: any,
	lastYaw: number,
	lastPosition: Vector3,
	smoothedSpeed: number,
}

local tracked: { [Model]: Tracked } = {}

local function isLocal(character: Model): boolean
	return player.Character == character
end

--- Horizontal position, so speed is measured on the ground plane.
local function groundPosition(root: BasePart): Vector3
	local p = root.Position
	return Vector3.new(p.X, 0, p.Z)
end

local function untrack(character: Model)
	tracked[character] = nil
end

--- Stops Roblox's stock animation from fighting us on this client.
---
--- RigService destroys the character's `Animate` script on the server, but that
--- is not enough: `Animate` is a LocalScript, so it can start on this client
--- before the server's destroy replicates. The AnimationTracks it leaves behind
--- outlive the script, and a single playing track makes the Animator rewrite
--- every Motor6D.Transform each frame - which is what was silently discarding
--- our pose. Doing it here, on the client that actually runs the script, is
--- the reliable place.
local function suppressDefaultAnimation(character: Model)
	local animate = character:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end
	local animator = character:FindFirstChildOfClass("Animator")
	if animator then
		for _, playing in ipairs(animator:GetPlayingAnimationTracks()) do
			playing:Stop(0)
		end
	end
end

local function track(character: Model)
	untrack(character)

	if not character:IsA("Model") then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end

	suppressDefaultAnimation(character)

	-- A rig whose joints we cannot find is the one failure mode that produces
	-- no error at all: every other mechanic works and the character simply
	-- never leaves its rest pose. Say so once, loudly, instead of failing
	-- silently - that is what made this bug take so long to find.
	local joints = R6Rig.collectJoints(character)
	if next(joints) == nil then
		warn(string.format(
			"[TLoU] %s has no drivable joints (looked for %s); its animations will not play. " ..
			"If the Avatar Joint Upgrade is on, its AnimationConstraints should have matched.",
			character.Name, table.concat(R6Rig.JOINT_NAMES or {}, ", ")))
	end

	local entry: Tracked
	entry = {
		character = character,
		humanoid = humanoid,
		root = root,
		anim = AnimationSystem.newState(),
		weights = AnimationSystem.blendWeights({}, AnimationSystem.EMPTY_WEIGHTS, 1, 1e6),
		lastYaw = R6Rig.yawOf(root.CFrame),
		lastPosition = groundPosition(root),
		smoothedSpeed = 0,
	}

	tracked[character] = entry
end

--- Reads the animation state a character is advertising. Attributes are the
--- replicated source of truth; for the local player we can fall back to
--- State, which is always ahead of the attribute write.
local function readWeights(character: Model, speed: number, grounded: boolean, localPlayer: boolean)
	local function attr(name: string, fallback: any): any
		local value = character:GetAttribute(name)
		if value == nil then
			return fallback
		end
		return value
	end

	local stance = attr("Stance", localPlayer and State.stance or "Stand")
	local aiming = attr("Aiming", localPlayer and State.aiming or false)
	local vaulting = attr("Vaulting", localPlayer and State.vaulting or false)
	local downed = attr("Downed", localPlayer and State.downed or false)
	local sprinting = attr("Sprinting", localPlayer and State.sprinting or false)
	-- The local player publishes "Armed" from the weapon controller. For
	-- every other player the server only publishes "EquippedWeapon", so
	-- derive the carry pose from that. Without this, remote players would
	-- hold a rifle with loose, swinging arms.
	local armed = attr("Armed", false) or (character:GetAttribute("EquippedWeapon") ~= nil)

	return {
		crouch = stance == "Crouch" and 1 or 0,
		prone = stance == "Prone" and 1 or 0,
		aim = aiming and 1 or 0,
		sprint = (sprinting and speed > Config.Movement.WalkSpeed * 0.8) and 1 or 0,
		air = grounded and 0 or 1,
		vault = vaulting and 1 or 0,
		downed = downed and 1 or 0,
		armed = armed and 1 or 0,
	}
end

local function update(dt: number)
	for character, entry in pairs(tracked) do
		local root = entry.root
		local humanoid = entry.humanoid
		if not character.Parent or not root.Parent or not humanoid.Parent then
			untrack(character)
			continue
		end

		-- Speed from real displacement: correct for remote characters too,
		-- and it never lies about what the body is actually doing.
		local position = groundPosition(root)
		local rawSpeed = (position - entry.lastPosition).Magnitude / math.max(dt, 1e-4)
		entry.lastPosition = position
		entry.smoothedSpeed += (rawSpeed - entry.smoothedSpeed) * math.min(1, 14 * dt)

		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		local yaw = R6Rig.yawOf(root.CFrame)
		local turnRate = R6Rig.angleDelta(entry.lastYaw, yaw) / math.max(dt, 1e-4)
		entry.lastYaw = yaw

		local localPlayer = isLocal(character)
		local target = readWeights(character, entry.smoothedSpeed, grounded, localPlayer)
		AnimationSystem.blendWeights(entry.weights, target, dt)

		local pose = AnimationSystem.computePose({
			dt = dt,
			speed = entry.smoothedSpeed,
			turnRate = turnRate,
			grounded = grounded,
			weights = entry.weights,
			anim = entry.anim,
		})

		R6Rig.applyPose(character, pose)

		-- Publish a little state so the camera and the weapon view can read
		-- it without recomputing the same numbers.
		character:SetAttribute("AnimPhase", pose.phase)
		character:SetAttribute("AnimSpeed", entry.smoothedSpeed)
	end
end

local function onCharacter(character: Model)
	track(character)
end

function AnimatorController.init()
	if not ANIM.Enabled then
		return
	end

	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
			onCharacter(child)
		end
	end

	workspace.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			onCharacter(child)
		end
	end)

	Players.PlayerAdded:Connect(function(otherPlayer)
		otherPlayer.CharacterAdded:Connect(onCharacter)
	end)
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer.Character then
			onCharacter(otherPlayer.Character)
		end
		otherPlayer.CharacterAdded:Connect(onCharacter)
	end

	-- PreSimulation, not Heartbeat. The Animator rewrites every
	-- Motor6D.Transform between PreAnimation and Stepped, and the transform
	-- batch is applied right after Stepped. Writing in Heartbeat (which is
	-- PostSimulation) lands *after* the batch, so the value is thrown away
	-- before it is ever used and the character stays in its rest pose.
	-- PreSimulation is the phase that runs after the Animator has had its
	-- turn and before the batch is applied.
	RunService.PreSimulation:Connect(update)
end

--- Forces a character to be re-read, e.g. after the server swaps its rig.
function AnimatorController.refresh(character: Model)
	track(character)
end

return AnimatorController
