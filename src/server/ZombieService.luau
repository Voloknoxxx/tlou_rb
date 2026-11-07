--!strict
--[[
	ZombieService
	----------------------------------------------------------------------------
	Three infected archetypes with distinct senses and behaviours.

	Walker  "Infected"
		A baseline infected. Smells the player inside a scent radius regardless of
		facing, sees them inside a moderate cone, hears nearby noises. Slow but
		relentless.

	Runner
		Frail and fast. Longer sight range, reacts quicker, and lunges at close
		range. Low per-hit damage but attacks often.

	Clicker
		Completely blind - SightRange is 0 and SmellRange is 0, so it can only
		find you through the NoiseBus. In exchange its hearing radius is huge and
		it reacts almost instantly to the smallest rustle. Highest damage.

	Stealth integration
		The AI asks StealthService for the player's stance and grass state, then
		uses the shared Stealth maths to decide how long it takes to notice. In
		grass the zombie additionally has to be within GrassNoticeRadius to see
		you at all.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)
local Stealth = require(ReplicatedStorage.Shared.Stealth)
local R6Animator = require(ReplicatedStorage.Shared.R6Animator)

local NoiseBus = require(script.Parent.NoiseBus)
local StealthService = require(script.Parent.StealthService)

local ZombieService = {}

export type Zombie = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	kind: string,
	def: any,
	animator: any,
	state: string,
	target: Player?,
	notice: { [Player]: number },
	pendingNoise: { [Player]: number },
	memory: number,
	lastKnown: Vector3?,
	investigate: Vector3?,
	attackCooldown: number,
	repath: number,
	dead: boolean,
	spawnPos: Vector3,
	stuckTimer: number,
	lastPos: Vector3,
	alertPlayed: boolean,
}

local zombies: { Zombie } = {}
local aliveCount: { [string]: number } = {}
local RNG = Random.new()

-- ------------------------------------------------------------------- rigging --

local function newPart(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = false
	p.CanCollide = true
	p.Parent = parent
	return p
end

local function newMotor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame, parent: Instance): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = c0
	m.C1 = c1
	m.Parent = parent
	return m
end

--[[
	Standard R6 joint transforms. These are the exact C0/C1 values the Roblox
	engine uses for a default R6 character, reproduced here so hand-built NPC
	rigs behave identically to player characters.
]]
local HALF_PI = math.pi / 2
local function rootCF(): CFrame
	return CFrame.new(0, 0, 0) * CFrame.Angles(-HALF_PI, 0, math.pi)
end

--[[
	Builds a complete, physics-simulated R6 zombie rig at `position`.
]]
local function buildRig(kind: string, position: Vector3): (Model, Humanoid, BasePart)
	local def = Config.Zombies.Kinds[kind]
	local skin = def.Color
	local cloth = Color3.fromRGB(
		math.max(0, skin.R * 255 * 0.55),
		math.max(0, skin.G * 255 * 0.5),
		math.max(0, skin.B * 255 * 0.45)
	)

	local model = Instance.new("Model")
	model.Name = "Zombie_" .. kind

	local origin = CFrame.new(position + Vector3.new(0, 3.5, 0))
	local root = newPart("HumanoidRootPart", Vector3.new(2, 2, 1), origin, skin, model)
	root.Transparency = 1
	root.CanCollide = false
	local torso = newPart("Torso", Vector3.new(2, 2, 1), origin, cloth, model)
	local head = newPart("Head", Vector3.new(2, 1, 1), origin * CFrame.new(0, 1.5, 0), skin, model)
	local leftArm = newPart("Left Arm", Vector3.new(1, 2, 1), origin * CFrame.new(-1.5, 0, 0), skin, model)
	local rightArm = newPart("Right Arm", Vector3.new(1, 2, 1), origin * CFrame.new(1.5, 0, 0), skin, model)
	local leftLeg = newPart("Left Leg", Vector3.new(1, 2, 1), origin * CFrame.new(-0.5, -2, 0), cloth, model)
	local rightLeg = newPart("Right Leg", Vector3.new(1, 2, 1), origin * CFrame.new(0.5, -2, 0), cloth, model)

	-- Face decal so the head reads as a head from a distance.
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	mesh.Parent = head
	local face = Instance.new("Decal")
	face.Name = "Face"
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = head

	-- Joints ------------------------------------------------------------------
	newMotor("RootJoint", root, torso, rootCF(), rootCF(), root)
	newMotor("Neck", torso, head,
		CFrame.new(0, 1, 0) * CFrame.Angles(-HALF_PI, 0, math.pi),
		CFrame.new(0, -0.5, 0) * CFrame.Angles(-HALF_PI, 0, math.pi),
		torso)
	newMotor("Left Shoulder", torso, leftArm,
		CFrame.new(-1, 0.5, 0) * CFrame.Angles(0, -HALF_PI, 0),
		CFrame.new(0.5, 0.5, 0) * CFrame.Angles(0, -HALF_PI, 0),
		torso)
	newMotor("Right Shoulder", torso, rightArm,
		CFrame.new(1, 0.5, 0) * CFrame.Angles(0, HALF_PI, 0),
		CFrame.new(-0.5, 0.5, 0) * CFrame.Angles(0, HALF_PI, 0),
		torso)
	newMotor("Left Hip", torso, leftLeg,
		CFrame.new(-1, -1, 0) * CFrame.Angles(0, -HALF_PI, 0),
		CFrame.new(-0.5, 1, 0) * CFrame.Angles(0, -HALF_PI, 0),
		torso)
	newMotor("Right Hip", torso, rightLeg,
		CFrame.new(1, -1, 0) * CFrame.Angles(0, HALF_PI, 0),
		CFrame.new(0.5, 1, 0) * CFrame.Angles(0, HALF_PI, 0),
		torso)

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = def.Health
	humanoid.Health = def.Health
	humanoid.WalkSpeed = def.WalkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("ZombieKind", kind)
	model:SetAttribute("ZombieName", def.DisplayName)
	CollectionService:AddTag(model, "Zombie")

	return model, humanoid, root
end

-- ---------------------------------------------------------------- perception --

local function playerState(player: Player)
	return StealthService.getState(player)
end

--[[
	Is `target` inside the zombie's sight cone and unobstructed?
]]
local function canSee(zombie: Zombie, targetPos: Vector3, ignoreList: { Instance }): boolean
	local def = zombie.def
	if def.SightRange <= 0 then
		return false
	end
	local eye = zombie.root.Position + Vector3.new(0, 1.6, 0)
	local toTarget = targetPos - eye
	local dist = toTarget.Magnitude
	if dist > def.SightRange then
		return false
	end
	local look = zombie.root.CFrame.LookVector
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	if flat.Magnitude < 0.01 then
		return true
	end
	local dot = look.Unit:Dot(flat.Unit)
	local halfFOV = math.cos(math.rad(def.SightFOV * 0.5))
	if dot < halfFOV then
		return false
	end
	-- Trace along the true 3D line to the target's chest, not the flattened one,
	-- so cover at head height is respected.
	local chest = targetPos + Vector3.new(0, 1.4, 0)
	local ray = chest - eye
	local result = Util.raycast(eye, ray, ignoreList)
	if result and result.Instance then
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		if model ~= zombie.model then
			return false
		end
	end
	return true
end

--[[
	Picks the most noticeable player and returns (player, senseStrength) where
	senseStrength is 1/seconds-to-notice.
]]
local function evaluateSenses(zombie: Zombie): (Player?, number)
	local def = zombie.def
	local bestPlayer: Player? = nil
	local bestScore = 0

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local targetHumanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not targetRoot or not targetHumanoid or targetHumanoid.Health <= 0 then
			continue
		end
		local dist = (targetRoot.Position - zombie.root.Position).Magnitude
		if dist > math.max(def.SightRange, def.SmellRange, def.HearingRange) * 1.15 then
			continue
		end

		local state = playerState(player)
		local stance = state and state.stance or "Stand"
		local inGrass = state and state.inGrass or false
		local sprinting = state and state.sprinting or false

		local ignoreList: { Instance } = { zombie.model }
		if character then
			table.insert(ignoreList, character)
		end

		local score = 0

		-- --- sight ---------------------------------------------------------
		local visible = canSee(zombie, targetRoot.Position, ignoreList)
		-- Grass hides the player unless the zombie is right on top of them.
		if inGrass and dist > Config.Stealth.GrassNoticeRadius then
			visible = false
		end
		if visible then
			local noticeTime = Stealth.noticeTime(def.NoticeTime, stance, inGrass, sprinting)
			-- Closer targets are noticed faster.
			local proximity = 1 - Util.clamp(dist / math.max(def.SightRange, 1), 0, 1)
			score += (1 / noticeTime) * (0.6 + 0.9 * proximity)
		end

		-- --- smell ---------------------------------------------------------
		-- Grass masks scent as well as sight: buried in a thicket, only a zombie
		-- right on top of you picks up your trail.
		local smellBlocked = inGrass and dist > Config.Stealth.GrassNoticeRadius
		if def.SmellRange > 0 and dist < def.SmellRange and not smellBlocked then
			local noticeTime = Stealth.noticeTime(def.NoticeTime * 2.2, stance, inGrass, sprinting)
			local proximity = 1 - Util.clamp(dist / def.SmellRange, 0, 1)
			score += (1 / noticeTime) * (0.3 + 0.6 * proximity)
		end

		if score > bestScore then
			bestScore = score
			bestPlayer = player
		end
	end

	return bestPlayer, bestScore
end

-- ------------------------------------------------------------------ behaviour --

local function setState(zombie: Zombie, state: string)
	if zombie.state == state then
		return
	end
	zombie.state = state
	if state == "Chase" and not zombie.alertPlayed then
		zombie.alertPlayed = true
		-- Alert scream: loud and attracts other infected.
		NoiseBus.emit(zombie.root.Position, 55, "Scream", zombie.root)
	end
end

local function moveToward(zombie: Zombie, position: Vector3, speed: number)
	zombie.humanoid.WalkSpeed = speed
	zombie.humanoid:MoveTo(position)
end

local function facePosition(zombie: Zombie, position: Vector3)
	local flat = Vector3.new(position.X, zombie.root.Position.Y, position.Z)
	if (flat - zombie.root.Position).Magnitude < 0.05 then
		return
	end
	zombie.root.CFrame = CFrame.lookAt(zombie.root.Position, flat)
end

local function attackTarget(zombie: Zombie, player: Player, dist: number)
	local def = zombie.def
	if zombie.attackCooldown > 0 then
		return
	end
	zombie.attackCooldown = def.AttackCooldown

	local clip = if zombie.kind == "Runner" then "Lunge" else "Attack"
	zombie.animator:play(clip, { duration = if clip == "Lunge" then 0.6 else 0.9 })

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and dist <= def.AttackRange + 1.5 then
		humanoid:TakeDamage(def.Damage)
		Net.fireClient(player, "DamageFeedback", ("Урон %d"):format(def.Damage))
	end
end

local function updateZombie(zombie: Zombie, dt: number)
	if zombie.dead then
		return
	end
	local humanoid = zombie.humanoid
	if humanoid.Health <= 0 then
		zombie.dead = true
		setState(zombie, "Dead")
		zombie.animator:play("ZombieDeath", { duration = 1.3, priority = 50 })
		humanoid.WalkSpeed = 0
		humanoid.PlatformStand = true
		zombie.animator:step(dt)
		-- Keep the corpse animating for a moment, then clean up.
		task.delay(1.4, function()
			zombie.animator:setEnabled(false)
		end)
		Debris:AddItem(zombie.model, Config.Zombies.CorpseLifetime)
		local count = (aliveCount[zombie.kind] or 1) - 1
		aliveCount[zombie.kind] = math.max(0, count)
		return
	end

	zombie.attackCooldown = math.max(0, zombie.attackCooldown - dt)
	zombie.repath -= dt

	local speed = Vector3.new(zombie.root.AssemblyLinearVelocity.X, 0, zombie.root.AssemblyLinearVelocity.Z).Magnitude

	-- ---------------- decision tick ----------------------------------------
	local bestPlayer, score = evaluateSenses(zombie)

	-- Accumulate / decay notice per player.
	local decay = dt * 0.55
	for _, player in Players:GetPlayers() do
		local current = zombie.notice[player] or 0
		if player == bestPlayer then
			current += score * dt
		else
			current -= decay
		end
		current = Util.clamp(current, 0, 1.2)
		zombie.notice[player] = current
		if current >= 1 and (not zombie.target or current > (zombie.notice[zombie.target] or 0)) then
			zombie.target = player
		end
	end

	-- Any player whose notice has fully decayed is forgotten, otherwise a zombie
	-- would keep a stale target forever after losing sight of them.
	for player, value in zombie.notice do
		if value <= 0 then
			zombie.notice[player] = nil
		end
	end

	-- Hearing: a noise from a tracked player tops up their notice directly.
	for player, bonus in zombie.pendingNoise do
		zombie.notice[player] = (zombie.notice[player] or 0) + bonus
		if not zombie.target then
			zombie.target = player
		end
	end
	table.clear(zombie.pendingNoise)

	-- ---------------- state machine -----------------------------------------
	local target = zombie.target
	local targetRoot: BasePart? = nil
	local targetHumanoid: Humanoid? = nil
	if target then
		local character = target.Character
		targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		targetHumanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not targetRoot or not targetHumanoid or targetHumanoid.Health <= 0 or (zombie.notice[target] or 0) <= 0 then
			zombie.target = nil
			target = nil
		end
	end

	local dist = if targetRoot then (targetRoot.Position - zombie.root.Position).Magnitude else math.huge

	if target and targetRoot and (zombie.notice[target] or 0) >= 0.999 then
		zombie.lastKnown = targetRoot.Position
		zombie.memory = zombie.def.MemoryTime
		if dist <= zombie.def.AttackRange then
			setState(zombie, "Attack")
			moveToward(zombie, zombie.root.Position, 0)
			facePosition(zombie, targetRoot.Position)
			attackTarget(zombie, target, dist)
		else
			setState(zombie, "Chase")
			zombie.memory = zombie.def.MemoryTime
			if zombie.repath <= 0 then
				zombie.repath = Config.Zombies.RepathInterval
				local lead = targetRoot.Position
				if targetHumanoid then
					lead += targetHumanoid.MoveDirection * 4
				end
				moveToward(zombie, lead, zombie.def.ChaseSpeed)
			end
		end
	else
		-- No current target: decay memory and fall back to investigating.
		zombie.memory = math.max(0, zombie.memory - dt)
		if zombie.memory <= 0 and zombie.target then
			zombie.target = nil
			target = nil
		end
		if zombie.memory <= 0 then
			local inv = zombie.investigate
			if inv then
				if (inv - zombie.root.Position).Magnitude < 4 then
					zombie.investigate = nil
					setState(zombie, "Idle")
					moveToward(zombie, zombie.spawnPos + Vector3.new(RNG:NextNumber(-12, 12), 0, RNG:NextNumber(-12, 12)), zombie.def.WalkSpeed)
				else
					setState(zombie, "Investigate")
					if zombie.repath <= 0 then
						zombie.repath = Config.Zombies.RepathInterval
						moveToward(zombie, inv, zombie.def.WalkSpeed * 1.35)
					end
				end
			else
				setState(zombie, "Idle")
			end
		end
	end

	-- ---------------- stuck detection ---------------------------------------
	if zombie.state == "Chase" or zombie.state == "Investigate" then
		local moved = (zombie.root.Position - zombie.lastPos).Magnitude
		if moved < 0.25 then
			zombie.stuckTimer += dt
		else
			zombie.stuckTimer = 0
		end
		zombie.lastPos = zombie.root.Position
		if zombie.stuckTimer > 1.4 then
			zombie.stuckTimer = 0
			local jitter = Vector3.new(RNG:NextNumber(-8, 8), 0, RNG:NextNumber(-8, 8))
			moveToward(zombie, zombie.root.Position + jitter + zombie.root.CFrame.LookVector * 6, zombie.def.ChaseSpeed)
			zombie.humanoid.Jump = true
		end
	else
		zombie.stuckTimer = 0
		zombie.lastPos = zombie.root.Position
	end

	-- ---------------- animation ---------------------------------------------
	local moving = speed > 0.6
	zombie.animator:setMotion(speed, moving)
	zombie.animator:step(dt)
end

-- ------------------------------------------------------------------- spawning --

function ZombieService.spawn(kind: string, position: Vector3): Zombie?
	local def = Config.Zombies.Kinds[kind]
	if not def then
		warn(("[ZombieService] unknown kind '%s'"):format(kind))
		return nil
	end
	if (aliveCount[kind] or 0) >= Config.Zombies.MaxAlivePerKind then
		return nil
	end

	local model, humanoid, root = buildRig(kind, position)
	model.Parent = workspace

	local animator = R6Animator.new(model)
	if animator then
		animator:setZombieKind(kind)
	end

	local zombie: Zombie = {
		model = model,
		humanoid = humanoid,
		root = root,
		kind = kind,
		def = def,
		animator = animator,
		state = "Idle",
		target = nil,
		notice = {},
		pendingNoise = {},
		memory = 0,
		lastKnown = nil,
		investigate = nil,
		attackCooldown = 0,
		repath = 0,
		dead = false,
		spawnPos = position,
		stuckTimer = 0,
		lastPos = position,
		alertPlayed = false,
	} :: any

	table.insert(zombies, zombie)
	aliveCount[kind] = (aliveCount[kind] or 0) + 1
	return zombie
end

--[[
	Spawns the initial population from the tagged spawn points. A mixture of
	kinds is distributed so each archetype is represented.
]]
function ZombieService.spawnInitialPopulation()
	local spawns: { BasePart } = {}
	for _, point in CollectionService:GetTagged("ZombieSpawn") do
		if point:IsA("BasePart") then
			table.insert(spawns, point)
		end
	end
	if #spawns == 0 then
		return
	end
	local kinds = { "Walker", "Walker", "Walker", "Runner", "Runner", "Clicker" }
	for index, point in spawns do
		local kind = kinds[((index - 1) % #kinds) + 1]
		ZombieService.spawn(kind, point.Position)
	end
end

--[[
	Removes a zombie immediately (used by tests / cleanup).
]]
function ZombieService.despawn(zombie: Zombie)
	zombie.dead = true
	if zombie.model.Parent then
		zombie.model:Destroy()
	end
	for i, other in zombies do
		if other == zombie then
			table.remove(zombies, i)
			break
		end
	end
end

function ZombieService.count(): number
	return #zombies
end

--[[
	Wires the noise listener and the AI heartbeat.
]]
function ZombieService.start()
	-- Hearing: every noise event is delivered to zombies inside their hearing
	-- radius. The amount of "notice" a noise grants scales with how loud it is
	-- relative to the zombie's hearing ability.
	NoiseBus.subscribe(function(noise)
		for _, zombie in zombies do
			if zombie.dead then
				continue
			end
			local dist = (noise.Position - zombie.root.Position).Magnitude
			local hearing = zombie.def.HearingRange
			if dist > hearing then
				continue
			end
			-- Loudness falls off with distance.
			local loudness = 1 - Util.clamp(dist / hearing, 0, 1)
			local strength = Util.clamp(noise.Radius / 60, 0.05, 1) * loudness

			-- Set the investigation point (all zombies react to sounds).
			zombie.investigate = noise.Position
			if zombie.state == "Idle" then
				zombie.memory = math.max(zombie.memory, 2.5)
			end

			if noise.Player then
				local bonus = strength * (2.2 / math.max(zombie.def.NoticeTime, 0.2))
				zombie.pendingNoise[noise.Player] = (zombie.pendingNoise[noise.Player] or 0) + bonus
				Net.fireClient(noise.Player, "ZombieAlerted", zombie.root.Position)
			end
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		for i = #zombies, 1, -1 do
			local zombie = zombies[i]
			if not zombie.model.Parent then
				table.remove(zombies, i)
				continue
			end
			local ok, err = pcall(updateZombie, zombie, dt)
			if not ok then
				warn(("[ZombieService] update error on %s: %s"):format(zombie.kind, tostring(err)))
			end
		end
	end)
end

return ZombieService
