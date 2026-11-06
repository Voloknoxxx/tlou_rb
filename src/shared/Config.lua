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
}

-- Camera ---------------------------------------------------------------
Config.Camera = {
	ShoulderOffset = Vector3.new(1.6, 1.6, 0), -- right, up, forward
	AimOffset = Vector3.new(1.15, 1.35, 0),
	FOV = 78,
	AimFOV = 52,
	SprintFOV = 86,
	FOVLerp = 7,

	BobFrequency = 8.5,
	BobAmplitude = 0.14,
	SwayAmount = 0.55,
	SwaySmoothing = 6,

	RecoilKick = 1.5, -- degrees per shot
	RecoilRecovery = 9,
	MaxRecoil = 6,

	MinPitch = -80,
	MaxPitch = 80,
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
