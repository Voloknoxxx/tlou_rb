--!strict
--[[
	InteractionService
	----------------------------------------------------------------------------
	Server authority for everything the player can walk up to and use:

		* world pickups   - weapons and ammo lying on the ground / on shelves
		* drawers         - slide out, reveal loot, make noise
		* cabinets        - hinged doors swing open, reveal loot
		* shelves         - rummage animation, reveal loot

	Flow for every interaction:
		1. client raycasts, finds the nearest tagged Interactable/Pickup and
		   sends RequestInteract / RequestPickup
		2. server re-validates distance and cooldown (never trust the client)
		3. server plays the matching animation on the character
		4. server animates the prop and grants any loot
		5. server publishes a noise event so zombies react
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)
local WeaponData = require(ReplicatedStorage.Shared.WeaponData)
local WeaponBuilder = require(ReplicatedStorage.Shared.WeaponBuilder)

local InventoryService = require(script.Parent.InventoryService)
local NoiseBus = require(script.Parent.NoiseBus)

local InteractionService = {}

InteractionService.PICKUP_TAG = "Pickup"
InteractionService.INTERACTABLE_TAG = "Interactable"

local lastInteract: { [Player]: number } = {}

-- ------------------------------------------------------------------ pickups --

--[[
	Spawns an ammo crate pickup.
]]
local function spawnAmmoPickup(position: Vector3, ammoType: string, amount: number): Model
	local model = Instance.new("Model")
	model.Name = "AmmoPickup"

	local box = Instance.new("Part")
	box.Name = "Box"
	box.Size = Vector3.new(1.6, 1.0, 1.1)
	box.CFrame = CFrame.new(position)
	box.Color = Color3.fromRGB(74, 78, 58)
	box.Material = Enum.Material.Metal
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.Parent = model
	model.PrimaryPart = box

	local band = Instance.new("Part")
	band.Name = "Band"
	band.Size = Vector3.new(1.7, 0.22, 1.2)
	band.CFrame = box.CFrame * CFrame.new(0, 0.1, 0)
	band.Color = Color3.fromRGB(140, 120, 60)
	band.Material = Enum.Material.Metal
	band.Anchored = true
	band.CanCollide = false
	band.CanQuery = false
	band.Parent = box
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = box
	weld.Part1 = band
	weld.Parent = box

	model:SetAttribute("Kind", "Ammo")
	model:SetAttribute("AmmoType", ammoType)
	model:SetAttribute("Amount", amount)
	model:SetAttribute("Label", ("Патроны %s x%d"):format(ammoType, amount))
	CollectionService:AddTag(model, InteractionService.PICKUP_TAG)
	return model
end

--[[
	Spawns a weapon pickup in the world.
]]
local function spawnWeaponPickup(position: Vector3, weaponId: string, yaw: number?): Model?
	local model = WeaponBuilder.build(weaponId, {
		Anchored = true,
		CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
			* CFrame.Angles(0, yaw or 0, math.rad(8))
			* WeaponBuilder.holdOffset(weaponId),
	})
	if not model then
		return nil
	end
	local def = WeaponData.Weapons[weaponId]
	model:SetAttribute("Kind", "Weapon")
	model:SetAttribute("Label", def.DisplayName)
	CollectionService:AddTag(model, InteractionService.PICKUP_TAG)
	model.Parent = workspace
	return model
end

--[[
	Fills every tagged LootSpawn point with a random item. Called once after the
	world is built.
]]
function InteractionService.populateLoot()
	local pickups = Instance.new("Folder")
	pickups.Name = "Pickups"
	pickups.Parent = workspace

	for _, point in CollectionService:GetTagged("LootSpawn") do
		if not point:IsA("BasePart") or point:GetAttribute("Used") then
			continue
		end
		point:SetAttribute("Used", true)
		local pos = point.Position
		if math.random() < 0.62 then
			local entry = WeaponData.pickWeighted(WeaponData.LootTable)
			local model = spawnWeaponPickup(pos, entry.id, math.random() * math.pi * 2)
			if model then
				model.Parent = pickups
			end
		else
			local entry = WeaponData.pickWeighted(WeaponData.AmmoTable)
			local model = spawnAmmoPickup(pos, entry.AmmoType, entry.Amount)
			model.Parent = pickups
		end
	end
end

--[[
	Used by containers when they are opened.
]]
function InteractionService.dropLootAt(position: Vector3, parent: Instance?)
	local roll = math.random()
	local model: Instance?
	if roll < 0.5 then
		local entry = WeaponData.pickWeighted(WeaponData.LootTable)
		local m = spawnWeaponPickup(position, entry.id, math.random() * math.pi * 2)
		if m then
			model = m
		end
	else
		local entry = WeaponData.pickWeighted(WeaponData.AmmoTable)
		model = spawnAmmoPickup(position, entry.AmmoType, entry.Amount)
	end
	if model then
		model.Parent = parent or workspace:FindFirstChild("Pickups") or workspace
	end
	return model
end

-- ------------------------------------------------------------------ animation --

local function playAnim(player: Player, name: string, duration: number, args: { any }?)
	Net.fireClient(player, "PlayAnim", name, duration, args or {})
end

-- ------------------------------------------------------------------- drawers --

local function openDrawer(player: Player, model: Model)
	if model:GetAttribute("Open") then
		return
	end
	model:SetAttribute("Open", true)

	local slide = model:FindFirstChild("Slide") :: BasePart?
	local closed = model:GetAttribute("ClosedCFrame") :: CFrame?
	local direction = model:GetAttribute("Direction") :: Vector3?
	local travel = (model:GetAttribute("Travel") :: number?) or 3
	local low = model:GetAttribute("Low") == true
	if not slide or not closed or not direction then
		return
	end

	local target = closed + direction * travel
	local tween = TweenService:Create(slide, TweenInfo.new(Config.Items.DrawerOpenTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { CFrame = target })
	tween:Play()

	playAnim(player, "DrawerOpen", Config.Items.DrawerOpenTime, { low })

	-- Contents: sometimes something, sometimes nothing (tension!).
	if math.random() < 0.55 then
		local count = if math.random() < 0.25 then 2 else 1
		for i = 1, count do
			task.delay(0.25 + i * 0.08, function()
				InteractionService.dropLootAt(
					target.Position + Vector3.new((i - 1) * 2 - 1, 1.2, 0),
					nil
				)
			end)
		end
	end

	task.delay(Config.Items.DrawerOpenTime, function()
		local root = Util.getRoot(player.Character)
		if root then
			NoiseBus.emit(root.Position, 22, "Door", model, player)
		end
	end)
end

-- ------------------------------------------------------------------ cabinets --

local function openCabinet(player: Player, model: Model)
	if model:GetAttribute("Open") then
		return
	end
	model:SetAttribute("Open", true)

	local doorCount = (model:GetAttribute("Doors") :: number?) or 1
	local openTime = Config.Items.CabinetOpenTime
	for i = 1, doorCount do
		local door = model:FindFirstChild("Door" .. i) :: BasePart?
		if not door then
			continue
		end
		local hinge = door:GetAttribute("Hinge") :: CFrame?
		local offset = door:GetAttribute("HingeOffset") :: CFrame?
		local side = (door:GetAttribute("Side") :: number?) or 1
		if not hinge or not offset then
			continue
		end
		-- Doors swing outward, away from the cabinet body. The leaf's free edge
		-- sits at -side along its local X, so the swing sign follows `side` to
		-- carry that edge toward the front (+Z).
		local angle = math.rad(Config.Items.CabinetOpenAngle) * side
		local target = hinge * CFrame.Angles(0, angle, 0) * offset
		local tween = TweenService:Create(door, TweenInfo.new(openTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { CFrame = target })
		tween:Play()
	end

	playAnim(player, "CabinetOpen", openTime, {})

	if math.random() < 0.6 then
		local base = model:FindFirstChild("Base") :: BasePart?
		if base then
			task.delay(0.3, function()
				InteractionService.dropLootAt(base.Position + base.CFrame.LookVector * 2 + Vector3.new(0, 3, 0), nil)
			end)
		end
	end

	task.delay(openTime, function()
		local root = Util.getRoot(player.Character)
		if root then
			NoiseBus.emit(root.Position, 20, "Door", model, player)
		end
	end)
end

-- ------------------------------------------------------------------- shelves --

local function rummageShelf(player: Player, model: Model)
	local now = os.clock()
	-- Per-model cooldown so a shelf cannot be farmed by spamming E.
	local last = model:GetAttribute("LastRummage") or 0
	if now - last < 4 then
		return
	end
	model:SetAttribute("LastRummage", now)

	playAnim(player, "PickupShelf", Config.Items.PickupTime, {})

	if math.random() < 0.65 then
		local base = model:FindFirstChild("Base") :: BasePart?
		if base then
			task.delay(0.4, function()
				local attach = model:FindFirstChild("Loot2", true) :: Attachment?
				local pos = if attach then attach.WorldPosition else base.Position + Vector3.new(0, 2, 0)
				InteractionService.dropLootAt(pos, nil)
			end)
		end
	end

	task.delay(0.5, function()
		local root = Util.getRoot(player.Character)
		if root then
			NoiseBus.emit(root.Position, 15, "Impact", model, player)
		end
	end)
end

-- --------------------------------------------------------------- pickups --

local function collectPickup(player: Player, model: Model)
	local kind = model:GetAttribute("Kind")
	if kind == "Ammo" then
		local ammoType = model:GetAttribute("AmmoType") :: string
		local amount = (model:GetAttribute("Amount") :: number?) or 10
		InventoryService.addAmmo(player, ammoType, amount)
		playAnim(player, "PickupFloor", Config.Items.PickupTime, {})
		model:Destroy()
		return
	elseif kind == "Weapon" then
		local weaponId = model:GetAttribute("WeaponId") :: string
		if InventoryService.addWeapon(player, weaponId) then
			playAnim(player, "PickupFloor", Config.Items.PickupTime, {})
			model:Destroy()
		else
			Net.fireClient(player, "DamageFeedback", "Инвентарь полон")
		end
		return
	end
end

-- ------------------------------------------------------------------- events --

function InteractionService.start()
	Net.onServerEvent("RequestInteract", function(player: Player, target: any)
		if typeof(target) ~= "Instance" or not target:IsDescendantOf(workspace) then
			return
		end
		local root = Util.getRoot(player.Character)
		if not root then
			return
		end
		local now = os.clock()
		if now - (lastInteract[player] or 0) < 0.25 then
			return
		end
		lastInteract[player] = now

		-- Resolve the interactable root (models carry the tag).
		local interactable = target
		if interactable:IsA("BasePart") and interactable.Parent and interactable.Parent:HasTag(InteractionService.INTERACTABLE_TAG) then
			interactable = interactable.Parent
		end
		if not interactable:HasTag(InteractionService.INTERACTABLE_TAG) then
			return
		end

		local origin = if interactable:IsA("Model") then interactable:GetPivot().Position else (interactable :: BasePart).Position
		if (origin - root.Position).Magnitude > Config.Items.CabinetRange + 4 then
			return -- too far, reject
		end

		local kind = interactable:GetAttribute("Type")
		if kind == "Drawer" then
			openDrawer(player, interactable)
		elseif kind == "Cabinet" then
			openCabinet(player, interactable)
		elseif kind == "Shelf" then
			rummageShelf(player, interactable)
		end
	end)

	Net.onServerEvent("RequestPickup", function(player: Player, target: any)
		if typeof(target) ~= "Instance" then
			return
		end
		local root = Util.getRoot(player.Character)
		if not root then
			return
		end
		local model = target
		if model:IsA("BasePart") then
			model = model.Parent
		end
		if not model or not model:HasTag(InteractionService.PICKUP_TAG) then
			return
		end
		local pivot = model:GetPivot().Position
		if (pivot - root.Position).Magnitude > Config.Items.PickupRange + 3 then
			return
		end
		collectPickup(player, model)
	end)
end

return InteractionService
