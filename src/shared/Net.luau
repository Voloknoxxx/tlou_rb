--!strict
--[[
	Net
	Thin, defensive wrapper around the remote-event layer.

	* RemoteEvents are created on the server and replicated down; the client
	  simply waits for them, so there is exactly one definition of every
	  channel.
	* Every handler is wrapped in pcall so a single bad payload can never take
	  down a listener, and the server validates all inbound arguments.

	Channels
		Client -> Server
			RequestStance(stance)          -- "Stand" | "Crouch" | "Prone"
			RequestSprint(on: boolean)
			RequestParkour(kind, dir)      -- "Mantle" | "Vault"
			RequestFire(origin, dir, seq)
			RequestReload()
			RequestEquip(slot)
			RequestDrop(slot)
			RequestInteract(target)        -- interactable instance
			RequestPickup(prompt)          -- world prompt instance
			RequestThrowBottle(origin, dir)
			RequestMelee()

		Server -> Client
			StanceChanged(stance)
			StaminaChanged(value)
			InventoryChanged(inventory, ammo, equippedSlot)
			FireEffect(origin, dir, weaponId, shooter)
			HitConfirm(worldPos, wasHead, killed)
			WeaponState(state)             -- { Ammo, Reserve, Reloading }
			InteractableOpened(target, openness)
			NoiseEmitted(position, radius, kind)
			PlayAnim(name, duration)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.FolderName = "Net"
Net.Events = {
	-- client -> server
	"RequestStance",
	"RequestSprint",
	"RequestParkour",
	"RequestFire",
	"RequestReload",
	"RequestEquip",
	"RequestDrop",
	"RequestInteract",
	"RequestPickup",
	"RequestThrowBottle",
	"RequestMelee",
	"RequestProne",
	-- server -> client
	"StanceChanged",
	"StaminaChanged",
	"InventoryChanged",
	"FireEffect",
	"HitConfirm",
	"WeaponState",
	"InteractableOpened",
	"NoiseEmitted",
	"PlayAnim",
	"DamageFeedback",
	"ZombieAlerted",
}

local cache: { [string]: RemoteEvent } = {}

--[[
	Server side: create the folder + every remote. Idempotent.
]]
function Net.initServer(): Folder
	local folder = ReplicatedStorage:FindFirstChild(Net.FolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Net.FolderName
		folder.Parent = ReplicatedStorage
	end
	for _, name in Net.Events do
		if not folder:FindFirstChild(name) then
			local ev = Instance.new("RemoteEvent")
			ev.Name = name
			ev.Parent = folder
		end
	end
	return folder :: Folder
end

--[[
	Returns the RemoteEvent for `name`, waiting for it to replicate on the
	client. Returns nil if it never shows up (e.g. a stale server build).
]]
function Net.event(name: string): RemoteEvent?
	if cache[name] then
		return cache[name]
	end
	if RunService:IsServer() then
		local folder = Net.initServer()
		local ev = folder:FindFirstChild(name) :: RemoteEvent?
		if ev then
			cache[name] = ev
		end
		return ev
	end
	local folder = ReplicatedStorage:WaitForChild(Net.FolderName, 30) :: Folder?
	if not folder then
		warn(("[Net] remote folder never replicated; is the server running? (wanted %s)"):format(name))
		return nil
	end
	local ev = folder:WaitForChild(name, 30) :: RemoteEvent?
	if ev then
		cache[name] = ev
	end
	return ev
end

function Net.fireServer(name: string, ...: any)
	local ev = Net.event(name)
	if ev then
		ev:FireServer(...)
	end
end

function Net.fireClient(player: Player, name: string, ...: any)
	local ev = Net.event(name)
	if ev then
		ev:FireClient(player, ...)
	end
end

function Net.fireAll(name: string, ...: any)
	local ev = Net.event(name)
	if ev then
		ev:FireAllClients(...)
	end
end

--[[
	Connects a handler with an automatic pcall guard.
]]
function Net.onServerEvent(name: string, handler: (player: Player, ...any) -> ()): RBXScriptConnection?
	local ev = Net.event(name)
	if not ev then
		return nil
	end
	return ev.OnServerEvent:Connect(function(player: Player, ...: any)
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(("[Net] %s handler error: %s"):format(name, tostring(err)))
		end
	end)
end

function Net.onClientEvent(name: string, handler: (...any) -> ()): RBXScriptConnection?
	local ev = Net.event(name)
	if not ev then
		return nil
	end
	return ev.OnClientEvent:Connect(function(...: any)
		local ok, err = pcall(handler, ...)
		if not ok then
			warn(("[Net] %s client error: %s"):format(name, tostring(err)))
		end
	end)
end

-- ------------------------------------------------------------ validation --

--[[
	Server-side payload guards. Return a cleaned value or nil when the payload is
	obviously bogus, so exploits cannot crash a handler.
]]
function Net.validString(value: any, maxLen: number?): string?
	if type(value) ~= "string" then
		return nil
	end
	if maxLen and #value > maxLen then
		return nil
	end
	return value
end

function Net.validBool(value: any): boolean?
	if type(value) ~= "boolean" then
		return nil
	end
	return value
end

function Net.validNumber(value: any, lo: number, hi: number): number?
	if type(value) ~= "number" or value ~= value then -- NaN check
		return nil
	end
	if value < lo or value > hi then
		return nil
	end
	return value
end

function Net.validVector(value: any): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	if value.Magnitude > 1e5 or value.Magnitude ~= value.Magnitude then
		return nil
	end
	return value
end

function Net.validCFrame(value: any): CFrame?
	if typeof(value) ~= "CFrame" then
		return nil
	end
	return value
end

return Net
