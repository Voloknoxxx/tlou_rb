--!strict
--[[
	Config
	Central tuning table for every gameplay system. All tunables live here so the
	whole game can be re-balanced from a single file.
]]

local Config = {}

-- ---------------------------------------------------------------- movement --
Config.Movement = {
	WalkSpeed = 13,
	SprintSpeed = 22,
	CrouchSpeed = 7,
	ProneSpeed = 4,
	-- How fast the humanoid's WalkSpeed is allowed to move toward its target.
	-- Low values give the heavy, momentum-driven feel of the reference game.
	SpeedAccel = 9.5,
	SpeedDecel = 12,

	JumpPower = 48,

	-- Parkour ------------------------------------------------------------------
	MantleHeightMin = 2.2,   -- lowest ledge the character will climb onto
	MantleHeightMax = 6.5,   -- highest ledge
	MantleReach = 3.2,       -- forward probe distance
	MantleDuration = 0.55,   -- seconds of the climb animation
	VaultMaxHeight = 3.4,    -- obstacle height that gets "vaulted" instead
	VaultDuration = 0.42,
	ParkourCooldown = 0.25,
	RunJumpBoost = 1.12,     -- small forward boost when jumping while sprinting

	-- Stamina ------------------------------------------------------------------
	StaminaMax = 100,
	SprintDrain = 12,        -- per second while sprinting on the ground
	JumpCost = 9,
	MantleCost = 12,
	RegenRate = 16,          -- per second while idle / walking
	RegenDelay = 1.1,        -- seconds before regen kicks in
	ExhaustedThreshold = 6,  -- below this you cannot sprint until partly recovered
	ExhaustedRecover = 28,

	-- Stance timings -----------------------------------------------------------
	CrouchTime = 0.22,
	ProneTime = 0.34,
}

-- ------------------------------------------------------------------ combat --
Config.Combat = {
	HeadshotMultiplier = 2.6,
	FalloffStart = 60,
	FalloffEnd = 190,
	FalloffMinMultiplier = 0.45,
	MaxRange = 500,
	-- Server-side fire-rate sanity limit (shots per second) to reject exploits.
	MaxShotsPerSecond = 18,
}

-- ------------------------------------------------------------------ stealth --
Config.Stealth = {
	-- How much longer a zombie takes to notice the player, per stance.
	-- 1.0 == standing baseline.
	StandMultiplier = 1.0,
	CrouchMultiplier = 1.5,
	ProneMultiplier = 2.0,
	-- Multiplier applied while inside grass (stacks with stance).
	GrassMultiplier = 0.25,
	-- Inside grass the zombie must be this close (studs) to notice at all.
	GrassNoticeRadius = 7,
	-- Base noise radius produced by locomotion, in studs.
	NoiseWalk = 16,
	NoiseSprint = 44,
	NoiseCrouch = 5,
	NoiseProne = 2,
	-- Noise radius multiplier while in grass.
	GrassNoiseMultiplier = 0.4,
	-- Minimum distance for "you are fully hidden" state.
	HiddenEpsilon = 1.0,
}

-- -------------------------------------------------------------------- items --
Config.Items = {
	MaxInventory = 6,
	PickupRange = 7,
	DrawerRange = 6,
	DrawerOpenAngle = 78,
	DrawerOpenTime = 0.5,
	CabinetRange = 7,
	CabinetOpenAngle = 105,
	CabinetOpenTime = 0.65,
	PickupTime = 0.85,
	ThrowVelocity = 78,
	ThrowCooldown = 0.7,
}

-- ------------------------------------------------------------------ zombies --
Config.Zombies = {
	Kinds = {
		Walker = {
			DisplayName = "Infected",
			Health = 140,
			WalkSpeed = 7.5,
			ChaseSpeed = 13.5,
			Damage = 17,
			AttackCooldown = 1.35,
			AttackRange = 5.2,
			SightRange = 90,
			SightFOV = 105,          -- degrees, half-angle applied per side
			HearingRange = 46,
			SmellRange = 34,         -- "scent" radius, ignores facing
			NoticeTime = 1.0,        -- seconds of exposure before it locks on
			MemoryTime = 8,          -- seconds it keeps chasing after losing you
			Color = Color3.fromRGB(96, 108, 74),
		},
		Runner = {
			DisplayName = "Runner",
			Health = 95,
			WalkSpeed = 9,
			ChaseSpeed = 25,
			Damage = 9,
			AttackCooldown = 0.75,
			AttackRange = 5.0,
			SightRange = 110,
			SightFOV = 120,
			HearingRange = 62,
			SmellRange = 52,
			NoticeTime = 0.45,
			MemoryTime = 11,
			Color = Color3.fromRGB(112, 72, 62),
		},
		Clicker = {
			DisplayName = "Clicker",
			Health = 220,
			WalkSpeed = 6.5,
			ChaseSpeed = 15.5,
			Damage = 34,
			AttackCooldown = 1.8,
			AttackRange = 6.0,
			SightRange = 0,          -- blind: relies on sound only
			SightFOV = 0,
			HearingRange = 120,      -- superb hearing
			SmellRange = 0,
			NoticeTime = 0.25,       -- reacts to sound almost instantly
			MemoryTime = 14,
			Color = Color3.fromRGB(150, 142, 128),
		},
	},
	MaxAlivePerKind = 8,
	RepathInterval = 0.35,
	CorpseLifetime = 25,
}

-- -------------------------------------------------------------------- world --
Config.World = {
	-- The world is generated at runtime by the WorldBuilder so the project works
	-- out of the box without any imported models.
	BuildOnStart = true,
	GroundSize = 700,
	GrassClumps = 260,
	LootSpawns = 46,
	PropClusters = 14,
	SpawnZombiesOnStart = 26,
}

-- -------------------------------------------------------------------- camera --
Config.Camera = {
	Distance = 8.5,
	AimDistance = 4.2,
	RightShoulderOffset = 2.0,   -- studs to the right of the character
	LeftShoulderOffset = -2.0,
	ShoulderHeight = 2.4,
	AimShoulderHeight = 2.2,
	SwapTime = 0.42,             -- seconds for the shoulder swap glide
	PositionSmooth = 0.09,
	RotationSmooth = 0.07,
	MinPitch = -70,
	MaxPitch = 78,
	FOV = 72,
	AimFOV = 58,
	FOVSmooth = 0.16,
	-- Spring-arm style collision so the camera never clips into walls.
	CollisionPadding = 0.6,
	RecoilRecoverSpeed = 1.0,
	BobAmount = 0.09,
	BobSpeed = 9,
}

Config.Keys = {
	Sprint = Enum.KeyCode.LeftShift,
	Crouch = Enum.KeyCode.LeftControl,
	Prone = Enum.KeyCode.Z,
	Interact = Enum.KeyCode.E,
	Reload = Enum.KeyCode.R,
	SwapShoulder = Enum.KeyCode.Q,
	ThrowBottle = Enum.KeyCode.G,
	Aim = Enum.KeyCode.F,
	Drop = Enum.KeyCode.X,
	Melee = Enum.KeyCode.V,
}

return Config
