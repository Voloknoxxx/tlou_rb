#!/usr/bin/env python3
"""
run_tests.py

Inlines the pure-logic modules (Config, Weapons, Util, Signal) into a
single self-contained Luau file together with the Roblox API stubs and
the test assertions, then runs it with the Luau CLI.

This lets us exercise the data invariants and helpers the whole pack
depends on without a Roblox runtime.

Usage:  python3 run_tests.py
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
LUAU = os.environ.get("LUAU_BIN", "/tmp/luaubin/luau")

STUBS = r'''
-- ---------------------------------------------------------------------
-- Roblox API stubs (shared by every inlined module)
-- ---------------------------------------------------------------------
Enum = setmetatable({}, { __index = function(_, key)
	return setmetatable({}, { __index = function(_, k)
		return { Name = k, Value = 0, EnumType = key }
	end })
end })

Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x, y, z)
	if type(x) == "table" then return x end
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end
function Vector3.__add(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function Vector3.__sub(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function Vector3.__mul(a, b)
	if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function Vector3.__eq(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
function Vector3:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
function Vector3.Magnitude(self) return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
Vector3.__index = function(self, key)
	if key == "Magnitude" then return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
	if key == "Unit" then
		local m = math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
		if m == 0 then return Vector3.new(0, 0, 0) end
		return Vector3.new(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(Vector3, key)
end

Color3 = {}
function Color3.fromRGB(r, g, b) return { R = r, G = g, B = b } end
function Color3.new(r, g, b) return { R = r, G = g, B = b } end

-- Minimal affine CFrame: position plus a 3x3 rotation.
CFrame = {}
CFrame.__index = CFrame
function CFrame.new(a, b, c)
	local cf = setmetatable({}, CFrame)
	if type(a) == "table" and a.X then
		cf.Position = Vector3.new(a.X, a.Y, a.Z)
	elseif type(a) == "table" and a.Position then
		cf.Position = a.Position
		cf.R = a.R
	else
		cf.Position = Vector3.new(a or 0, b or 0, c or 0)
	end
	cf.R = cf.R or { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
	cf.LookVector = Vector3.new(-cf.R[3], -cf.R[6], -cf.R[9])
	cf.RightVector = Vector3.new(cf.R[1], cf.R[4], cf.R[7])
	cf.UpVector = Vector3.new(cf.R[2], cf.R[5], cf.R[8])
	return cf
end
function CFrame.Angles(x, y, z)
	local cf = CFrame.new(0, 0, 0)
	cf.Angles = { x or 0, y or 0, z or 0 }
	return cf
end
function CFrame.__mul(a, b)
	if type(b) == "number" then
		return CFrame.new(a.Position.X * b, a.Position.Y * b, a.Position.Z * b)
	end
	local out = CFrame.new(
		a.Position.X + b.Position.X,
		a.Position.Y + b.Position.Y,
		a.Position.Z + b.Position.Z
	)
	return out
end
function CFrame:ToEulerAnglesYXZ() return 0, 0, 0 end

-- Instance stub with parent/child bookkeeping and property storage.
local function makeInstance(class)
	local inst
	inst = {
		ClassName = class,
		Name = class,
		_children = {},
		_attributes = {},
	}
	function inst:FindFirstChild(name)
		for _, child in ipairs(self._children) do
			if child.Name == name then return child end
		end
		return nil
	end
	function inst:FindFirstChildOfClass(class2)
		for _, child in ipairs(self._children) do
			if child.ClassName == class2 then return child end
		end
		return nil
	end
	function inst:GetChildren() return self._children end
	function inst:GetDescendants()
		local out = {}
		for _, child in ipairs(self._children) do
			table.insert(out, child)
			for _, d in ipairs(child:GetDescendants()) do
				table.insert(out, d)
			end
		end
		return out
	end
	function inst:SetAttribute(key, value) self._attributes[key] = value end
	function inst:GetAttribute(key) return self._attributes[key] end
	function inst:IsA(class2) return self.ClassName == class2 end
	function inst:Destroy()
		self.Parent = nil
	end
	-- Parent assignment tracked via metatable so we can maintain children.
	return setmetatable(inst, {
		__index = function(t, key)
			return rawget(t, key)
		end,
		__newindex = function(t, key, value)
			if key == "Parent" then
				local old = rawget(t, "Parent")
				if old and old._children then
					for i, child in ipairs(old._children) do
						if child == t then table.remove(old._children, i) break end
					end
				end
				rawset(t, "Parent", value)
				if value and value._children then
					table.insert(value._children, t)
				end
			else
				rawset(t, key, value)
			end
		end,
	})
end

Instance = { new = function(class) return makeInstance(class) end }

Players = {
	GetPlayers = function() return {} end,
	PlayerAdded = { Connect = function() return { Disconnect = function() end } end },
	PlayerRemoving = { Connect = function() return { Disconnect = function() end } end },
}

RunService = { IsServer = function() return false end, IsClient = function() return true end }
ReplicatedStorage = { FindFirstChild = function() return nil end, WaitForChild = function() return {} end }

game = {
	GetService = function(_, name)
		if name == "Players" then return Players end
		if name == "RunService" then return RunService end
		if name == "ReplicatedStorage" then return ReplicatedStorage end
		return {}
	end,
	Workspace = {},
}
workspace = { CurrentCamera = {} }
task = { wait = function() end, spawn = function(f, ...) f(...) end, delay = function(_, f, ...) f(...) end }
'''

HARNESS = r'''
-- ---------------------------------------------------------------------
-- Tiny test framework
-- ---------------------------------------------------------------------
local passed, failed = 0, 0
local failures = {}

local function check(label, condition, detail)
	if condition then
		passed += 1
	else
		failed += 1
		table.insert(failures, label .. (detail and (" :: " .. tostring(detail)) or ""))
		print("  FAIL  " .. label .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
	end
end

local function section(name) print("\n== " .. name .. " ==") end
'''

ASSERTIONS = r'''
-- ---------------------------------------------------------------------
section("Config")
-- ---------------------------------------------------------------------
check("Config has Movement", type(Config.Movement) == "table")
check("Config has Camera", type(Config.Camera) == "table")
check("Config has Combat", type(Config.Combat) == "table")
check("Config has Visual", type(Config.Visual) == "table")
check("Config has Keys", type(Config.Keys) == "table")
check("sprint faster than walk", Config.Movement.SprintSpeed > Config.Movement.WalkSpeed)
check("prone slower than crouch", Config.Movement.ProneSpeed < Config.Movement.CrouchSpeed)
check("crouch slower than walk", Config.Movement.CrouchSpeed < Config.Movement.WalkSpeed)
check("walk slower than run", Config.Movement.WalkSpeed < Config.Movement.RunSpeed)
check("aim FOV narrower than hip FOV", Config.Camera.AimFOV < Config.Camera.FOV)
check("sprint FOV wider than hip FOV", Config.Camera.SprintFOV > Config.Camera.FOV)
check("headshot multiplier > 1", Config.Combat.HeadshotMultiplier > 1)
check("limb multiplier < 1", Config.Combat.LimbMultiplier < 1)
check("gunshot noisier than silenced", Config.Combat.Noise.Gunshot > Config.Combat.Noise.Silenced)
check("prone makes no noise", Config.Combat.Noise.Prone == 0)
check("crouch quieter than walk", Config.Combat.Noise.Crouch < Config.Combat.Noise.Walk)
check("sprint noisier than run", Config.Combat.Noise.Sprint > Config.Combat.Noise.Run)
check("stamina drains faster than it regens", Config.Movement.StaminaDrainSprint > Config.Movement.StaminaRegen)
check("exhausted threshold below max", Config.Movement.ExhaustedThreshold < Config.Movement.MaxStamina)
check("vault min below max", Config.Movement.VaultMinHeight < Config.Movement.VaultMaxHeight)

-- ---------------------------------------------------------------------
section("Weapons data integrity")
-- ---------------------------------------------------------------------
local REQUIRED = {
	"id", "name", "category", "model", "damage", "fireMode", "rpm",
	"magazine", "reserveMax", "reloadTime", "bulletSpread", "aimSpread",
	"recoil", "range", "pellets", "silenced", "adsTime", "raiseTime", "visual",
}
local VALID_CATEGORIES = { Firearm = true, Melee = true, Throwable = true }
local VALID_FIRE_MODES = { Auto = true, Semi = true, Bolt = true, Pump = true, Swing = true, Throw = true }
local VALID_SCOPES = { none = true, small = true, large = true }

local weaponCount = 0
for id, data in pairs(Weapons) do
	if type(data) == "table" and data.id then
		weaponCount += 1
		for _, field in ipairs(REQUIRED) do
			check(id .. " has " .. field, data[field] ~= nil)
		end
		check(id .. " category valid", VALID_CATEGORIES[data.category] == true, data.category)
		check(id .. " fireMode valid", VALID_FIRE_MODES[data.fireMode] == true, data.fireMode)
		check(id .. " positive damage", data.damage > 0 or data.category == "Throwable")
		check(id .. " positive rpm", data.rpm > 0)
		check(id .. " positive range", data.range > 0)
		check(id .. " pellets >= 1", data.pellets >= 1)
		check(id .. " id matches key", data.id == id)
		check(id .. " visual table", type(data.visual) == "table")
		check(id .. " visual.length > 0", data.visual.length > 0)
		check(id .. " visual has bodyColor", data.visual.bodyColor ~= nil)
		check(id .. " visual has accentColor", data.visual.accentColor ~= nil)
		check(id .. " visual scope valid", VALID_SCOPES[data.visual.scope] == true, data.visual.scope)

		if data.category == "Melee" then
			check(id .. " melee has swing", data.meleeSwing ~= nil)
			check(id .. " melee has damage", data.meleeDamage ~= nil)
			check(id .. " melee has range", data.meleeRange ~= nil)
			check(id .. " melee magazine 0", data.magazine == 0)
			check(id .. " melee swing positive", (data.meleeSwing or 0) > 0)
		end

		if data.category == "Firearm" then
			check(id .. " firearm has magazine", data.magazine > 0)
			check(id .. " firearm has reserve", data.reserveMax > 0)
			check(id .. " firearm reload time > 0", data.reloadTime > 0)
			check(id .. " firearm adsTime > 0", data.adsTime > 0)
		end

		check(id .. " aim spread <= hip spread", data.aimSpread <= data.bulletSpread)
		check(id .. " raiseTime > 0", data.raiseTime > 0)

		if data.model == "Shotgun" then
			check(id .. " shotgun multi-pellet", data.pellets > 1)
		end
		if data.model == "Bow" then
			check(id .. " bow is silent", data.silenced == true)
			check(id .. " bow magazine 1", data.magazine == 1)
		end
	end
end
check("at least 8 weapons defined", weaponCount >= 8, weaponCount)

check("get() returns a weapon", Weapons.get("Pistol") ~= nil)
check("get() returns nil for unknown", Weapons.get("Nope") == nil)
check("isFirearm(Pistol)", Weapons.isFirearm(Weapons.get("Pistol")))
check("isMelee(Machete)", Weapons.isMelee(Weapons.get("Machete")))
check("isThrowable(Molotov)", Weapons.isThrowable(Weapons.get("Molotov")))
check("isFirearm(Machete) false", not Weapons.isFirearm(Weapons.get("Machete")))
check("isMelee(Pistol) false", not Weapons.isMelee(Weapons.get("Pistol")))

local loadout = Weapons.defaultLoadout()
check("default loadout has 4 items", #loadout == 4, #loadout)
for _, id in ipairs(loadout) do
	check("loadout id exists: " .. id, Weapons.get(id) ~= nil)
end

-- Shotgun should out-pellet and out-spread a pistol.
local shotgun = Weapons.get("Shotgun")
local pistol = Weapons.get("Pistol")
check("shotgun shorter range than pistol", shotgun.range < pistol.range)
check("shotgun more spread than pistol", shotgun.bulletSpread > pistol.bulletSpread)

-- ---------------------------------------------------------------------
section("Util")
-- ---------------------------------------------------------------------
local fakeHead = { Name = "Head" }
local fakeTorso = { Name = "Torso" }
local fakeLimb = { Name = "Right Arm" }
local fakeLeg = { Name = "Left Leg" }

check("partCategory Head", Util.partCategory(fakeHead) == "Head")
check("partCategory Torso", Util.partCategory(fakeTorso) == "Torso")
check("partCategory Limb arm", Util.partCategory(fakeLimb) == "Limb")
check("partCategory Limb leg", Util.partCategory(fakeLeg) == "Limb")

check("head multiplier applied", Util.locationMultiplier(fakeHead, 2.5, 0.75) == 2.5)
check("limb multiplier applied", Util.locationMultiplier(fakeLimb, 2.5, 0.75) == 0.75)
check("torso multiplier is 1", Util.locationMultiplier(fakeTorso, 2.5, 0.75) == 1)

check("clamp low", Util.clamp(-5, 0, 10) == 0)
check("clamp high", Util.clamp(50, 0, 10) == 10)
check("clamp mid", Util.clamp(5, 0, 10) == 5)

local damp0 = Util.damp(0, 10)
check("damp(0) is 0", damp0 == 0)
local damp1 = Util.damp(0.1, 10)
check("damp in range", damp1 > 0 and damp1 < 1, damp1)
check("damp increases with dt", Util.damp(0.2, 10) > Util.damp(0.1, 10))
check("damp never exceeds 1", Util.damp(100, 10) <= 1)

local original = { a = 1, b = { c = 2 } }
local copy = Util.deepCopy(original)
check("deepCopy equal", copy.a == 1 and copy.b.c == 2)
check("deepCopy not same ref", copy.b ~= original.b)
copy.b.c = 99
check("deepCopy is independent", original.b.c == 2)

local vecA, vecB = Vector3.new(0, 0, 0), Vector3.new(10, 0, 0)
check("lerpVector 0.5", Util.lerpVector(vecA, vecB, 0.5).X == 5)
check("lerpVector 0", Util.lerpVector(vecA, vecB, 0).X == 0)
check("lerpVector 1", Util.lerpVector(vecA, vecB, 1).X == 10)

-- ---------------------------------------------------------------------
section("Signal")
-- ---------------------------------------------------------------------
local sig = Signal.new()
local received = nil
local conn = sig:Connect(function(value) received = value end)
sig:Fire("hello")
check("signal fired", received == "hello")

conn:Disconnect()
received = nil
sig:Fire("again")
check("disconnect stops delivery", received == nil)

local count = 0
sig:Connect(function() count += 1 end)
sig:Connect(function() count += 1 end)
sig:Fire()
check("multiple handlers fire", count == 2, count)

-- ---------------------------------------------------------------------
section("WeaponModels (procedural builder)")
-- ---------------------------------------------------------------------
-- Every weapon must build into a Model with a Handle, a Muzzle, and a
-- welded hierarchy, because the viewmodel and effects code rely on those.
local builtCount = 0
for id, data in pairs(Weapons) do
	if type(data) == "table" and data.id then
		local ok, model = pcall(WeaponModels.build, data)
		check(id .. " builds without error", ok, not ok and model or nil)
		if ok and model then
			builtCount += 1
			check(id .. " model is a Model", model.ClassName == "Model")
			check(id .. " has PrimaryPart", model.PrimaryPart ~= nil)
			local handle = model.PrimaryPart
			check(id .. " primary part named Handle", handle and handle.Name == "Handle")

			local muzzle = model:FindFirstChild("Muzzle")
			check(id .. " has Muzzle", muzzle ~= nil)
			if muzzle then
				check(id .. " Muzzle flagged", muzzle:GetAttribute("IsMuzzle") == true)
				check(id .. " Muzzle not collidable", muzzle.CanCollide == false)
			end

			check(id .. " WeaponId attribute set", model:GetAttribute("WeaponId") == id)
			check(id .. " Category attribute set", model:GetAttribute("Category") == data.category)

			-- Every non-handle part must be welded to something so the
			-- whole model moves as one unit.
			local parts = 0
			local welds = 0
			for _, child in ipairs(model:GetDescendants()) do
				if child.ClassName == "Part" then
					parts += 1
					if child:FindFirstChildOfClass("WeldConstraint") then
						welds += 1
					end
				end
			end
			check(id .. " has parts", parts >= 1, parts)
			check(id .. " all non-handle parts welded", welds >= parts - 1, welds .. "/" .. parts)

			-- Nothing in a weapon model may block movement or raycasts.
			for _, child in ipairs(model:GetDescendants()) do
				if child.ClassName == "Part" then
					check(id .. " part not collidable", child.CanCollide == false)
				end
			end
		end
	end
end
check("built every weapon model", builtCount == weaponCount, builtCount .. "/" .. weaponCount)

-- Model-specific expectations the visuals depend on.
local function hasChildNamed(model, name)
	for _, child in ipairs(model:GetDescendants()) do
		if child.Name == name then return true end
	end
	return false
end

local rifle = WeaponModels.buildById("HuntingRifle")
check("HuntingRifle builds by id", rifle ~= nil)
check("HuntingRifle has Scope", hasChildNamed(rifle, "Scope"))
check("HuntingRifle has Stock", hasChildNamed(rifle, "Stock"))
check("HuntingRifle has Bolt", hasChildNamed(rifle, "Bolt"))

local silenced = WeaponModels.buildById("SilencedSMG")
check("SilencedSMG has Suppressor", hasChildNamed(silenced, "Suppressor"))

local shotgun = WeaponModels.buildById("Shotgun")
check("Shotgun has Pump", hasChildNamed(shotgun, "Pump"))

local machete = WeaponModels.buildById("Machete")
check("Machete has Blade", hasChildNamed(machete, "Blade"))

local bat = WeaponModels.buildById("Bat")
check("Bat has Blade", hasChildNamed(bat, "Blade"))

local revolver = WeaponModels.buildById("Revolver")
check("Revolver has Cylinder", hasChildNamed(revolver, "Cylinder"))

local bow = WeaponModels.buildById("Bow")
check("Bow has Limb", hasChildNamed(bow, "Limb"))
check("Bow has String", hasChildNamed(bow, "String"))

local bottle = WeaponModels.buildById("Molotov")
check("Molotov has Rag", hasChildNamed(bottle, "Rag"))

check("buildById unknown returns nil", WeaponModels.buildById("Nope") == nil)

-- ---------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	print("Failures:")
	for _, f in ipairs(failures) do
		print("  - " .. f)
	end
	error("tests failed", 0)
end
print("ALL TESTS PASSED")
'''

MODULES = [
    ("Config", "src/shared/Config.lua"),
    ("Weapons", "src/shared/Weapons.lua"),
    ("Util", "src/shared/Util.lua"),
    ("Signal", "src/client/Controllers/Signal.lua"),
]

# WeaponModels calls require(script.Parent.Weapons) at load time, so it
# needs a prelude that fakes `script` and lets require() accept a table.
MODEL_MODULES = [
    ("WeaponModels", "src/shared/WeaponModels.lua"),
]


def read(rel):
    with open(os.path.join(ROOT, rel), "r", encoding="utf-8") as handle:
        return handle.read()


def inline(rel):
    """Wrap a module body in a loader closure that returns its value."""
    source = read(rel)
    return (
        "\ndo\n"
        f"  local function __load()\n{source}\n  end\n"
        "  __LOADED[__MODULE_KEY] = __load()\n"
        "end\n"
    )


def build():
    chunks = [STUBS, HARNESS]
    chunks.append("\n__LOADED = {}\n")

    for name, rel in MODULES:
        chunks.append(f'\n-- >>> {rel}\n')
        chunks.append(f'__MODULE_KEY = "{name}"\n')
        chunks.append(inline(rel))

    for name, _ in MODULES:
        chunks.append(f'local {name} = __LOADED["{name}"]\n')

    # WeaponModels calls require(script.Parent.Weapons). Provide a fake
    # `script` whose Parent has a Weapons child that require() can return.
    chunks.append('\n-- >>> fake Roblox require() for WeaponModels\n')
    chunks.append(
        'do\n'
        '  local WeaponsModule = __LOADED["Weapons"]\n'
        '  local Parent = { Weapons = WeaponsModule }\n'
        '  script = { Parent = Parent }\n'
        '  __real_require = require\n'
        '  require = function(target)\n'
        '    if target == WeaponsModule then return WeaponsModule end\n'
        '    return __real_require(target)\n'
        '  end\n'
        'end\n'
    )
    for name, rel in MODEL_MODULES:
        chunks.append(f'\n-- >>> {rel}\n')
        chunks.append(f'__MODULE_KEY = "{name}"\n')
        chunks.append(inline(rel))
    for name, _ in MODEL_MODULES:
        chunks.append(f'local {name} = __LOADED["{name}"]\n')

    chunks.append(ASSERTIONS)
    return "".join(chunks)


def main():
    generated = build()
    out_path = os.path.join(ROOT, "tests", "generated_test.luau")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(generated)

    if not os.path.exists(LUAU):
        print(f"Luau binary not found at {LUAU}. Set LUAU_BIN to override.")
        return 2

    result = subprocess.run([LUAU, out_path], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
