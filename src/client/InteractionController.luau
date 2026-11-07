--!strict
--[[
	InteractionController
	----------------------------------------------------------------------------
	Finds the thing the player is looking at and offers it as a prompt.

	Detection runs every frame from the camera, casting a cone of rays (centre
	plus a ring) so small pickups are easy to grab. The nearest candidate inside
	its configured range wins, and the server independently re-validates the
	distance before anything happens.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Util = require(ReplicatedStorage.Shared.Util)

local ClientState = require(script.Parent.ClientState)

local InteractionController = {}

local camera = workspace.CurrentCamera

local PICKUP_TAG = "Pickup"
local INTERACTABLE_TAG = "Interactable"

local current: { instance: Instance, label: string, kind: string }? = nil
local lastPromptKey = ""

-- ------------------------------------------------------------------ detection --

local function classify(inst: Instance): (string?, string?, Instance?)
	-- Walk up the ancestry looking for a tagged model.
	local node: Instance? = inst
	while node and node ~= workspace do
		if node:IsA("Model") then
			if node:HasTag(PICKUP_TAG) then
				local label = node:GetAttribute("Label") or "Подобрать"
				return "Pickup", label, node
			end
			if node:HasTag(INTERACTABLE_TAG) then
				local label = node:GetAttribute("Label") or "Использовать"
				if node:GetAttribute("Open") then
					label = "Уже открыто"
				end
				return "Interactable", label, node
			end
		end
		node = node.Parent
	end
	return nil
end

local function probe(): (Instance?, number, string?, string?)
	local root = ClientState.root
	if not root then
		return nil, math.huge, nil, nil
	end

	local camCF = camera.CFrame
	local directions = { camCF.LookVector }
	-- A small ring of extra rays makes thin objects much easier to target.
	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local offset = (camCF.RightVector * math.cos(angle) + camCF.UpVector * math.sin(angle)) * 0.09
		table.insert(directions, (camCF.LookVector + offset).Unit)
	end

	local ignore: { Instance } = {}
	if ClientState.character then
		table.insert(ignore, ClientState.character)
	end

	local bestInstance: Instance? = nil
	local bestDist = math.huge
	local bestKind: string? = nil
	local bestLabel: string? = nil

	for _, dir in directions do
		local result = Util.raycast(camCF.Position, dir * 14, ignore)
		if result and result.Instance then
			local kind, label, model = classify(result.Instance)
			if kind and model then
				local pivot = if model:IsA("Model") then model:GetPivot().Position else (model :: BasePart).Position
				local dist = (pivot - root.Position).Magnitude
				local maxRange = if kind == "Pickup" then Config.Items.PickupRange else Config.Items.CabinetRange
				if dist <= maxRange and dist < bestDist then
					bestDist = dist
					bestInstance = model
					bestKind = kind
					bestLabel = label
				end
			end
		end
	end

	return bestInstance, bestDist, bestKind, bestLabel
end

-- -------------------------------------------------------------------- actions --

local function performInteract()
	local prompt = current
	if not prompt then
		return
	end
	if prompt.kind == "Pickup" then
		Net.fireServer("RequestPickup", prompt.instance)
	else
		Net.fireServer("RequestInteract", prompt.instance)
	end
end

-- ---------------------------------------------------------------------- input --

local function bindInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not ClientState.isAlive() then
			return
		end
		if input.KeyCode == Config.Keys.Interact then
			performInteract()
		elseif input.KeyCode == Config.Keys.Melee then
			Net.fireServer("RequestMelee")
		end
	end)
end

-- ----------------------------------------------------------------------- start --

function InteractionController.start()
	camera = workspace.CurrentCamera
	bindInput()

	RunService.RenderStepped:Connect(function()
		if not ClientState.isAlive() then
			ClientState.interactPrompt = nil
			return
		end
		local instance, _dist, kind, label = probe()
		if instance and kind and label then
			current = { instance = instance, label = label, kind = kind }
			ClientState.interactPrompt = current
			local key = tostring(instance) .. label
			if key ~= lastPromptKey then
				lastPromptKey = key
				ClientState.notify()
			end
		else
			if current then
				current = nil
				ClientState.interactPrompt = nil
				lastPromptKey = ""
				ClientState.notify()
			end
		end
	end)
end

return InteractionController
