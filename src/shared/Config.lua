--!strict
--[[
	Config
	Central tuning table for the TLoU-style mechanics pack.
	Every value here is data only - no logic - so designers can tweak
	feel without touching controllers.
]]

local Config = {}

-- Movement -------------------------------------------------------------
Config.Movement = {
	WalkSpeed = 14,
	RunSpeed = 22,
	CrouchSpeed = 7,
	ProneSpeed = 3,
	SprintSpeed = 24,

	JumpPower = 42,

	-- Stamina is a 0..100 resource.
	MaxStamina = 100,
	StaminaDrainSprint = 14, -- per second
	StaminaDrainJump = 12, -- flat cost
	StaminaRegen = 10, -- per second
	StaminaRegenDelay = 1.1, -- seconds after last drain
	ExhaustedThreshold = 5, -- cannot sprint below this

	-- Lean / peek
	LeanAngle = 18, -- degrees
	LeanSpeed = 9,
	LeanOffset = 1.4, -- studs sideways camera shift

	-- Vault / climb
	VaultMinHeight = 2.5,
	VaultMaxHeight = 7,
	VaultSpeed = 22,
	ClimbSpeed = 16,

	-- How fast the body yaws toward the camera. The TLoU character turns
	-- with weight, so this is deliberately not instant.
	TurnSpeed = 9,
	TurnSpeedAiming = 14,
}

-- Camera ---------------------------------------------------------------
Config.Camera = {
	-- Over-the-shoulder third person, the way TLoU frames combat.
	ThirdPerson = true,
	ShoulderOffset = Vector3.new(1.7, 1.7, 0), -- right, up, forward
	AimOffset = Vector3.new(1.15, 1.5, 0),
	Distance = 4.6,
	AimDistance = 2.5,
	MinDistance = 1.2,

	FOV = 76,
	AimFOV = 50,
	SprintFOV = 84,
	FOVLerp = 7,

	BobFrequency = 8.5,
	BobAmplitude = 0.12,
	SwayAmount = 0.55,
	SwaySmoothing = 6,

	RecoilKick = 1.5, -- degrees per shot
	RecoilRecovery = 9,
	MaxRecoil = 6,

	MinPitch = -70,
	MaxPitch = 70,

	-- The camera pivots around this point on the character, in studs above
	-- the root. R6 torsos are 2 tall, so the eyes sit near the top.
	PivotHeight = 1.5,
}

-- Animation ------------------------------------------------------------
-- All of this drives our own R6 animator (Motor6D.Transform). No asset
-- ids are involved, so it works in any place with no upload step.
Config.Animation = {
	Enabled = true,

	-- Stride: the walk cycle advances with distance travelled, so the feet
	-- do not skate. StrideLength is the studs covered by one full cycle
	-- (two steps).
	StrideLength = 6.0,
	SprintStrideBoost = 1.25, -- feet cycle faster than the body when sprinting

	-- Amplitudes in degrees.
	LegSwing = 40,
	RunLegSwing = 58,
	ArmSwing = 24,
	RunArmSwing = 40,
	TorsoYaw = 6, -- shoulders counter-rotate against the hips
	TorsoRoll = 3,
	LeanForward = 7, -- torso pitch while sprinting
	HeadStabilise = 0.55, -- how much the head counter-rotates

	-- Vertical bob, in studs.
	BobAmplitude = 0.13,
	BobLateral = 0.05,

	-- Turn-in-place: stepping feet when the body yaws without moving.
	TurnStepSwing = 24,
	TurnStepRate = 0.9, -- steps per radian of turn
	TurnMinSpeed = 0.6, -- below this movement speed, turning steps play
	TurnDeadzone = 0.12, -- radians/sec before stepping starts

	-- Idle breathing.
	IdleBreath = 1.6, -- cycles per second
	IdleBreathAmp = 1.2, -- degrees of torso pitch

	-- Poses.
	BlendSpeed = 9, -- how fast we blend between stance poses
	AimArmPitch = 78, -- arms raised to hold the weapon
	AimArmYaw = 12,
	-- Low ready: weapon carried at the hip, not raised to the eye. This is
	-- the resting pose whenever something is held, and it is what makes a
	-- third-person character read as "armed" while walking.
	ReadyArmPitch = 34,
	ReadyArmYaw = 8,
	ReadyLeftArmPitch = 44,
	CrouchTorsoPitch = 24,
	CrouchLegPitch = 26,
	CrouchDrop = 0.7, -- torso lowered, in studs
	ProneTorsoPitch = 70,
	ProneLegPitch = -62,
	ProneDrop = 1.45,
	ProneArmPitch = 84,

	-- Vault / climb pose.
	VaultLegPitch = 46,
	VaultArmPitch = 62,

	-- Jump / fall.
	AirLegPitch = 26,
	AirArmPitch = 20,
}

-- Rig ------------------------------------------------------------------
-- The pack targets the classic R6 body: six parts, six joints, simple
-- animation maths, and the blocky silhouette TLoU's survivors have.
Config.Rig = {
	ForceR6 = true, -- the place is generated as R6 and the server enforces it
	RebuildIfNotR6 = true, -- swap in a canonical R6 rig if the player is R15
	DisableDefaultAnimate = true, -- Roblox's Animate script would fight ours

	-- Classic R6 part sizes (studs).
	HeadSize = Vector3.new(2, 1, 1),
	TorsoSize = Vector3.new(2, 2, 1),
	LimbSize = Vector3.new(1, 2, 1),
	RootSize = Vector3.new(2, 2, 1),

	-- Fallback rig palette, used only when we have to build a body.
	BodyColor = Color3.fromRGB(224, 178, 150),
	ShirtColor = Color3.fromRGB(72, 78, 66),
	PantsColor = Color3.fromRGB(58, 54, 48),
}

-- Combat ---------------------------------------------------------------
Config.Combat = {
	HeadshotMultiplier = 2.5,
	LimbMultiplier = 0.75,
	MaxRange = 400,

	HitScanStepStuds = 0.6, -- raycast resolution for hit verification
	FriendlyFire = false,

	BleedOutTime = 12,
	DownedHealth = 100,
	DownedReviveTime = 3.5,
	MaxHealth = 100,

	-- Noise made by actions, drives stealth AI interest
	Noise = {
		Walk = 8,
		Run = 26,
		Sprint = 40,
		Crouch = 2,
		Prone = 0,
		Gunshot = 120,
		Silenced = 18,
		Melee = 12,
	},
}

-- Inventory ------------------------------------------------------------
Config.Inventory = {
	MaxSlots = 4,
	MaxThrowables = 3,
	SwapTime = 0.45,
	DropOnDeath = true,
}

-- Input ----------------------------------------------------------------
Config.Keys = {
	Fire = Enum.UserInputType.MouseButton1,
	Aim = Enum.UserInputType.MouseButton2,
	Reload = Enum.KeyCode.R,
	Melee = Enum.KeyCode.F,
	Throw = Enum.KeyCode.G,
	Sprint = Enum.KeyCode.LeftShift,
	Crouch = Enum.KeyCode.LeftControl,
	Prone = Enum.KeyCode.Z,
	LeanLeft = Enum.KeyCode.Q,
	LeanRight = Enum.KeyCode.E,
	Swap = Enum.KeyCode.Tab,
	Heal = Enum.KeyCode.H,
}

-- Visual ---------------------------------------------------------------
Config.Visual = {
	MuzzleFlashTime = 0.045,
	TracerTime = 0.06,
	HitDecalLifetime = 12,
	BloodTime = 0.5,
	ShellEjectSpeed = 18,
	CameraShakeIntensity = 0.6,
}

return Config
