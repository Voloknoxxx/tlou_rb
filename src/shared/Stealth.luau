--!strict
--[[
	Stealth
	----------------------------------------------------------------------------
	Pure, stateless stealth maths shared by the client HUD and the server AI so
	both agree on how visible the player is.

	Concealment model
		* stance multiplier  : standing 1.0, crouching 1.5, prone 2.0
		  (a larger multiplier means a zombie needs proportionally longer to
		  notice you - "тебя на секунду дольше замечают")
		* grass multiplier   : 0.25 and a hard "must be this close" radius
		* motion             : sprinting makes you louder and more visible
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local Stealth = {}

Stealth.Stance = {
	Stand = "Stand",
	Crouch = "Crouch",
	Prone = "Prone",
}

--[[
	Returns the stance notice multiplier.
]]
function Stealth.stanceMultiplier(stance: string): number
	local S = Config.Stealth
	if stance == "Prone" then
		return S.ProneMultiplier
	elseif stance == "Crouch" then
		return S.CrouchMultiplier
	end
	return S.StandMultiplier
end

--[[
	How long (seconds) a zombie with the given base notice time needs to lock on
	to a player in the given stance / cover.
]]
function Stealth.noticeTime(baseNoticeTime: number, stance: string, inGrass: boolean, sprinting: boolean): number
	local t = baseNoticeTime * Stealth.stanceMultiplier(stance)
	if inGrass then
		t /= Config.Stealth.GrassMultiplier * 4 -- grass makes you ~4x harder to see
	end
	if sprinting then
		t *= 0.75
	end
	return math.max(t, 0.05)
end

--[[
	Noise radius produced by locomotion, in studs.
]]
function Stealth.noiseRadius(stance: string, speed: number, inGrass: boolean): number
	local S = Config.Stealth
	local base: number
	if speed < 1 then
		base = 0
	elseif stance == "Prone" then
		base = S.NoiseProne
	elseif stance == "Crouch" then
		base = S.NoiseCrouch
	elseif speed > 16 then
		base = S.NoiseSprint
	else
		base = S.NoiseWalk
	end
	if inGrass then
		base *= S.GrassNoiseMultiplier
	end
	return base
end

--[[
	Returns 0..1 "how visible am I", for the HUD eye indicator.
	1 == fully exposed, 0 == effectively invisible.
]]
function Stealth.visibilityScore(stance: string, inGrass: boolean, sprinting: boolean): number
	local v = 1 / Stealth.stanceMultiplier(stance)
	if inGrass then
		v *= Config.Stealth.GrassMultiplier * 4
	end
	if sprinting then
		v *= 1.25
	end
	return math.clamp(v, 0, 1)
end

return Stealth
