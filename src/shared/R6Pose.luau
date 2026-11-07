--!strict
--[[
	R6Pose
	----------------------------------------------------------------------------
	A hand-authored pose library for R6 rigs. Every pose is a table mapping a
	joint name to a CFrame *transform* that is right-multiplied onto that joint's
	resting C0:

		motor.C0 = restC0 * pose[jointName]

	Right-multiplication rotates the limb around its joint in the parent limb's
	space, which is exactly how hand-animated R6 rigs work.

	Axis conventions (Roblox R6, character faces -Z):
		rx > 0  ->  limb swings FORWARD
		rx < 0  ->  limb swings BACKWARD
		rz > 0  ->  right-side limb abducts outward (+X)
		rz < 0  ->  left-side limb abducts outward (-X)
		ry      ->  twist about the vertical axis

	Clips come in two flavours:
		* Continuous clips  f(t: number, rate: number) -> Pose   (walk, run, idle)
		* One-shot clips    f(alpha: number) -> Pose            (reload, mantle...)

	Because every clip is evaluated per-frame from continuous maths there are no
	keyframe pops: motion is inherently smooth at any framerate.
]]

local R6Pose = {}

R6Pose.Joints = {
	"HumanoidRootPart",
	"Torso",
	"Head",
	"Left Arm",
	"Right Arm",
	"Left Leg",
	"Right Leg",
}

R6Pose.HipHeight = {
	Stand = 2.0,
	Crouch = 1.05,
	Prone = 0.45,
}

-- --------------------------------------------------------------- primitives --

local function a(rx: number, ry: number, rz: number, px: number?, py: number?, pz: number?): CFrame
	local cf = CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
	if px or py or pz then
		cf = cf * CFrame.new(px or 0, py or 0, pz or 0)
	end
	return cf
end

-- Shorthand used inside the clip definitions.
local function J(t: { [string]: CFrame }): { [string]: CFrame }
	return t
end

local IDENTITY = CFrame.new()

function R6Pose.identity(): { [string]: CFrame }
	return {
		["HumanoidRootPart"] = IDENTITY,
		Torso = IDENTITY,
		Head = IDENTITY,
		["Left Arm"] = IDENTITY,
		["Right Arm"] = IDENTITY,
		["Left Leg"] = IDENTITY,
		["Right Leg"] = IDENTITY,
	}
end

--[[
	Blends two poses. `alpha` 0 returns `from`, 1 returns `to`.
]]
function R6Pose.lerp(from: { [string]: CFrame }, to: { [string]: CFrame }, alpha: number): { [string]: CFrame }
	local out = {}
	for _, joint in R6Pose.Joints do
		local f = from[joint] or IDENTITY
		local t = to[joint] or IDENTITY
		out[joint] = f:Lerp(t, alpha)
	end
	return out
end

--[[
	Adds two poses together (rotation composition). Used to layer recoil, aim
	sway and hit reactions on top of a locomotion clip.
]]
function R6Pose.add(base: { [string]: CFrame }, layer: { [string]: CFrame }, weight: number?): { [string]: CFrame }
	local w = weight or 1
	local out = {}
	for _, joint in R6Pose.Joints do
		local b = base[joint] or IDENTITY
		local l = layer[joint] or IDENTITY
		out[joint] = b * IDENTITY:Lerp(l, w)
	end
	return out
end

-- ------------------------------------------------------------------- poses --

R6Pose.Static = {}

-- Relaxed standing idle: arms hang, slight asymmetry so it never looks robotic.
R6Pose.Static.Idle = J({
	Torso = a(-2, 0, 0),
	Head = a(2, 0, 0),
	["Left Arm"] = a(-4, 0, -3),
	["Right Arm"] = a(-4, 0, 3),
	["Left Leg"] = a(1, 0, -1),
	["Right Leg"] = a(-1, 0, 1),
})

R6Pose.Static.Crouch = J({
	Torso = a(16, 0, 0, 0, -0.15, 0.1),
	Head = a(-14, 0, 0),
	["Left Arm"] = a(24, 0, -6),
	["Right Arm"] = a(22, 0, 6),
	["Left Leg"] = a(-16, 0, -3),
	["Right Leg"] = a(-16, 0, 3),
})

-- Prone: torso rotated flat, arms braced forward, head lifted to look ahead.
R6Pose.Static.Prone = J({
	Torso = a(-90, 0, 0),
	Head = a(48, 0, 0),
	["Left Arm"] = a(-62, 0, -14),
	["Right Arm"] = a(-58, 0, 14),
	["Left Leg"] = a(6, 0, -3),
	["Right Leg"] = a(4, 0, 3),
})

R6Pose.Static.Aim = J({
	Torso = a(4, -8, 0),
	Head = a(-4, 8, 0),
	["Left Arm"] = a(-72, 0, -8),
	["Right Arm"] = a(-78, 0, 10),
	["Left Leg"] = a(3, 0, -1),
	["Right Leg"] = a(-3, 0, 1),
})

-- ------------------------------------------------------------------- clips --

R6Pose.Clips = {}

--[[
	Continuous idle: slow breathing, weight shifts, subtle head drift.
]]
function R6Pose.Clips.Idle(t: number, _rate: number): { [string]: CFrame }
	local breath = math.sin(t * 1.7)
	local sway = math.sin(t * 0.9)
	local look = math.sin(t * 0.37)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, breath * 0.045, 0),
		Torso = a(-2 + breath * 1.1, sway * 1.6, sway * 0.9),
		Head = a(2 - breath * 0.8, look * 9, sway * -1.2),
		["Left Arm"] = a(-4 + breath * 1.4, 0, -3 - math.abs(sway) * 1.6),
		["Right Arm"] = a(-4 + breath * 1.4, 0, 3 + math.abs(sway) * 1.6),
		["Left Leg"] = a(1, 0, -1),
		["Right Leg"] = a(-1, 0, 1),
	})
end

--[[
	Continuous walk/run cycle. `rate` is the cycle frequency in Hz and should be
	driven from the character's actual speed so the feet never skate.
	`intensity` 0..1 blends from a relaxed stroll to an all-out sprint.
]]
function R6Pose.Clips.Locomotion(t: number, rate: number, intensity: number): { [string]: CFrame }
	local phase = t * rate * math.pi * 2
	local i = math.clamp(intensity, 0, 1)

	local legSwing = 22 + 30 * i
	local armSwing = 16 + 34 * i
	local lean = 3 + 9 * i
	local bob = 0.06 + 0.14 * i

	local left = math.sin(phase)
	local right = math.sin(phase + math.pi)

	-- Knee-less R6 rigs read better with a small "fold" on the trailing leg.
	local leftFold = math.max(0, -left) * (8 + 10 * i)
	local rightFold = math.max(0, -right) * (8 + 10 * i)

	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, math.abs(math.sin(phase)) * bob - bob * 0.5, 0),
		Torso = a(lean + math.abs(left) * 1.5, left * 4 * i, left * 2 * i),
		Head = a(-lean * 0.6 + math.sin(phase * 2) * 1.2, -left * 5 * i, 0),
		["Left Arm"] = a(-armSwing * left - 4, 0, -6 - 4 * i),
		["Right Arm"] = a(-armSwing * right - 4, 0, 6 + 4 * i),
		["Left Leg"] = a(legSwing * left + leftFold, 0, -2 - 2 * i),
		["Right Leg"] = a(legSwing * right + rightFold, 0, 2 + 2 * i),
	})
end

--[[
	Crouch-walk: same cycle, compressed, torso pitched forward, hands low.
]]
function R6Pose.Clips.CrouchLocomotion(t: number, rate: number): { [string]: CFrame }
	local phase = t * rate * math.pi * 2
	local left = math.sin(phase)
	local right = math.sin(phase + math.pi)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, math.abs(left) * 0.07 - 0.035, 0),
		Torso = a(17 + math.abs(left) * 2, left * 5, left * 2.5),
		Head = a(-15, -left * 6, 0),
		["Left Arm"] = a(24 - 12 * left, 0, -8),
		["Right Arm"] = a(22 - 12 * right, 0, 8),
		["Left Leg"] = a(-16 + 20 * left, 0, -4),
		["Right Leg"] = a(-16 + 20 * right, 0, 4),
	})
end

--[[
	Prone crawl: alternating elbow-drag with the torso flat.
]]
function R6Pose.Clips.ProneCrawl(t: number, rate: number): { [string]: CFrame }
	local phase = t * rate * math.pi * 2
	local left = math.sin(phase)
	local right = math.sin(phase + math.pi)
	return J({
		Torso = a(-90 + math.abs(left) * 2.5, left * 4, 0),
		Head = a(48, -left * 8, 0),
		["Left Arm"] = a(-62 + 18 * left, 0, -14 - 6 * left),
		["Right Arm"] = a(-58 + 18 * right, 0, 14 + 6 * right),
		["Left Leg"] = a(6 - 10 * right, 0, -4),
		["Right Leg"] = a(4 - 10 * left, 0, 4),
	})
end

--[[
	One-shot: airborne. `alpha` 0 == start of jump, 1 == apex.
]]
function R6Pose.Clips.Jump(alpha: number): { [string]: CFrame }
	local tuck = math.sin(alpha * math.pi)
	return J({
		Torso = a(6 - 8 * tuck, 0, 0),
		Head = a(-6, 0, 0),
		["Left Arm"] = a(-40 - 30 * tuck, 0, -18),
		["Right Arm"] = a(-40 - 30 * tuck, 0, 18),
		["Left Leg"] = a(28 + 30 * tuck, 0, -4),
		["Right Leg"] = a(10 + 14 * tuck, 0, 4),
	})
end

--[[
	One-shot: falling, arms out for balance, legs reaching for the ground.
]]
function R6Pose.Clips.Fall(alpha: number): { [string]: CFrame }
	local wobble = math.sin(alpha * math.pi * 2)
	return J({
		Torso = a(-6 + wobble * 2, wobble * 3, 0),
		Head = a(4, 0, 0),
		["Left Arm"] = a(-70 + wobble * 12, 0, -30),
		["Right Arm"] = a(-70 - wobble * 12, 0, 30),
		["Left Leg"] = a(18, 0, -6),
		["Right Leg"] = a(-8, 0, 6),
	})
end

--[[
	One-shot: landing absorb. `alpha` 0 == touch-down, 1 == recovered.
]]
function R6Pose.Clips.Land(alpha: number): { [string]: CFrame }
	local absorb = 1 - alpha
	local bend = math.sin(absorb * math.pi * 0.5)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, -bend * 0.5, 0),
		Torso = a(6 + bend * 22, 0, 0),
		Head = a(-4 - bend * 12, 0, 0),
		["Left Arm"] = a(-10 + bend * 40, 0, -10 - bend * 12),
		["Right Arm"] = a(-10 + bend * 40, 0, 10 + bend * 12),
		["Left Leg"] = a(4 - bend * 30, 0, -6 - bend * 6),
		["Right Leg"] = a(-2 - bend * 30, 0, 6 + bend * 6),
	})
end

--[[
	One-shot: ledge mantle. The body is pulled up and over a knee-high ledge.
	`alpha` 0 == hands grabbing the lip, 1 == standing on top.
]]
function R6Pose.Clips.Mantle(alpha: number): { [string]: CFrame }
	local reach = math.clamp(alpha / 0.4, 0, 1)          -- 0.0-0.4  reaching up
	local pull = math.clamp((alpha - 0.4) / 0.35, 0, 1)  -- 0.4-0.75 pulling up
	local step = math.clamp((alpha - 0.75) / 0.25, 0, 1) -- 0.75-1.0 stepping over
	local crouch = math.sin(pull * math.pi) * 0.9 + (1 - step) * 0.4
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, -0.4 * (1 - step), 0),
		Torso = a(4 + reach * 26 - step * 10, 0, 0),
		Head = a(-6 - reach * 18 + step * 20, 0, 0),
		["Left Arm"] = a(-30 - reach * 120 + pull * 40, 0, -14 - reach * 6),
		["Right Arm"] = a(-30 - reach * 120 + pull * 40, 0, 14 + reach * 6),
		["Left Leg"] = a(-6 + pull * 70 - step * 60 + crouch * 12, 0, -6),
		["Right Leg"] = a(-10 + pull * 30 - step * 20, 0, 6),
	})
end

--[[
	One-shot: vault over a waist-high obstacle while running.
]]
function R6Pose.Clips.Vault(alpha: number): { [string]: CFrame }
	local plant = math.sin(math.clamp(alpha, 0, 1) * math.pi)
	local tuck = math.sin(alpha * math.pi * 0.8)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, plant * 0.35, 0),
		Torso = a(20 + plant * 34, 0, 0),
		Head = a(-14 - plant * 6, 0, 0),
		["Left Arm"] = a(-50 - plant * 70, 0, -20),
		["Right Arm"] = a(-50 - plant * 70, 0, 20),
		["Left Leg"] = a(20 + tuck * 70, 0, -14),
		["Right Leg"] = a(-10 - tuck * 50, 0, 14),
	})
end

--[[
	One-shot: firing the equipped weapon. `alpha` 0 == rest, 1 == full kick.
]]
function R6Pose.Clips.Fire(alpha: number, kick: number): { [string]: CFrame }
	local k = math.clamp(kick, 0, 2.5)
	return J({
		Torso = a(-k * 2.2 * alpha, 0, 0),
		Head = a(k * 1.4 * alpha, 0, 0),
		["Left Arm"] = a(-k * 3.5 * alpha, 0, 0),
		["Right Arm"] = a(-k * 4.5 * alpha, 0, 0),
	})
end

--[[
	One-shot: magazine / cylinder / shell reload. `kind` picks the choreography.
]]
function R6Pose.Clips.Reload(alpha: number, kind: string): { [string]: CFrame }
	-- Two-beat motion: weapon dips toward the body, then snaps back up.
	local dip = math.sin(math.clamp(alpha, 0, 1) * math.pi)
	local leftHand: CFrame
	local rightHand: CFrame

	if kind == "Shells" then
		-- Shell-by-shell: left hand feeds the tube repeatedly.
		local feed = math.sin(alpha * math.pi * 3)
		leftHand = a(-95 + dip * 15 + feed * 14, 0, -26 - feed * 8)
		rightHand = a(-58 + dip * 10, 0, 12)
	elseif kind == "Cylinder" then
		-- Swing the cylinder out, dump brass, snap it shut.
		local swing = math.sin(math.clamp(alpha / 0.7, 0, 1) * math.pi)
		leftHand = a(-88 + swing * 22, 0, -30 - swing * 16)
		rightHand = a(-70 + swing * 26, 0, 16 + swing * 6)
	else
		-- Magazine: strip, insert, tap, charge.
		local insert = math.clamp((alpha - 0.45) / 0.35, 0, 1)
		local tap = math.sin(math.clamp((alpha - 0.82) / 0.18, 0, 1) * math.pi) * 8
		leftHand = a(-92 + dip * 18 - insert * 12 - tap, 0, -24 - dip * 8)
		rightHand = a(-62 + dip * 16 - insert * 8, 0, 12 + dip * 6)
	end

	return J({
		Torso = a(6 * dip, 6 * dip, 0),
		Head = a(10 * dip, -8 * dip, 0),
		["Left Arm"] = leftHand,
		["Right Arm"] = rightHand,
	})
end

--[[
	One-shot: reaching down to pick an item off the floor.
]]
function R6Pose.Clips.PickupFloor(alpha: number): { [string]: CFrame }
	local reach = math.sin(math.clamp(alpha, 0, 1) * math.pi * 0.9)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, -reach * 0.7, 0),
		Torso = a(reach * 62, -reach * 10, 0),
		Head = a(-reach * 18, reach * 6, 0),
		["Left Arm"] = a(-reach * 20, 0, -6),
		["Right Arm"] = a(-reach * 105, 0, 12 - reach * 6),
		["Left Leg"] = a(-reach * 24, 0, -6),
		["Right Leg"] = a(-reach * 30, 0, 6),
	})
end

--[[
	One-shot: taking an item from a shelf at chest height.
]]
function R6Pose.Clips.PickupShelf(alpha: number): { [string]: CFrame }
	local reach = math.sin(math.clamp(alpha, 0, 1) * math.pi)
	return J({
		Torso = a(6 + reach * 10, -reach * 14, 0),
		Head = a(-2, reach * 12, 0),
		["Left Arm"] = a(-reach * 30, 0, -8),
		["Right Arm"] = a(-reach * 88, 0, 14),
	})
end

--[[
	One-shot: pulling a drawer open. `alpha` 0..1 scales how far the hand
	travels, so the pose matches the drawer's animated travel. `low` is true when
	the drawer is below waist height and the character has to bend down.
]]
local function crouchBend(bend: number): number
	return bend * 42
end

function R6Pose.Clips.DrawerOpen(alpha: number, low: boolean): { [string]: CFrame }
	local pull = math.sin(math.clamp(alpha, 0, 1) * math.pi * 0.75)
	local bend = low and 1 or 0.25
	return J({
		Torso = a(crouchBend(bend) + pull * 14, -pull * 12, 0),
		Head = a(-pull * 14 * bend, pull * 10, 0),
		["Left Arm"] = a(-pull * 24, 0, -6),
		["Right Arm"] = a(-(40 + 30 * bend) - pull * 22, 0, 12 - pull * 4),
		["Left Leg"] = a(-bend * 16, 0, -5),
		["Right Leg"] = a(-bend * 20, 0, 5),
	})
end

--[[
	One-shot: swinging a cabinet door open. `alpha` 0..1 == door travel.
]]
function R6Pose.Clips.CabinetOpen(alpha: number): { [string]: CFrame }
	local pull = math.sin(math.clamp(alpha, 0, 1) * math.pi * 0.7)
	return J({
		Torso = a(4 + pull * 8, -pull * 16, 0),
		Head = a(-pull * 8, pull * 12, 0),
		["Left Arm"] = a(-pull * 28, 0, -8),
		["Right Arm"] = a(-62 - pull * 20, 0, 16 + pull * 8),
	})
end

--[[
	One-shot: throwing a bottle. `alpha` 0 == wind-up, 0.5 == release.
]]
function R6Pose.Clips.Throw(alpha: number): { [string]: CFrame }
	local wind = math.clamp(alpha / 0.4, 0, 1)
	local release = math.clamp((alpha - 0.4) / 0.35, 0, 1)
	local settle = math.clamp((alpha - 0.75) / 0.25, 0, 1)
	local swing = -wind * 60 + release * 130
	return J({
		Torso = a(-wind * 8 + release * 22 - settle * 8, wind * 18 - release * 22, 0),
		Head = a(release * 6, -wind * 10 + release * 12, 0),
		["Left Arm"] = a(-wind * 20 + release * 30, 0, -8),
		["Right Arm"] = a(-wind * 150 + swing, 0, 16 - wind * 10),
		["Left Leg"] = a(release * 12, 0, -5),
		["Right Leg"] = a(-release * 14, 0, 5),
	})
end

--[[
	One-shot: melee shove with the weapon butt (used for zombie repulsion).
]]
function R6Pose.Clips.Shove(alpha: number): { [string]: CFrame }
	local push = math.sin(math.clamp(alpha, 0, 1) * math.pi)
	return J({
		Torso = a(push * 18, push * 8, 0),
		["Left Arm"] = a(-push * 70, 0, -10),
		["Right Arm"] = a(-push * 90, 0, 12),
		["Left Leg"] = a(-push * 14, 0, -5),
		["Right Leg"] = a(push * 16, 0, 5),
	})
end

--[[
	One-shot: death collapse. `alpha` 0 == standing, 1 == on the ground.
]]
function R6Pose.Clips.Death(alpha: number): { [string]: CFrame }
	local a0 = math.clamp(alpha, 0, 1)
	local sag = math.sin(a0 * math.pi * 0.5)
	return J({
		Torso = a(-sag * 88, sag * 12, sag * 6),
		Head = a(sag * 34, 0, sag * 10),
		["Left Arm"] = a(sag * 70, 0, -sag * 30),
		["Right Arm"] = a(sag * 62, 0, sag * 26),
		["Left Leg"] = a(sag * 40, 0, -sag * 10),
		["Right Leg"] = a(sag * 28, 0, sag * 10),
	})
end

-- ------------------------------------------------------------ zombie clips --

R6Pose.Zombie = {}

--[[
	Shambling walk for the standard infected: uneven gait, head lolling.
]]
function R6Pose.Zombie.Walk(t: number, rate: number): { [string]: CFrame }
	local phase = t * rate * math.pi * 2
	local left = math.sin(phase)
	local right = math.sin(phase + math.pi)
	local lurch = math.sin(phase * 0.5)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, math.abs(left) * 0.16 - 0.08, 0),
		Torso = a(14 + math.abs(left) * 4, left * 8 + lurch * 6, left * 6),
		Head = a(-10 + lurch * 8, -left * 14, left * 10),
		["Left Arm"] = a(-58 + left * 22, 0, -10 - lurch * 6),
		["Right Arm"] = a(-52 + right * 20, 0, 12 + lurch * 6),
		["Left Leg"] = a(16 * left - 6, 0, -4),
		["Right Leg"] = a(16 * right - 4, 0, 4),
	})
end

--[[
	Aggressive run: deep forward lean, arms clawing, big stride.
]]
function R6Pose.Zombie.Run(t: number, rate: number): { [string]: CFrame }
	local phase = t * rate * math.pi * 2
	local left = math.sin(phase)
	local right = math.sin(phase + math.pi)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, math.abs(left) * 0.22 - 0.11, 0),
		Torso = a(30 + math.abs(left) * 5, left * 10, left * 5),
		Head = a(-22, -left * 12, 0),
		["Left Arm"] = a(-92 + left * 34, 0, -22),
		["Right Arm"] = a(-92 + right * 34, 0, 22),
		["Left Leg"] = a(34 * left - 8, 0, -6),
		["Right Leg"] = a(34 * right - 8, 0, 6),
	})
end

--[[
	Blind clicker idle: head cocked, listening, occasional twitch.
]]
function R6Pose.Zombie.ClickerIdle(t: number): { [string]: CFrame }
	local twitch = math.sin(t * 6.1) * math.max(0, math.sin(t * 0.7))
	local cock = math.sin(t * 0.5)
	return J({
		Torso = a(10 + twitch * 2, cock * 10, cock * 5),
		Head = a(-16, cock * 22, cock * 14 + twitch * 6),
		["Left Arm"] = a(-30 + twitch * 8, 0, -26),
		["Right Arm"] = a(-30 - twitch * 8, 0, 26),
		["Left Leg"] = a(-4, 0, -4),
		["Right Leg"] = a(-4, 0, 4),
	})
end

--[[
	One-shot: zombie claw swipe. `alpha` 0..1 == the swing.
]]
function R6Pose.Zombie.Attack(alpha: number): { [string]: CFrame }
	local swing = math.sin(math.clamp(alpha, 0, 1) * math.pi)
	return J({
		Torso = a(20 + swing * 12, -swing * 24, 0),
		Head = a(-14, swing * 16, 0),
		["Left Arm"] = a(-100 - swing * 20, 0, -20),
		["Right Arm"] = a(-120 + swing * 40, 0, 24 - swing * 30),
		["Left Leg"] = a(swing * 16, 0, -6),
		["Right Leg"] = a(-swing * 12, 0, 6),
	})
end

--[[
	One-shot: runner's leaping lunge.
]]
function R6Pose.Zombie.Lunge(alpha: number): { [string]: CFrame }
	local launch = math.sin(math.clamp(alpha, 0, 1) * math.pi)
	return J({
		["HumanoidRootPart"] = a(0, 0, 0, 0, launch * 0.6, 0),
		Torso = a(34 + launch * 20, 0, 0),
		Head = a(-26, 0, 0),
		["Left Arm"] = a(-110 - launch * 30, 0, -26),
		["Right Arm"] = a(-110 - launch * 30, 0, 26),
		["Left Leg"] = a(20 + launch * 60, 0, -8),
		["Right Leg"] = a(-10 - launch * 30, 0, 8),
	})
end

return R6Pose
