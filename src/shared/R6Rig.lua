--!strict
--[[
	R6Rig
	Everything about the classic R6 body in one place: the six parts, the
	six Motor6D joints, their canonical offsets, and the maths that turns a
	pose (degrees, in character space) into a joint rotation.

	Pose convention
	---------------
	Angles are authored in *character space*, where
	    X = right, Y = up, Z = back (Roblox's forward is -Z).

	* pitch  rotation about X. For a limb that hangs down, positive swings
	         the far end forward. For the torso and head, which point up,
	         positive would tilt them backward - so the sign is flipped for
	         those two joints, and "positive pitch" always means "lean or
	         look forward" everywhere in the pack.
	* yaw    rotation about Y (turn).
	* roll   rotation about Z (tilt sideways).

	The joints
	----------
	    HumanoidRootPart --RootJoint-- Torso
	    Torso --Neck-- Head
	    Torso --Left/Right Shoulder-- Left/Right Arm
	    Torso --Left/Right Hip-- Left/Right Leg

	Because an R6 limb is an axis-aligned box whose local axes line up with
	the torso's, rotating a limb is just a rotation about the matching
	character axis. That is why this module can stay small.
]]

local Config = require(script.Parent.Config)

local R6Rig = {}

local RAD = math.pi / 180

-- Rotation matrices for the canonical R6 joints, as the 9 numbers that
-- CFrame.new takes after the position (R00 R01 R02 R10 R11 R12 R20 R21 R22).
local NECK_R = { -1, 0, 0, 0, 0, 1, 0, 1, 0 }
local LEFT_R = { 0, 0, -1, 0, 1, 0, 1, 0, 0 }
local RIGHT_R = { 0, 0, 1, 0, 1, 0, -1, 0, 0 }

local function cf(px: number, py: number, pz: number, r): CFrame
	return CFrame.new(px, py, pz, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
end

--- The canonical R6 skeleton. Order matters: parts are created in this
--- order so every parent exists before its children.
R6Rig.PARTS = {
	{ name = "Head", size = Config.Rig.HeadSize },
	{ name = "Torso", size = Config.Rig.TorsoSize },
	{ name = "Left Arm", size = Config.Rig.LimbSize },
	{ name = "Right Arm", size = Config.Rig.LimbSize },
	{ name = "Left Leg", size = Config.Rig.LimbSize },
	{ name = "Right Leg", size = Config.Rig.LimbSize },
}

--- Joint definitions. "kind" selects the pitch sign convention.
R6Rig.JOINTS = {
	{
		name = "RootJoint",
		kind = "torso",
		part0 = "HumanoidRootPart",
		part1 = "Torso",
		c0 = cf(0, 0, 0, NECK_R),
		c1 = cf(0, 0, 0, NECK_R),
	},
	{
		name = "Neck",
		kind = "head",
		part0 = "Torso",
		part1 = "Head",
		c0 = cf(0, 1, 0, NECK_R),
		c1 = cf(0, -0.5, 0, NECK_R),
	},
	{
		name = "Left Shoulder",
		kind = "limb",
		part0 = "Torso",
		part1 = "Left Arm",
		c0 = cf(-1, 0.5, 0, LEFT_R),
		c1 = cf(0.5, 0.5, 0, LEFT_R),
	},
	{
		name = "Right Shoulder",
		kind = "limb",
		part0 = "Torso",
		part1 = "Right Arm",
		c0 = cf(1, 0.5, 0, RIGHT_R),
		c1 = cf(-0.5, 0.5, 0, RIGHT_R),
	},
	{
		name = "Left Hip",
		kind = "limb",
		part0 = "Torso",
		part1 = "Left Leg",
		c0 = cf(-1, -1, 0, LEFT_R),
		c1 = cf(-0.5, 1, 0, LEFT_R),
	},
	{
		name = "Right Hip",
		kind = "limb",
		part0 = "Torso",
		part1 = "Right Leg",
		c0 = cf(1, -1, 0, RIGHT_R),
		c1 = cf(0.5, 1, 0, RIGHT_R),
	},
}

--- Which pose channel drives each joint. The root joint also carries the
--- torso twist, which is why it is handled specially in applyPose.
R6Rig.channelFor = {
	RootJoint = "root",
	Neck = "head",
	["Left Shoulder"] = "leftArm",
	["Right Shoulder"] = "rightArm",
	["Left Hip"] = "leftLeg",
	["Right Hip"] = "rightLeg",
}

--- Joint lookup by name, and the channel each joint reads, built once.
R6Rig.jointByName = {}
for _, joint in ipairs(R6Rig.JOINTS) do
	joint.channel = R6Rig.channelFor[joint.name]
	R6Rig.jointByName[joint.name] = joint
end

--- The pitch sign for a joint kind: limbs swing forward on positive pitch,
--- the upright parts (torso, head) lean forward on negative, so we flip
--- them here and the rest of the pack never has to think about it.
function R6Rig.pitchSign(kind: string): number
	return (kind == "torso" or kind == "head") and -1 or 1
end

--- Builds the rotation to apply to a joint, from a pose channel.
function R6Rig.rotationFor(kind: string, pitch: number, yaw: number, roll: number): CFrame
	return CFrame.fromEulerAnglesYXZ(
		(pitch or 0) * R6Rig.pitchSign(kind) * RAD,
		(yaw or 0) * RAD,
		(roll or 0) * RAD
	)
end

--- True when an instance looks like a complete R6 character.
function R6Rig.isR6(character: Instance): boolean
	if not character or not character:IsA("Model") then
		return false
	end
	for _, part in ipairs(R6Rig.PARTS) do
		local child = character:FindFirstChild(part.name)
		if not child or not child:IsA("BasePart") then
			return false
		end
	end
	-- Joints are not direct children of the character in R6: RootJoint
	-- lives under HumanoidRootPart and the rest under Torso. Search the
	-- whole model so both layouts are accepted.
	for _, joint in ipairs(R6Rig.JOINTS) do
		local child = character:FindFirstChild(joint.name, true)
		if not child or not child:IsA("Motor6D") then
			return false
		end
	end
	return true
end

--- Every R6 Motor6D joint on a character, by name.
function R6Rig.collectJoints(character: Instance): { [string]: Motor6D }
	local found = {}
	for _, joint in ipairs(R6Rig.JOINTS) do
		local child = character:FindFirstChild(joint.name, true)
		if child and child:IsA("Motor6D") then
			found[joint.name] = child
		end
	end
	return found
end

--- Applies a pose to a character's rig.
--- `pose` is the table AnimationSystem.computePose returns.
---
--- We write Motor6D.Transform rather than C0. Transform is an extra
--- transform composed on top of C0/C1, and it is what it exists for:
--- * it is not replicated, so every client can pose every character
---   independently without the server seeing a stream of joint writes;
--- * it leaves C0/C1 as the rig's rest pose, so the character returns to
---   rest the moment we stop, with nothing to restore;
--- * it does not move the parts physically, so it cannot fight the
---   Humanoid's own physics or make the character fall over.
function R6Rig.applyPose(character: Instance, pose)
local joints = R6Rig.collectJoints(character)
for _, joint in ipairs(R6Rig.JOINTS) do
local motor = joints[joint.name]
if motor then
local channel = pose[joint.channel]
if channel then
motor.Transform = R6Rig.rotationFor(joint.kind, channel.pitch, channel.yaw, channel.roll)
end
end
end

-- The root joint carries the torso twist as well as the vertical offset
-- (bob, crouch and prone drop). Applying the offset here keeps the drop
-- in the joint rather than moving the character, so the physics stays
-- honest and the silhouette still lowers.
local rootMotor = joints.RootJoint
if rootMotor and pose.root and pose.torso then
local joint = R6Rig.jointByName.RootJoint
local rotation = R6Rig.rotationFor(
joint.kind,
(pose.root.pitch or 0) + (pose.torso.pitch or 0),
(pose.root.yaw or 0) + (pose.torso.yaw or 0),
(pose.root.roll or 0) + (pose.torso.roll or 0)
)
local offset = pose.offset or Vector3.new(0, 0, 0)
rootMotor.Transform = CFrame.new(offset) * rotation
end
end

--- Returns every joint to its rest pose by clearing the transform.
function R6Rig.resetPose(character: Instance)
for _, motor in pairs(R6Rig.collectJoints(character)) do
motor.Transform = CFrame.new()
end
end

--- Builds a canonical R6 character. Used to replace an R15 body, and by the
--- test harness to exercise the pose maths without a Roblox runtime.
function R6Rig.build(name: string): Model
	local model = Instance.new("Model")
	model.Name = name or "R6Rig"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Config.Rig.RootSize
	root.Transparency = 1
	root.CanCollide = false
	root.Parent = model
	model.PrimaryPart = root

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Config.Rig.TorsoSize
	torso.Color = Config.Rig.ShirtColor
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Config.Rig.HeadSize
	head.Color = Config.Rig.BodyColor
	head.Parent = model

	for _, limbName in ipairs({ "Left Arm", "Right Arm", "Left Leg", "Right Leg" }) do
		local limb = Instance.new("Part")
		limb.Name = limbName
		limb.Size = Config.Rig.LimbSize
		limb.Color = (limbName:find("Leg") and Config.Rig.PantsColor) or Config.Rig.BodyColor
		limb.Parent = model
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.Parent = model

	for _, joint in ipairs(R6Rig.JOINTS) do
		local motor = Instance.new("Motor6D")
		motor.Name = joint.name
		motor.Part0 = model:FindFirstChild(joint.part0)
		motor.Part1 = model:FindFirstChild(joint.part1)
		motor.C0 = joint.c0
		motor.C1 = joint.c1
		motor.Parent = model:FindFirstChild(joint.part0)
	end

	return model
end

--- Rebuilds a character as R6 in place, keeping its position and identity.
--- Returns the new model, or nil if the swap could not be done.
function R6Rig.convertToR6(character: Model): Model?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return nil
	end

	local player = game:GetService("Players"):GetPlayerFromCharacter(character)
	local rig = R6Rig.build(player and player.Name or character.Name)

	local newRoot = rig:FindFirstChild("HumanoidRootPart") :: BasePart
	local newHumanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid

	-- Carry over everything that defines who this character is.
	newRoot.CFrame = root.CFrame
	newHumanoid.WalkSpeed = humanoid.WalkSpeed
	newHumanoid.JumpPower = humanoid.JumpPower
	newHumanoid.UseJumpPower = humanoid.UseJumpPower
	newHumanoid.AutoRotate = humanoid.AutoRotate
	newHumanoid.MaxHealth = humanoid.MaxHealth
	newHumanoid.Health = humanoid.Health
	newHumanoid.BreakJointsOnDeath = humanoid.BreakJointsOnDeath
	newHumanoid.HipHeight = humanoid.HipHeight

	rig.Parent = character.Parent
	if player then
		player.Character = rig
	end
	character:Destroy()

	return rig
end

--- The yaw (rotation about world up) of a CFrame, in radians.
function R6Rig.yawOf(cframe: CFrame): number
	local look = cframe.LookVector
	return math.atan2(-look.X, -look.Z)
end

--- Shortest signed difference between two angles, in radians.
function R6Rig.angleDelta(from: number, to: number): number
	return math.atan2(math.sin(to - from), math.cos(to - from))
end

return R6Rig
