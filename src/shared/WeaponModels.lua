--!strict
--[[
	WeaponModels
	Builds every weapon out of plain Parts at runtime. No imported meshes,
	no asset ids - so the pack drops into any place and works immediately.
	The same builder is used for the world models and for anything welded to
	a character's hand, which keeps them consistent.

	Conventions
	-----------
	* The weapon points along its local -Z, which is Roblox's forward.
	* "Handle" is the receiver and the model's PrimaryPart. Everything else
	  is welded to it, so the whole model moves as one rigid unit and can be
	  attached to a hand with a single weld.
	* "Muzzle" is an invisible part sitting exactly at the barrel (or
	  suppressor) tip. Effects anchor to it, so its position must match the
	  visible barrel end - a mismatch is what makes a muzzle flash appear
	  inside the gun.

	Part orientation notes
	----------------------
	A Part with Shape = Cylinder runs along its local X axis. To lay a
	barrel along -Z it is rotated 90 degrees about Y; to stand a bottle up
	it is rotated 90 degrees about Z. Getting this wrong is the classic
	"cylinder points the wrong way" bug, so every cylinder here goes
	through the helpers below rather than being rotated inline.
]]

local Weapons = require(script.Parent.Weapons)

local WeaponModels = {}

local DEFAULT_METAL = Enum.Material.Metal
local DEFAULT_POLYMER = Enum.Material.SmoothPlastic

local function materialFor(visual): Enum.Material
	return visual.woodFurniture and Enum.Material.Wood or DEFAULT_POLYMER
end

--- Creates a part parented to the model. Never collidable, never queryable:
--- a weapon must not block movement or soak up its own raycasts.
local function newPart(
	model: Model,
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Shape = shape or Enum.PartType.Block
	p.Color = color
	p.Material = material or DEFAULT_METAL
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.Massless = true
	p.Parent = model
	return p
end

--- Welds a part to the handle at a fixed offset from it. The offset is
--- relative to the handle, so the whole weapon is defined in one frame.
local function weldTo(handle: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = handle.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = part
end

--- A part welded to the handle in one call.
local function piece(
	model: Model,
	handle: BasePart,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part
	local p = newPart(model, name, size, color, material, shape)
	weldTo(handle, p, offset)
	return p
end

--- A cylinder lying along the weapon's forward (-Z) axis. Size is
--- (length, diameter, diameter).
local function barrelPiece(
	model: Model,
	handle: BasePart,
	name: string,
	length: number,
	diameter: number,
	offset: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local size = Vector3.new(length, diameter, diameter)
	local oriented = offset * CFrame.Angles(0, math.rad(90), 0)
	return piece(model, handle, name, size, oriented, color, material, Enum.PartType.Cylinder)
end

--- A cylinder standing along the weapon's up (+Y) axis. Size is
--- (height, diameter, diameter).
local function uprightPiece(
	model: Model,
	handle: BasePart,
	name: string,
	height: number,
	diameter: number,
	offset: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part
	local size = Vector3.new(height, diameter, diameter)
	local oriented = offset * CFrame.Angles(0, 0, math.rad(90))
	return piece(model, handle, name, size, oriented, color, material, shape or Enum.PartType.Cylinder)
end

--- The invisible anchor effects fire from. It must sit at the very tip of
--- whatever is at the front of the gun.
local function addMuzzle(model: Model, handle: BasePart, tipZ: number): Part
	local muzzle = newPart(model, "Muzzle", Vector3.new(0.14, 0.14, 0.14), Color3.fromRGB(255, 255, 255), DEFAULT_METAL)
	muzzle.Transparency = 1
	weldTo(handle, muzzle, CFrame.new(0, 0, tipZ))
	muzzle:SetAttribute("IsMuzzle", true)
	return muzzle
end

-- ---------------------------------------------------------------------
-- Firearms
-- ---------------------------------------------------------------------

--- The common furniture shared by rifles, SMGs and shotguns.
local function addStock(model, handle, visual, color, zBack: number)
	if not visual.stock then
		return
	end
	local stock = piece(
		model,
		handle,
		"Stock",
		Vector3.new(0.26, 0.34, 0.55),
		CFrame.new(0, -0.04, zBack),
		color,
		materialFor(visual)
	)
	-- A small comb on top of the stock reads as a cheek rest.
	piece(model, handle, "CheekRest", Vector3.new(0.2, 0.1, 0.4), CFrame.new(0, 0.16, zBack), color, materialFor(visual))
	return stock
end

local function addGrip(model, handle, visual, color, z: number)
	piece(
		model,
		handle,
		"Grip",
		Vector3.new(0.2, 0.46, 0.22),
		CFrame.new(0, -0.42, z) * CFrame.Angles(math.rad(12), 0, 0),
		color,
		materialFor(visual)
	)
	piece(model, handle, "Trigger", Vector3.new(0.07, 0.14, 0.05), CFrame.new(0, -0.28, z - 0.16), Color3.fromRGB(30, 30, 32), DEFAULT_METAL)
end

local function addMagazine(model, handle, visual, color, size: Vector3, z: number, tilt: number)
	return piece(
		model,
		handle,
		"Magazine",
		size,
		CFrame.new(0, -(size.Y * 0.5 + 0.16), z) * CFrame.Angles(math.rad(tilt), 0, 0),
		color,
		DEFAULT_METAL
	)
end

local function addSights(model, handle, frontZ: number, rearZ: number, top: number)
	piece(model, handle, "RearSight", Vector3.new(0.14, 0.09, 0.06), CFrame.new(0, top, rearZ), Color3.fromRGB(20, 20, 22), DEFAULT_METAL)
	piece(model, handle, "FrontSight", Vector3.new(0.05, 0.11, 0.05), CFrame.new(0, top, frontZ), Color3.fromRGB(20, 20, 22), DEFAULT_METAL)
end

local function addScope(model, handle, visual, top: number, z: number)
	if not visual.scope or visual.scope == "none" then
		return
	end
	local large = visual.scope == "large"
	local length = large and 1.15 or 0.6
	barrelPiece(model, handle, "Scope", length, 0.22, CFrame.new(0, top + 0.14, z), Color3.fromRGB(18, 18, 20), DEFAULT_METAL)
	if large then
		barrelPiece(
			model,
			handle,
			"Lens",
			0.06,
			0.17,
			CFrame.new(0, top + 0.14, z - length * 0.5),
			Color3.fromRGB(70, 140, 180),
			Enum.Material.Glass
		).Transparency = 0.35
	end
end

local function addBolt(model, handle, visual, data, z: number)
	if data.fireMode ~= "Bolt" and data.fireMode ~= "Auto" then
		return
	end
	piece(model, handle, "Bolt", Vector3.new(0.14, 0.14, 0.44), CFrame.new(0.17, 0.06, z), data.visual.accentColor, DEFAULT_METAL)
end

--- Builds a long gun. `profile` carries the few numbers that differ
--- between a rifle, an SMG and a shotgun.
local function buildLongGun(model: Model, handle: BasePart, data, profile)
	local visual = data.visual
	local L = visual.length
	local bodyColor = visual.bodyColor
	local accent = visual.accentColor
	local furniture = materialFor(visual)

	local receiverLength = L * profile.receiver
	local receiverZ = -L * 0.06
	handle.Size = Vector3.new(0.2, 0.28, receiverLength)
	handle.Color = bodyColor
	handle.Material = furniture
	handle.CFrame = CFrame.new()

	piece(model, handle, "Receiver", Vector3.new(0.24, 0.3, receiverLength), CFrame.new(0, 0, receiverZ), bodyColor, furniture)
	-- Handguard along the barrel.
	local guardLength = L * profile.guard
	local guardZ = receiverZ - receiverLength * 0.5 - guardLength * 0.5
	piece(model, handle, "Handguard", Vector3.new(0.22, 0.22, guardLength), CFrame.new(0, 0.02, guardZ), accent, furniture)

	-- Barrel: starts at the front of the handguard and runs to the tip.
	local barrelLength = L * profile.barrel
	local barrelStart = guardZ - guardLength * 0.5
	local barrelZ = barrelStart - barrelLength * 0.5
	barrelPiece(model, handle, "Barrel", barrelLength, profile.bore, CFrame.new(0, 0.02, barrelZ), bodyColor, DEFAULT_METAL)

	local tipZ = barrelStart - barrelLength
	if visual.suppressor then
		local supLength = L * 0.3
		barrelPiece(
			model,
			handle,
			"Suppressor",
			supLength,
			profile.bore * 2.6,
			CFrame.new(0, 0.02, tipZ - supLength * 0.5),
			Color3.fromRGB(24, 24, 26),
			DEFAULT_METAL
		)
		tipZ = tipZ - supLength
	end

	if profile.pump then
		piece(
			model,
			handle,
			"Pump",
			Vector3.new(0.26, 0.26, L * 0.2),
			CFrame.new(0, -0.13, guardZ - L * 0.02),
			accent,
			furniture
		)
		barrelPiece(model, handle, "TubeMagazine", L * 0.42, 0.1, CFrame.new(0, -0.13, barrelZ + L * 0.05), bodyColor, DEFAULT_METAL)
	end

	if profile.magazine then
		addMagazine(model, handle, visual, accent, profile.magazine, receiverZ - receiverLength * 0.25, profile.magTilt or 0)
	end

	addStock(model, handle, visual, accent, receiverZ + receiverLength * 0.5 + 0.3)
	addGrip(model, handle, visual, accent, receiverZ + receiverLength * 0.3)
	addSights(model, handle, tipZ + L * 0.06, receiverZ + receiverLength * 0.4, 0.24)
	addScope(model, handle, visual, 0.24, receiverZ - L * 0.05)
	addBolt(model, handle, visual, data, receiverZ + L * 0.06)

	return tipZ
end

--- A pistol: short slide, angled grip, no stock.
local function buildPistol(model: Model, handle: BasePart, data)
	local visual = data.visual
	local L = visual.length
	local bodyColor = visual.bodyColor
	local accent = visual.accentColor

	local slideLength = L * 0.62
	handle.Size = Vector3.new(0.16, 0.2, slideLength)
	handle.Color = bodyColor
	handle.Material = DEFAULT_METAL
	handle.CFrame = CFrame.new()

	piece(model, handle, "Slide", Vector3.new(0.18, 0.22, slideLength), CFrame.new(0, 0.02, -L * 0.08), bodyColor, DEFAULT_METAL)
	piece(model, handle, "Frame", Vector3.new(0.16, 0.14, slideLength * 0.85), CFrame.new(0, -0.13, -L * 0.06), accent, DEFAULT_POLYMER)

	local barrelLength = L * 0.34
	local barrelZ = -L * 0.08 - slideLength * 0.5 - barrelLength * 0.5
	barrelPiece(model, handle, "Barrel", barrelLength, 0.075, CFrame.new(0, 0.02, barrelZ), bodyColor, DEFAULT_METAL)

	local tipZ = barrelZ - barrelLength * 0.5
	if visual.suppressor then
		local supLength = L * 0.32
		barrelPiece(model, handle, "Suppressor", supLength, 0.19, CFrame.new(0, 0.02, tipZ - supLength * 0.5), Color3.fromRGB(24, 24, 26), DEFAULT_METAL)
		tipZ = tipZ - supLength
	end

	piece(
		model,
		handle,
		"Grip",
		Vector3.new(0.16, 0.44, 0.2),
		CFrame.new(0, -0.4, L * 0.12) * CFrame.Angles(math.rad(14), 0, 0),
		accent,
		DEFAULT_POLYMER
	)
	addMagazine(model, handle, visual, accent, Vector3.new(0.12, 0.4, 0.14), L * 0.12, 14)
	piece(model, handle, "Trigger", Vector3.new(0.06, 0.12, 0.05), CFrame.new(0, -0.26, L * 0.02), Color3.fromRGB(30, 30, 32), DEFAULT_METAL)
	addSights(model, handle, tipZ + 0.05, -L * 0.08 + slideLength * 0.42, 0.18)

	return tipZ
end

--- A revolver: a rotating cylinder in front of the frame.
local function buildRevolver(model: Model, handle: BasePart, data)
	local visual = data.visual
	local L = visual.length
	local bodyColor = visual.bodyColor
	local accent = visual.accentColor

	handle.Size = Vector3.new(0.14, 0.18, L * 0.5)
	handle.Color = bodyColor
	handle.CFrame = CFrame.new()

	piece(model, handle, "Frame", Vector3.new(0.16, 0.2, L * 0.42), CFrame.new(0, 0.02, -L * 0.02), bodyColor, DEFAULT_METAL)

	-- The cylinder is the revolver's signature: a fat drum in front of the
	-- frame, running along the barrel axis.
	local cylZ = -L * 0.24
	barrelPiece(model, handle, "Cylinder", L * 0.2, 0.34, CFrame.new(0, 0.02, cylZ), Color3.fromRGB(58, 58, 62), DEFAULT_METAL)

	local barrelLength = L * 0.4
	local barrelZ = cylZ - L * 0.1 - barrelLength * 0.5
	barrelPiece(model, handle, "Barrel", barrelLength, 0.09, CFrame.new(0, 0.02, barrelZ), bodyColor, DEFAULT_METAL)
	-- A vent rib on top of the barrel.
	piece(model, handle, "Rib", Vector3.new(0.06, 0.05, barrelLength), CFrame.new(0, 0.12, barrelZ), bodyColor, DEFAULT_METAL)

	piece(
		model,
		handle,
		"Grip",
		Vector3.new(0.16, 0.42, 0.22),
		CFrame.new(0, -0.36, L * 0.16) * CFrame.Angles(math.rad(18), 0, 0),
		accent,
		materialFor(visual)
	)
	piece(model, handle, "Trigger", Vector3.new(0.06, 0.12, 0.05), CFrame.new(0, -0.24, L * 0.06), Color3.fromRGB(30, 30, 32), DEFAULT_METAL)

	local tipZ = barrelZ - barrelLength * 0.5
	addSights(model, handle, tipZ + 0.06, -L * 0.12, 0.16)
	return tipZ
end

--- A compound bow: two limbs along the character's up axis, a riser, and a
--- string between the limb tips.
local function buildBow(model: Model, handle: BasePart, data)
	local visual = data.visual
	local L = visual.length
	local bodyColor = visual.bodyColor
	local accent = visual.accentColor

	handle.Size = Vector3.new(0.12, 0.6, 0.14)
	handle.Color = accent
	handle.Material = Enum.Material.Wood
	handle.CFrame = CFrame.new()

	-- Riser: the part the hand holds, standing vertically.
	uprightPiece(model, handle, "Riser", 0.7, 0.13, CFrame.new(0, 0, 0), accent, Enum.Material.Wood, Enum.PartType.Block)

	local limbLength = L * 0.62
	uprightPiece(model, handle, "Limb", limbLength, 0.1, CFrame.new(0, 0.34 + limbLength * 0.5, -0.06), bodyColor, Enum.Material.Wood, Enum.PartType.Block)
	uprightPiece(model, handle, "LimbLower", limbLength, 0.1, CFrame.new(0, -(0.34 + limbLength * 0.5), -0.06), bodyColor, Enum.Material.Wood, Enum.PartType.Block)

	-- The string runs between the limb tips, a little behind them.
	local stringHeight = limbLength * 2 + 0.7
	uprightPiece(model, handle, "String", stringHeight, 0.03, CFrame.new(0, 0, -0.02), Color3.fromRGB(220, 220, 220), Enum.Material.SmoothPlastic, Enum.PartType.Block)

	-- Arrow rest and sight pin.
	piece(model, handle, "ArrowRest", Vector3.new(0.1, 0.06, 0.2), CFrame.new(0, 0.06, -0.16), Color3.fromRGB(40, 40, 42), DEFAULT_METAL)
	piece(model, handle, "SightPin", Vector3.new(0.06, 0.06, 0.2), CFrame.new(0.12, 0.18, -0.18), Color3.fromRGB(40, 40, 42), DEFAULT_METAL)

	-- The arrow sits where the muzzle would be: bows fire from the rest.
	return -0.5
end

-- ---------------------------------------------------------------------
-- Melee
-- ---------------------------------------------------------------------

local function buildBat(model: Model, handle: BasePart, data)
	local visual = data.visual
	local L = visual.length

	handle.Size = Vector3.new(0.14, 0.14, L * 0.34)
	handle.Color = visual.accentColor
	handle.Material = Enum.Material.Wood
	handle.CFrame = CFrame.new()

	-- The barrel of the bat is thicker than the grip and tapers forward.
	barrelPiece(model, handle, "Blade", L * 0.62, 0.3, CFrame.new(0, 0, -(L * 0.17 + L * 0.31)), visual.bodyColor, Enum.Material.Wood)
	barrelPiece(model, handle, "Knob", 0.08, 0.2, CFrame.new(0, 0, L * 0.19), visual.accentColor, Enum.Material.Wood)
	return -(L * 0.17 + L * 0.62)
end

local function buildMachete(model: Model, handle: BasePart, data)
	local visual = data.visual
	local L = visual.length

	handle.Size = Vector3.new(0.1, 0.12, L * 0.3)
	handle.Color = visual.accentColor
	handle.Material = Enum.Material.Wood
	handle.CFrame = CFrame.new()

	-- The blade is a flat slab: wide in Y, thin in X.
	local bladeLength = L * 0.66
	piece(model, handle, "Blade", Vector3.new(0.05, 0.3, bladeLength), CFrame.new(0, 0.02, -(L * 0.15 + bladeLength * 0.5)), visual.bodyColor, DEFAULT_METAL)
	piece(model, handle, "Guard", Vector3.new(0.16, 0.09, 0.1), CFrame.new(0, 0, -L * 0.15), visual.accentColor, DEFAULT_METAL)
	return -(L * 0.15 + bladeLength)
end

-- ---------------------------------------------------------------------
-- Throwables
-- ---------------------------------------------------------------------

local function buildBottle(model: Model, handle: BasePart, data)
	local visual = data.visual
	local height = visual.length
	handle.Size = Vector3.new(height, 0.3, 0.3)
	handle.Shape = Enum.PartType.Cylinder
	handle.Color = visual.bodyColor
	handle.Material = Enum.Material.Glass
	handle.Transparency = 0.35
	-- The cylinder's axis must point up, which is a rotation about Z.
	handle.CFrame = CFrame.Angles(0, 0, math.rad(90))

	uprightPiece(model, handle, "Neck", height * 0.3, 0.14, CFrame.new(0, height * 0.5 + height * 0.15, 0), visual.bodyColor, Enum.Material.Glass)
	uprightPiece(model, handle, "Rag", 0.26, 0.13, CFrame.new(0, height * 0.5 + height * 0.3 + 0.13, 0), visual.accentColor, Enum.Material.Fabric)
	return -height * 0.5
end

local function buildCanister(model: Model, handle: BasePart, data)
	local visual = data.visual
	local height = visual.length
	handle.Size = Vector3.new(height, 0.34, 0.34)
	handle.Shape = Enum.PartType.Cylinder
	handle.Color = visual.bodyColor
	handle.CFrame = CFrame.Angles(0, 0, math.rad(90))

	uprightPiece(model, handle, "Cap", 0.1, 0.22, CFrame.new(0, height * 0.5 + 0.05, 0), visual.accentColor, DEFAULT_METAL, Enum.PartType.Block)
	piece(model, handle, "Band", Vector3.new(0.36, 0.08, 0.36), CFrame.new(0, 0, 0), visual.accentColor, DEFAULT_METAL)
	return -height * 0.5
end

local function buildBrick(model: Model, handle: BasePart, data)
	local visual = data.visual
	local size = Vector3.new(0.34, 0.22, visual.length)
	handle.Size = size
	handle.Color = visual.bodyColor
	handle.Material = Enum.Material.Brick
	handle.CFrame = CFrame.new()
	return -visual.length * 0.5
end

-- ---------------------------------------------------------------------
-- Assembly
-- ---------------------------------------------------------------------

local LONG_GUN_PROFILES = {
	Rifle = {
		receiver = 0.5,
		guard = 0.24,
		barrel = 0.34,
		bore = 0.09,
		magazine = Vector3.new(0.16, 0.4, 0.2),
		magTilt = 0,
	},
	SMG = {
		receiver = 0.44,
		guard = 0.14,
		barrel = 0.22,
		bore = 0.07,
		magazine = Vector3.new(0.15, 0.5, 0.18),
		magTilt = 0,
	},
	Shotgun = {
		receiver = 0.42,
		guard = 0.3,
		barrel = 0.44,
		bore = 0.11,
		pump = true,
		magazine = nil,
	},
}

--- Builds the model. Returns a Model whose PrimaryPart is "Handle".
function WeaponModels.build(data): Model
	local visual = data.visual
	local model = Instance.new("Model")
	model.Name = "Weapon_" .. data.id

	local handle = newPart(model, "Handle", Vector3.new(0.2, 0.28, visual.length * 0.5), visual.bodyColor, DEFAULT_METAL)
	model.PrimaryPart = handle

	local tipZ = -visual.length * 0.5

	if data.category == "Melee" then
		if data.model == "Bat" then
			tipZ = buildBat(model, handle, data)
		else
			tipZ = buildMachete(model, handle, data)
		end
	elseif data.category == "Throwable" then
		if data.model == "Bottle" then
			tipZ = buildBottle(model, handle, data)
		elseif data.model == "Canister" then
			tipZ = buildCanister(model, handle, data)
		else
			tipZ = buildBrick(model, handle, data)
		end
	else
		-- Firearm
		if data.model == "Pistol" then
			tipZ = buildPistol(model, handle, data)
		elseif data.model == "Revolver" then
			tipZ = buildRevolver(model, handle, data)
		elseif data.model == "Bow" then
			tipZ = buildBow(model, handle, data)
		else
			local profile = LONG_GUN_PROFILES[data.model] or LONG_GUN_PROFILES.Rifle
			tipZ = buildLongGun(model, handle, data, profile)
		end
	end

	model:SetAttribute("WeaponId", data.id)
	model:SetAttribute("Category", data.category)

	-- Every weapon needs a Muzzle for flash/tracer anchoring, sitting at the
	-- actual tip of the model.
	local muzzle = addMuzzle(model, handle, tipZ)
	muzzle:SetAttribute("IsMuzzle", true)

	-- Attachment points for a character's hands in third person.
	local gripAttachment = Instance.new("Attachment")
	gripAttachment.Name = "GripAttachment"
	gripAttachment.Position = Vector3.new(0, -0.42, 0.12)
	gripAttachment.Parent = handle

	local leftAttachment = Instance.new("Attachment")
	leftAttachment.Name = "LeftGripAttachment"
	leftAttachment.Position = Vector3.new(0, -0.1, tipZ * 0.45)
	leftAttachment.Parent = handle

	return model
end

--- Convenience: build a model for a weapon id.
function WeaponModels.buildById(id: string): Model?
	local data = Weapons.get(id)
	if not data then
		return nil
	end
	return WeaponModels.build(data)
end

return WeaponModels
