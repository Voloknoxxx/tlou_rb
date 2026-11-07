--!strict
--[[
	WeaponController
	----------------------------------------------------------------------------
	Everything the player sees and feels when using a weapon.

		* a first-person view model parented to the camera (built by
		  WeaponBuilder, so it matches the third-person model exactly)
		* spring-based sway and bob so the weapon feels attached to a body
		* recoil: the camera kicks (through CameraController) and the view model
		  translates + pitches, then both recover
		* dynamic spread that blooms while firing and settles when you stop
		* tracers, muzzle flash and shell ejection
		* reload, equip, drop and bottle-throwing driven through the server

	The server is always the authority for ammo, damage and hit registration;
	this module only predicts the feel.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)
local WeaponData = require(ReplicatedStorage.Shared.WeaponData)
local WeaponBuilder = require(ReplicatedStorage.Shared.WeaponBuilder)

local ClientState = require(script.Parent.ClientState)

local WeaponController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local state = {
	inventory = {} :: { any },
	reserve = {} :: { [string]: number },
	equipped = 0,
	ammo = 0,
	weaponId = "" :: string,
	def = nil :: any,
	reloading = false,

	viewModel = nil :: Model?,
	viewOffset = CFrame.new(),
	swayVelocity = Vector2.new(0, 0),
	swayTarget = Vector2.new(0, 0),
	recoilOffset = Vector3.zero,
	recoilPitch = 0,
	recoilVelocity = Vector3.zero,
	spread = 0,
	spreadBloom = 0,
	lastFire = 0,
	firing = false,
	equipTime = 0,
	equipDuration = 0,
}

-- ------------------------------------------------------------------ view model --

local function destroyViewModel()
	if state.viewModel then
		state.viewModel:Destroy()
		state.viewModel = nil
	end
end

local function setViewModelVisible(visible: boolean)
	local model = state.viewModel
	if not model then
		return
	end
	if model:GetAttribute("Visible") == visible then
		return
	end
	model:SetAttribute("Visible", visible)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = if visible then 0 else 1
		end
	end
end

local function buildViewModel()
	destroyViewModel()
	if state.weaponId == "" or state.weaponId == "Bottle" then
		return
	end
	local model = WeaponBuilder.build(state.weaponId, { Anchored = true })
	if not model then
		return
	end
	model.Name = "ViewModel"
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			-- Hidden until the player aims; in the default shoulder view the
			-- third-person held weapon is what the player sees.
			part.LocalTransparencyModifier = 1
		end
	end
	model:SetAttribute("Visible", false)
	model.Parent = camera
	state.viewModel = model
end

-- -------------------------------------------------------------------- effects --

local function muzzleFlash(position: Vector3, direction: Vector3)
	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(0.7, 0.7, 0.7)
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 214, 140)
	flash.Transparency = 0.1
	flash.CanCollide = false
	flash.CanQuery = false
	flash.Anchored = true
	flash.CFrame = CFrame.new(position + direction * 0.4)
	flash.Parent = workspace

	local light = Instance.new("PointLight")
	light.Brightness = 4
	light.Range = 18
	light.Color = Color3.fromRGB(255, 200, 130)
	light.Parent = flash

	TweenService:Create(flash, TweenInfo.new(0.06), { Size = Vector3.new(0.1, 0.1, 0.1), Transparency = 1 }):Play()
	Debris:AddItem(flash, 0.1)
end

local function tracer(from: Vector3, to: Vector3)
	local distance = (to - from).Magnitude
	if distance < 0.5 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Size = Vector3.new(0.08, 0.08, distance)
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 240, 190)
	beam.Transparency = 0.25
	beam.CanCollide = false
	beam.CanQuery = false
	beam.Anchored = true
	beam.CFrame = CFrame.lookAt(from + (to - from) / 2, to)
	beam.Parent = workspace
	TweenService:Create(beam, TweenInfo.new(0.08), { Transparency = 1 }):Play()
	Debris:AddItem(beam, 0.1)
end

local function shellEject(position: Vector3)
	local shell = Instance.new("Part")
	shell.Name = "Shell"
	shell.Size = Vector3.new(0.2, 0.2, 0.45)
	shell.Material = Enum.Material.Metal
	shell.Color = Color3.fromRGB(196, 168, 92)
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CFrame = CFrame.new(position)
	shell.AssemblyLinearVelocity = Vector3.new(math.random(-6, 6), math.random(6, 12), math.random(-6, 6))
	shell.Parent = workspace
	Debris:AddItem(shell, 2)
end

-- --------------------------------------------------------------------- firing --

local function currentSpread(): number
	if not state.def then
		return 0
	end
	return state.def.Spread + state.spreadBloom
end

local function fireOnce()
	local def = state.def
	if not def then
		return
	end
	local now = os.clock()
	if now - state.lastFire < def.FireRate then
		return
	end
	if state.reloading or state.equipTime > 0 then
		return
	end
	if state.ammo <= 0 then
		-- Dry fire: single click, no recoil.
		if now - state.lastFire > 0.25 then
			state.lastFire = now
			Net.fireServer("RequestReload")
		end
		return
	end
	state.lastFire = now

	local Camera = ClientState.sibling("CameraController")
	local origin = Camera and Camera.getAimOrigin() or (ClientState.root and ClientState.root.Position)
	local direction = Camera and Camera.getLookDirection() or Vector3.new(0, 0, -1)

	-- Apply spread locally for the tracer so the visual matches the server's
	-- raycast closely.
	local spreadRad = math.rad(currentSpread())
	local jitter = Vector3.new(
		(math.random() - 0.5) * 2 * spreadRad,
		(math.random() - 0.5) * 2 * spreadRad,
		(math.random() - 0.5) * 2 * spreadRad
	)
	local shotDir = (direction + jitter).Unit

	Net.fireServer("RequestFire", origin, shotDir, tick())

	-- Recoil feel.
	if Camera then
		Camera.addRecoil(def.RecoilKick, def.RecoilYaw)
	end
	state.recoilPitch += def.RecoilKick * 0.06
	state.recoilOffset += Vector3.new(0, 0.02, def.MuzzleRise * 0.5)

	-- Bloom.
	state.spreadBloom = math.min(state.def.SpreadMax, state.spreadBloom + def.SpreadPerShot)

	-- Visuals from the muzzle.
	local muzzlePos = origin + shotDir * 2
	if state.viewModel then
		local muzzle = WeaponBuilder.getMuzzle(state.viewModel)
		if muzzle then
			muzzlePos = muzzle.Position
		end
	end
	muzzleFlash(muzzlePos, shotDir)

	local ignore: { Instance } = {}
	if ClientState.character then
		table.insert(ignore, ClientState.character)
	end
	if state.viewModel then
		table.insert(ignore, state.viewModel)
	end
	local hit = Util.raycast(origin, shotDir * Config.Combat.MaxRange, ignore)
	local endPos = if hit then hit.Position else origin + shotDir * Config.Combat.MaxRange
	tracer(muzzlePos, endPos)

	if def.Category ~= "Shotgun" and math.random() < 0.9 then
		shellEject(origin + shotDir * 0.5)
	end

	if ClientState.animator then
		ClientState.animator:play("Fire", { duration = 0.22, priority = 15, args = { def.RecoilKick }, restart = true })
	end

	state.ammo = math.max(0, state.ammo - 1)
	ClientState.notify()
end

local function throwBottle(quick: boolean)
	local Camera = ClientState.sibling("CameraController")
	local origin = Camera and Camera.getAimOrigin() or Vector3.zero
	local direction = Camera and Camera.getLookDirection() or Vector3.new(0, 0, -1)
	if quick then
		-- Find a bottle anywhere in the inventory and throw it without equipping.
		for _, slot in state.inventory do
			if slot and slot.id == "Bottle" and slot.ammo > 0 then
				Net.fireServer("RequestThrowBottle", origin, direction)
				break
			end
		end
	else
		if state.weaponId ~= "Bottle" or state.ammo <= 0 then
			return
		end
		Net.fireServer("RequestThrowBottle", origin, direction)
	end
	if ClientState.animator then
		ClientState.animator:play("Throw", { duration = 0.7, priority = 18 })
	end
end

-- ------------------------------------------------------------------- equipping --

local function equipSlot(index: number)
	if index == state.equipped then
		return
	end
	if index == 0 then
		state.equipped = 0
		state.weaponId = ""
		state.def = nil
		destroyViewModel()
		Net.fireServer("RequestEquip", 0)
		ClientState.notify()
		return
	end
	local slot = state.inventory[index]
	if not slot then
		return
	end
	state.equipped = index
	state.weaponId = slot.id
	state.ammo = slot.ammo
	state.def = WeaponData.Weapons[slot.id]
	state.reloading = false
	state.spreadBloom = 0
	state.equipDuration = state.def and state.def.EquipTime or 0.4
	state.equipTime = state.equipDuration
	buildViewModel()
	Net.fireServer("RequestEquip", index)
	ClientState.notify()
end

WeaponController.equipSlot = equipSlot

function WeaponController.holster()
	equipSlot(0)
end

-- --------------------------------------------------------------- HUD accessors --

function WeaponController.getSpread(): number
	return state.spread
end

function WeaponController.getInventory(): ({ any }, number)
	return state.inventory, state.equipped
end

--[[
	Everything the HUD needs to draw the ammo block, or nil when unarmed.
]]
function WeaponController.getHudInfo(): { ammo: number, reserve: number, name: string, reloading: boolean, weaponId: string }?
	if state.equipped == 0 or not state.def then
		return nil
	end
	local ammoType = state.def.AmmoType
	return {
		ammo = state.ammo,
		reserve = state.reserve[ammoType] or 0,
		name = state.def.DisplayName,
		reloading = state.reloading,
		weaponId = state.weaponId,
	}
end

function WeaponController.setAiming(on: boolean)
	ClientState.aiming = on
	ClientState.notify()
end

-- -------------------------------------------------------------------- update --

local function updateViewModel(dt: number)
	local model = state.viewModel
	if not model or not model.PrimaryPart then
		return
	end
	local def = state.def
	if not def then
		return
	end

	local aiming = ClientState.aiming
	local stance = ClientState.stance
	-- The view model is a first-person sight: it only appears while aiming.
	setViewModelVisible(aiming and stance ~= "Prone")

	-- Base hold position: bottom-right of the screen, pulled toward the centre
	-- when aiming. Values are in camera-local studs.
	local baseX = if aiming then 0.05 else 0.55
	local baseY = if aiming then -0.35 else -0.75
	local baseZ = if aiming then -1.1 else -1.6
	if stance == "Crouch" then
		baseY -= 0.08
	elseif stance == "Prone" then
		baseY -= 0.16
	end
	-- Heavier weapons sit lower and further out.
	local weightOffset = (def.Weight - 1) * 0.12
	baseY -= weightOffset
	baseZ -= weightOffset * 0.4

	-- Sway: the weapon lags behind camera rotation.
	local delta = UserInputService:GetMouseDelta()
	state.swayTarget = Vector2.new(
		Util.clamp(-delta.X * 0.004, -0.09, 0.09),
		Util.clamp(delta.Y * 0.004, -0.09, 0.09)
	)
	state.swayVelocity = Vector2.new(
		Util.damp(state.swayVelocity.X, state.swayTarget.X, 8, dt),
		Util.damp(state.swayVelocity.Y, state.swayTarget.Y, 8, dt)
	)

	-- Walk bob.
	local root = ClientState.root
	local horizontal = if root then Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude else 0
	local bobX, bobY = 0, 0
	if horizontal > 1 and not aiming then
		local t = os.clock() * 8 * math.clamp(horizontal / 12, 0.3, 1.6)
		bobX = math.sin(t) * 0.05 * math.clamp(horizontal / 16, 0, 1)
		bobY = math.abs(math.cos(t)) * 0.05 * math.clamp(horizontal / 16, 0, 1)
	end

	-- Recoil recovery.
	state.recoilOffset = Vector3.new(
		Util.damp(state.recoilOffset.X, 0, 14, dt),
		Util.damp(state.recoilOffset.Y, 0, 14, dt),
		Util.damp(state.recoilOffset.Z, 0, 14, dt)
	)
	state.recoilPitch = Util.damp(state.recoilPitch, 0, 14, dt)

	-- Equip raise: the weapon starts low and swings up.
	local equipAlpha = 1
	if state.equipTime > 0 then
		state.equipTime = math.max(0, state.equipTime - dt)
		equipAlpha = 1 - (state.equipTime / math.max(state.equipDuration, 0.01))
	end
	local equipDip = (1 - equipAlpha) * 0.9

	state.viewOffset = CFrame.new(
		baseX + bobX + state.swayVelocity.X,
		baseY + bobY + state.swayVelocity.Y - equipDip - state.recoilOffset.Y,
		baseZ + state.recoilOffset.Z
	) * CFrame.Angles(math.rad(state.recoilPitch * 4 + equipDip * 30), math.rad(state.swayVelocity.X * 40), math.rad(state.swayVelocity.Y * 30))

	-- The offset is authored for the grip, so the hold offset maps it onto the
	-- model's primary part.
	model:PivotTo(camera.CFrame * state.viewOffset * WeaponBuilder.holdOffset(state.weaponId))
end

local function updateSpread(dt: number)
	-- Bloom decays back to zero when not firing.
	local decay = if state.firing then 0.6 else 6
	state.spreadBloom = Util.damp(state.spreadBloom, 0, decay, dt)
	state.spread = currentSpread()
end

-- ---------------------------------------------------------------------- input --

local function bindInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not ClientState.isAlive() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if state.weaponId == "Bottle" then
				throwBottle(false)
			else
				state.firing = true
				fireOnce()
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			WeaponController.setAiming(true)
		elseif input.KeyCode == Config.Keys.Reload then
			if state.equipped > 0 and not state.reloading then
				Net.fireServer("RequestReload")
			end
		elseif input.KeyCode == Config.Keys.Aim then
			WeaponController.setAiming(not ClientState.aiming)
		elseif input.KeyCode == Config.Keys.ThrowBottle then
			throwBottle(true)
		elseif input.KeyCode == Config.Keys.Drop then
			if state.equipped > 0 then
				Net.fireServer("RequestDrop", state.equipped)
			end
		elseif input.KeyCode == Enum.KeyCode.One then
			equipSlot(1)
		elseif input.KeyCode == Enum.KeyCode.Two then
			equipSlot(2)
		elseif input.KeyCode == Enum.KeyCode.Three then
			equipSlot(3)
		elseif input.KeyCode == Enum.KeyCode.Four then
			equipSlot(4)
		elseif input.KeyCode == Enum.KeyCode.Five then
			equipSlot(5)
		elseif input.KeyCode == Enum.KeyCode.Six then
			equipSlot(6)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			state.firing = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			WeaponController.setAiming(false)
		end
	end)
end

-- ---------------------------------------------------------------------- events --

local function onInventoryChanged(slots: any, reserve: any, equipped: any)
	state.inventory = slots or {}
	state.reserve = reserve or {}
	if equipped ~= state.equipped then
		state.equipped = equipped or 0
		local slot = state.inventory[state.equipped]
		if slot then
			state.weaponId = slot.id
			state.ammo = slot.ammo
			state.def = WeaponData.Weapons[slot.id]
			buildViewModel()
		else
			state.weaponId = ""
			state.def = nil
			destroyViewModel()
		end
	end
	-- Keep the ammo readout in sync when the slot we hold changed.
	local slot = state.inventory[state.equipped]
	if slot then
		state.weaponId = slot.id
		state.ammo = slot.ammo
		state.def = WeaponData.Weapons[slot.id]
	end
	ClientState.notify()
end

local function onWeaponState(payload: any)
	if type(payload) ~= "table" then
		return
	end
	state.ammo = payload.Ammo or 0
	if payload.Reserve then
		state.reserve[payload.WeaponId and WeaponData.Weapons[payload.WeaponId] and WeaponData.Weapons[payload.WeaponId].AmmoType or ""] = payload.Reserve
	end
	state.reloading = payload.Reloading == true
	if payload.WeaponId and payload.WeaponId ~= state.weaponId then
		state.weaponId = payload.WeaponId
		state.def = WeaponData.Weapons[payload.WeaponId]
		buildViewModel()
	end
	ClientState.notify()
end

function WeaponController.start()
	camera = workspace.CurrentCamera
	Net.onClientEvent("InventoryChanged", onInventoryChanged)
	Net.onClientEvent("WeaponState", onWeaponState)

	-- Remote-played effects from other shooters.
	Net.onClientEvent("FireEffect", function(origin: Vector3, direction: Vector3, weaponId: string, shooter: Player)
		if shooter == player then
			return
		end
		local def = WeaponData.Weapons[weaponId]
		if not def then
			return
		end
		local muzzle = origin + Vector3.new(0, 2, 0)
		muzzleFlash(muzzle, direction)
		tracer(muzzle, muzzle + direction * 120)
	end)

	bindInput()

	RunService.RenderStepped:Connect(function(dt)
		if not ClientState.isAlive() then
			return
		end
		-- Automatic fire: keep firing while the button is held.
		if state.firing and state.def and state.def.Automatic then
			fireOnce()
		end
		updateSpread(dt)
		updateViewModel(dt)
	end)
end

return WeaponController
