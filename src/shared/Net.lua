--!strict
--[[
	Net
	Thin wrapper over a folder of RemoteEvents. The server creates them
	on demand; the client waits for them. This keeps the wire protocol in
	one place instead of scattered Instance lookups.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()

local EVENTS = {
	"Ready", -- client -> server: client finished loading, resend state
	"Fire", -- client -> server: request shot
	"FireResult", -- server -> client: confirmed shot (for tracer/recoil)
	"Reload", -- client -> server
	"ReloadResult", -- server -> client
	"Swap", -- client -> server
	"SwapResult", -- server -> client
	"Melee", -- client -> server
	"Throw", -- client -> server
	"StateUpdate", -- client -> server: movement state (crouch/lean/etc.)
	"HitFeedback", -- server -> client: damage numbers / hitmarker
	"Health", -- server -> client: health & downed state
	"Noise", -- server -> client: noise ping for stealth UI
	"Effect", -- server -> all: cosmetic effect request
	"Inventory", -- server -> client: authoritative inventory sync
	"Heal", -- client -> server
}

local Net = {}

local folder: Folder

if IS_SERVER then
	folder = ReplicatedStorage:FindFirstChild("TLoUNet") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TLoUNet"
		folder.Parent = ReplicatedStorage
	end

	for _, name in ipairs(EVENTS) do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("TLoUNet") :: Folder
end

function Net.get(name: string): RemoteEvent
	local remote = folder:WaitForChild(name, 10)
	assert(remote, "Missing RemoteEvent: " .. name)
	return remote :: RemoteEvent
end

-- Convenience: server -> one player
function Net.toPlayer(player: Player, name: string, ...)
	Net.get(name):FireClient(player, ...)
end

-- Convenience: server -> everyone
function Net.toAll(name: string, ...)
	Net.get(name):FireAllClients(...)
end

-- Convenience: client -> server
function Net.toServer(name: string, ...)
	Net.get(name):FireServer(...)
end

return Net
