--!strict
--[[
	NetworkController
	The single place that translates server remote traffic into client
	State and signals. Keeping it separate means no other controller needs
	to know about remote names.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Net = require(Shared.Net)
local Config = require(Shared.Config)

local State = require(script.Parent.State)

local NetworkController = {}

local player = Players.LocalPlayer

function NetworkController.init()
	Net.get("Health").OnClientEvent:Connect(function(value: number, downed: boolean)
		State.health = value
		State.downed = downed
		State.Signals.HealthChanged:Fire(value, downed)
	end)

	Net.get("Inventory").OnClientEvent:Connect(function(payload)
		if payload.slots then
			State.slots = payload.slots
		end
		-- Inventory is an authoritative full-state push (join, respawn,
		-- or an explicit Ready request), so always trust its equipped
		-- field. Individual swaps are confirmed separately via SwapResult.
		if payload.equipped then
			State.setEquipped(payload.equipped)
		end
		if payload.magazines then
			for id, count in pairs(payload.magazines) do
				State.magazines[id] = count
			end
		end
		if payload.reserves then
			for id, count in pairs(payload.reserves) do
				State.reserves[id] = count
			end
		end
		State.Signals.AmmoChanged:Fire(State.equipped, 0, 0)
	end)

	Net.get("HitFeedback").OnClientEvent:Connect(function(payload)
		State.Signals.HitFeedback:Fire(payload)
	end)

	Net.get("Noise").OnClientEvent:Connect(function(position: Vector3, radius: number, sourceUserId: number)
		if sourceUserId == player.UserId then
			State.Signals.Noise:Fire(position, radius, true)
		else
			State.Signals.Noise:Fire(position, radius, false)
		end
	end)

	Net.get("Effect").OnClientEvent:Connect(function(kind: string, ...)
		local EffectsController = require(script.Parent.EffectsController)
		if kind == "Explosion" then
			local position, weaponId = ...
			EffectsController.spawnExplosion(position, weaponId)
		elseif kind == "Melee" then
			local character, weaponId, hit = ...
			EffectsController.spawnMelee(character, weaponId, hit)
		elseif kind == "Blood" then
			local position, normal = ...
			EffectsController.spawnBlood(position, normal)
		end
	end)

	State.Signals.HealthChanged:Connect(function(value, downed)
		local HUDController = require(script.Parent.HUDController)
		HUDController.showDowned(downed == true)
	end)

	State.Signals.CharacterChanged:Connect(function()
		State.health = Config.Combat.MaxHealth
		State.downed = false
		local HUDController = require(script.Parent.HUDController)
		HUDController.showDowned(false)
	end)
end

return NetworkController
