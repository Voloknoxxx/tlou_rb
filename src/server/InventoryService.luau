--!strict
--[[
	InventoryService
	----------------------------------------------------------------------------
	Authoritative per-player inventory.

	Layout
		slots       array of { id = "M9", ammo = 15 } or nil, length MaxInventory
		reserve     { ["9mm"] = 45, ["5.56"] = 90, ... }
		equipped    slot index or 0 for "holstered"
		held        the welded third-person weapon model in the character

	Everything the client needs to draw the HUD is pushed through the
	InventoryChanged remote whenever the state changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local WeaponData = require(ReplicatedStorage.Shared.WeaponData)
local WeaponBuilder = require(ReplicatedStorage.Shared.WeaponBuilder)

local InventoryService = {}

export type Slot = { id: string, ammo: number }
export type Inventory = {
	slots: { Slot? },
	reserve: { [string]: number },
	equipped: number,
	held: Model?,
	lastShot: number,
}

local inventories: { [Player]: Inventory } = {}

-- ------------------------------------------------------------------ helpers --

local function newInventory(): Inventory
	local slots = table.create(Config.Items.MaxInventory) :: { Slot? }
	for i = 1, Config.Items.MaxInventory do
		slots[i] = nil
	end
	return {
		slots = slots,
		reserve = {},
		equipped = 0,
		held = nil,
		lastShot = 0,
	}
end

local function snapshot(inv: Inventory)
	local slots = {}
	for i, slot in inv.slots do
		slots[i] = if slot then { id = slot.id, ammo = slot.ammo } else nil
	end
	local reserve = table.clone(inv.reserve)
	return slots, reserve, inv.equipped
end

function InventoryService.push(player: Player)
	local inv = inventories[player]
	if not inv then
		return
	end
	local slots, reserve, equipped = snapshot(inv)
	Net.fireClient(player, "InventoryChanged", slots, reserve, equipped)
end

function InventoryService.get(player: Player): Inventory?
	return inventories[player]
end

function InventoryService.getAmmo(player: Player, ammoType: string): number
	local inv = inventories[player]
	if not inv then
		return 0
	end
	return inv.reserve[ammoType] or 0
end

--[[
	Adds ammo to the reserve pool.
]]
function InventoryService.addAmmo(player: Player, ammoType: string, amount: number)
	local inv = inventories[player]
	if not inv then
		return
	end
	inv.reserve[ammoType] = (inv.reserve[ammoType] or 0) + amount
	InventoryService.push(player)
end

--[[
	Adds a weapon. If a slot of the same weapon with spare magazine room exists we
	top it up instead of consuming a slot. Returns true when something changed.
]]
function InventoryService.addWeapon(player: Player, weaponId: string, ammo: number?): boolean
	local inv = inventories[player]
	local def = WeaponData.Weapons[weaponId]
	if not inv or not def then
		return false
	end

	if def.Category == "Throwable" then
		-- Throwables stack in one slot.
		for i, slot in inv.slots do
			if slot and slot.id == weaponId then
				slot.ammo += (ammo or 1)
				InventoryService.push(player)
				return true
			end
		end
	end

	for i = 1, Config.Items.MaxInventory do
		if inv.slots[i] == nil then
			inv.slots[i] = { id = weaponId, ammo = ammo or def.MagSize }
			InventoryService.push(player)
			return true
		end
	end
	return false
end

function InventoryService.removeSlot(player: Player, index: number): Slot?
	local inv = inventories[player]
	if not inv then
		return nil
	end
	local slot = inv.slots[index]
	if not slot then
		return nil
	end
	inv.slots[index] = nil
	if inv.equipped == index then
		InventoryService.unequip(player)
	end
	InventoryService.push(player)
	return slot
end

-- ------------------------------------------------------------ third-person --

local function destroyHeld(inv: Inventory)
	if inv.held then
		inv.held:Destroy()
		inv.held = nil
	end
end

--[[
	Welds a freshly built weapon model to the character's right arm so other
	players see what you are carrying.
]]
local function attachHeld(player: Player, weaponId: string, ammo: number)
	local inv = inventories[player]
	local character = player.Character
	if not inv or not character then
		return
	end
	destroyHeld(inv)
	local hand = character:FindFirstChild("Right Arm") :: BasePart?
	local torso = character:FindFirstChild("Torso") :: BasePart?
	if not hand or not torso then
		return
	end

	local model = WeaponBuilder.build(weaponId, { Anchored = false })
	if not model then
		return
	end
	model:SetAttribute("AmmoInMag", ammo)
	model.Parent = character

	local primary = model.PrimaryPart
	if not primary then
		return
	end

	-- Place the grip in the hand with the barrel pointing down the arm's
	-- forward (-Z) axis, then weld it there.
	local cf = hand.CFrame * CFrame.new(0, -0.15, 0) * WeaponBuilder.holdOffset(weaponId)
	model:PivotTo(cf)

	local motor = Instance.new("Motor6D")
	motor.Name = "WeaponMotor"
	motor.Part0 = hand
	motor.Part1 = primary
	motor.C0 = hand.CFrame:ToObjectSpace(cf)
	motor.Parent = hand

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.Anchored = false
		end
	end

	inv.held = model
end

function InventoryService.unequip(player: Player)
	local inv = inventories[player]
	if not inv then
		return
	end
	inv.equipped = 0
	destroyHeld(inv)
	InventoryService.push(player)
end

function InventoryService.equip(player: Player, index: number): boolean
	local inv = inventories[player]
	if not inv then
		return false
	end
	local slot = inv.slots[index]
	if not slot then
		return false
	end
	inv.equipped = index
	attachHeld(player, slot.id, slot.ammo)
	InventoryService.push(player)
	Net.fireClient(player, "WeaponState", {
		Ammo = slot.ammo,
		Reserve = inv.reserve[WeaponData.Weapons[slot.id].AmmoType] or 0,
		Reloading = false,
		WeaponId = slot.id,
	})
	return true
end

--[[
	Re-welds the held model after a respawn.
]]
function InventoryService.rebuildHeld(player: Player)
	local inv = inventories[player]
	if not inv or inv.equipped == 0 then
		return
	end
	local slot = inv.slots[inv.equipped]
	if slot then
		attachHeld(player, slot.id, slot.ammo)
	end
end

-- ------------------------------------------------------------------- events --

local function onPlayerAdded(player: Player)
	inventories[player] = newInventory()
	InventoryService.push(player)
end

local function onCharacterAdded(player: Player, character: Model)
	-- Wait for the rig to exist before welding.
	local inv = inventories[player]
	if not inv then
		return
	end
	destroyHeld(inv)
	task.defer(function()
		task.wait(0.2)
		InventoryService.rebuildHeld(player)
	end)
end

function InventoryService.start()
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		local inv = inventories[player]
		if inv then
			destroyHeld(inv)
		end
		inventories[player] = nil
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
		if player.Character then
			onCharacterAdded(player, player.Character)
		end
	end)
end

return InventoryService
