--!strict
--[[
	HUDController
	----------------------------------------------------------------------------
	The whole user interface, built in code so there is nothing to import.

	Design language: flat, dark, low-contrast panels with a single accent colour.
	No drop shadows, no gradients, generous spacing, thin strokes. Everything
	fades rather than pops.

	Elements
		* dynamic crosshair driven by the weapon's live spread
		* health + stamina bars, stamina turns amber then red as it drains
		* ammo counter with reserve
		* six inventory quick-slots
		* contextual interaction prompt with a key badge
		* stealth eye: tells you whether you are exposed or concealed
		* hit marker, damage vignette, and a zombie-alert direction arrow
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)
local WeaponData = require(ReplicatedStorage.Shared.WeaponData)

local ClientState = require(script.Parent.ClientState)

local HUDController = {}

local player = Players.LocalPlayer

local PALETTE = {
	panel = Color3.fromRGB(12, 13, 14),
	panelLight = Color3.fromRGB(24, 26, 27),
	accent = Color3.fromRGB(214, 168, 84),
	health = Color3.fromRGB(196, 78, 70),
	stamina = Color3.fromRGB(198, 196, 186),
	staminaLow = Color3.fromRGB(198, 142, 62),
	staminaEmpty = Color3.fromRGB(170, 66, 60),
	text = Color3.fromRGB(232, 230, 224),
	dim = Color3.fromRGB(150, 148, 142),
	danger = Color3.fromRGB(206, 62, 54),
	stealth = Color3.fromRGB(126, 176, 138),
}

local refs = {} :: { [string]: any }
local gui: ScreenGui

-- ------------------------------------------------------------------ builders --

local function panel(props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = PALETTE.panel
	f.BackgroundTransparency = 0.35
	f.BorderSizePixel = 0
	for k, v in props do
		(f :: any)[k] = v
	end
	return f
end

local function label(props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamMedium
	t.TextColor3 = PALETTE.text
	t.TextSize = 14
	t.TextXAlignment = Enum.TextXAlignment.Left
	for k, v in props do
		(t :: any)[k] = v
	end
	return t
end

local function bar(parent: Instance, colour: Color3): Frame
	local track = panel({
		Name = "Track",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 0.55,
		Parent = parent,
	})
	local fill = panel({
		Name = "Fill",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = colour,
		BackgroundTransparency = 0,
		Parent = track,
	})
	return fill
end

local function corner(instance: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = instance
end

-- ------------------------------------------------------------------ building --

local function buildCrosshair()
	local cross = Instance.new("Frame")
	cross.Name = "Crosshair"
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromOffset(2, 2)
	cross.BackgroundColor3 = PALETTE.text
	cross.BackgroundTransparency = 0.15
	cross.BorderSizePixel = 0
	cross.Parent = gui
	corner(cross, 1)

	local ticks = {}
	for i = 1, 4 do
		local tick = Instance.new("Frame")
		tick.BackgroundColor3 = PALETTE.text
		tick.BackgroundTransparency = 0.15
		tick.BorderSizePixel = 0
		tick.Parent = gui
		corner(tick, 1)
		if i <= 2 then
			tick.Size = UDim2.fromOffset(2, 8)
		else
			tick.Size = UDim2.fromOffset(8, 2)
		end
		ticks[i] = tick
	end

	refs.crosshair = cross
	refs.crosshairTicks = ticks
end

local function buildVitals()
	local holder = panel({
		Name = "Vitals",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 34, 1, -34),
		Size = UDim2.fromOffset(268, 54),
		BackgroundTransparency = 1,
		Parent = gui,
	})

	local healthRow = panel({ Size = UDim2.new(1, 0, 0, 10), BackgroundTransparency = 1, Parent = holder })
	local healthBar = bar(healthRow, PALETTE.health)
	corner(healthRow:FindFirstChild("Track"), 5)
	refs.healthFill = healthBar
	refs.healthText = label({
		Position = UDim2.new(0, 0, 0, 14),
		Size = UDim2.new(1, 0, 0, 16),
		Text = "100",
		TextColor3 = PALETTE.dim,
		TextSize = 13,
		Parent = holder,
	})

	local staminaRow = panel({ Position = UDim2.new(0, 0, 0, 38), Size = UDim2.new(1, 0, 0, 6), BackgroundTransparency = 1, Parent = holder })
	local staminaBar = bar(staminaRow, PALETTE.stamina)
	corner(staminaRow:FindFirstChild("Track"), 3)
	refs.staminaFill = staminaBar
end

local function buildAmmo()
	local holder = panel({
		Name = "Ammo",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -34, 1, -34),
		Size = UDim2.fromOffset(200, 60),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	refs.ammoMag = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(1, 0, 0, 40),
		Text = "--",
		Font = Enum.Font.GothamBold,
		TextSize = 38,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = holder,
	})
	refs.ammoReserve = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -2, 0, 42),
		Size = UDim2.new(1, 0, 0, 18),
		Text = "",
		TextColor3 = PALETTE.dim,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = holder,
	})
	refs.weaponName = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 60),
		Size = UDim2.new(1, 0, 0, 16),
		Text = "",
		TextColor3 = PALETTE.accent,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = holder,
	})
end

local function buildSlots()
	local holder = panel({
		Name = "Slots",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -30),
		Size = UDim2.fromOffset(6 * 46 + 5 * 8, 44),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = holder

	refs.slots = {}
	for i = 1, Config.Items.MaxInventory do
		local slot = panel({
			Name = "Slot" .. i,
			Size = UDim2.fromOffset(46, 44),
			BackgroundTransparency = 0.5,
			LayoutOrder = i,
			Parent = holder,
		})
		corner(slot, 4)
		local stroke = Instance.new("UIStroke")
		stroke.Color = PALETTE.panelLight
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = slot
		local name = label({
			Size = UDim2.new(1, 0, 1, 0),
			Text = "",
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			TextColor3 = PALETTE.text,
			Parent = slot,
		})
		local key = label({
			Position = UDim2.new(0, 4, 0, 2),
			Size = UDim2.fromOffset(12, 12),
			Text = tostring(i),
			TextSize = 10,
			TextColor3 = PALETTE.dim,
			Parent = slot,
		})
		refs.slots[i] = { frame = slot, name = name, key = key, stroke = stroke }
	end
end

local function buildPrompt()
	local holder = panel({
		Name = "Prompt",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -96),
		Size = UDim2.fromOffset(240, 34),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	refs.promptHolder = holder

	local badge = panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 18, 0.5, 0),
		Size = UDim2.fromOffset(30, 30),
		BackgroundColor3 = PALETTE.panelLight,
		BackgroundTransparency = 0.25,
		Parent = holder,
	})
	corner(badge, 4)
	refs.promptBadge = badge
	refs.promptKey = label({
		Size = UDim2.new(1, 0, 1, 0),
		Text = "E",
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = badge,
	})
	refs.promptText = label({
		Position = UDim2.new(0, 40, 0, 0),
		Size = UDim2.new(1, -40, 1, 0),
		Text = "",
		TextSize = 15,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = holder,
	})
	holder.Visible = false
end

local function buildStealth()
	local holder = panel({
		Name = "Stealth",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 22),
		Size = UDim2.fromOffset(190, 26),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	refs.stealthDot = panel({
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(9, 9),
		BackgroundColor3 = PALETTE.stealth,
		Parent = holder,
	})
	corner(refs.stealthDot, 5)
	refs.stealthText = label({
		Position = UDim2.new(0, 18, 0, 0),
		Size = UDim2.new(1, -18, 1, 0),
		Text = "ОТКРЫТ",
		TextSize = 12,
		TextColor3 = PALETTE.dim,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = holder,
	})
end

local function buildEffects()
	local vignette = Instance.new("Frame")
	vignette.Name = "Vignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.ZIndex = 0
	vignette.Parent = gui
	-- A single UIGradient carries both the colour and the falloff, so the
	-- vignette can be faded in by animating one Transparency sequence.
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(PALETTE.danger)
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	gradient.Parent = vignette
	refs.vignette = vignette
	refs.vignetteGradient = gradient

	-- Hit marker: four diagonal ticks around the crosshair.
	local hit = Instance.new("Frame")
	hit.Name = "HitMarker"
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.fromOffset(26, 26)
	hit.BackgroundTransparency = 1
	hit.Parent = gui
	local hitTicks = {}
	for i = 1, 4 do
		local t = Instance.new("Frame")
		t.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		t.BackgroundTransparency = 1
		t.BorderSizePixel = 0
		t.Size = UDim2.fromOffset(2, 7)
		t.AnchorPoint = Vector2.new(0.5, 0.5)
		t.Parent = hit
		hitTicks[i] = t
	end
	refs.hitMarker = hit
	refs.hitTicks = hitTicks

	-- Centre status text (damage numbers, warnings).
	refs.statusText = label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 60),
		Size = UDim2.fromOffset(320, 22),
		Text = "",
		TextColor3 = PALETTE.danger,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		Parent = gui,
	})

	-- Alert arrow: points toward the zombie that noticed you.
	local arrow = panel({
		Name = "AlertArrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 22),
		BackgroundColor3 = PALETTE.danger,
		BackgroundTransparency = 1,
		Rotation = 0,
		Parent = gui,
	})
	corner(arrow, 3)
	refs.alertArrow = arrow
	refs.alertUntil = 0
end

-- -------------------------------------------------------------------- update --

local function updateCrosshair(dt: number)
	local cross = refs.crosshair
	local ticks = refs.crosshairTicks
	local Weapon = ClientState.sibling("WeaponController")
	local spread = 0
	if Weapon then
		spread = Weapon.getSpread and Weapon.getSpread() or 0
	end
	-- Gap grows with spread; base gap keeps it readable at rest.
	local gap = 5 + spread * 3.2
	local alpha = 1 - math.exp(-12 * dt)
	cross.BackgroundTransparency = Util.lerp(cross.BackgroundTransparency, 0.15, alpha)

	local positions = {
		Vector2.new(0, -gap),
		Vector2.new(0, gap),
		Vector2.new(-gap, 0),
		Vector2.new(gap, 0),
	}
	for i, tick in ticks do
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.new(0.5, positions[i].X, 0.5, positions[i].Y)
	end
end

local function updateVitals()
	local humanoid = ClientState.humanoid
	if humanoid then
		local ratio = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
		refs.healthFill.Size = UDim2.new(ratio, 0, 1, 0)
		refs.healthText.Text = ("%d"):format(math.ceil(humanoid.Health))
	end
	local stamina = ClientState.stamina / Config.Movement.StaminaMax
	refs.staminaFill.Size = UDim2.new(math.clamp(stamina, 0, 1), 0, 1, 0)
	if ClientState.exhausted then
		refs.staminaFill.BackgroundColor3 = PALETTE.staminaEmpty
	elseif stamina < 0.35 then
		refs.staminaFill.BackgroundColor3 = PALETTE.staminaLow
	else
		refs.staminaFill.BackgroundColor3 = PALETTE.stamina
	end
end

local function updateAmmo()
	local Weapon = ClientState.sibling("WeaponController")
	if not Weapon then
		return
	end
	local info = Weapon.getHudInfo and Weapon.getHudInfo()
	if not info then
		refs.ammoMag.Text = "--"
		refs.ammoReserve.Text = ""
		refs.weaponName.Text = ""
		return
	end
	if info.reloading then
		refs.ammoMag.Text = "ПЕРЕЗАРЯДКА"
		refs.ammoMag.TextSize = 20
	else
		refs.ammoMag.Text = tostring(info.ammo)
		refs.ammoMag.TextSize = 38
	end
	refs.ammoReserve.Text = ("/ %d"):format(info.reserve)
	refs.weaponName.Text = info.name
end

local function updateSlots()
	local Weapon = ClientState.sibling("WeaponController")
	if not Weapon then
		return
	end
	local inv, equipped = Weapon.getInventory and Weapon.getInventory()
	if not inv then
		return
	end
	for i, slotUi in refs.slots do
		local slot = inv[i]
		if slot then
			local def = WeaponData.Weapons[slot.id]
			slotUi.name.Text = if def then def.DisplayName:sub(1, 6) else slot.id
			slotUi.name.TextColor3 = PALETTE.text
			slotUi.frame.BackgroundTransparency = 0.35
			slotUi.stroke.Transparency = if i == equipped then 0 else 0.5
			slotUi.stroke.Color = if i == equipped then PALETTE.accent else PALETTE.panelLight
			slotUi.key.Text = if def and def.Category == "Throwable" then ("%d"):format(slot.ammo) else tostring(i)
			slotUi.key.TextColor3 = if def and def.Category == "Throwable" then PALETTE.accent else PALETTE.dim
		else
			slotUi.name.Text = ""
			slotUi.frame.BackgroundTransparency = 0.7
			slotUi.stroke.Transparency = 0.6
			slotUi.stroke.Color = PALETTE.panelLight
			slotUi.key.Text = tostring(i)
			slotUi.key.TextColor3 = PALETTE.dim
		end
	end
end

local function updatePrompt()
	local prompt = ClientState.interactPrompt
	if prompt then
		refs.promptHolder.Visible = true
		refs.promptText.Text = prompt.label
	else
		refs.promptHolder.Visible = false
	end
end

local function updateStealth()
	local inGrass = ClientState.inGrass
	local stance = ClientState.stance
	local sprinting = ClientState.sprinting
	local exposed = not inGrass and stance == "Stand"
	local text: string
	local colour: Color3
	if inGrass then
		text = "ТРАВА · СКРЫТ"
		colour = PALETTE.stealth
	elseif stance == "Prone" then
		text = "ЛЁЖА · СКРЫТ"
		colour = PALETTE.stealth
	elseif stance == "Crouch" then
		text = "ПРИСЕД · ТИХО"
		colour = Color3.fromRGB(190, 178, 120)
	elseif sprinting then
		text = "БЕГ · ШУМНО"
		colour = PALETTE.danger
	else
		text = "ОТКРЫТ"
		colour = PALETTE.dim
	end
	refs.stealthText.Text = text
	refs.stealthText.TextColor3 = colour
	refs.stealthDot.BackgroundColor3 = colour
	local _ = exposed
end

local function updateHitMarker(dt: number)
	local now = os.clock()
	local flash = refs.hitMarkerFlash or 0
	flash = math.max(0, flash - dt * 4)
	refs.hitMarkerFlash = flash
	local ticks = refs.hitTicks
	for i, tick in ticks do
		tick.BackgroundTransparency = 1 - flash
		local d = 6 + (1 - flash) * 4
		local pos = {
			Vector2.new(-d, -d),
			Vector2.new(d, -d),
			Vector2.new(-d, d),
			Vector2.new(d, d),
		}
		tick.Position = UDim2.new(0.5, pos[i].X, 0.5, pos[i].Y)
		tick.Rotation = if i == 1 then 45 elseif i == 2 then -45 elseif i == 3 then -45 else 45
	end
	local _ = now
end

local function updateAlert(dt: number)
	local now = os.clock()
	local arrow = refs.alertArrow
	if now > refs.alertUntil then
		arrow.BackgroundTransparency = Util.damp(arrow.BackgroundTransparency, 1, 8, dt)
		return
	end
	local root = ClientState.root
	local target = refs.alertPos :: Vector3?
	local camera = workspace.CurrentCamera
	if not root or not target or not camera then
		return
	end
	local toTarget = (target - root.Position)
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	local camLook = camera.CFrame.LookVector
	local camFlat = Vector3.new(camLook.X, 0, camLook.Z)
	local angle = math.atan2(flat.Unit.Z, flat.Unit.X) - math.atan2(camFlat.Unit.Z, camFlat.Unit.X)
	-- Place the arrow on a circle around the crosshair.
	local radius = 90
	local offset = Vector2.new(math.cos(angle), math.sin(angle)) * radius
	arrow.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
	arrow.Rotation = math.deg(-angle) + 90
	arrow.BackgroundTransparency = 0.15
end

-- ---------------------------------------------------------------------- events --

local function showStatus(text: string, colour: Color3?, duration: number?)
	refs.statusText.Text = text
	refs.statusText.TextColor3 = colour or PALETTE.danger
	refs.statusText.TextTransparency = 0
	refs.statusFadeAt = os.clock() + (duration or 1.6)
end

local function damageVignette(strength: number)
	refs.vignetteDamage = math.min(1, (refs.vignetteDamage or 0) + strength)
end

local function flashVignette(dt: number)
	local damage = refs.vignetteDamage or 0
	local humanoid = ClientState.humanoid
	local lowHealth = 0
	if humanoid then
		local ratio = humanoid.Health / math.max(humanoid.MaxHealth, 1)
		if ratio < 0.35 then
			lowHealth = (0.35 - ratio) / 0.35 * 0.5
		end
	end
	local target = math.max(damage, lowHealth)
	refs.vignetteDamage = math.max(0, damage - dt * 0.8)

	-- One gradient drives colour and falloff; only the alpha changes per frame.
	local g = refs.vignetteGradient :: UIGradient
	local edge = 0.4 - target * 0.38
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1 - target * 0.35),
		NumberSequenceKeypoint.new(0.55, 1 - target * 0.1),
		NumberSequenceKeypoint.new(1, math.clamp(edge, 0, 1)),
	})
end

function HUDController.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "LastStandHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	buildCrosshair()
	buildVitals()
	buildAmmo()
	buildSlots()
	buildPrompt()
	buildStealth()
	buildEffects()

	-- Server -> client signals.
	Net.onClientEvent("HitConfirm", function(worldPos: Vector3, wasHead: boolean, killed: boolean)
		refs.hitMarkerFlash = 1
		if killed then
			showStatus("УБИТ", PALETTE.accent, 1.0)
		end
		local _ = worldPos
		local _ = wasHead
	end)

	Net.onClientEvent("DamageFeedback", function(text: any)
		damageVignette(0.6)
		if type(text) == "string" then
			showStatus(text, PALETTE.danger, 1.2)
		end
	end)

	Net.onClientEvent("ZombieAlerted", function(position: Vector3)
		refs.alertPos = position
		refs.alertUntil = os.clock() + 3
	end)

	Net.onClientEvent("NoiseEmitted", function(position: Vector3, radius: number, kind: string)
		-- Only surface the loudest, most meaningful pings.
		if kind == "Glass" or kind == "Gunshot" then
			refs.alertPos = position
			refs.alertUntil = os.clock() + 1.5
		end
		local _ = radius
	end)

	-- Track local health changes for the vignette.
	RunService.RenderStepped:Connect(function(dt)
		if not ClientState.isAlive() then
			return
		end
		updateCrosshair(dt)
		updateVitals()
		updateAmmo()
		updateSlots()
		updatePrompt()
		updateStealth()
		updateHitMarker(dt)
		updateAlert(dt)
		flashVignette(dt)

		if refs.statusFadeAt and os.clock() > refs.statusFadeAt then
			refs.statusText.TextTransparency = math.min(1, refs.statusText.TextTransparency + dt * 2)
		end
	end)

	-- Damage feedback from the engine (e.g. zombie melee) also drives the
	-- vignette, so the screen reacts even before the server message arrives.
	local function watchHumanoid(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then
			return
		end
		humanoid.HealthChanged:Connect(function(newHealth)
			local old = refs.lastHealth or newHealth
			if newHealth < old then
				damageVignette(math.clamp((old - newHealth) / 30, 0.2, 1))
			end
			refs.lastHealth = newHealth
		end)
	end

	player.CharacterAdded:Connect(watchHumanoid)
	if player.Character then
		watchHumanoid(player.Character)
	end
end

return HUDController
