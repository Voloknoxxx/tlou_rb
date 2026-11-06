--!strict
--[[
	Util
	Shared helpers used by both server and client controllers.
]]

local Players = game:GetService("Players")

local Util = {}

local HEAD_NAMES = { Head = true }
local LIMB_NAMES = { ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true, ["LeftHand"] = true, ["RightHand"] = true, ["LeftFoot"] = true, ["RightFoot"] = true }

--- Returns the body-part category for a hit part: "Head" | "Limb" | "Torso"
function Util.partCategory(part: BasePart): string
	local name = part.Name
	if HEAD_NAMES[name] then
		return "Head"
	elseif LIMB_NAMES[name] then
		return "Limb"
	end
	return "Torso"
end

--- Applies the right damage multiplier for a hit location.
function Util.locationMultiplier(part: BasePart, headMul: number, limbMul: number): number
	local cat = Util.partCategory(part)
	if cat == "Head" then
		return headMul
	elseif cat == "Limb" then
		return limbMul
	end
	return 1
end

--- Walks up from an instance to the player who owns the character, if any.
function Util.playerFromPart(part: BasePart?): (Player?, Model?)
	if not part then
		return nil, nil
	end
	local character = part:FindFirstAncestorOfClass("Model")
	while character do
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local player = Players:GetPlayerFromCharacter(character)
			return player, character
		end
		character = character:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

--- Deep-copies a table (arrays/maps of primitives and nested tables).
function Util.deepCopy<T>(source: T): T
	if type(source) ~= "table" then
		return source
	end
	local copy = {}
	for key, value in pairs(source :: any) do
		copy[key] = Util.deepCopy(value)
	end
	return copy :: T
end

--- Linearly interpolates between two Vector3s.
function Util.lerpVector(a: Vector3, b: Vector3, alpha: number): Vector3
	return a + (b - a) * alpha
end

--- Frame-rate independent smoothing factor.
function Util.damp(deltaTime: number, speed: number): number
	return 1 - math.exp(-speed * deltaTime)
end

--- Clamps a number between min and max.
function Util.clamp(value: number, min: number, max: number): number
	return math.max(min, math.min(max, value))
end

--- Converts a mouse/keyboard keycode list into a readable prompt.
function Util.keyLabel(key: Enum.KeyCode): string
	return key.Name
end

return Util
