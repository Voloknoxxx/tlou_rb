--!strict
--[[
	AnimationSystem
	The maths behind every character animation in the pack. It is a pure
	function: given how the character is moving, it returns a pose. No
	Roblox state, no instances, no side effects - which makes it testable
	and makes the animator that applies it trivial.

	Why not Roblox animation assets?
	* The pack has to drop into any place with no upload step, so there are
	  no animation ids to reference.
	* We need poses that depend on live state (aim, lean, turn rate, how
	  fast you are actually moving). A fixed clip cannot blend like that.

	A pose is expressed in the character's own frame, in degrees:
	    pitch  rotation about the character's right axis (swing forward)
	    yaw    rotation about the character's up axis (twist)
	    roll   rotation about the character's forward axis (tilt)
	and, for the root, a world-space offset. The animator converts those
	into Motor6D.Transform values. Authoring in degrees in the character's
	frame is what keeps a walk cycle readable no matter which way you face.
]]

local Config = require(script.Parent.Config)

local AnimationSystem = {}

local ANIM = Config.Animation
local MOVE = Config.Movement

-- Stance weights are 0..1 blends the caller smooths over time.
AnimationSystem.EMPTY_WEIGHTS = {
	crouch = 0,
	prone = 0,
	aim = 0,
	sprint = 0,
	air = 0,
	vault = 0,
	downed = 0,
	armed = 0,
}

local function clamp01(v: number): number
	return math.max(0, math.min(1, v))
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--- A fresh set of animation accumulators. The caller owns one of these per
--- character and passes it back on every call.
function AnimationSystem.newState()
	return {
		phase = 0, -- walk cycle, in radians
		turnPhase = 0, -- turn-in-place stepping, in radians
		breath = 0, -- idle breathing timer, in seconds
		lastYaw = nil, -- previous body yaw, for measuring turn rate
	}
end

--- One pose channel. Everything starts at rest so a pose is just data.
local function channel(): { pitch: number, yaw: number, roll: number }
	return { pitch = 0, yaw = 0, roll = 0 }
end

--- How fast the walk cycle should advance this frame, in radians.
--- Driving the phase from distance travelled is what stops the feet from
--- skating: walk slower and the legs cycle slower, automatically.
function AnimationSystem.strideAdvance(speed: number, sprinting: boolean, dt: number): number
	local perStud = (math.pi * 2) / math.max(ANIM.StrideLength, 0.1)
	local boost = sprinting and ANIM.SprintStrideBoost or 1
	return speed * perStud * boost * dt
end

--- How much the body should yaw this frame toward the camera, plus the
--- resulting turn rate. Turn rate is what feeds turn-in-place stepping, so
--- this is the single place that decides how heavy a turn feels.
---
--- `boost` scales the turn speed. The camera uses it while the player is
--- moving, so a strafe snaps the body around rather than turning it with a
--- slow pirouette.
function AnimationSystem.bodyTurn(currentYaw: number, targetYaw: number, aiming: boolean, dt: number, boost: number?): (number, number)
	local delta = math.atan2(math.sin(targetYaw - currentYaw), math.cos(targetYaw - currentYaw))
	local speed = (aiming and MOVE.TurnSpeedAiming or MOVE.TurnSpeed) * (boost or 1)
	local step = delta * (1 - math.exp(-speed * dt))
	return currentYaw + step, step / math.max(dt, 1e-4)
end

--- Computes the pose for this frame.
---
--- input fields:
---   dt         delta time
---   speed      horizontal speed in studs/second
---   turnRate   signed yaw rate in radians/second
---   grounded   standing on something
---   weights    stance blend weights (see EMPTY_WEIGHTS)
---   anim       accumulator from newState() (mutated in place)
function AnimationSystem.computePose(input)
	local dt = input.dt
	local speed = input.speed or 0
	local turnRate = input.turnRate or 0
	local grounded = input.grounded ~= false
	local w = input.weights or AnimationSystem.EMPTY_WEIGHTS
	local anim = input.anim

	local crouch = clamp01(w.crouch or 0)
	local prone = clamp01(w.prone or 0)
	local aim = clamp01(w.aim or 0)
	local sprint = clamp01(w.sprint or 0)
	local air = clamp01(w.air or 0)
	local vault = clamp01(w.vault or 0)
	local downed = clamp01(w.downed or 0)
	local armed = clamp01(w.armed or 0)

	-- Grounded locomotion only counts while actually on the floor.
	local moving = speed > 0.6 and grounded
	local speedFactor = math.clamp(speed / math.max(MOVE.WalkSpeed, 1), 0, 1.8)
	local cycleFactor = math.min(speedFactor, 1.35)

	-- Advance the walk cycle by distance travelled.
	local phase = anim.phase or 0
	if moving then
		phase = (phase + AnimationSystem.strideAdvance(speed, sprint > 0.5, dt)) % (math.pi * 2)
	end
	anim.phase = phase

	-- Turn-in-place: when the body yaws but the feet are not travelling,
	-- step them. This is the detail that makes a third-person character
	-- read as "turning" rather than pivoting like a turret.
	local turnPhase = anim.turnPhase or 0
	local turning = grounded and speed < ANIM.TurnMinSpeed and math.abs(turnRate) > ANIM.TurnDeadzone
	local turnDir = 0
	if turning then
		turnDir = turnRate > 0 and 1 or -1
		turnPhase = turnPhase + math.abs(turnRate) * ANIM.TurnStepRate * dt
	end
	anim.turnPhase = turnPhase

	-- Idle breathing timer.
	local breath = (anim.breath or 0) + dt
	anim.breath = breath

	-- ------------------------------------------------------------------
	-- Base walk cycle
	-- ------------------------------------------------------------------
	local legAmp = lerp(ANIM.LegSwing, ANIM.RunLegSwing, sprint) * cycleFactor
	local armAmp = lerp(ANIM.ArmSwing, ANIM.RunArmSwing, sprint) * cycleFactor
	-- Aiming pins the arms to the weapon.
	armAmp = armAmp * (1 - aim * 0.85)

	local swing = math.sin(phase)
	local swingAbs = math.abs(swing)

	local leftLeg = channel()
	local rightLeg = channel()
	local leftArm = channel()
	local rightArm = channel()
	local torso = channel()
	local head = channel()
	local root = channel()

	leftLeg.pitch = swing * legAmp
	rightLeg.pitch = -swing * legAmp
	-- Arms swing opposite the legs.
	rightArm.pitch = swing * armAmp
	leftArm.pitch = -swing * armAmp

	-- Shoulders counter-rotate against the hips.
	torso.yaw = -swing * ANIM.TorsoYaw * cycleFactor
	torso.roll = -math.cos(phase) * ANIM.TorsoRoll * cycleFactor
	-- Sprinting pitches the torso forward.
	torso.pitch = ANIM.LeanForward * sprint * cycleFactor

	-- Feet leave the ground slightly at the peak of the stride.
	local footLift = swingAbs * cycleFactor
	leftLeg.pitch = leftLeg.pitch - footLift * 4
	rightLeg.pitch = rightLeg.pitch - footLift * 4

	-- Body bob: up at mid-stride, plus a little lateral sway.
	local bobY = swingAbs * ANIM.BobAmplitude * (0.6 + cycleFactor * 0.5)
	local bobX = math.cos(phase) * ANIM.BobLateral * cycleFactor

	-- ------------------------------------------------------------------
	-- Turn-in-place stepping
	-- ------------------------------------------------------------------
	if turning then
		local step = math.sin(turnPhase) * ANIM.TurnStepSwing
		-- The leading foot depends on which way we are turning.
		leftLeg.pitch = leftLeg.pitch + step * turnDir
		rightLeg.pitch = rightLeg.pitch - step * turnDir
		torso.yaw = torso.yaw + step * 0.25 * turnDir
		bobY = bobY + math.abs(math.sin(turnPhase)) * ANIM.BobAmplitude * 0.5
	else
		-- Let the stepping phase decay to zero so it does not pop.
		anim.turnPhase = turnPhase * (1 - math.min(1, 6 * dt))
	end

	-- ------------------------------------------------------------------
	-- Idle breathing (only when not moving, so it never fights the stride)
	-- ------------------------------------------------------------------
	local idleWeight = (1 - clamp01(speedFactor)) * (1 - prone) * (1 - downed)
	if idleWeight > 0 then
		local breathCycle = math.sin(breath * math.pi * 2 * ANIM.IdleBreath)
		torso.pitch = torso.pitch + breathCycle * ANIM.IdleBreathAmp * idleWeight
		leftArm.pitch = leftArm.pitch + breathCycle * ANIM.IdleBreathAmp * 0.5 * idleWeight
		rightArm.pitch = rightArm.pitch + breathCycle * ANIM.IdleBreathAmp * 0.5 * idleWeight
	end

	-- ------------------------------------------------------------------
	-- Armed: carry the weapon at the hip, or raise it to aim
	-- ------------------------------------------------------------------
	if armed > 0 then
		-- Blend from a free-swinging arm to a braced, weapon-carrying arm.
		-- Even while walking the arms stay mostly braced, which is what
		-- reads as "carrying a gun" rather than "walking hands free".
		local brace = armed * (1 - aim * 0.15)
		leftArm.pitch = lerp(leftArm.pitch, ANIM.ReadyLeftArmPitch, brace)
		rightArm.pitch = lerp(rightArm.pitch, ANIM.ReadyArmPitch, brace)
		leftArm.yaw = lerp(leftArm.yaw, -ANIM.ReadyArmYaw, brace)
		rightArm.yaw = lerp(rightArm.yaw, ANIM.ReadyArmYaw, brace)
		torso.yaw = lerp(torso.yaw, torso.yaw * 0.4, brace)
	end

	-- ------------------------------------------------------------------
	-- Aiming: raise both arms to the weapon and bring them together
	-- ------------------------------------------------------------------
	if aim > 0 then
		leftArm.pitch = lerp(leftArm.pitch, ANIM.AimArmPitch, aim)
		rightArm.pitch = lerp(rightArm.pitch, ANIM.AimArmPitch, aim)
		leftArm.yaw = lerp(leftArm.yaw, -ANIM.AimArmYaw, aim)
		rightArm.yaw = lerp(rightArm.yaw, ANIM.AimArmYaw, aim)
		torso.yaw = lerp(torso.yaw, 0, aim * 0.7)
	end

	-- ------------------------------------------------------------------
	-- Stances: crouch, prone, downed, air, vault
	-- ------------------------------------------------------------------
	local drop = 0

	if crouch > 0 then
		torso.pitch = lerp(torso.pitch, ANIM.CrouchTorsoPitch, crouch)
		leftLeg.pitch = lerp(leftLeg.pitch, ANIM.CrouchLegPitch, crouch)
		rightLeg.pitch = lerp(rightLeg.pitch, ANIM.CrouchLegPitch, crouch)
		-- Knees bend outward a touch so the pose does not look flat.
		leftLeg.roll = lerp(leftLeg.roll, -6, crouch)
		rightLeg.roll = lerp(rightLeg.roll, 6, crouch)
		drop = drop + ANIM.CrouchDrop * crouch
	end

	if prone > 0 or downed > 0 then
		local lie = math.max(prone, downed)
		root.pitch = lerp(root.pitch, ANIM.ProneTorsoPitch, lie)
		leftLeg.pitch = lerp(leftLeg.pitch, ANIM.ProneLegPitch, lie)
		rightLeg.pitch = lerp(rightLeg.pitch, ANIM.ProneLegPitch, lie)
		leftArm.pitch = lerp(leftArm.pitch, ANIM.ProneArmPitch, lie * 0.7)
		rightArm.pitch = lerp(rightArm.pitch, ANIM.ProneArmPitch, lie * 0.7)
		drop = drop + ANIM.ProneDrop * lie
		bobX = 0
		bobY = 0
	end

	if air > 0 then
		-- Legs tuck up and arms come out for balance.
		leftLeg.pitch = lerp(leftLeg.pitch, ANIM.AirLegPitch, air)
		rightLeg.pitch = lerp(rightLeg.pitch, -ANIM.AirLegPitch * 0.4, air)
		leftArm.pitch = lerp(leftArm.pitch, ANIM.AirArmPitch, air * (1 - aim))
		rightArm.pitch = lerp(rightArm.pitch, ANIM.AirArmPitch, air * (1 - aim))
		torso.pitch = lerp(torso.pitch, ANIM.LeanForward * 0.5, air)
		bobY = 0
	end

	if vault > 0 then
		-- One leg swings over, the other trails, arms reach forward.
		leftLeg.pitch = lerp(leftLeg.pitch, ANIM.VaultLegPitch, vault)
		rightLeg.pitch = lerp(rightLeg.pitch, -ANIM.VaultLegPitch * 0.5, vault)
		leftArm.pitch = lerp(leftArm.pitch, ANIM.VaultArmPitch, vault)
		rightArm.pitch = lerp(rightArm.pitch, ANIM.VaultArmPitch, vault)
		torso.pitch = lerp(torso.pitch, ANIM.LeanForward, vault)
		bobY = 0
	end

	-- ------------------------------------------------------------------
	-- Head: stabilise against torso motion so the gaze stays level.
	-- ------------------------------------------------------------------
	head.pitch = -torso.pitch * ANIM.HeadStabilise
	head.yaw = -torso.yaw * ANIM.HeadStabilise
	head.roll = -torso.roll * ANIM.HeadStabilise

	local pose = {
		root = root,
		torso = torso,
		head = head,
		leftArm = leftArm,
		rightArm = rightArm,
		leftLeg = leftLeg,
		rightLeg = rightLeg,
		offset = Vector3.new(bobX, bobY - drop, 0),
		phase = phase,
		moving = moving,
	}

	return pose
end

--- Smoothly moves a set of stance weights toward a target set. Called once
--- per frame by the animator so stance changes ease instead of snapping.
function AnimationSystem.blendWeights(current, target, dt: number, speed: number?)
	local alpha = 1 - math.exp(-(speed or ANIM.BlendSpeed) * dt)
	for key in pairs(AnimationSystem.EMPTY_WEIGHTS) do
		local from = current[key] or 0
		local to = target[key] or 0
		current[key] = from + (to - from) * alpha
	end
	return current
end

return AnimationSystem
