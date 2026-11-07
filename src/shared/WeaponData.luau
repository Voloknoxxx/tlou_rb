--!strict
--[[
	WeaponData
	Definitions for every weapon. The `Model` builder functions construct the
	weapon geometry procedurally in Roblox, so the project runs with zero
	imported assets. The Blender scripts in tools/blender generate higher
	fidelity meshes with the exact same proportions if you want to swap them in
	(see docs/ASSETS.md).
]]

local WeaponData = {}

type WeaponStats = {
	DisplayName: string,
	Category: string,       -- "Pistol" | "Revolver" | "Rifle" | "Shotgun" | "Throwable"
	AmmoType: string,
	Damage: number,
	FireRate: number,       -- seconds between shots
	Automatic: boolean,
	MagSize: number,
	ReloadTime: number,
	ReloadKind: string,     -- "Magazine" | "Shells" | "Cylinder"
	RecoilKick: number,     -- degrees of camera pitch per shot
	RecoilYaw: number,
	RecoilRecovery: number, -- degrees per second of recovery
	Spread: number,         -- base cone in degrees
	SpreadPerShot: number,
	SpreadMax: number,
	MuzzleRise: number,     -- studs of visual kickback
	BulletsPerShot: number,
	EquipTime: number,
	Weight: number,
	Color: Color3,
	Accent: Color3,
	Parts: { [string]: { size: Vector3, offset: CFrame, shape: Enum.PartType? } },
	MuzzleOffset: CFrame,
	GripOffset: CFrame,
}

local function p(size: Vector3, offset: CFrame, color: Color3?, shape: Enum.PartType?): any
	return { size = size, offset = offset, shape = shape }
end

local function vec(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function cf(x: number, y: number, z: number, rx: number?, ry: number?, rz: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(math.rad(rx or 0), math.rad(ry or 0), math.rad(rz or 0))
end

-- ---------------------------------------------------------------------------
-- Part blueprints. All sizes are in studs and modelled around the weapon's
-- local origin (the grip). +X is right, +Y is up, -Z is forward (barrel).
-- ---------------------------------------------------------------------------

local function pistolParts(body: Color3, accent: Color3): { [string]: any }
	return {
		Frame = p(vec(0.34, 0.9, 2.2), cf(0, 0.35, -0.7), body),
		Slide = p(vec(0.32, 0.34, 2.3), cf(0, 0.86, -0.72), body),
		Barrel = p(vec(0.2, 0.2, 0.7), cf(0, 0.72, -2.0), accent, Enum.PartType.Cylinder),
		Grip = p(vec(0.3, 1.15, 0.42), cf(0, -0.45, 0.32, -12), body),
		Trigger = p(vec(0.16, 0.34, 0.16), cf(0, -0.02, 0.16), accent),
		TriggerGuard = p(vec(0.18, 0.12, 0.7), cf(0, -0.2, -0.06), accent),
		Magazine = p(vec(0.26, 1.0, 0.5), cf(0, -0.42, 0.18), accent),
		SightRear = p(vec(0.3, 0.16, 0.12), cf(0, 1.06, 0.1), accent),
		SightFront = p(vec(0.12, 0.18, 0.1), cf(0, 1.08, -1.72), accent),
	}
end

local function revolverParts(body: Color3, accent: Color3): { [string]: any }
	return {
		Frame = p(vec(0.36, 1.0, 2.4), cf(0, 0.3, -0.6), body),
		Barrel = p(vec(0.28, 0.28, 2.6), cf(0, 0.66, -1.7), body, Enum.PartType.Cylinder),
		BarrelRib = p(vec(0.18, 0.16, 2.6), cf(0, 0.98, -1.7), accent),
		Cylinder = p(vec(0.62, 0.62, 0.9), cf(0, 0.34, -0.15), accent, Enum.PartType.Cylinder),
		Grip = p(vec(0.34, 1.35, 0.5), cf(0, -0.55, 0.55, -22), accent),
		Trigger = p(vec(0.16, 0.34, 0.16), cf(0, -0.16, 0.18), body),
		TriggerGuard = p(vec(0.18, 0.12, 0.7), cf(0, -0.34, -0.04), body),
		Hammer = p(vec(0.16, 0.34, 0.2), cf(0, 0.78, 0.42, 18), accent),
		SightRear = p(vec(0.32, 0.16, 0.12), cf(0, 1.06, 0.4), accent),
		SightFront = p(vec(0.1, 0.2, 0.1), cf(0, 1.1, -2.85), accent),
	}
end

local function rifleParts(body: Color3, accent: Color3): { [string]: any }
	return {
		Receiver = p(vec(0.42, 1.0, 3.2), cf(0, 0.4, -1.0), body),
		Upper = p(vec(0.36, 0.3, 3.2), cf(0, 0.98, -1.0), body),
		Barrel = p(vec(0.22, 0.22, 3.6), cf(0, 0.62, -4.1), accent, Enum.PartType.Cylinder),
		Handguard = p(vec(0.44, 0.5, 2.0), cf(0, 0.5, -3.0), accent),
		Stock = p(vec(0.4, 0.85, 2.0), cf(0, 0.3, 1.5, -4), body),
		StockTube = p(vec(0.3, 0.3, 0.9), cf(0, 0.42, 0.9), accent),
		Grip = p(vec(0.32, 1.1, 0.44), cf(0, -0.3, 0.35, -14), body),
		Trigger = p(vec(0.16, 0.32, 0.16), cf(0, 0.02, 0.2), accent),
		TriggerGuard = p(vec(0.2, 0.12, 0.75), cf(0, -0.16, -0.02), accent),
		Magazine = p(vec(0.34, 1.5, 0.8), cf(0, -0.6, -0.85, 6), accent),
		Scope = p(vec(0.36, 0.36, 1.6), cf(0, 1.35, -1.2), body, Enum.PartType.Cylinder),
		ScopeMount = p(vec(0.16, 0.3, 0.3), cf(0, 1.16, -0.7), accent),
		ChargingHandle = p(vec(0.5, 0.14, 0.24), cf(0.28, 1.06, 0.35), accent),
		Muzzle = p(vec(0.3, 0.3, 0.5), cf(0, 0.62, -5.9), accent, Enum.PartType.Cylinder),
	}
end

local function shotgunParts(body: Color3, accent: Color3): { [string]: any }
	return {
		Receiver = p(vec(0.5, 1.05, 2.6), cf(0, 0.35, -0.7), body),
		Barrel = p(vec(0.3, 0.3, 5.0), cf(0, 0.72, -3.4), body, Enum.PartType.Cylinder),
		MagTube = p(vec(0.26, 0.26, 4.2), cf(0, 0.3, -3.0), accent, Enum.PartType.Cylinder),
		Pump = p(vec(0.46, 0.6, 1.5), cf(0, 0.35, -2.6), accent),
		Stock = p(vec(0.42, 0.95, 2.2), cf(0, 0.22, 1.6, -6), body),
		Grip = p(vec(0.34, 1.15, 0.5), cf(0, -0.4, 0.3, -16), body),
		Trigger = p(vec(0.16, 0.32, 0.16), cf(0, -0.06, 0.16), accent),
		TriggerGuard = p(vec(0.22, 0.12, 0.8), cf(0, -0.24, -0.06), accent),
		ShellHolder = p(vec(0.22, 0.7, 0.5), cf(0.32, 0.05, 0.5, 0, 0, 8), accent),
		Bead = p(vec(0.1, 0.14, 0.1), cf(0, 0.94, -5.7), accent),
	}
end

local function bottleParts(body: Color3, accent: Color3): { [string]: any }
	return {
		Body = p(vec(0.7, 1.6, 0.7), cf(0, 0, 0), body, Enum.PartType.Cylinder),
		Neck = p(vec(0.34, 0.8, 0.34), cf(0, 1.05, 0), body, Enum.PartType.Cylinder),
		Cap = p(vec(0.38, 0.24, 0.38), cf(0, 1.55, 0), accent, Enum.PartType.Cylinder),
	}
end

-- ---------------------------------------------------------------------------
-- Public table
-- ---------------------------------------------------------------------------

WeaponData.Weapons = {
	M9 = {
		DisplayName = "M9 Sidearm",
		Category = "Pistol",
		AmmoType = "9mm",
		Damage = 26,
		FireRate = 0.14,
		Automatic = false,
		MagSize = 15,
		ReloadTime = 1.65,
		ReloadKind = "Magazine",
		RecoilKick = 1.35,
		RecoilYaw = 0.5,
		RecoilRecovery = 11,
		Spread = 0.7,
		SpreadPerShot = 0.6,
		SpreadMax = 4.5,
		MuzzleRise = 0.12,
		BulletsPerShot = 1,
		EquipTime = 0.45,
		Weight = 1.0,
		Color = Color3.fromRGB(48, 50, 54),
		Accent = Color3.fromRGB(28, 30, 33),
		Parts = pistolParts(Color3.fromRGB(48, 50, 54), Color3.fromRGB(28, 30, 33)),
		MuzzleOffset = cf(0, 0.72, -2.35),
		GripOffset = cf(0, -0.45, 0.32),
	} :: WeaponStats,

	Python = {
		DisplayName = ".357 Revolver",
		Category = "Revolver",
		AmmoType = "357",
		Damage = 58,
		FireRate = 0.55,
		Automatic = false,
		MagSize = 6,
		ReloadTime = 2.6,
		ReloadKind = "Cylinder",
		RecoilKick = 3.4,
		RecoilYaw = 1.1,
		RecoilRecovery = 8,
		Spread = 0.5,
		SpreadPerShot = 1.4,
		SpreadMax = 6,
		MuzzleRise = 0.3,
		BulletsPerShot = 1,
		EquipTime = 0.55,
		Weight = 1.2,
		Color = Color3.fromRGB(78, 80, 86),
		Accent = Color3.fromRGB(94, 70, 46),
		Parts = revolverParts(Color3.fromRGB(78, 80, 86), Color3.fromRGB(94, 70, 46)),
		MuzzleOffset = cf(0, 0.66, -3.0),
		GripOffset = cf(0, -0.55, 0.55),
	} :: WeaponStats,

	AR15 = {
		DisplayName = "AR-15",
		Category = "Rifle",
		AmmoType = "5.56",
		Damage = 31,
		FireRate = 0.088,
		Automatic = true,
		MagSize = 30,
		ReloadTime = 2.35,
		ReloadKind = "Magazine",
		RecoilKick = 1.05,
		RecoilYaw = 0.42,
		RecoilRecovery = 9.5,
		Spread = 0.45,
		SpreadPerShot = 0.32,
		SpreadMax = 4.2,
		MuzzleRise = 0.08,
		BulletsPerShot = 1,
		EquipTime = 0.7,
		Weight = 1.8,
		Color = Color3.fromRGB(44, 45, 48),
		Accent = Color3.fromRGB(64, 60, 52),
		Parts = rifleParts(Color3.fromRGB(44, 45, 48), Color3.fromRGB(64, 60, 52)),
		MuzzleOffset = cf(0, 0.62, -6.2),
		GripOffset = cf(0, -0.3, 0.35),
	} :: WeaponStats,

	Remington = {
		DisplayName = "Remington 870",
		Category = "Shotgun",
		AmmoType = "12ga",
		Damage = 15,
		FireRate = 0.85,
		Automatic = false,
		MagSize = 6,
		ReloadTime = 0.62,     -- per shell
		ReloadKind = "Shells",
		RecoilKick = 4.6,
		RecoilYaw = 1.6,
		RecoilRecovery = 7,
		Spread = 5.5,
		SpreadPerShot = 0,
		SpreadMax = 5.5,
		MuzzleRise = 0.34,
		BulletsPerShot = 9,
		EquipTime = 0.8,
		Weight = 2.1,
		Color = Color3.fromRGB(40, 38, 36),
		Accent = Color3.fromRGB(86, 60, 38),
		Parts = shotgunParts(Color3.fromRGB(40, 38, 36), Color3.fromRGB(86, 60, 38)),
		MuzzleOffset = cf(0, 0.72, -5.9),
		GripOffset = cf(0, -0.4, 0.3),
	} :: WeaponStats,

	Bottle = {
		DisplayName = "Glass Bottle",
		Category = "Throwable",
		AmmoType = "None",
		Damage = 6,
		FireRate = 0.6,
		Automatic = false,
		MagSize = 1,
		ReloadTime = 0,
		ReloadKind = "None",
		RecoilKick = 0,
		RecoilYaw = 0,
		RecoilRecovery = 10,
		Spread = 0,
		SpreadPerShot = 0,
		SpreadMax = 0,
		MuzzleRise = 0,
		BulletsPerShot = 0,
		EquipTime = 0.3,
		Weight = 0.4,
		Color = Color3.fromRGB(120, 168, 140),
		Accent = Color3.fromRGB(70, 96, 84),
		Parts = bottleParts(Color3.fromRGB(120, 168, 140), Color3.fromRGB(70, 96, 84)),
		MuzzleOffset = cf(0, 0, 0),
		GripOffset = cf(0, 0, 0),
	} :: WeaponStats,
}

-- Loot table used by the world builder when scattering pickups.
WeaponData.LootTable = {
	{ id = "M9", weight = 26 },
	{ id = "Python", weight = 14 },
	{ id = "AR15", weight = 18 },
	{ id = "Remington", weight = 13 },
	{ id = "Bottle", weight = 29 },
}

-- Ammo pickups, spawned separately from weapons.
WeaponData.AmmoTable = {
	{ AmmoType = "9mm", Amount = 15, weight = 30 },
	{ AmmoType = "357", Amount = 6, weight = 18 },
	{ AmmoType = "5.56", Amount = 30, weight = 22 },
	{ AmmoType = "12ga", Amount = 6, weight = 18 },
}

function WeaponData.pickWeighted(table_): any
	local total = 0
	for _, entry in table_ do
		total += entry.weight
	end
	local roll = math.random() * total
	local acc = 0
	for _, entry in table_ do
		acc += entry.weight
		if roll <= acc then
			return entry
		end
	end
	return table_[#table_]
end

return WeaponData
