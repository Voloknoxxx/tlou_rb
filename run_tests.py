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

import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
LUAU = os.environ.get("LUAU_BIN", "/tmp/luaubin/luau")

STUBS = r'''
-- ---------------------------------------------------------------------
-- Roblox API stubs (shared by every inlined module)
-- ---------------------------------------------------------------------
-- Strict Enum stub. The old version invented a member for any name, which
-- is exactly how Enum.Material.Polymer slipped through: real Roblox raises
-- on an unknown member, and that error takes down the whole requiring
-- script. The table below is generated from Roblox's API dump, so a bad
-- reference now fails here instead of silently returning nil in Studio.
Enum = (function()
	local data = __ENUM_DATA
	local function enumType(name)
		local items = data[name]
		if not items then
			error("Enum." .. name .. " does not exist", 2)
		end
		return setmetatable({}, { __index = function(_, k)
			local v = items[k]
			if v == nil then
				error("Enum." .. name .. "." .. k ..
					" is not a valid member of Enum." .. name, 2)
			end
			return { Name = k, Value = v, EnumType = name }
		end })
	end
	return setmetatable({}, { __index = function(_, key) return enumType(key) end })
end)()

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

-- Real 3x3 matrix maths, because the animation code composes rotations and
-- we want the tests to exercise the actual composition, not a stub that
-- always returns identity.
local function matMul(a, b)
return {
a[1]*b[1] + a[2]*b[4] + a[3]*b[7], a[1]*b[2] + a[2]*b[5] + a[3]*b[8], a[1]*b[3] + a[2]*b[6] + a[3]*b[9],
a[4]*b[1] + a[5]*b[4] + a[6]*b[7], a[4]*b[2] + a[5]*b[5] + a[6]*b[8], a[4]*b[3] + a[5]*b[6] + a[6]*b[9],
a[7]*b[1] + a[8]*b[4] + a[9]*b[7], a[7]*b[2] + a[8]*b[5] + a[9]*b[8], a[7]*b[3] + a[8]*b[6] + a[9]*b[9],
}
end

local function matVec(m, v)
return Vector3.new(
m[1]*v.X + m[2]*v.Y + m[3]*v.Z,
m[4]*v.X + m[5]*v.Y + m[6]*v.Z,
m[7]*v.X + m[8]*v.Y + m[9]*v.Z
)
end

local function matTranspose(m)
return { m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9] }
end

local IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

function CFrame.new(a, b, c, r0, r1, r2, r3, r4, r5, r6, r7, r8)
local cf = setmetatable({}, CFrame)
if type(a) == "table" and a.X then
cf.Position = Vector3.new(a.X, a.Y, a.Z)
cf.R = IDENTITY
elseif type(a) == "table" and a.Position then
cf.Position = a.Position
cf.R = a.R or IDENTITY
else
cf.Position = Vector3.new(a or 0, b or 0, c or 0)
cf.R = IDENTITY
end
if r0 ~= nil then
cf.R = { r0, r1, r2, r3, r4, r5, r6, r7, r8 }
end
cf:refresh()
return cf
end

function CFrame:refresh()
local R = self.R
self.RightVector = Vector3.new(R[1], R[4], R[7])
self.UpVector = Vector3.new(R[2], R[5], R[8])
self.LookVector = Vector3.new(-R[3], -R[6], -R[9])
-- Build Rotation directly rather than through CFrame.new: that would
-- call refresh again and recurse forever.
local rot = setmetatable({}, CFrame)
rot.Position = Vector3.new(0, 0, 0)
rot.R = { R[1], R[2], R[3], R[4], R[5], R[6], R[7], R[8], R[9] }
rot.RightVector = Vector3.new(R[1], R[4], R[7])
rot.UpVector = Vector3.new(R[2], R[5], R[8])
rot.LookVector = Vector3.new(-R[3], -R[6], -R[9])
self.Rotation = rot
return self
end

-- Euler angles in YXZ order (yaw, pitch, roll), matching Roblox's
-- CFrame.fromEulerAnglesYXZ which the animation code uses.
function CFrame.fromEulerAnglesYXZ(y, p, r)
local cy, sy = math.cos(y), math.sin(y)
local cp, sp = math.cos(p), math.sin(p)
local cr, sr = math.cos(r), math.sin(r)
local m = matMul({ cy, 0, sy, 0, 1, 0, -sy, 0, cy }, { 1, 0, 0, 0, cp, -sp, 0, sp, cp })
m = matMul(m, { cr, -sr, 0, sr, cr, 0, 0, 0, 1 })
return CFrame.new(0, 0, 0, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
end

function CFrame.fromAxisAngle(axis, angle)
local v = axis.Unit
local c, s = math.cos(angle), math.sin(angle)
local t = 1 - c
local m = {
t*v.X*v.X + c, t*v.X*v.Y - s*v.Z, t*v.X*v.Z + s*v.Y,
t*v.X*v.Y + s*v.Z, t*v.Y*v.Y + c, t*v.Y*v.Z - s*v.X,
t*v.X*v.Z - s*v.Y, t*v.Y*v.Z + s*v.X, t*v.Z*v.Z + c,
}
return CFrame.new(0, 0, 0, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
end

function CFrame.Angles(x, y, z)
return CFrame.fromEulerAnglesYXZ(y, x, z)
end

function CFrame.__mul(a, b)
if type(b) == "number" then
return CFrame.new(a.Position.X * b, a.Position.Y * b, a.Position.Z * b)
end
local pos = a.Position + matVec(a.R, b.Position)
local rot = matMul(a.R, b.R)
local out = CFrame.new(pos.X, pos.Y, pos.Z, rot[1], rot[2], rot[3], rot[4], rot[5], rot[6], rot[7], rot[8], rot[9])
return out
end

function CFrame:ToEulerAnglesYXZ()
local R = self.R
local pitch = math.asin(-math.clamp(R[6], -1, 1))
local yaw = math.atan2(R[3], R[9])
local roll = math.atan2(R[4], R[5])
return yaw, pitch, roll
end

-- Instance stub with parent/child bookkeeping and property storage.
local function makeInstance(class)
	local inst
	inst = {
		ClassName = class,
		Name = class,
		_children = {},
		_attributes = {},
	}
	function inst:FindFirstChild(name, recursive)
		for _, child in ipairs(self._children) do
			if child.Name == name then return child end
		end
		if recursive then
			for _, child in ipairs(self._children) do
				local found = child:FindFirstChild(name, true)
				if found then return found end
			end
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
	-- Motor6D carries an extra Transform that defaults to identity; our
	-- animator writes it every frame.
	if class == "Motor6D" then
		inst.Transform = CFrame.new()
	end
	function inst:SetAttribute(key, value) self._attributes[key] = value end
	function inst:GetAttribute(key) return self._attributes[key] end
	function inst:IsA(class2)
		if self.ClassName == class2 then return true end
		-- Roblox parts share the abstract "BasePart" superclass.
		local PARTS = { Part = true, MeshPart = true, UnionOperation = true, TrussPart = true, WedgePart = true, CornerWedgePart = true, Sphere = true, Cylinder = true }
		if class2 == "BasePart" and PARTS[self.ClassName] then return true end
		if class2 == "Instance" then return true end
		return false
	end
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
section("AnimationSystem (pose maths)")
-- ---------------------------------------------------------------------
local AS = AnimationSystem

-- A fresh accumulator must start clean.
local st = AS.newState()
check("newState has phase", type(st.phase) == "number")
check("newState phase starts at 0", st.phase == 0)
check("newState has turnPhase", type(st.turnPhase) == "number")
check("newState has breath", type(st.breath) == "number")

-- Weights table must cover every channel the pose reader looks for.
for _, key in ipairs({ "crouch", "prone", "aim", "sprint", "air", "vault", "downed", "armed" }) do
check("EMPTY_WEIGHTS has " .. key, AS.EMPTY_WEIGHTS[key] ~= nil)
end

-- The stride advances with distance travelled, so faster movement means a
-- faster cycle. This is what keeps the feet from skating.
local walkAdvance = AS.strideAdvance(Config.Movement.WalkSpeed, false, 0.1)
local runAdvance = AS.strideAdvance(Config.Movement.SprintSpeed, false, 0.1)
check("stride advances with speed", runAdvance > walkAdvance, runAdvance .. " vs " .. walkAdvance)
check("stride is positive for movement", walkAdvance > 0)
check("sprint boost quickens the cycle", AS.strideAdvance(10, true, 0.1) > AS.strideAdvance(10, false, 0.1))
check("no movement means no stride", AS.strideAdvance(0, false, 0.1) == 0)

-- Turning the body: the returned rate feeds turn-in-place stepping.
local yaw0 = 0
local yaw1, rate = AS.bodyTurn(yaw0, math.rad(90), false, 0.016)
check("bodyTurn moves toward target", yaw1 > yaw0)
check("bodyTurn does not overshoot", yaw1 <= math.rad(90) + 1e-6)
check("bodyTurn reports a positive rate for a positive turn", rate > 0)
check("bodyTurn is symmetric", AS.bodyTurn(0, math.rad(-90), false, 0.016) < 0)

-- Wrapping: a turn across the -pi/pi seam must take the short way round.
local wrapped, wrappedRate = AS.bodyTurn(math.rad(179), math.rad(-179), false, 0.016)
check("bodyTurn wraps across the seam", wrapped > math.rad(179), math.deg(wrapped))

-- Idle: with no speed and no turn, the pose should be near rest.
local idleState = AS.newState()
local idlePose = AS.computePose({
dt = 0.016, speed = 0, turnRate = 0, grounded = true,
weights = AS.EMPTY_WEIGHTS, anim = idleState,
})
check("idle pose exists", idlePose ~= nil)
check("idle pose has all channels", idlePose.leftLeg and idlePose.rightLeg and idlePose.torso and idlePose.head)
check("idle legs are near rest", math.abs(idlePose.leftLeg.pitch) < 2, idlePose.leftLeg.pitch)
check("idle offset is small", idlePose.offset.Magnitude < 0.2)

-- Walking: the legs must swing, and the two legs must oppose each other.
local walkState = AS.newState()
local maxSwing = 0
local opposed = true
for _ = 1, 60 do
local pose = AS.computePose({
dt = 0.016, speed = Config.Movement.WalkSpeed, turnRate = 0, grounded = true,
weights = AS.EMPTY_WEIGHTS, anim = walkState,
})
maxSwing = math.max(maxSwing, math.abs(pose.leftLeg.pitch))
if pose.leftLeg.pitch * pose.rightLeg.pitch > 0 then
opposed = false
end
end
check("walking swings the legs", maxSwing > 10, maxSwing)
check("legs swing in opposition", opposed)

-- Sprinting swings wider than walking.
local function maxLegSwing(speed, weights)
local st2 = AS.newState()
local best = 0
for _ = 1, 60 do
local pose = AS.computePose({ dt = 0.016, speed = speed, turnRate = 0, grounded = true, weights = weights, anim = st2 })
best = math.max(best, math.abs(pose.leftLeg.pitch))
end
return best
end
local sprintWeights = { crouch = 0, prone = 0, aim = 0, sprint = 1, air = 0, vault = 0, downed = 0, armed = 0 }
check("sprint swings legs wider than walk",
maxLegSwing(Config.Movement.SprintSpeed, sprintWeights) > maxLegSwing(Config.Movement.WalkSpeed, AS.EMPTY_WEIGHTS))

-- Turn in place: yawing while standing still must move the feet.
local turnState = AS.newState()
local turnSwing = 0
for _ = 1, 30 do
local pose = AS.computePose({
dt = 0.016, speed = 0, turnRate = 2.0, grounded = true,
weights = AS.EMPTY_WEIGHTS, anim = turnState,
})
turnSwing = math.max(turnSwing, math.abs(pose.leftLeg.pitch))
end
check("turning in place steps the feet", turnSwing > 3, turnSwing)

-- But a tiny drift should not trigger stepping.
local driftState = AS.newState()
local driftPose = AS.computePose({
dt = 0.016, speed = 0, turnRate = Config.Animation.TurnDeadzone * 0.5, grounded = true,
weights = AS.EMPTY_WEIGHTS, anim = driftState,
})
check("small turn drift does not step", math.abs(driftPose.leftLeg.pitch) < 2)

-- Stances.
local crouchWeights = { crouch = 1, prone = 0, aim = 0, sprint = 0, air = 0, vault = 0, downed = 0, armed = 0 }
local crouchPose = AS.computePose({ dt = 0.016, speed = 0, turnRate = 0, grounded = true, weights = crouchWeights, anim = AS.newState() })
check("crouch bends the legs", crouchPose.leftLeg.pitch > 10, crouchPose.leftLeg.pitch)
check("crouch lowers the body", crouchPose.offset.Y < 0, crouchPose.offset.Y)

local proneWeights = { crouch = 0, prone = 1, aim = 0, sprint = 0, air = 0, vault = 0, downed = 0, armed = 0 }
local pronePose = AS.computePose({ dt = 0.016, speed = 0, turnRate = 0, grounded = true, weights = proneWeights, anim = AS.newState() })
check("prone drops the body further than crouch", pronePose.offset.Y < crouchPose.offset.Y, pronePose.offset.Y)
check("prone pitches the root", pronePose.root.pitch ~= 0, pronePose.root.pitch)

-- Aiming raises both arms toward the weapon.
local aimWeights = { crouch = 0, prone = 0, aim = 1, sprint = 0, air = 0, vault = 0, downed = 0, armed = 1 }
local aimPose = AS.computePose({ dt = 0.016, speed = 0, turnRate = 0, grounded = true, weights = aimWeights, anim = AS.newState() })
check("aiming raises the right arm", aimPose.rightArm.pitch > 40, aimPose.rightArm.pitch)
check("aiming raises the left arm", aimPose.leftArm.pitch > 40, aimPose.leftArm.pitch)
check("aiming brings the arms together", aimPose.rightArm.yaw > 0 and aimPose.leftArm.yaw < 0)

-- Armed carry sits between idle and aim.
local armedWeights = { crouch = 0, prone = 0, aim = 0, sprint = 0, air = 0, vault = 0, downed = 0, armed = 1 }
local armedPose = AS.computePose({ dt = 0.016, speed = 0, turnRate = 0, grounded = true, weights = armedWeights, anim = AS.newState() })
check("armed carry raises the arms off idle", armedPose.rightArm.pitch > 10, armedPose.rightArm.pitch)
check("armed carry is lower than full aim", armedPose.rightArm.pitch < aimPose.rightArm.pitch)

-- The head stabilises against torso motion.
local moveState2 = AS.newState()
local lastPose
for _ = 1, 20 do
lastPose = AS.computePose({ dt = 0.016, speed = Config.Movement.WalkSpeed, turnRate = 0, grounded = true, weights = AS.EMPTY_WEIGHTS, anim = moveState2 })
end
check("head counter-rotates against the torso",
lastPose.head.yaw ~= 0 and (lastPose.head.yaw > 0) ~= (lastPose.torso.yaw > 0))

-- Air pose.
local airWeights = { crouch = 0, prone = 0, aim = 0, sprint = 0, air = 1, vault = 0, downed = 0, armed = 0 }
local airPose = AS.computePose({ dt = 0.016, speed = 0, turnRate = 0, grounded = false, weights = airWeights, anim = AS.newState() })
check("air pose tucks the legs", airPose.leftLeg.pitch ~= 0, airPose.leftLeg.pitch)

-- blendWeights eases toward the target instead of snapping.
local weights = { crouch = 0, prone = 0, aim = 0, sprint = 0, air = 0, vault = 0, downed = 0, armed = 0 }
AS.blendWeights(weights, crouchWeights, 0.016, 9)
check("blendWeights moves toward the target", weights.crouch > 0 and weights.crouch < 1, weights.crouch)
for _ = 1, 200 do
AS.blendWeights(weights, crouchWeights, 0.016, 9)
end
check("blendWeights converges", math.abs(weights.crouch - 1) < 0.01, weights.crouch)

-- ---------------------------------------------------------------------
section("R6Rig (skeleton and pose application)")
-- ---------------------------------------------------------------------
check("R6Rig has parts", #R6Rig.PARTS == 6)
check("R6Rig has joints", #R6Rig.JOINTS == 6)

-- The pitch sign flips for upright parts so "positive pitch" always means
-- "lean forward".
check("limb pitch sign is positive", R6Rig.pitchSign("limb") == 1)
check("torso pitch sign is negative", R6Rig.pitchSign("torso") == -1)
check("head pitch sign is negative", R6Rig.pitchSign("head") == -1)

-- Every joint must reference real parts.
local partNames = { HumanoidRootPart = true }
for _, part in ipairs(R6Rig.PARTS) do partNames[part.name] = true end
for _, joint in ipairs(R6Rig.JOINTS) do
check(joint.name .. " part0 exists", partNames[joint.part0] == true, joint.part0)
check(joint.name .. " part1 exists", partNames[joint.part1] == true, joint.part1)
check(joint.name .. " has a channel", joint.channel ~= nil)
end

-- The canonical rig must satisfy our own isR6 check.
local rig = R6Rig.build("TestRig")
check("built rig is a Model", rig.ClassName == "Model")
check("built rig passes isR6", R6Rig.isR6(rig))
check("built rig has a Humanoid", rig:FindFirstChildOfClass("Humanoid") ~= nil)
check("built rig has a root", rig:FindFirstChild("HumanoidRootPart") ~= nil)
check("rig joints are Motor6D",
rig:FindFirstChild("RootJoint", true) ~= nil and rig:FindFirstChild("RootJoint", true).ClassName == "Motor6D")

-- Applying a pose must drive every joint's Transform, and resetting must
-- clear it again.
local testPose = {
root = { pitch = 0, yaw = 0, roll = 0 },
torso = { pitch = 5, yaw = 0, roll = 0 },
head = { pitch = -2, yaw = 0, roll = 0 },
leftArm = { pitch = 40, yaw = 0, roll = 0 },
rightArm = { pitch = -40, yaw = 0, roll = 0 },
leftLeg = { pitch = 30, yaw = 0, roll = 0 },
rightLeg = { pitch = -30, yaw = 0, roll = 0 },
offset = Vector3.new(0, -0.5, 0),
}
local rootMotor = rig:FindFirstChild("RootJoint", true)
local identity = CFrame.new()
check("joints start at rest transform", rootMotor.Transform.Position.Magnitude < 1e-6)

R6Rig.applyPose(rig, testPose)
check("applyPose drives the root transform", rootMotor.Transform ~= identity)
-- The offset must move the joint, since that is what lowers the body.
check("pose offset moves the root joint down", rootMotor.Transform.Position.Y < -0.1, rootMotor.Transform.Position.Y)

-- Every joint with a pose channel must have been driven.
local driven = 0
for _, joint in ipairs(R6Rig.JOINTS) do
local motor = rig:FindFirstChild(joint.name, true)
if motor and motor.Transform.Position.Magnitude + math.abs(motor.Transform:ToEulerAnglesYXZ()) > 0 then
driven += 1
end
end
check("applyPose drove the joints", driven >= 5, driven)

-- Resetting must clear every transform.
R6Rig.resetPose(rig)
local allClear = true
for _, joint in ipairs(R6Rig.JOINTS) do
local motor = rig:FindFirstChild(joint.name, true)
local y, p, r = motor.Transform:ToEulerAnglesYXZ()
if motor.Transform.Position.Magnitude > 1e-6 or math.abs(y) + math.abs(p) + math.abs(r) > 1e-6 then
allClear = false
end
end
check("resetPose clears every transform", allClear)

-- Joint lookup by name is complete.
for _, joint in ipairs(R6Rig.JOINTS) do
check("jointByName has " .. joint.name, R6Rig.jointByName[joint.name] ~= nil)
end

-- Yaw helpers.
local facing = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(90), 0)
check("yawOf reads a 90 degree turn", math.abs(math.deg(R6Rig.yawOf(facing)) - 90) < 1, math.deg(R6Rig.yawOf(facing)))
check("angleDelta wraps", math.abs(R6Rig.angleDelta(math.rad(179), math.rad(-179)) - math.rad(2)) < 1e-6)

-- An incomplete rig must fail the check.
local broken = Instance.new("Model")
broken.Name = "Broken"
local onlyTorso = Instance.new("Part")
onlyTorso.Name = "Torso"
onlyTorso.Parent = broken
check("incomplete rig fails isR6", R6Rig.isR6(broken) == false)

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

# These modules call require(script.Parent.X) at load time, so they need a
# prelude that fakes `script` and lets require() accept a table.
MODEL_MODULES = [
    ("WeaponModels", "src/shared/WeaponModels.lua"),
    ("AnimationSystem", "src/shared/AnimationSystem.lua"),
    ("R6Rig", "src/shared/R6Rig.lua"),
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


def enum_prelude():
    """Vendored Roblox enum members, emitted as a Luau table literal."""
    path = os.path.join(ROOT, "tests", "roblox_enums.json")
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    parts = ["__ENUM_DATA = {"]
    for enum_name in sorted(data):
        parts.append(f'  ["{enum_name}"] = {{')
        for item in sorted(data[enum_name]):
            parts.append(f'    ["{item}"] = {data[enum_name][item]},')
        parts.append("  },")
    parts.append("}")
    return "\n".join(parts) + "\n"


def build():
    chunks = [enum_prelude(), STUBS, HARNESS]
    chunks.append("\n__LOADED = {}\n")

    for name, rel in MODULES:
        chunks.append(f'\n-- >>> {rel}\n')
        chunks.append(f'__MODULE_KEY = "{name}"\n')
        chunks.append(inline(rel))

    for name, _ in MODULES:
        chunks.append(f'local {name} = __LOADED["{name}"]\n')

    # These modules call require(script.Parent.X). Provide a fake `script`
    # whose Parent exposes every sibling they might ask for.
    chunks.append('\n-- >>> fake Roblox require() for model/animation modules\n')
    chunks.append(
        'do\n'
        '  local WeaponsModule = __LOADED["Weapons"]\n'
        '  local ConfigModule = __LOADED["Config"]\n'
        '  local Parent = { Weapons = WeaponsModule, Config = ConfigModule }\n'
        '  script = { Parent = Parent }\n'
        '  __real_require = require\n'
        '  require = function(target)\n'
        '    if target == WeaponsModule then return WeaponsModule end\n'
        '    if target == ConfigModule then return ConfigModule end\n'
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


# ---------------------------------------------------------------------
# Static guards
# ---------------------------------------------------------------------
# The inlined modules above only cover part of the tree, and the Luau stub for
# `Enum` can only catch a bad member when the code actually runs. These two
# checks read every file directly, so a mistake in a controller we never load
# (or in the place generator) still fails the build.

ENUM_RE = re.compile(r"Enum\.(\w+)\.(\w+)")

def check_enums(data):
    """Every Enum.X.Y in src/ must exist in Roblox's API dump."""
    problems = []
    for root, _dirs, files in os.walk(os.path.join(ROOT, "src")):
        for name in sorted(files):
            if not name.endswith(".lua"):
                continue
            path = os.path.join(root, name)
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
            for enum_type, member in ENUM_RE.findall(text):
                items = data.get(enum_type)
                if items is None:
                    problems.append(f"{name}: Enum.{enum_type} does not exist")
                elif member not in items:
                    problems.append(
                        f"{name}: Enum.{enum_type}.{member} is not a valid member")
    return problems


def check_place_structure():
    """The place must parse, keep properties inside <Properties>, and spawn.

    A regex cannot see nesting here: an <Item> that contains other items ends
    at the first child's </Item>, not its own, so the scan has to walk the real
    tree.
    """
    path = os.path.join(ROOT, "TLoUMechanics.rbxlx")
    if not os.path.exists(path):
        return ["TLoUMechanics.rbxlx is missing; run generate_place.py"]

    problems = []
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [f"place XML does not parse: {exc}"]

    def walk(node, trail):
        for item in node.findall("Item"):
            cls = item.get("class", "?")
            props = item.find("Properties")
            name = "?"
            if props is not None:
                name_el = props.find('string[@name="Name"]')
                if name_el is not None:
                    name = name_el.text or "?"
            here = f"{trail}/{name}"

            # Anything directly under <Item> must be <Properties> or a child <Item>.
            for child in item:
                if child.tag not in ("Properties", "Item"):
                    problems.append(
                        f"{here}: <{child.tag} name={child.get('name')!r}> sits "
                        f"outside <Properties>")
            walk(item, here)

    walk(tree.getroot(), "")

    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if 'class="SpawnLocation"' not in text:
        problems.append("place has no SpawnLocation instance")
    return problems


def run_static_guards():
    with open(os.path.join(ROOT, "tests", "roblox_enums.json"), "r",
              encoding="utf-8") as handle:
        data = json.load(handle)
    problems = check_enums(data) + check_place_structure()
    if problems:
        print("STATIC GUARD FAILURES:")
        for problem in problems:
            print("  - " + problem)
        return 1
    print("Static guards passed: enum references and place structure are valid.")
    return 0


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
    if result.returncode != 0:
        return result.returncode

    print()
    return run_static_guards()


if __name__ == "__main__":
    sys.exit(main())
