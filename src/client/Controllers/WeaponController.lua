--!strict
--[[
	WeaponController
	Everything the player does with a weapon in hand:
	* Builds a first-person-style viewmodel from WeaponModels and welds it
	  to the camera, so it swings and bobs with the view.
	* Aim (ADS): narrows the view, tightens spread, pulls the weapon to a
	  sighted pose.
	* Fire: respects fire mode (auto/semi/bolt/pump), sends the shot to
	  the server, and plays local recoil + muzzle flash + tracer
	  immediately so the response feels instant.
	* Reload, swap, melee swings and throwing are all driven from here and
	  validated server-side.
	* Procedural posing: the arms and weapon are animated in code (idle
	  sway, walk sway, aim pose, reload dip) rather than needing an
	  animation asset.
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

-- Viewmodel ------------------------------------------------------------
local viewmodel: Model?
local handle: BasePart?
local muzzle: BasePart?
local rightArm: BasePart?
local leftArm: BasePart?

-- Runtime --------------------------------------------------------------
local lastShotAt = 0
local nextFireAllowed = 0
local triggerHeld = false
local boltCycling = false
local pumpCycling = false
local reloadStartAt = 0
local swapStartAt = 0
local raiseAlpha = 0

-- Procedural animation state
local idlePhase = 0
local aimAlpha = 0
local swayVector = Vector3.new(0, 0, 0)
local recoilKick = 0

local currentData = nil :: any

local function getEquippedData()
	local id = State.equipped
	if not id then
		return nil
	end
	return Weapons.get(id)
end

--- Where the camera is looking, as a ray.
local function getAimRay(): (Vector3, Vector3)
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector
	-- Fire from just below the camera so the tracer appears to leave the
	-- weapon, not the eye.
	local muzzleOffset = camera.CFrame * CFrame.new(0.4, -0.5, -1)
	return muzzleOffset.Position, direction
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

-- Viewmodel construction -----------------------------------------------
local function destroyViewmodel()
	if viewmodel then
		viewmodel:Destroy()
		viewmodel = nil
		State.viewmodel = nil
		handle = nil
		muzzle = nil
		rightArm = nil
		leftArm = nil
	end
end

local function buildArm(name: string, color: Color3): Model
	-- A simple two-segment arm: upper arm + forearm, joined with a
	-- Motor6D-free weld (we pose the whole arm as one part for clarity).
	local arm = Instance.new("Model")
	arm.Name = name

	local upper = Instance.new("Part")
	upper.Name = "Upper"
	upper.Size = Vector3.new(0.32, 0.32, 0.9)
	upper.Color = color
	upper.Material = Enum.Material.SmoothPlastic
	upper.CanCollide = false
	upper.CanQuery = false
	upper.Massless = true
	upper.Parent = arm

	local forearm = Instance.new("Part")
	forearm.Name = "Forearm"
	forearm.Size = Vector3.new(0.3, 0.3, 0.85)
	forearm.Color = color
	forearm.Material = Enum.Material.SmoothPlastic
	forearm.CanCollide = false
	forearm.CanQuery = false
	forearm.Massless = true
	forearm.CFrame = upper.CFrame * CFrame.new(0, 0, -0.85)
	forearm.Parent = arm

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = upper
	weld.Part1 = forearm
	weld.Parent = forearm

	local hand = Instance.new("Part")
	hand.Name = "Hand"
	hand.Size = Vector3.new(0.34, 0.3, 0.36)
	hand.Color = color
	hand.Material = Enum.Material.SmoothPlastic
	hand.CanCollide = false
	hand.CanQuery = false
	hand.Massless = true
	hand.CFrame = upper.CFrame * CFrame.new(0, 0, -1.6)
	hand.Parent = arm

	local weld2 = Instance.new("WeldConstraint")
	weld2.Part0 = upper
	weld2.Part1 = hand
	weld2.Parent = hand

	arm.PrimaryPart = upper
	return arm
end

local function buildViewmodel(weaponId: string)
	destroyViewmodel()

	local data = Weapons.get(weaponId)
	if not data then
		return
	end
	currentData = data

	-- Throwables have no viewmodel; the throw is fired from the camera.
	if data.category == "Throwable" then
		return
	end

	viewmodel = Instance.new("Model")
	viewmodel.Name = "TLoUViewmodel"

	local weaponModel = WeaponModels.build(data)
	weaponModel.Parent = viewmodel
	handle = weaponModel.PrimaryPart
	muzzle = weaponModel:FindFirstChild("Muzzle") :: BasePart?

	local skinColor = Color3.fromRGB(224, 178, 150)

	-- Right arm grips the weapon handle; left arm supports the foregrip.
	local rArm = buildArm("RightArm", skinColor)
	rArm.Parent = viewmodel
	rightArm = rArm.PrimaryPart

	local lArm = buildArm("LeftArm", skinColor)
	lArm.Parent = viewmodel
	leftArm = lArm.PrimaryPart

	-- The viewmodel is parented to the Camera (which is a child of
	-- Workspace). That makes it render only for the local player and keeps
	-- it out of replication, while the welds still pin the sub-parts to
	-- the anchored root that we drive every frame.
	handle.Anchored = true
	rightArm.Anchored = true
	leftArm.Anchored = true

	viewmodel.PrimaryPart = handle
	viewmodel.Parent = camera

	local baseOffset = CFrame.new(0.55, -0.65, -1.35) * CFrame.Angles(math.rad(-4), math.rad(-3), 0)
	handle.CFrame = camera.CFrame * baseOffset
	rightArm.CFrame = handle.CFrame * CFrame.new(0, -0.05, 0.15) * CFrame.Angles(math.rad(90), 0, 0)
	leftArm.CFrame = handle.CFrame * CFrame.new(0.05, -0.15, -data.visual.length * 0.35) * CFrame.Angles(math.rad(90), 0, 0)

	State.viewmodel = viewmodel
	raiseAlpha = 0
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
	-- Cannot fire while the weapon is still being raised after a swap.
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

	-- The server confirms with ReloadResult; we also auto-clear in case.
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

	-- Bolt / pump cycle gate.
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
	recoilKick = math.min(recoilKick + data.recoil * 0.02, 0.06)

	-- Locally draw a tracer so there is no network wait.
	local Effects = require(script.Parent.EffectsController)
	Effects.spawnTracer(origin, origin + shotDirection * data.range, data.silenced)
	if muzzle then
		Effects.spawnMuzzleFlash(muzzle)
	end
	Effects.ejectShell(handle, data)

	State.Signals.AmmoChanged:Fire(data.id, State.magazines[data.id], State.reserves[data.id] or 0)

	-- Cycle bolt/pump weapons.
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
	-- setEquipped fires EquippedChanged, which rebuilds the viewmodel.
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

-- Per-frame posing -----------------------------------------------------
local function poseViewmodel(dt: number)
	if not viewmodel or not handle or not rightArm or not leftArm then
		return
	end

	local data = currentData
	if not data then
		return
	end

	idlePhase += dt * (State.moveSpeed > 1 and 7 or 1.6)
	-- (viewmodel is anchored and driven from the camera below)

	-- Raise / lower the weapon when swapping.
	local raiseTarget = 1
	if swapStartAt > 0 and os.clock() - swapStartAt < data.raiseTime then
		raiseTarget = 0
	else
		swapStartAt = 0
	end
	raiseAlpha += (raiseTarget - raiseAlpha) * Util.damp(dt, 9)

	-- Aim blend.
	local aimTarget = State.aiming and 1 or 0
	aimAlpha += (aimTarget - aimAlpha) * Util.damp(dt, 12)

	-- Base pose, then aim pose.
	local hipPosition = Vector3.new(0.55, -0.65, -1.35)
	local hipRotation = CFrame.Angles(math.rad(-4), math.rad(-3), 0)

	local aimPosition = Vector3.new(0.0, -0.18, -0.85)
	local aimRotation = CFrame.Angles(math.rad(0), math.rad(0), 0)

	local position = hipPosition:Lerp(aimPosition, aimAlpha)
	local rotation = hipRotation:Lerp(aimRotation, aimAlpha)

	-- Weapon-specific hip offset so long guns sit further out.
	local lengthFactor = data.visual.length / 3
	position = position + Vector3.new(0.1 * lengthFactor, 0, -0.15 * lengthFactor)

	-- Walk sway: side-to-side and up-down, scaled by speed.
	local moveFactor = math.clamp(State.moveSpeed / Config.Movement.SprintSpeed, 0, 1)
	local swayX = math.sin(idlePhase) * 0.035 * moveFactor
	local swayY = math.abs(math.cos(idlePhase)) * 0.025 * moveFactor
	local idleY = math.sin(idlePhase * 0.7) * 0.006 * (1 - moveFactor)

	-- Recoil push-back and rise.
	recoilKick *= (1 - math.min(1, 12 * dt))

	local crouchDrop = State.stance == "Crouch" and 0.15 or (State.stance == "Prone" and 0.4 or 0)

	local finalPosition = position
		+ Vector3.new(swayX, swayY + idleY - raiseAlpha * 0.6 - crouchDrop, recoilKick)

	local finalRotation = rotation
		* CFrame.Angles(
			math.rad(recoilKick * 200) - swayY * 0.6,
			-swayX * 0.6,
			0
		)

	local weaponCFrame = camera.CFrame * CFrame.new(finalPosition) * finalRotation

	handle.CFrame = weaponCFrame
	-- Right hand tracks the grip; left hand tracks the foregrip.
	rightArm.CFrame = weaponCFrame * CFrame.new(0, -0.05, 0.15) * CFrame.Angles(math.rad(90), 0, 0)
	leftArm.CFrame = weaponCFrame * CFrame.new(0.05, -0.15, -data.visual.length * 0.35) * CFrame.Angles(math.rad(90), 0, 0)
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
	-- Full-auto fire loop.
	if triggerHeld and currentData and currentData.fireMode == "Auto" then
		fireOnce()
	end
	poseViewmodel(dt)
end

function WeaponController.init()
	camera = workspace.CurrentCamera
	bindInput()

	-- Inventory state itself is owned by NetworkController; we only react
	-- to the resulting EquippedChanged signal (bound below).

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
			buildViewmodel(weaponId)
		end
	end)

	State.Signals.CharacterChanged:Connect(function()
		destroyViewmodel()
		if State.equipped then
			buildViewmodel(State.equipped)
		end
	end)

	RunService.RenderStepped:Connect(update)
end

return WeaponController
