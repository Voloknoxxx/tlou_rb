--!strict
--[[
	HUDController
	Builds the whole interface in code - no GUI instances needed in the
	place file. The layout mirrors TLoU's diegetic, minimal HUD:
	* Health arc bottom-left that flashes red when hurt.
	* Stamina bar that appears only while sprinting or exhausted.
	* Ammo readout bottom-right: "mag / reserve".
	* Weapon slot strip showing the four equipped items.
	* A small compass at the top centre.
	* Hitmarker flash on a confirmed hit.
	* A subtle vignette that darkens when health is low.
	* Noise indicator ring that pulses when the player makes noise.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Weapons = require(Shared.Weapons)

local State = require(script.Parent.State)

local HUDController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui: ScreenGui
local healthBar: Frame
local healthLabel: TextLabel
local staminaBar: Frame
local staminaContainer: Frame
local ammoLabel: TextLabel
local weaponNameLabel: TextLabel
local slotButtons: { TextLabel } = {}
local compassLabel: TextLabel
local hitmarker: TextLabel
local vignette: Frame
local noiseRing: Frame
local centerDot: Frame
local downedOverlay: Frame

local hitmarkerAlpha = 0
local hitmarkerTimer = 0
local noiseAlpha = 0
local vignetteAlpha = 0

local COLORS = {
	panel = Color3.fromRGB(12, 12, 14),
	accent = Color3.fromRGB(196, 162, 96),
	health = Color3.fromRGB(180, 60, 50),
	healthLow = Color3.fromRGB(230, 40, 30),
	stamina = Color3.fromRGB(210, 190, 120),
	text = Color3.fromRGB(228, 226, 220),
	dim = Color3.fromRGB(120, 118, 112),
}

local function newFrame(name: string, parent: Instance, size: UDim2, position: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = COLORS.panel
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

local function newLabel(name: string, parent: Instance, text: string, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Text = text
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextColor3 = COLORS.text
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "TLoUHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	-- Vignette (behind everything else) ------------------------------
	vignette = Instance.new("Frame")
	vignette.Name = "Vignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.ZIndex = 0
	vignette.Parent = gui

	-- Center dot -----------------------------------------------------
	centerDot = Instance.new("Frame")
	centerDot.Name = "CenterDot"
	centerDot.Size = UDim2.fromOffset(4, 4)
	centerDot.Position = UDim2.fromScale(0.5, 0.5)
	centerDot.AnchorPoint = Vector2.new(0.5, 0.5)
	centerDot.BackgroundColor3 = COLORS.text
	centerDot.BackgroundTransparency = 0.3
	centerDot.BorderSizePixel = 0
	centerDot.ZIndex = 2
	centerDot.Parent = gui

	-- Health ---------------------------------------------------------
	local healthContainer = newFrame("HealthContainer", gui, UDim2.fromOffset(280, 44), UDim2.new(0, 32, 1, -84))
	healthContainer.BackgroundTransparency = 1

	local healthBack = newFrame("HealthBack", healthContainer, UDim2.fromScale(1, 0.45), UDim2.fromScale(0, 0.1))
	healthBack.BackgroundColor3 = Color3.fromRGB(30, 30, 32)
	healthBack.BackgroundTransparency = 0.25

	healthBar = newFrame("HealthFill", healthBack, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	healthBar.BackgroundColor3 = COLORS.health
	healthBar.BackgroundTransparency = 0

	healthLabel = newLabel("HealthLabel", healthContainer, "100", UDim2.fromScale(1, 0.5), UDim2.fromScale(0, 0.55))
	healthLabel.TextSize = 22
	healthLabel.Font = Enum.Font.GothamBold

	-- Stamina --------------------------------------------------------
	staminaContainer = newFrame("StaminaContainer", gui, UDim2.fromOffset(200, 12), UDim2.new(0, 32, 1, -118))
	staminaContainer.BackgroundColor3 = Color3.fromRGB(30, 30, 32)
	staminaContainer.BackgroundTransparency = 0.4
	staminaContainer.Visible = false

	staminaBar = newFrame("StaminaFill", staminaContainer, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	staminaBar.BackgroundColor3 = COLORS.stamina
	staminaBar.BackgroundTransparency = 0

	-- Ammo -----------------------------------------------------------
	ammoLabel = newLabel("AmmoLabel", gui, "-- / --", UDim2.fromOffset(220, 44), UDim2.new(1, -252, 1, -84))
	ammoLabel.TextSize = 34
	ammoLabel.Font = Enum.Font.GothamBold
	ammoLabel.TextXAlignment = Enum.TextXAlignment.Right

	weaponNameLabel = newLabel("WeaponName", gui, "", UDim2.fromOffset(220, 20), UDim2.new(1, -252, 1, -44))
	weaponNameLabel.TextSize = 15
	weaponNameLabel.TextColor3 = COLORS.dim
	weaponNameLabel.TextXAlignment = Enum.TextXAlignment.Right

	-- Weapon slots ---------------------------------------------------
	local slotContainer = newFrame("SlotContainer", gui, UDim2.fromOffset(300, 40), UDim2.new(0.5, -150, 1, -60))
	slotContainer.BackgroundTransparency = 1

	for i = 1, Config.Inventory.MaxSlots do
		local slot = newLabel("Slot" .. i, slotContainer, tostring(i), UDim2.fromOffset(70, 36), UDim2.fromOffset((i - 1) * 74, 2))
		slot.BackgroundColor3 = COLORS.panel
		slot.BackgroundTransparency = 0.4
		slot.TextXAlignment = Enum.TextXAlignment.Center
		slot.TextSize = 13
		slot.TextColor3 = COLORS.dim
		table.insert(slotButtons, slot)
	end

	-- Compass --------------------------------------------------------
	local compassBack = newFrame("CompassBack", gui, UDim2.fromOffset(360, 26), UDim2.new(0.5, -180, 0, 18))
	compassBack.BackgroundTransparency = 0.5

	compassLabel = newLabel("CompassLabel", compassBack, "N", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	compassLabel.TextSize = 18
	compassLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- Hitmarker ------------------------------------------------------
	hitmarker = newLabel("Hitmarker", gui, "X", UDim2.fromOffset(40, 40), UDim2.new(0.5, -20, 0.5, -20))
	hitmarker.TextSize = 28
	hitmarker.Font = Enum.Font.GothamBold
	hitmarker.TextColor3 = COLORS.text
	hitmarker.TextTransparency = 1
	hitmarker.TextXAlignment = Enum.TextXAlignment.Center
	hitmarker.ZIndex = 3

	-- Noise ring -----------------------------------------------------
	noiseRing = Instance.new("Frame")
	noiseRing.Name = "NoiseRing"
	noiseRing.Size = UDim2.fromOffset(60, 60)
	noiseRing.Position = UDim2.new(0.5, -30, 0.5, -30)
	noiseRing.BackgroundTransparency = 1
	noiseRing.ZIndex = 1
	noiseRing.Parent = gui

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0.5, 0)
	ringCorner.Parent = noiseRing

	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 2
	ringStroke.Color = COLORS.accent
	ringStroke.Transparency = 1
	ringStroke.Parent = noiseRing

	-- Downed overlay -------------------------------------------------
	downedOverlay = newFrame("DownedOverlay", gui, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	downedOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	downedOverlay.BackgroundTransparency = 1
	downedOverlay.Visible = false

	local downedText = newLabel("DownedText", downedOverlay, "DOWNED - HOLD ON", UDim2.fromScale(1, 0.1), UDim2.fromScale(0, 0.6))
	downedText.TextSize = 32
	downedText.Font = Enum.Font.GothamBold
	downedText.TextColor3 = Color3.fromRGB(200, 60, 50)
	downedText.TextXAlignment = Enum.TextXAlignment.Center
end

-- Update helpers -------------------------------------------------------
local function updateHealth()
	local fraction = math.clamp(State.health / Config.Combat.MaxHealth, 0, 1)
	healthBar.Size = UDim2.fromScale(fraction, 1)
	healthLabel.Text = tostring(math.floor(State.health))

	if fraction < 0.35 then
		healthBar.BackgroundColor3 = COLORS.healthLow
		vignetteAlpha = math.clamp(1 - fraction / 0.35, 0, 1) * 0.35
	else
		healthBar.BackgroundColor3 = COLORS.health
		vignetteAlpha = 0
	end
end

local function updateAmmo()
	local weaponId = State.equipped
	if not weaponId then
		ammoLabel.Text = "-- / --"
		weaponNameLabel.Text = ""
		return
	end
	local data = Weapons.get(weaponId)
	if not data then
		return
	end

	if data.category == "Melee" then
		ammoLabel.Text = "∞"
	elseif data.category == "Throwable" then
		ammoLabel.Text = tostring(State.reserves[weaponId] or 0)
	else
		local mag = State.magazines[weaponId] or 0
		local reserve = State.reserves[weaponId] or 0
		ammoLabel.Text = string.format("%d / %d", mag, reserve)
		if mag == 0 then
			ammoLabel.TextColor3 = COLORS.healthLow
		else
			ammoLabel.TextColor3 = COLORS.text
		end
	end

	weaponNameLabel.Text = data.name
end

local function updateSlots()
	for i, slot in ipairs(slotButtons) do
		local weaponId = State.slots[i]
		if weaponId then
			local data = Weapons.get(weaponId)
			slot.Text = string.format("[%d] %s", i, data and data.name or weaponId)
			slot.TextColor3 = (weaponId == State.equipped) and COLORS.accent or COLORS.dim
			slot.BackgroundTransparency = (weaponId == State.equipped) and 0.15 or 0.5
		else
			slot.Text = string.format("[%d] -", i)
			slot.TextColor3 = COLORS.dim
		end
	end
end

local function updateCompass()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local look = camera.CFrame.LookVector
	local angle = math.deg(math.atan2(-look.X, -look.Z))
	angle = (angle % 360 + 360) % 360

	local directions = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
	local index = math.floor(((angle + 22.5) % 360) / 45) + 1
	local direction = directions[index]

	compassLabel.Text = string.format("%s  %03d°", direction, math.floor(angle))
end

local function update(dt: number)
	local camera = workspace.CurrentCamera

	-- Stamina bar visibility: only when relevant.
	local showStamina = State.sprinting or State.exhausted or State.stamina < Config.Movement.MaxStamina - 1
	staminaContainer.Visible = showStamina
	if showStamina then
		staminaBar.Size = UDim2.fromScale(math.clamp(State.stamina / Config.Movement.MaxStamina, 0, 1), 1)
		staminaBar.BackgroundColor3 = State.exhausted and COLORS.healthLow or COLORS.stamina
	end

	-- Vignette.
	vignette.BackgroundTransparency = 1 - vignetteAlpha

	-- Hitmarker fade (time based, so it cannot get stuck on).
	if hitmarkerAlpha > 0 then
		hitmarkerTimer -= dt
		if hitmarkerTimer <= 0 then
			hitmarkerAlpha = 0
		else
			hitmarkerAlpha = math.clamp(hitmarkerTimer / 0.3, 0, 1)
		end
		hitmarker.TextTransparency = 1 - hitmarkerAlpha
	end

	-- Noise ring pulse.
	local ringStroke = noiseRing:FindFirstChildOfClass("UIStroke")
	if ringStroke then
		if noiseAlpha > 0 then
			noiseAlpha = math.max(0, noiseAlpha - dt * 1.5)
			ringStroke.Transparency = 1 - noiseAlpha * 0.8
			local scale = 1 + (1 - noiseAlpha) * 0.8
			noiseRing.Size = UDim2.fromOffset(60 * scale, 60 * scale)
			noiseRing.Position = UDim2.new(0.5, -30 * scale, 0.5, -30 * scale)
		else
			ringStroke.Transparency = 1
		end
	end

	-- Aiming tightens the reticle.
	centerDot.Size = State.aiming and UDim2.fromOffset(2, 2) or UDim2.fromOffset(4, 4)
	centerDot.BackgroundTransparency = State.aiming and 0.1 or 0.35

	updateCompass()
end

function HUDController.init()
	buildGui()
	updateHealth()
	updateAmmo()
	updateSlots()

	State.Signals.HealthChanged:Connect(function()
		updateHealth()
	end)

	State.Signals.AmmoChanged:Connect(function()
		updateAmmo()
	end)

	State.Signals.EquippedChanged:Connect(function()
		updateAmmo()
		updateSlots()
	end)

	State.Signals.HitFeedback:Connect(function(payload)
		hitmarkerAlpha = 1
		hitmarkerTimer = 0.3
		hitmarker.TextColor3 = payload.lethal and COLORS.healthLow or COLORS.text
	end)

	State.Signals.Noise:Connect(function()
		noiseAlpha = 1
	end)

	State.Signals.Shake:Connect(function()
		-- Camera shake is handled by the camera controller.
	end)

	RunService.RenderStepped:Connect(update)

	-- Push server state into the HUD state model.
	State.Signals.StanceChanged:Connect(function()
		updateSlots()
	end)
end

function HUDController.showDowned(downed: boolean)
	State.downed = downed
	downedOverlay.Visible = downed
	downedOverlay.BackgroundTransparency = downed and 0.5 or 1
end

return HUDController
