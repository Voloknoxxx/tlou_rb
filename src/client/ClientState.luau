--!strict
--[[
	ClientState
	----------------------------------------------------------------------------
	One shared table that every client module reads from and writes to. Keeping
	the cross-module state in a single place avoids circular requires between the
	movement, camera, weapon and HUD controllers.

	`ClientState.changed` is a BindableEvent used as a coarse "something
	gameplay-relevant changed" signal for the HUD.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)

local ClientState = {}

ClientState.player = nil :: Player?
ClientState.character = nil :: Model?
ClientState.humanoid = nil :: Humanoid?
ClientState.root = nil :: BasePart?
ClientState.animator = nil :: any

ClientState.stance = "Stand"
ClientState.aiming = false
ClientState.sprinting = false
ClientState.stamina = Config.Movement.StaminaMax
ClientState.exhausted = false

-- Movement locks are counted, not boolean, so independent systems (mantle,
-- interaction, reload) can each hold the player still without stomping on
-- each other.
ClientState.moveLocks = {} :: { [string]: boolean }

ClientState.shoulderSide = 1 -- 1 = right, -1 = left
ClientState.noisePing = nil :: { position: Vector3, radius: number, kind: string, time: number }?
ClientState.inGrass = false
ClientState.visibility = 1
ClientState.interactPrompt = nil :: { instance: Instance, label: string, kind: string }?

ClientState.changed = Instance.new("BindableEvent")
ClientState.ready = false

function ClientState.setCharacter(character: Model?)
	ClientState.character = character
	ClientState.humanoid = character and character:FindFirstChildOfClass("Humanoid")
	ClientState.root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	ClientState.ready = character ~= nil
end

function ClientState.isAlive(): boolean
	local humanoid = ClientState.humanoid
	return humanoid ~= nil and humanoid.Health > 0
end

function ClientState.lock(key: string)
	ClientState.moveLocks[key] = true
end

function ClientState.unlock(key: string)
	ClientState.moveLocks[key] = nil
end

function ClientState.isLocked(): boolean
	return next(ClientState.moveLocks) ~= nil
end

function ClientState.notify()
	ClientState.changed:Fire()
end

--[[
	Looks up another module's public table without creating a require cycle by
	using the fact that every client module is a sibling in StarterPlayerScripts.
]]
function ClientState.sibling(name: string): any
	local scripts = script.Parent
	local child = scripts and scripts:FindFirstChild(name)
	if child then
		return require(child)
	end
	return nil
end

ClientState.RunService = RunService

return ClientState
