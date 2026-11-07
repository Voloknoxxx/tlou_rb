--!strict
--[[
	InventoryService
	Owns the per-player slot list and hands starting gear to the server's
	weapon service. Kept separate from CombatService so loadout rules can
	change (survival mode, arena mode) without touching gunplay.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Weapons = require(Shared.Weapons)
local Net = require(Shared.Net)

local InventoryService = {}

-- player -> ordered array of weapon ids
local inventories: { [Player]: { string } } = {}

function InventoryService.init()
	Players.PlayerAdded:Connect(function(player)
		InventoryService.grantLoadout(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		InventoryService.grantLoadout(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		inventories[player] = nil
	end)
end

function InventoryService.grantLoadout(player: Player)
	local loadout = Weapons.defaultLoadout()
	inventories[player] = loadout
	Net.toPlayer(player, "Inventory", {
		slots = loadout,
		equipped = loadout[1],
	})
end

function InventoryService.get(player: Player): { string }
	return inventories[player] or {}
end

function InventoryService.has(player: Player, weaponId: string): boolean
	local slots = inventories[player]
	if not slots then
		return false
	end
	for _, id in ipairs(slots) do
		if id == weaponId then
			return true
		end
	end
	return false
end

function InventoryService.add(player: Player, weaponId: string): boolean
	local slots = inventories[player]
	if not slots or not Weapons.get(weaponId) then
		return false
	end
	if #slots >= Config.Inventory.MaxSlots then
		return false
	end
	table.insert(slots, weaponId)
	Net.toPlayer(player, "Inventory", { slots = slots, added = weaponId })
	return true
end

return InventoryService
