--!strict
--[[
	Weapons
	Data table describing every weapon in the pack. The WeaponController
	and the procedural model builder both read from here, so adding a
	weapon is purely a data change.
]]

export type WeaponData = {
	id: string,
	name: string,
	category: string, -- "Firearm" | "Melee" | "Throwable"
	model: string, -- procedural model key

	damage: number,
	fireMode: string, -- "Auto" | "Semi" | "Bolt" | "Pump"
	rpm: number,
	magazine: number,
	reserveMax: number,
	reloadTime: number,
	bulletSpread: number, -- degrees at hip
	aimSpread: number, -- degrees when aiming
	recoil: number,
	range: number,
	pellets: number, -- >1 for shotguns
	silenced: boolean,

	adsTime: number,
	raiseTime: number,

	-- Procedural visual parameters
	visual: {
		bodyColor: Color3,
		accentColor: Color3,
		length: number,
		stock: boolean,
		scope: string?, -- "none" | "small" | "large"
		suppressor: boolean,
		woodFurniture: boolean,
	},

	-- Melee only
	meleeSwing: number?,
	meleeDamage: number?,
	meleeRange: number?,
}

local Weapons: { [string]: WeaponData } = {}

local function gun(partial): WeaponData
	return partial :: any
end

-- Firearms ------------------------------------------------------------
Weapons.Pistol = gun({
	id = "Pistol",
	name = "9mm Pistol",
	category = "Firearm",
	model = "Pistol",
	damage = 24,
	fireMode = "Semi",
	rpm = 340,
	magazine = 12,
	reserveMax = 60,
	reloadTime = 1.6,
	bulletSpread = 1.4,
	aimSpread = 0.25,
	recoil = 0.9,
	range = 250,
	pellets = 1,
	silenced = false,
	adsTime = 0.18,
	raiseTime = 0.4,
	visual = {
		bodyColor = Color3.fromRGB(38, 38, 40),
		accentColor = Color3.fromRGB(120, 96, 64),
		length = 1.5,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = true,
	},
})

Weapons.Revolver = gun({
	id = "Revolver",
	name = ".357 Revolver",
	category = "Firearm",
	model = "Revolver",
	damage = 52,
	fireMode = "Semi",
	rpm = 120,
	magazine = 6,
	reserveMax = 36,
	reloadTime = 2.6,
	bulletSpread = 1.8,
	aimSpread = 0.2,
	recoil = 2.2,
	range = 280,
	pellets = 1,
	silenced = false,
	adsTime = 0.22,
	raiseTime = 0.5,
	visual = {
		bodyColor = Color3.fromRGB(30, 30, 34),
		accentColor = Color3.fromRGB(92, 70, 44),
		length = 1.7,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = true,
	},
})

Weapons.HuntingRifle = gun({
	id = "HuntingRifle",
	name = "Hunting Rifle",
	category = "Firearm",
	model = "Rifle",
	damage = 95,
	fireMode = "Bolt",
	rpm = 45,
	magazine = 5,
	reserveMax = 40,
	reloadTime = 2.9,
	bulletSpread = 2.0,
	aimSpread = 0.05,
	recoil = 3.0,
	range = 400,
	pellets = 1,
	silenced = false,
	adsTime = 0.32,
	raiseTime = 0.7,
	visual = {
		bodyColor = Color3.fromRGB(36, 32, 28),
		accentColor = Color3.fromRGB(110, 84, 52),
		length = 2.9,
		stock = true,
		scope = "large",
		suppressor = false,
		woodFurniture = true,
	},
})

Weapons.Shotgun = gun({
	id = "Shotgun",
	name = "Pump Shotgun",
	category = "Firearm",
	model = "Shotgun",
	damage = 18,
	fireMode = "Pump",
	rpm = 65,
	magazine = 6,
	reserveMax = 36,
	reloadTime = 0.9, -- per shell
	bulletSpread = 4.0,
	aimSpread = 2.6,
	recoil = 3.4,
	range = 60,
	pellets = 8,
	silenced = false,
	adsTime = 0.28,
	raiseTime = 0.65,
	visual = {
		bodyColor = Color3.fromRGB(34, 30, 26),
		accentColor = Color3.fromRGB(96, 74, 48),
		length = 3.0,
		stock = true,
		scope = "none",
		suppressor = false,
		woodFurniture = true,
	},
})

Weapons.AssaultRifle = gun({
	id = "AssaultRifle",
	name = "Assault Rifle",
	category = "Firearm",
	model = "Rifle",
	damage = 27,
	fireMode = "Auto",
	rpm = 620,
	magazine = 30,
	reserveMax = 150,
	reloadTime = 2.2,
	bulletSpread = 2.2,
	aimSpread = 0.7,
	recoil = 1.3,
	range = 350,
	pellets = 1,
	silenced = false,
	adsTime = 0.24,
	raiseTime = 0.55,
	visual = {
		bodyColor = Color3.fromRGB(30, 30, 32),
		accentColor = Color3.fromRGB(70, 70, 72),
		length = 2.7,
		stock = true,
		scope = "small",
		suppressor = false,
		woodFurniture = false,
	},
})

Weapons.SilencedSMG = gun({
	id = "SilencedSMG",
	name = "Silenced SMG",
	category = "Firearm",
	model = "SMG",
	damage = 18,
	fireMode = "Auto",
	rpm = 800,
	magazine = 25,
	reserveMax = 125,
	reloadTime = 1.9,
	bulletSpread = 2.6,
	aimSpread = 0.9,
	recoil = 1.1,
	range = 220,
	pellets = 1,
	silenced = true,
	adsTime = 0.2,
	raiseTime = 0.45,
	visual = {
		bodyColor = Color3.fromRGB(28, 30, 30),
		accentColor = Color3.fromRGB(52, 54, 54),
		length = 2.1,
		stock = true,
		scope = "small",
		suppressor = true,
		woodFurniture = false,
	},
})

Weapons.SilencedPistol = gun({
	id = "SilencedPistol",
	name = "Silenced Pistol",
	category = "Firearm",
	model = "Pistol",
	damage = 22,
	fireMode = "Semi",
	rpm = 320,
	magazine = 12,
	reserveMax = 60,
	reloadTime = 1.7,
	bulletSpread = 1.5,
	aimSpread = 0.3,
	recoil = 0.8,
	range = 200,
	pellets = 1,
	silenced = true,
	adsTime = 0.18,
	raiseTime = 0.4,
	visual = {
		bodyColor = Color3.fromRGB(34, 36, 36),
		accentColor = Color3.fromRGB(60, 62, 62),
		length = 1.9,
		stock = false,
		scope = "none",
		suppressor = true,
		woodFurniture = false,
	},
})

Weapons.Bow = gun({
	id = "Bow",
	name = "Compound Bow",
	category = "Firearm",
	model = "Bow",
	damage = 80,
	fireMode = "Bolt",
	rpm = 50,
	magazine = 1,
	reserveMax = 24,
	reloadTime = 1.1,
	bulletSpread = 0.4,
	aimSpread = 0.0,
	recoil = 0.3,
	range = 320,
	pellets = 1,
	silenced = true,
	adsTime = 0.4,
	raiseTime = 0.7,
	visual = {
		bodyColor = Color3.fromRGB(40, 34, 28),
		accentColor = Color3.fromRGB(150, 120, 80),
		length = 2.0,
		stock = false,
		scope = "small",
		suppressor = false,
		woodFurniture = true,
	},
})

-- Melee ----------------------------------------------------------------
Weapons.Machete = gun({
	id = "Machete",
	name = "Machete",
	category = "Melee",
	model = "Machete",
	damage = 45,
	meleeDamage = 45,
	meleeSwing = 0.55,
	meleeRange = 6.5,
	fireMode = "Swing",
	rpm = 90,
	magazine = 0,
	reserveMax = 0,
	reloadTime = 0,
	bulletSpread = 0,
	aimSpread = 0,
	recoil = 0,
	range = 6.5,
	pellets = 1,
	silenced = true,
	adsTime = 0.1,
	raiseTime = 0.35,
	visual = {
		bodyColor = Color3.fromRGB(150, 150, 155),
		accentColor = Color3.fromRGB(70, 50, 34),
		length = 2.2,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = true,
	},
})

Weapons.Bat = gun({
	id = "Bat",
	name = "Baseball Bat",
	category = "Melee",
	model = "Bat",
	damage = 38,
	meleeDamage = 38,
	meleeSwing = 0.5,
	meleeRange = 7,
	fireMode = "Swing",
	rpm = 100,
	magazine = 0,
	reserveMax = 0,
	reloadTime = 0,
	bulletSpread = 0,
	aimSpread = 0,
	recoil = 0,
	range = 7,
	pellets = 1,
	silenced = true,
	adsTime = 0.1,
	raiseTime = 0.35,
	visual = {
		bodyColor = Color3.fromRGB(120, 82, 46),
		accentColor = Color3.fromRGB(60, 44, 30),
		length = 2.4,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = true,
	},
})

-- Throwables -----------------------------------------------------------
Weapons.Molotov = gun({
	id = "Molotov",
	name = "Molotov Cocktail",
	category = "Throwable",
	model = "Bottle",
	damage = 40,
	fireMode = "Throw",
	rpm = 40,
	magazine = 1,
	reserveMax = 3,
	reloadTime = 0.6,
	bulletSpread = 0,
	aimSpread = 0,
	recoil = 0,
	range = 45,
	pellets = 1,
	silenced = false,
	adsTime = 0.2,
	raiseTime = 0.35,
	visual = {
		bodyColor = Color3.fromRGB(120, 150, 110),
		accentColor = Color3.fromRGB(180, 80, 40),
		length = 0.8,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = false,
	},
})

Weapons.SmokeBomb = gun({
	id = "SmokeBomb",
	name = "Smoke Bomb",
	category = "Throwable",
	model = "Canister",
	damage = 0,
	fireMode = "Throw",
	rpm = 40,
	magazine = 1,
	reserveMax = 3,
	reloadTime = 0.6,
	bulletSpread = 0,
	aimSpread = 0,
	recoil = 0,
	range = 45,
	pellets = 1,
	silenced = false,
	adsTime = 0.2,
	raiseTime = 0.35,
	visual = {
		bodyColor = Color3.fromRGB(80, 82, 78),
		accentColor = Color3.fromRGB(150, 150, 150),
		length = 0.7,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = false,
	},
})

Weapons.Brick = gun({
	id = "Brick",
	name = "Brick",
	category = "Throwable",
	model = "Brick",
	damage = 30,
	fireMode = "Throw",
	rpm = 40,
	magazine = 1,
	reserveMax = 3,
	reloadTime = 0.6,
	bulletSpread = 0,
	aimSpread = 0,
	recoil = 0,
	range = 45,
	pellets = 1,
	silenced = false,
	adsTime = 0.2,
	raiseTime = 0.35,
	visual = {
		bodyColor = Color3.fromRGB(150, 80, 66),
		accentColor = Color3.fromRGB(120, 60, 50),
		length = 0.6,
		stock = false,
		scope = "none",
		suppressor = false,
		woodFurniture = false,
	},
})

-- Helpers --------------------------------------------------------------
function Weapons.get(id: string): WeaponData?
	return Weapons[id]
end

function Weapons.isFirearm(data: WeaponData): boolean
	return data.category == "Firearm"
end

function Weapons.isMelee(data: WeaponData): boolean
	return data.category == "Melee"
end

function Weapons.isThrowable(data: WeaponData): boolean
	return data.category == "Throwable"
end

function Weapons.defaultLoadout(): { string }
	return { "Pistol", "HuntingRifle", "Machete", "Molotov" }
end

return Weapons
