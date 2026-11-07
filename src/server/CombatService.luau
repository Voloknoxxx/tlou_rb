--!strict
--[[
	CombatService
	----------------------------------------------------------------------------
	Server authority for shooting, reloading, dropping and throwing.

	Anti-cheat posture
		* The client sends the shot origin + direction, but the server
		  re-raycasts and re-applies damage itself.
		* Rate of fire is enforced against the weapon definition, plus a global
		  MaxShotsPerSecond ceiling.
		* Reload is a server timer; the client only plays the animation.
		* Only the shooter's own character (and their held weapon) is ignored by
		  the raycast, so you cannot shoot through yourself but you can be shot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)
local WeaponData = require(ReplicatedStorage.Shared.WeaponData)
local WeaponBuilder = require(ReplicatedStorage.Shared.WeaponBuilder)

local InventoryService = require(script.Parent.InventoryService)
local NoiseBus = require(script.Parent.NoiseBus)

local CombatService = {}

local lastShot: { [Player]: number } = {}
local reloading: { [Player]: boolean } = {}
local shotWindow: { [Player]: { number } } = {}

local function weaponDef(player: Player)
	local inv = InventoryService.get(player)
	if not inv or inv.equipped == 0 then
		return nil, nil
	end
	local slot = inv.slots[inv.equipped]
	if not slot then
		return nil, nil
	end
	return WeaponData.Weapons[slot.id], slot
end

local function pushWeaponState(player: Player)
	local inv = InventoryService.get(player)
	local def, slot = weaponDef(player)
	if not inv or not def or not slot then
		return
	end
	Net.fireClient(player, "WeaponState", {
		Ammo = slot.ammo,
		Reserve = inv.reserve[def.AmmoType] or 0,
		Reloading = reloading[player] == true,
		WeaponId = slot.id,
	})
end

--[[
	Global exploit ceiling: rejects more than MaxShotsPerSecond shots in any
	one second window.
]]
local function rateAllowed(player: Player): boolean
	local now = os.clock()
	local window = shotWindow[player]
	if not window then
		window = {}
		shotWindow[player] = window
	end
	local kept = {}
	for _, t in window do
		if now - t < 1 then
			table.insert(kept, t)
		end
	end
	shotWindow[player] = kept
	if #kept >= Config.Combat.MaxShotsPerSecond then
		return false
	end
	table.insert(kept, now)
	return true
end

-- --------------------------------------------------------------- reloading --

local function finishReload(player: Player)
	reloading[player] = false
	local inv = InventoryService.get(player)
	local def, slot = weaponDef(player)
	if not inv or not def or not slot then
		return
	end

	if def.ReloadKind == "Shells" then
		-- Shell-by-shell: fill as many as the reserve allows.
		local reserve = inv.reserve[def.AmmoType] or 0
		local needed = def.MagSize - slot.ammo
		local used = math.min(needed, reserve)
		slot.ammo += used
		inv.reserve[def.AmmoType] = reserve - used
	else
		local reserve = inv.reserve[def.AmmoType] or 0
		local needed = def.MagSize - slot.ammo
		local used = math.min(needed, reserve)
		slot.ammo += used
		inv.reserve[def.AmmoType] = reserve - used
	end

	InventoryService.push(player)
	pushWeaponState(player)
end

-- ------------------------------------------------------------------ firing --

local function applyDamage(player: Player, humanoid: Humanoid, part: BasePart, damage: number, distance: number)
	local C = Config.Combat
	local mult = 1
	if distance > C.FalloffStart then
		local t = Util.clamp((distance - C.FalloffStart) / (C.FalloffEnd - C.FalloffStart), 0, 1)
		mult = Util.lerp(1, C.FalloffMinMultiplier, t)
	end
	local wasHead = part.Name == "Head"
	if wasHead then
		mult *= C.HeadshotMultiplier
	end
	local final = damage * mult
	local killed = false
	humanoid:TakeDamage(final)
	if humanoid.Health <= 0 then
		killed = true
	end
	Net.fireClient(player, "HitConfirm", part.Position, wasHead, killed)
end

local function handleShot(player: Player, origin: Vector3, direction: Vector3)
	local inv = InventoryService.get(player)
	local def, slot = weaponDef(player)
	if not inv or not def or not slot or def.Category == "Throwable" then
		return
	end
	if reloading[player] then
		return
	end

	local now = os.clock()
	if now - (lastShot[player] or 0) < def.FireRate * 0.92 then
		return
	end
	if not rateAllowed(player) then
		return
	end
	lastShot[player] = now

	if slot.ammo <= 0 then
		Net.fireClient(player, "WeaponState", {
			Ammo = 0,
			Reserve = inv.reserve[def.AmmoType] or 0,
			Reloading = false,
			WeaponId = slot.id,
			DryFire = true,
		})
		return
	end
	slot.ammo -= 1

	local character = player.Character
	local root = Util.getRoot(character)
	local ignore: { Instance } = {}
	if character then
		table.insert(ignore, character)
	end
	if inv.held then
		table.insert(ignore, inv.held)
	end

	-- Spread: derived from the weapon cone plus accumulated per-shot bloom.
	local spread = math.rad(def.Spread)
	local bullets = math.max(1, def.BulletsPerShot)
	local anyHit = false
	local params = Util.filterFor(ignore)

	for _ = 1, bullets do
		local jitter = Vector3.new(
			(math.random() - 0.5) * 2 * spread,
			(math.random() - 0.5) * 2 * spread,
			(math.random() - 0.5) * 2 * spread
		)
		local dir = (direction + jitter).Unit
		local result = workspace:Raycast(origin, dir * Config.Combat.MaxRange, params)
		if result then
			anyHit = true
			local hit = result.Instance
			local model = hit:FindFirstAncestorOfClass("Model")
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and model ~= character then
				applyDamage(player, humanoid, hit, def.Damage, result.Distance)
			else
				-- World hit: small impact puff / noise.
				Net.fireClient(player, "HitConfirm", result.Position, false, false)
			end
		end
	end
	local _ = anyHit

	-- Muzzle flash + tracer for everyone nearby.
	Net.fireAll("FireEffect", root and root.Position or origin, direction, slot.id, player)
	Net.fireClient(player, "PlayAnim", "Fire", 0.22, { def.RecoilKick })
	pushWeaponState(player)

	-- Gunshots are the loudest thing in the game.
	NoiseBus.emit(root and root.Position or origin, 200, "Gunshot", root, player)
end

-- --------------------------------------------------------------- throwable --

local function handleThrow(player: Player, origin: Vector3, direction: Vector3)
	local inv = InventoryService.get(player)
	local def, slot = weaponDef(player)
	if not inv or not def or not slot or def.Category ~= "Throwable" then
		return
	end
	if slot.ammo <= 0 then
		return
	end
	slot.ammo -= 1
	if slot.ammo <= 0 then
		inv.slots[inv.equipped] = nil
		InventoryService.unequip(player)
	else
		InventoryService.push(player)
	end

	local projectile = Instance.new("Part")
	projectile.Name = "Bottle"
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(1.1, 1.1, 1.1)
	projectile.Color = Color3.fromRGB(140, 190, 165)
	projectile.Material = Enum.Material.Glass
	projectile.Transparency = 0.15
	projectile.CanCollide = true
	projectile.CanQuery = false
	projectile.CFrame = CFrame.new(origin)
	projectile.AssemblyLinearVelocity = direction.Unit * Config.Items.ThrowVelocity
	projectile.Parent = workspace

	Net.fireClient(player, "PlayAnim", "Throw", 0.7, {})

	local broken = false
	local function shatter(position: Vector3)
		if broken then
			return
		end
		broken = true
		NoiseBus.emit(position, 95, "Glass", projectile, player)
		-- Splash of damage to anything very close.
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character :: any }
		for _, part in workspace:GetPartBoundsInRadius(position, 12, params) do
			local model = part:FindFirstAncestorOfClass("Model")
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid:TakeDamage(def.Damage)
			end
		end
		projectile:Destroy()
	end

	local touched = projectile.Touched:Connect(function(hit)
		if hit:IsDescendantOf(player.Character) then
			return
		end
		shatter(projectile.Position)
	end)
	Debris:AddItem(projectile, 6)
	task.delay(6, function()
		touched:Disconnect()
	end)
end

-- ------------------------------------------------------------------- events --

function CombatService.start()
	Net.onServerEvent("RequestFire", function(player: Player, origin: any, direction: any, _seq: any)
		local o = Net.validVector(origin)
		local d = Net.validVector(direction)
		if not o or not d or d.Magnitude < 0.01 then
			return
		end
		-- Never trust the reported origin: it must be near the shooter.
		local root = Util.getRoot(player.Character)
		if not root or (o - root.Position).Magnitude > 12 then
			o = root and (root.Position + Vector3.new(0, 2, 0)) or o
		end
		handleShot(player, o, d.Unit)
	end)

	Net.onServerEvent("RequestReload", function(player: Player)
		if reloading[player] then
			return
		end
		local inv = InventoryService.get(player)
		local def, slot = weaponDef(player)
		if not inv or not def or not slot then
			return
		end
		if def.ReloadKind == "None" then
			return
		end
		if slot.ammo >= def.MagSize then
			return
		end
		if (inv.reserve[def.AmmoType] or 0) <= 0 then
			Net.fireClient(player, "DamageFeedback", "Нет патронов")
			return
		end
		reloading[player] = true
		pushWeaponState(player)
		Net.fireClient(player, "PlayAnim", "Reload", def.ReloadTime, { def.ReloadKind })
		task.delay(def.ReloadTime, function()
			if Players:GetPlayerByUserId(player.UserId) then
				finishReload(player)
			end
		end)
	end)

	Net.onServerEvent("RequestEquip", function(player: Player, slot: any)
		if slot == 0 then
			InventoryService.unequip(player)
			return
		end
		local index = Net.validNumber(slot, 1, Config.Items.MaxInventory)
		if index then
			InventoryService.equip(player, index)
		end
	end)

	-- Parkour is predicted on the client (it has to be, to feel responsive), but
	-- the server still validates the request and publishes the noise the climb
	-- makes, so sprinting up a wall is not a silent way to escape a Clicker.
	Net.onServerEvent("RequestParkour", function(player: Player, kind: any, target: any)
		local k = Net.validString(kind, 12)
		local pos = Net.validVector(target)
		if not k or (k ~= "Mantle" and k ~= "Vault") or not pos then
			return
		end
		local root = Util.getRoot(player.Character)
		if not root then
			return
		end
		-- Reject teleports: the destination must be a short hop from the player.
		local delta = pos - root.Position
		if delta.Magnitude > Config.Movement.MantleHeightMax + Config.Movement.MantleReach + 4 then
			return
		end
		NoiseBus.emit(root.Position, if k == "Vault" then 34 else 26, "Impact", root, player)
	end)

	Net.onServerEvent("RequestDrop", function(player: Player, slot: any)
		local index = Net.validNumber(slot, 1, Config.Items.MaxInventory)
		if not index then
			return
		end
		local inv = InventoryService.get(player)
		local root = Util.getRoot(player.Character)
		if not inv or not root then
			return
		end
		local removed = InventoryService.removeSlot(player, index)
		if not removed then
			return
		end
		local def = WeaponData.Weapons[removed.id]
		local dropCF = root.CFrame * CFrame.new(0, 1.5, 3)
		if def.Category == "Throwable" then
			for i = 1, math.min(removed.ammo, 4) do
				local offset = CFrame.new((i - 2.5) * 1.4, 0.4, 0)
				local bottle = WeaponBuilder.build("Bottle", {
					Anchored = true,
					CFrame = dropCF * offset * WeaponBuilder.holdOffset("Bottle"),
				})
				if bottle then
					bottle.Parent = workspace:FindFirstChild("Pickups") or workspace
				end
			end
		else
			local model = WeaponBuilder.build(removed.id, {
				Anchored = true,
				AmmoInMag = removed.ammo,
				CFrame = dropCF * WeaponBuilder.holdOffset(removed.id),
			})
			if model then
				model:SetAttribute("Kind", "Weapon")
				model:SetAttribute("Label", def.DisplayName)
				game:GetService("CollectionService"):AddTag(model, "Pickup")
				model.Parent = workspace:FindFirstChild("Pickups") or workspace
			end
		end
	end)

	Net.onServerEvent("RequestThrowBottle", function(player: Player, origin: any, direction: any)
		local o = Net.validVector(origin)
		local d = Net.validVector(direction)
		if not o or not d or d.Magnitude < 0.01 then
			return
		end
		local root = Util.getRoot(player.Character)
		if root then
			o = root.Position + Vector3.new(0, 2.2, 0) + d.Unit * 2
		end
		handleThrow(player, o, d.Unit)
	end)

	Net.onServerEvent("RequestMelee", function(player: Player)
		local root = Util.getRoot(player.Character)
		if not root then
			return
		end
		Net.fireClient(player, "PlayAnim", "Shove", 0.4, {})
		NoiseBus.emit(root.Position, 40, "Impact", root, player)
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character :: any }
		local origin = root.Position + root.CFrame.LookVector * 3
		for _, part in workspace:GetPartBoundsInRadius(origin, 6, params) do
			local model = part:FindFirstAncestorOfClass("Model")
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid:TakeDamage(12)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastShot[player] = nil
		reloading[player] = nil
		shotWindow[player] = nil
	end)
end

return CombatService
