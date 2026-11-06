--!strict
--[[
	WeaponController
	Everything the player does with a weapon in hand.

	Third person changes how a weapon is presented. There is no camera
	viewmodel here: the weapon is welded into the character's right hand, so
	you see your own gun in the world exactly as everyone else does. The
	animator carries it - the arm pose it already produces for walking,
	aiming, crouching and vaulting moves the gun with it, so there is only
	one source of truth for where the weapon is.

	That also fixes a whole class of first-person bugs: no camera-parented
	geometry to clip through walls, no viewmodel that has to be hidden from
	other players, and no divergence between what you see and what they see.

	Firing, reloading, swapping, melee and throwing are driven from here and
	validated server-side.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local State = require(script.Parent.State)

local WeaponController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Held weapon ----------------------------------------------------------
local weaponModel: Model? = nil
local weaponWeld: Weld? = nil
local handle: BasePart? = nil
local muzzle: BasePart? = nil

-- Runtime --------------------------------------------------------------
local lastShotAt = 0
local nextFireAllowed = 0
local triggerHeld = false
local boltCycling = false
local pumpCycling = false
local reloadStartAt = 0
local swapStartAt = 0
local raiseAlpha = 1

local currentData = nil :: any

--- Where the camera is looking, as a ray. Shots originate from the muzzle
--- so the tracer leaves the barrel, but they are aimed along the camera's
--- centre line so the crosshair tells the truth.
local function getAimRay(): (Vector3, Vector3)
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector

	local muzzlePos = origin + direction * 1.5
	if muzzle and muzzle.Parent then
		muzzlePos = muzzle.Position
	end

	-- Find what the crosshair is on, then aim the muzzle at that point.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { State.character :: any }
	params.IgnoreWater = true

	local hit = workspace:Raycast(origin, direction * Config.Combat.MaxRange, params)
	local aimPoint = hit and hit.Position or (origin + direction * Config.Combat.MaxRange)
	local shotDirection = (aimPoint - muzzlePos).Unit

	return muzzlePos, shotDirection
end

--- Applies spread jitter client-side for the visual tracer only. The
--- server independently rolls spread for damage, so cheating the visual
--- does not change hit registration.
local function spreadDirection(direction: Vector3, degrees: number): Vector3
	if degrees <= 0 then
		return direction
	end
	local rad = math.rad(degrees)
	local jitter = Vector3.new(
		(math.random() - 0.5) * 2 * rad,
		(math.random() - 0.5) * 2 * rad,
		0
	)
	return (direction + jitter).Unit
end

-- Weapon attachment ----------------------------------------------------
local function destroyWeapon()
	if weaponWeld then
		weaponWeld:Destroy()
		weaponWeld = nil
	end
	if weaponModel then
		weaponModel:Destroy()
		weaponModel = nil
	end
	handle = nil
	muzzle = nil
	State.viewmodel = nil
end

--- Where the weapon sits in the hand, in the right arm's local space.
--- The R6 right arm points along its own -Y when it hangs, and swings to
--- point forward when the animator raises it. Welding the gun so its barrel
--- runs along the arm's -Y means one offset reads correctly in every pose:
--- muzzle-down at the side when idle, level and forward when aiming.
local function gripOffsetFor(data): CFrame
	local hand = CFrame.new(0, -1, 0)
	local align = CFrame.Angles(math.rad(-90), 0, 0)

	if data.category == "Melee" then
		-- A blade is held further out and angled back a little.
		return CFrame.new(0, -1.1, -0.1) * align * CFrame.Angles(math.rad(-20), 0, 0)
	elseif data.model == "Pistol" or data.model == "Revolver" then
		-- Short guns sit close to the hand.
		return CFrame.new(0, -0.85, 0.05) * align
	end
	return hand * align
end

local function buildWeapon(weaponId: string)
	destroyWeapon()

	local data = Weapons.get(weaponId)
	if not data then
		return
	end
	currentData = data

	-- Throwables are carried in the hand too, but they are not welded: they
	-- leave the hand on throw, so the model is only built when thrown.
	if data.category == "Throwable" then
		return
	end

	local character = State.character
	if not character then
		return
	end
	local arm = character:FindFirstChild("Right Arm")
	if not arm or not arm:IsA("BasePart") then
		return
	end

	weaponModel = WeaponModels.build(data)
	weaponModel.Parent = character
	handle = weaponModel.PrimaryPart
	muzzle = weaponModel:FindFirstChild("Muzzle") :: BasePart?

	local weld = Instance.new("Weld")
	weld.Name = "TLoUWeaponWeld"
	weld.Part0 = arm
	weld.Part1 = handle
	weld.C0 = gripOffsetFor(data)
	weld.C1 = CFrame.new()
	weld.Parent = arm
	weaponWeld = weld

	State.viewmodel = weaponModel
	raiseAlpha = 0
end

--- Tells the animator this character is holding something, so the arms are
--- carried in a low-ready pose rather than swinging loose.
local function publishArmed()
	local character = State.character
	if not character then
		return
	end
	local armed = State.equipped ~= nil
	character:SetAttribute("Armed", armed)
	character:SetAttribute("Melee", armed and currentData ~= nil and Weapons.isMelee(currentData) or false)
end

-- Firing ---------------------------------------------------------------
local function canFire(): boolean
	if not currentData or not Weapons.isFirearm(currentData) then
		return false
	end
	if State.reloading or State.downed or State.vaulting then
		return false
	end
	if State.stance == "Prone" then
		return false -- cannot fire while crawling
	end
	if raiseAlpha < 0.6 then
		return false
	end
	local mag = State.magazines[currentData.id] or 0
	if mag <= 0 then
		return false
	end
	return os.clock() >= nextFireAllowed
end

local function doReload()
	local data = currentData
	if not data or not Weapons.isFirearm(data) then
		return
	end
	if State.reloading then
		return
	end
	local mag = State.magazines[data.id] or 0
	if mag >= data.magazine then
		return
	end
	if (State.reserves[data.id] or 0) <= 0 then
		return
	end

	State.reloading = true
	reloadStartAt = os.clock()
	Net.toServer("Reload", data.id)

	task.delay(data.reloadTime + 0.1, function()
		if State.reloading and os.clock() - reloadStartAt >= data.reloadTime then
			State.reloading = false
		end
	end)
end

local function fireOnce()
	local data = currentData
	if not data then
		return
	end

	if not canFire() then
		if (State.magazines[data.id] or 0) <= 0 and not State.reloading then
			doReload()
		end
		return
	end

	if boltCycling or pumpCycling then
		return
	end

	State.magazines[data.id] = (State.magazines[data.id] or 0) - 1
	nextFireAllowed = os.clock() + (60 / data.rpm)
	lastShotAt = os.clock()

	local origin, direction = getAimRay()
	local spread = State.aiming and data.aimSpread or data.bulletSpread
	local shotDirection = spreadDirection(direction, spread)

	Net.toServer("Fire", {
		weapon = data.id,
		origin = origin,
		direction = shotDirection,
	})

	-- Immediate local feedback.
	local kickPitch = data.recoil * (State.aiming and 0.6 or 1)
	local kickYaw = (math.random() - 0.5) * data.recoil * 0.5
	State.Signals.Fired:Fire(kickPitch, kickYaw)

	local Effects = require(script.Parent.EffectsController)
	Effects.spawnTracer(origin, origin + shotDirection * data.range, data.silenced)
	if muzzle and muzzle.Parent then
		Effects.spawnMuzzleFlash(muzzle)
	end
	if handle and handle.Parent then
		Effects.ejectShell(handle, data)
	end

	State.Signals.AmmoChanged:Fire(data.id, State.magazines[data.id], State.reserves[data.id] or 0)

	if data.fireMode == "Bolt" then
		boltCycling = true
		task.delay(60 / data.rpm, function()
			boltCycling = false
		end)
	elseif data.fireMode == "Pump" then
		pumpCycling = true
		task.delay(60 / data.rpm * 0.7, function()
			pumpCycling = false
		end)
	end
end

local function doMelee()
	local data = currentData
	if not data or not Weapons.isMelee(data) then
		return
	end
	if State.downed or State.reloading then
		return
	end
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector
	Net.toServer("Melee", { weapon = data.id, origin = origin, direction = direction })
	State.Signals.Shake:Fire(0.25, 0.15)
end

local function doThrow()
	local data = currentData
	if not data or not Weapons.isThrowable(data) then
		return
	end
	local direction = camera.CFrame.LookVector
	Net.toServer("Throw", { weapon = data.id, direction = direction })
end

local function swapTo(index: number)
	local slots = State.slots
	if #slots == 0 then
		return
	end
	index = ((index - 1) % #slots) + 1
	local weaponId = slots[index]
	if not weaponId or weaponId == State.equipped then
		return
	end

	State.reloading = false
	swapStartAt = os.clock()
	State.setEquipped(weaponId)
	Net.toServer("Swap", weaponId)
end

local function cycleWeapon()
	local slots = State.slots
	if #slots == 0 then
		return
	end
	local currentIndex = table.find(slots, State.equipped) or 0
	swapTo(currentIndex + 1)
end

-- Input ----------------------------------------------------------------
local function bindInput()
	UserInputService.InputBegan:Connect(function(inputObject, processed)
		if processed then
			return
		end

		if inputObject.UserInputType == Config.Keys.Fire then
			triggerHeld = true
			fireOnce()
		elseif inputObject.UserInputType == Config.Keys.Aim then
			if currentData and Weapons.isThrowable(currentData) then
				doThrow()
			else
				State.aiming = true
			end
		elseif inputObject.KeyCode == Config.Keys.Reload then
			doReload()
		elseif inputObject.KeyCode == Config.Keys.Melee then
			doMelee()
		elseif inputObject.KeyCode == Config.Keys.Throw then
			doThrow()
		elseif inputObject.KeyCode == Config.Keys.Swap then
			cycleWeapon()
		elseif inputObject.KeyCode == Config.Keys.Heal then
			Net.toServer("Heal")
		elseif inputObject.KeyCode == Enum.KeyCode.One then
			swapTo(1)
		elseif inputObject.KeyCode == Enum.KeyCode.Two then
			swapTo(2)
		elseif inputObject.KeyCode == Enum.KeyCode.Three then
			swapTo(3)
		elseif inputObject.KeyCode == Enum.KeyCode.Four then
			swapTo(4)
		end
	end)

	UserInputService.InputEnded:Connect(function(inputObject)
		if inputObject.UserInputType == Config.Keys.Fire then
			triggerHeld = false
		elseif inputObject.UserInputType == Config.Keys.Aim then
			State.aiming = false
		end
	end)
end

local function update(dt: number)
	-- Raise blend, used to gate firing right after a swap.
	local raiseTarget = 1
	if swapStartAt > 0 and currentData then
		if os.clock() - swapStartAt < currentData.raiseTime then
			raiseTarget = 0
		else
			swapStartAt = 0
		end
	end
	raiseAlpha += (raiseTarget - raiseAlpha) * Util.damp(dt, 9)

	-- Full-auto fire loop.
	if triggerHeld and currentData and currentData.fireMode == "Auto" then
		fireOnce()
	end
end

function WeaponController.init()
	camera = workspace.CurrentCamera
	bindInput()

	Net.get("ReloadResult").OnClientEvent:Connect(function(weaponId, mag, reserve)
		State.reloading = false
		State.magazines[weaponId] = mag
		State.reserves[weaponId] = reserve
		State.Signals.AmmoChanged:Fire(weaponId, mag, reserve)
	end)

	Net.get("SwapResult").OnClientEvent:Connect(function(weaponId)
		-- Server acknowledged the swap; nothing extra to do client-side.
	end)

	-- The server's FireResult is authoritative. For our own shots we skip
	-- the tracer (already drawn locally for zero-latency feel) but still
	-- draw the impacts, which the server alone knows.
	Net.get("FireResult").OnClientEvent:Connect(function(shooter, payload)
		local Effects = require(script.Parent.EffectsController)
		if shooter ~= player then
			Effects.spawnTracer(payload.origin, payload.origin + payload.direction * 200, payload.silenced)
		end
		for _, impact in ipairs(payload.impacts or {}) do
			if impact.character then
				Effects.spawnBlood(impact.position, impact.normal)
			else
				Effects.spawnImpact(impact.position, impact.normal, impact.material)
			end
		end
	end)

	State.Signals.EquippedChanged:Connect(function(weaponId)
		if weaponId then
			buildWeapon(weaponId)
		else
			destroyWeapon()
		end
		publishArmed()
	end)

	State.Signals.CharacterChanged:Connect(function()
		destroyWeapon()
		if State.equipped then
			buildWeapon(State.equipped)
		end
		publishArmed()
	end)

	RunService.RenderStepped:Connect(update)
end

return WeaponController
