--!strict
--[[
	R6Animator
	----------------------------------------------------------------------------
	Turns the declarative clips in R6Pose into live motion on an R6 rig.

	How it works
		* Every Motor6D of an R6 character has a *rest* C0. The animator caches
		  those once, then each frame writes

		      motor.C0 = restC0 * pose[motor]

		  so a pose is a pure, stateless description of the skeleton.
		* Locomotion is a continuous clip parameterised by time, cycle rate and
		  intensity. There is no keyframe stepping, so it is smooth at any
		  framerate and the feet never skate because the rate is derived from
		  the character's real speed.
		* Full-body one-shots (reload, mantle, pickup, death...) cross-fade on
		  top with a smooth envelope.
		* Additive one-shots (recoil, shove) are layered on with R6Pose.add so
		  they never interrupt locomotion.

	Usage
		animator = R6Animator.new(character)
		animator:setStance("Crouch")
		animator:setMotion(speed, moving)
		animator:play("Reload", { duration = 2.3, args = { "Magazine" } })
		RunService.RenderStepped:Connect(function(dt) animator:step(dt) end)
]]

local R6Pose = require(script.Parent.R6Pose)
local Util = require(script.Parent.Util)

local R6Animator = {}
R6Animator.__index = R6Animator

local MOTOR_FOR_JOINT: { [string]: string } = {
	["HumanoidRootPart"] = "RootJoint",
	Head = "Neck",
	["Left Arm"] = "Left Shoulder",
	["Right Arm"] = "Right Shoulder",
	["Left Leg"] = "Left Hip",
	["Right Leg"] = "Right Hip",
}

-- Clip descriptors: where each clip lives, whether it is additive, and how long
-- it lasts by default.
local CLIPS: { [string]: { additive: boolean, duration: number } } = {
	Idle = { additive = false, duration = 0 },
	Locomotion = { additive = false, duration = 0 },
	CrouchLocomotion = { additive = false, duration = 0 },
	ProneCrawl = { additive = false, duration = 0 },
	Jump = { additive = false, duration = 0.5 },
	Fall = { additive = false, duration = 0.6 },
	Land = { additive = false, duration = 0.4 },
	Mantle = { additive = false, duration = 0.55 },
	Vault = { additive = false, duration = 0.42 },
	Reload = { additive = false, duration = 2.3 },
	PickupFloor = { additive = false, duration = 0.85 },
	PickupShelf = { additive = false, duration = 0.85 },
	DrawerOpen = { additive = false, duration = 0.5 },
	CabinetOpen = { additive = false, duration = 0.65 },
	Throw = { additive = false, duration = 0.7 },
	Shove = { additive = false, duration = 0.4 },
	Death = { additive = false, duration = 1.4 },
	Fire = { additive = true, duration = 0.22 },
	-- zombie-specific one-shots
	Attack = { additive = false, duration = 0.9 },
	Lunge = { additive = false, duration = 0.6 },
	ZombieDeath = { additive = false, duration = 1.3 },
}

export type ActiveClip = {
	name: string,
	elapsed: number,
	duration: number,
	weight: number,
	priority: number,
	args: { any },
	finished: boolean,
}

export type Animator = typeof(setmetatable({} :: any, R6Animator))

--[[
	Creates an animator bound to an R6 character. Returns nil if the character is
	not a usable R6 rig.
]]
function R6Animator.new(character: Model): Animator?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return nil
	end

	local self = setmetatable({}, R6Animator) :: any
	self.character = character
	self.humanoid = humanoid
	self.root = root
	self.motors = {} :: { [string]: Motor6D }
	self.rest = {} :: { [string]: CFrame }

	-- Locomotion state
	self.stance = "Stand"
	self.stanceBlend = 0 -- 0 stand, 1 crouch, 2 prone (smoothed)
	self.speed = 0
	self.moving = false
	self.cycleRate = 0
	self.cycleTime = 0
	self.clipRate = 0
	self.idleTime = 0

	-- Overlay state
	self.clips = {} :: { ActiveClip }
	self.enabled = true
	self.yawOffset = 0
	self.torsoLean = 0
	self.headAim = Vector2.new(0, 0)
	self.bobEnabled = true

	-- Zombie rigs use a completely different locomotion clip set.
	self.zombieKind = nil :: string?

	self:_cacheMotors()
	if next(self.motors) == nil then
		return nil
	end
	return self
end

function R6Animator:_cacheMotors()
	for joint, motorName in MOTOR_FOR_JOINT do
		local motor = self.character:FindFirstChild(motorName, true)
		if motor and motor:IsA("Motor6D") then
			self.motors[joint] = motor
			self.rest[joint] = motor.C0
		end
	end
end

--[[
	Call after a rig change (e.g. a R6 accessory welded in) to refresh caches.
]]
function R6Animator:refresh()
	self.motors = {}
	self.rest = {}
	self:_cacheMotors()
end

function R6Animator:setEnabled(on: boolean)
	self.enabled = on
end

--[[
	"Stand" | "Crouch" | "Prone"
]]
function R6Animator:setStance(stance: string)
	self.stance = stance
end

--[[
	Feeds the locomotion solver. `speed` is the horizontal speed in studs/s and
	`moving` is whether the player is actively driving the character.
	The cycle rate is derived from speed so the gait matches the ground travel.
]]
function R6Animator:setMotion(speed: number, moving: boolean)
	self.speed = speed
	self.moving = moving
end

--[[
	Extra torso yaw/lean used by the movement controller for turns and slopes.
]]
function R6Animator:setBodyOffsets(yawOffset: number, lean: number)
	self.yawOffset = yawOffset
	self.torsoLean = lean
end

--[[
	-1..1 head aim, applied on top of the head clip for over-the-shoulder look.
]]
function R6Animator:setHeadAim(yaw: number, pitch: number)
	self.headAim = Vector2.new(Util.clamp(yaw, -1, 1), Util.clamp(pitch, -1, 1))
end

--[[
	Plays a one-shot clip. Re-playing the same clip restarts it. Clips with a
	lower-or-equal priority are cancelled so the newest motion wins.
]]
function R6Animator:play(name: string, opts: { duration: number?, weight: number?, priority: number?, args: { any }?, restart: boolean? }?): boolean
	local desc = CLIPS[name]
	if not desc then
		warn(("[R6Animator] unknown clip '%s'"):format(name))
		return false
	end
	local o = opts or {}
	local priority = o.priority or 10
	local desc = CLIPS[name]

	-- Cancel clips that this one supersedes. Additive clips (recoil, shove)
	-- layer on top and never interrupt full-body motion.
	local kept = {} :: { ActiveClip }
	for _, clip in self.clips do
		local keep = true
		if clip.name == name and o.restart ~= false then
			keep = false
		elseif not desc.additive and clip.priority <= priority then
			keep = false
		end
		if keep then
			table.insert(kept, clip)
		end
	end
	self.clips = kept

	table.insert(self.clips, {
		name = name,
		elapsed = 0,
		duration = o.duration or desc.duration,
		weight = o.weight or 1,
		priority = priority,
		args = o.args or {},
		finished = false,
	})
	return true
end

function R6Animator:stop(name: string)
	local kept = {} :: { ActiveClip }
	for _, clip in self.clips do
		if clip.name ~= name then
			table.insert(kept, clip)
		end
	end
	self.clips = kept
end

function R6Animator:stopAll()
	self.clips = {}
end

function R6Animator:isPlaying(name: string): boolean
	for _, clip in self.clips do
		if clip.name == name then
			return true
		end
	end
	return false
end

--[[
	Smooth envelope for a one-shot: ease in over the first 18%, out over the last
	28%. Returns 0..1.
]]
local function envelope(alpha: number): number
	local easeIn = Util.clamp(alpha / 0.18, 0, 1)
	local easeOut = Util.clamp((1 - alpha) / 0.28, 0, 1)
	local e = math.min(easeIn, easeOut)
	return e * e * (3 - 2 * e) -- smoothstep
end

--[[
	Evaluates the locomotion base pose for the current stance blend and motion.
]]
function R6Animator:_basePose(): { [string]: CFrame }
	if self.zombieKind then
		return self:_zombiePose()
	end

	local pose = R6Pose.Static.Idle
	pose = R6Pose.lerp(R6Pose.Static.Idle, R6Pose.Static.Crouch, Util.clamp(self.stanceBlend, 0, 1))
	pose = R6Pose.lerp(pose, R6Pose.Static.Prone, Util.clamp(self.stanceBlend - 1, 0, 1))

	-- Overlay the movement cycle when the character is actually travelling.
	local moving = self.moving and self.speed > 0.4
	if moving then
		local intensity = Util.clamp(self.speed / 24, 0, 1)
		local cycle: { [string]: CFrame }
		if self.stanceBlend < 0.5 then
			cycle = R6Pose.Clips.Locomotion(self.cycleTime, 1, intensity)
		elseif self.stanceBlend < 1.5 then
			cycle = R6Pose.Clips.CrouchLocomotion(self.cycleTime, 1)
		else
			cycle = R6Pose.Clips.ProneCrawl(self.cycleTime, 1)
		end
		-- Blend the cycle in proportionally to how fast we are moving.
		local cycleWeight = Util.clamp(self.speed / 3, 0, 1)
		pose = R6Pose.lerp(pose, cycle, cycleWeight)
	end

	return pose
end

--[[
	Marks this animator as driving a zombie rig of the given kind, which swaps
	the locomotion clip set for the shambling infected clips.
]]
function R6Animator:setZombieKind(kind: string?)
	self.zombieKind = kind
end

--[[
	Zombie locomotion: shambling walk below a speed threshold, aggressive run
	above it, with the Clicker using its own listening idle.
]]
function R6Animator:_zombiePose(): { [string]: CFrame }
	local kind = self.zombieKind
	local moving = self.moving and self.speed > 0.4

	if kind == "Clicker" then
		if moving then
			local intensity = Util.clamp(self.speed / 18, 0, 1)
			local clip = R6Pose.Zombie.Run(self.cycleTime, 1)
			local idle = R6Pose.Zombie.ClickerIdle(self.idleTime)
			return R6Pose.lerp(idle, clip, 0.35 + intensity * 0.65)
		end
		return R6Pose.Zombie.ClickerIdle(self.idleTime)
	end

	if moving then
		if self.speed > 9 then
			return R6Pose.Zombie.Run(self.cycleTime, 1)
		end
		return R6Pose.Zombie.Walk(self.cycleTime, 1)
	end
	-- Idle: freeze the walk clip at a neutral phase so limbs settle.
	return R6Pose.Zombie.Walk(0.25, 0.05)
end

--[[
	Advances a one-shot clip's time and returns its current pose contribution.
]]
function R6Animator:_evaluateClip(clip: ActiveClip): { [string]: CFrame }
	local alpha = 1
	if clip.duration > 0 then
		alpha = Util.clamp(clip.elapsed / clip.duration, 0, 1)
	end
	local name = clip.name
	local args = clip.args

	if name == "Jump" then
		return R6Pose.Clips.Jump(alpha)
	elseif name == "Fall" then
		return R6Pose.Clips.Fall(alpha)
	elseif name == "Land" then
		return R6Pose.Clips.Land(alpha)
	elseif name == "Mantle" then
		return R6Pose.Clips.Mantle(alpha)
	elseif name == "Vault" then
		return R6Pose.Clips.Vault(alpha)
	elseif name == "Reload" then
		return R6Pose.Clips.Reload(alpha, args[1] or "Magazine")
	elseif name == "PickupFloor" then
		return R6Pose.Clips.PickupFloor(alpha)
	elseif name == "PickupShelf" then
		return R6Pose.Clips.PickupShelf(alpha)
	elseif name == "DrawerOpen" then
		return R6Pose.Clips.DrawerOpen(alpha, args[1] == true)
	elseif name == "CabinetOpen" then
		return R6Pose.Clips.CabinetOpen(alpha)
	elseif name == "Throw" then
		return R6Pose.Clips.Throw(alpha)
	elseif name == "Shove" then
		return R6Pose.Clips.Shove(alpha)
	elseif name == "Death" then
		return R6Pose.Clips.Death(alpha)
	elseif name == "Fire" then
		return R6Pose.Clips.Fire(alpha, args[1] or 1)
	elseif name == "Attack" then
		return R6Pose.Zombie.Attack(alpha)
	elseif name == "Lunge" then
		return R6Pose.Zombie.Lunge(alpha)
	elseif name == "ZombieDeath" then
		return R6Pose.Clips.Death(alpha)
	end
	return R6Pose.identity()
end

--[[
	Advances every clip and applies the composed pose to the motors.
	Call once per frame.
]]
function R6Animator:step(dt: number)
	if not self.enabled then
		return
	end
	if not self.character.Parent or self.humanoid.Health <= 0 then
		return
	end

	-- Smooth the stance blend so crouch/prone transitions are eased.
	local targetBlend = if self.stance == "Prone" then 2 elseif self.stance == "Crouch" then 1 else 0
	self.stanceBlend = Util.damp(self.stanceBlend, targetBlend, 9, dt)

	-- Advance the locomotion cycle. Rate scales with speed so the feet plant.
	local strideHz = Util.clamp(0.55 + self.speed * 0.075, 0.55, 2.6)
	self.cycleRate = Util.damp(self.cycleRate, if self.moving then strideHz else 0, 6, dt)
	self.cycleTime += dt * self.cycleRate
	self.idleTime += dt

	local pose = self:_basePose()

	-- Compose overlays. Sort so higher priority clips land last.
	local clips = table.clone(self.clips)
	table.sort(clips, function(a, b)
		return a.priority < b.priority
	end)

	for _, clip in clips do
		if clip.duration > 0 then
			clip.elapsed += dt
		end
		local alpha = if clip.duration > 0 then Util.clamp(clip.elapsed / clip.duration, 0, 1) else 1
		local clipPose = self:_evaluateClip(clip)
		local desc = CLIPS[clip.name]
		if desc and desc.additive then
			pose = R6Pose.add(pose, clipPose, clip.weight)
		else
			pose = R6Pose.lerp(pose, clipPose, envelope(alpha) * clip.weight)
		end
		if alpha >= 1 and clip.duration > 0 then
			clip.finished = true
		end
	end

	-- Drop finished clips.
	local live = {} :: { ActiveClip }
	for _, clip in clips do
		if not clip.finished then
			table.insert(live, clip)
		end
	end
	self.clips = live

	-- Body offsets from the movement controller.
	if self.yawOffset ~= 0 or self.torsoLean ~= 0 then
		pose = R6Pose.add(pose, {
			Torso = CFrame.Angles(0, self.yawOffset, self.torsoLean),
		}, 1)
	end

	-- Head aim (over-the-shoulder look).
	if self.headAim.Magnitude > 0.001 then
		pose = R6Pose.add(pose, {
			Head = CFrame.Angles(math.rad(-self.headAim.Y * 22), math.rad(self.headAim.X * 34), 0),
		}, 1)
	end

	self:_apply(pose)
end

function R6Animator:_apply(pose: { [string]: CFrame })
	for joint, motor in self.motors do
		local rest = self.rest[joint]
		local offset = pose[joint]
		if rest and offset and motor.Parent then
			motor.C0 = rest * offset
		end
	end
end

return R6Animator
