--!strict
--[[
	State (client)
	A single mutable table that every client controller reads and writes.
	Controllers never require each other directly - they coordinate through
	this state plus a tiny signal bus. That keeps them independently
	replaceable and avoids require cycles.
]]

local Signal = require(script.Parent.Signal)

local State = {}

State.character = nil :: Model?
State.humanoid = nil :: Humanoid?
State.rootPart = nil :: BasePart?
State.head = nil :: BasePart?
State.camera = workspace.CurrentCamera

-- Movement
State.stance = "Stand" :: string -- "Stand" | "Crouch" | "Prone"
State.sprinting = false
State.exhausted = false
State.stamina = 100
State.lean = 0 -- -1 left .. 1 right
State.grounded = true
State.vaulting = false
State.moveSpeed = 0

-- Combat
State.aiming = false
State.reloading = false
State.firing = false
State.equipped = nil :: string?
State.slots = {} :: { string }
State.magazines = {} :: { [string]: number }
State.reserves = {} :: { [string]: number }
State.health = 100
State.downed = false
State.inCombat = false
State.lastDamageAt = 0

-- Viewmodel
State.viewmodel = nil :: Model?
State.recoil = Vector2.new(0, 0)
State.recoilVelocity = Vector2.new(0, 0)

-- Last authoritative hit the local player landed (for the HUD hitmarker).
State.lastHitAt = 0
State.lastHitLethal = false

-- Signals
State.Signals = {
	CharacterChanged = Signal.new(),
	StanceChanged = Signal.new(),
	EquippedChanged = Signal.new(),
	HealthChanged = Signal.new(),
	AmmoChanged = Signal.new(),
	HitFeedback = Signal.new(),
	Noise = Signal.new(),
	Fired = Signal.new(),
	Shake = Signal.new(),
}

function State.setStance(stance: string)
	if State.stance ~= stance then
		State.stance = stance
		State.Signals.StanceChanged:Fire(stance)
	end
end

function State.setEquipped(weaponId: string?)
	if State.equipped ~= weaponId then
		State.equipped = weaponId
		State.Signals.EquippedChanged:Fire(weaponId)
	end
end

return State
