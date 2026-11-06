--!strict
--[[
	WeaponModels
	Builds every weapon out of plain Parts at runtime. No imported meshes,
	no asset ids - so the pack drops into any place and works immediately.
	The same builder is used for the client viewmodel and for any world
	models (dropped weapons, NPC gear), which keeps them consistent.

	Each weapon is assembled from named segments so the animation code can
	find the muzzle, the bolt/slide, the magazine, and the grip.
]]

local Weapons = require(script.Parent.Weapons)

local WeaponModels = {}

local function part(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.Metal
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.Massless = true
	return p
end

local function weldTo(model: Model, child: BasePart, parent: BasePart, offset: CFrame)
	child.CFrame = parent.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = parent
	weld.Part1 = child
	weld.Parent = child
end

--- Creates a barrel along the -Z axis of the weapon root.
local function addBarrel(root: Part, length: number, radius: number, color: Color3, suppressor: boolean)
	local barrel = part("Barrel", Vector3.new(radius * 2, radius * 2, length), CFrame.new(0, 0, -length / 2), color, Enum.Material.Metal)
	weldTo(root.Parent :: Model, barrel, root, CFrame.new(0, 0, -length / 2))
	barrel.CFrame = root.CFrame * CFrame.new(0, 0, -length / 2)

	if suppressor then
		local can = part(
			"Suppressor",
			Vector3.new(radius * 3.2, radius * 3.2, length * 0.42),
			root.CFrame * CFrame.new(0, 0, -(length + length * 0.21)),
			Color3.fromRGB(24, 24, 26),
			Enum.Material.Metal
		)
		can.Parent = root.Parent
		weldTo(root.Parent :: Model, can, root, CFrame.new(0, 0, -(length + length * 0.21)))
	end
end

local function addMuzzle(root: Part, data): Part
	local muzzle = Instance.new("Part")
	muzzle.Name = "Muzzle"
	muzzle.Size = Vector3.new(0.12, 0.12, 0.12)
	muzzle.Transparency = 1
	muzzle.CanCollide = false
	muzzle.CanQuery = false
	muzzle.Massless = true
	muzzle.Parent = root.Parent
	local visual = data.visual
	local z = -(visual.length * 0.5 + (visual.suppressor and visual.length * 0.42 or 0))
	weldTo(root.Parent :: Model, muzzle, root, CFrame.new(0, 0, z))
	return muzzle
end

local function addStock(root: Part, visual, color: Color3)
	if not visual.stock then
		return
	end
	local stock = part(
		"Stock",
		Vector3.new(0.28, 0.36, visual.length * 0.42),
		CFrame.new(),
		color,
		visual.woodFurniture and Enum.Material.Wood or Enum.Material.Polymer
	)
	stock.Parent = root.Parent
	weldTo(root.Parent :: Model, stock, root, CFrame.new(0, -0.06, visual.length * 0.34))
end

local function addScope(root: Part, visual)
	if not visual.scope or visual.scope == "none" then
		return
	end
	local large = visual.scope == "large"
	local scope = part(
		"Scope",
		Vector3.new(0.22, 0.22, large and 1.1 or 0.55),
		CFrame.new(),
		Color3.fromRGB(18, 18, 20),
		Enum.Material.Metal
	)
	scope.Parent = root.Parent
	weldTo(root.Parent :: Model, scope, root, CFrame.new(0, 0.32, -0.1))

	if large then
		local lens = part("Lens", Vector3.new(0.16, 0.16, 0.05), CFrame.new(), Color3.fromRGB(70, 140, 180), Enum.Material.Glass)
		lens.Transparency = 0.35
		lens.Parent = root.Parent
		weldTo(root.Parent :: Model, lens, scope, CFrame.new(0, 0, -0.55))
	end
end

local function addGrip(root: Part, visual, color: Color3)
	local grip = part(
		"Grip",
		Vector3.new(0.22, 0.5, 0.26),
		CFrame.new(),
		color,
		visual.woodFurniture and Enum.Material.Wood or Enum.Material.Polymer
	)
	grip.Parent = root.Parent
	weldTo(root.Parent :: Model, grip, root, CFrame.new(0, -0.42, 0.12))

	local trigger = part("Trigger", Vector3.new(0.08, 0.16, 0.05), CFrame.new(), Color3.fromRGB(30, 30, 30), Enum.Material.Metal)
	trigger.Parent = root.Parent
	weldTo(root.Parent :: Model, trigger, root, CFrame.new(0, -0.28, 0.05))
end

local function addMagazine(root: Part, data, color: Color3): Part
	local visual = data.visual
	local mag = part(
		"Magazine",
		Vector3.new(0.2, 0.55, 0.22),
		CFrame.new(),
		color,
		Enum.Material.Metal
	)
	mag.Parent = root.Parent
	weldTo(root.Parent :: Model, mag, root, CFrame.new(0, -0.5, 0.02))
	return mag
end

local function addSights(root: Part, visual)
	local rear = part("RearSight", Vector3.new(0.14, 0.08, 0.06), CFrame.new(), Color3.fromRGB(20, 20, 20), Enum.Material.Metal)
	rear.Parent = root.Parent
	weldTo(root.Parent :: Model, rear, root, CFrame.new(0, 0.2, 0.5))

	local front = part("FrontSight", Vector3.new(0.05, 0.1, 0.05), CFrame.new(), Color3.fromRGB(20, 20, 20), Enum.Material.Metal)
	front.Parent = root.Parent
	weldTo(root.Parent :: Model, front, root, CFrame.new(0, 0.2, -(visual.length * 0.42)))
end

local function addBolt(root: Part, data): Part
	local bolt = part("Bolt", Vector3.new(0.16, 0.16, 0.5), CFrame.new(), data.visual.accentColor, Enum.Material.Metal)
	bolt.Parent = root.Parent
	weldTo(root.Parent :: Model, bolt, root, CFrame.new(0.18, 0.08, 0.1))
	return bolt
end

--- Builds the model. Returns a Model with a "Handle" part (the root).
function WeaponModels.build(data): Model
	local visual = data.visual
	local model = Instance.new("Model")
	model.Name = "Weapon_" .. data.id

	local handle = part(
		"Handle",
		Vector3.new(0.24, 0.3, visual.length),
		CFrame.new(),
		visual.bodyColor,
		visual.woodFurniture and Enum.Material.Wood or Enum.Material.Metal
	)
	handle.Parent = model

	model.PrimaryPart = handle

	if data.category == "Melee" then
		if data.model == "Bat" then
			local bat = part("Blade", Vector3.new(0.24, 0.24, visual.length), CFrame.new(), visual.bodyColor, Enum.Material.Wood)
			bat.Parent = model
			weldTo(model, bat, handle, CFrame.new(0, 0, -visual.length * 0.5))
			handle.Size = Vector3.new(0.22, 0.22, visual.length * 0.35)
		else
			local blade = part("Blade", Vector3.new(0.06, 0.34, visual.length * 0.62), CFrame.new(), visual.bodyColor, Enum.Material.Metal)
			blade.Parent = model
			weldTo(model, blade, handle, CFrame.new(0, 0.02, -visual.length * 0.45))
			local guard = part("Guard", Vector3.new(0.26, 0.08, 0.1), CFrame.new(), visual.accentColor, Enum.Material.Metal)
			guard.Parent = model
			weldTo(model, guard, handle, CFrame.new(0, 0, -visual.length * 0.18))
			handle.Size = Vector3.new(0.18, 0.18, visual.length * 0.5)
		end
	elseif data.category == "Throwable" then
		if data.model == "Bottle" then
			handle.Shape = Enum.PartType.Cylinder
			handle.Size = Vector3.new(visual.length, 0.32, 0.32)
			handle.Material = Enum.Material.Glass
			handle.Transparency = 0.35
			handle.Orientation = Vector3.new(0, 0, 90)
			local rag = part("Rag", Vector3.new(0.1, 0.1, 0.3), CFrame.new(), visual.accentColor, Enum.Material.Fabric)
			rag.Parent = model
			weldTo(model, rag, handle, CFrame.new(0, visual.length * 0.5, 0))
		elseif data.model == "Canister" then
			handle.Shape = Enum.PartType.Cylinder
			handle.Size = Vector3.new(visual.length, 0.34, 0.34)
			handle.Orientation = Vector3.new(0, 0, 90)
		else
			handle.Size = Vector3.new(0.5, 0.4, visual.length)
		end
	else
		-- Firearm
		if data.model == "Revolver" then
			local cylinder = part("Cylinder", Vector3.new(0.34, 0.34, 0.34), CFrame.new(), visual.bodyColor, Enum.Material.Metal)
			cylinder.Parent = model
			weldTo(model, cylinder, handle, CFrame.new(0, 0.02, 0.05))
		elseif data.model == "Shotgun" then
			addBarrel(handle, visual.length * 0.7, 0.09, visual.bodyColor, false)
			local pump = part("Pump", Vector3.new(0.3, 0.3, 0.5), CFrame.new(), visual.accentColor, Enum.Material.Wood)
			pump.Parent = model
			weldTo(model, pump, handle, CFrame.new(0, -0.14, -visual.length * 0.3))
		elseif data.model == "Bow" then
			local limb = part("Limb", Vector3.new(0.08, visual.length * 1.4, 0.14), CFrame.new(), visual.bodyColor, Enum.Material.Wood)
			limb.Parent = model
			weldTo(model, limb, handle, CFrame.new(0, 0, -0.2))
			local string = part("String", Vector3.new(0.02, visual.length * 1.35, 0.02), CFrame.new(), Color3.fromRGB(220, 220, 220), Enum.Material.SmoothPlastic)
			string.Parent = model
			weldTo(model, string, handle, CFrame.new(0, 0, 0.1))
		else
			local barrelLength = data.model == "SMG" and visual.length * 0.5 or visual.length * 0.62
			addBarrel(handle, barrelLength, 0.06, visual.bodyColor, visual.suppressor)
			addMagazine(handle, data, visual.accentColor)
			addSights(handle, visual)
			if data.fireMode == "Bolt" or data.fireMode == "Auto" then
				addBolt(handle, data)
			end
		end

		addStock(handle, visual, visual.accentColor)
		addScope(handle, visual)
		addGrip(handle, visual, visual.accentColor)
	end

	model:SetAttribute("WeaponId", data.id)
	model:SetAttribute("Category", data.category)

	-- Every weapon needs a Muzzle attachment for flash/tracer anchoring.
	local muzzle = addMuzzle(handle, data)
	muzzle:SetAttribute("IsMuzzle", true)

	-- The grip attachment is where the right hand sits.
	local gripAttachment = Instance.new("Attachment")
	gripAttachment.Name = "GripAttachment"
	gripAttachment.Position = Vector3.new(0, -0.42, 0.12)
	gripAttachment.Parent = handle

	local leftAttachment = Instance.new("Attachment")
	leftAttachment.Name = "LeftGripAttachment"
	leftAttachment.Position = Vector3.new(0, -0.2, -(data.visual.length * 0.3))
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
