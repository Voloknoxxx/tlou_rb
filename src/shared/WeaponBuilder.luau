--!strict
--[[
	WeaponBuilder
	----------------------------------------------------------------------------
	Builds weapon models procedurally from the blueprints in WeaponData. The same
	builder is used for
		* world pickups (server)
		* the third-person held model (server, welded to the hand)
		* the first-person view model (client, parented to the camera)

	Blueprint part names starting with "Cylinder" use Enum.PartType.Cylinder,
	whose local axis is +X, so the blueprint offsets already rotate them into
	place.

	Every generated model is tagged with CollectionService "Weapon" and carries
	attributes WeaponId and AmmoInMag so any system can identify it.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponData = require(ReplicatedStorage.Shared.WeaponData)

local WeaponBuilder = {}

WeaponBuilder.TAG = "Weapon"

local function makePart(name: string, spec: any, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = spec.size
	part.CFrame = spec.offset
	part.Color = color
	part.Material = Enum.Material.Metal
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = true
	part.Shape = spec.shape or Enum.PartType.Block
	part.Anchored = false
	return part
end

--[[
	Builds a weapon model.
		opts.Anchored     freeze it (world pickups)
		opts.CanCollide   let it rest on the ground
		opts.AmmoInMag    starting round count
		opts.CFrame       where to place it (applied after welding)

	The model is always assembled at the origin first, welded, and only then
	pivoted into place. Welding before moving is what keeps every part's offset
	relative to the receiver intact - moving the primary part first would bake a
	huge relative offset into the welds and tear the model apart.
]]
function WeaponBuilder.build(weaponId: string, opts: { Anchored: boolean?, CanCollide: boolean?, AmmoInMag: number?, CFrame: CFrame? }?): Model?
	local def = WeaponData.Weapons[weaponId]
	if not def then
		warn(("[WeaponBuilder] unknown weapon '%s'"):format(weaponId))
		return nil
	end
	local o = opts or {}

	local model = Instance.new("Model")
	model.Name = weaponId

	local bodyColor = def.Color
	local accentColor = def.Accent
	local accentNames = {
		Barrel = true, Grip = true, Magazine = true, Scope = true, Trigger = true,
		TriggerGuard = true, Pump = true, Stock = true, Handguard = true, Cap = true,
		Hammer = true, Cylinder = true, BarrelRib = true, StockTube = true,
		ScopeMount = true, ChargingHandle = true, Muzzle = true, MagTube = true,
		ShellHolder = true, Bead = true, Neck = true,
	}
	for name, spec in def.Parts do
		local color = if accentNames[name] then accentColor else bodyColor
		local part = makePart(name, spec, color)
		part.Anchored = o.Anchored == true
		part.CanCollide = o.CanCollide == true
		part.Parent = model
	end

	local primaryName = WeaponBuilder.primaryName(weaponId)
	local primary = (primaryName and model:FindFirstChild(primaryName)
		or model:FindFirstChildOfClass("Part")) :: BasePart?
	if not primary then
		model:Destroy()
		return nil
	end
	model.PrimaryPart = primary

	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= primary then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = primary
			weld.Part1 = part
			weld.Parent = primary
		end
	end

	if o.CFrame then
		model:PivotTo(o.CFrame)
	end

	model:SetAttribute("WeaponId", weaponId)
	model:SetAttribute("AmmoInMag", o.AmmoInMag or def.MagSize)
	CollectionService:AddTag(model, WeaponBuilder.TAG)
	return model
end

--[[
	The part that acts as the model's pivot: the receiver if there is one, else
	the frame, else whatever comes first in the blueprint.
]]
function WeaponBuilder.primaryName(weaponId: string): string?
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return nil
	end
	if def.Parts.Frame then
		return "Frame"
	end
	if def.Parts.Receiver then
		return "Receiver"
	end
	for name in def.Parts do
		return name
	end
	return nil
end

--[[
	Maps a CFrame authored in blueprint space (the weapon's own origin) into the
	pivot part's space. Every blueprint offset is written around that origin, so
	this is the transform that makes them line up with the pivot.
]]
function WeaponBuilder.originToPrimary(weaponId: string): CFrame
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return CFrame.new()
	end
	local name = WeaponBuilder.primaryName(weaponId)
	local spec = name and def.Parts[name]
	if not spec then
		return CFrame.new()
	end
	return spec.offset:Inverse()
end

--[[
	The pivot CFrame that puts the weapon's grip exactly on the hand: pass it to
	Model:PivotTo together with the hand's CFrame.

	Model:PivotTo(target) maps a blueprint point X to `target * primaryOffset^-1 * X`,
	so requiring the grip (GripOffset) to land on the hand means
	target = hand * GripOffset^-1 * primaryOffset.
]]
function WeaponBuilder.holdOffset(weaponId: string): CFrame
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return CFrame.new()
	end
	local name = WeaponBuilder.primaryName(weaponId)
	local spec = name and def.Parts[name]
	local primaryOffset = if spec then spec.offset else CFrame.new()
	return def.GripOffset:Inverse() * primaryOffset
end

--[[
	Returns the muzzle CFrame in world space for a built model. MuzzleOffset is
	authored in blueprint space, so it is mapped into the pivot part's space.
]]
function WeaponBuilder.getMuzzle(model: Model): CFrame?
	local weaponId = model:GetAttribute("WeaponId")
	local def = WeaponData.Weapons[weaponId]
	local primary = model.PrimaryPart
	if not def or not primary then
		return nil
	end
	return primary.CFrame * WeaponBuilder.originToPrimary(weaponId) * def.MuzzleOffset
end

--[[
	Returns the world CFrame of the weapon's grip (where the hand attaches).
]]
function WeaponBuilder.getGrip(model: Model): CFrame?
	local primary = model.PrimaryPart
	return primary and primary.CFrame or nil
end

return WeaponBuilder
