--!strict
--[[
	NoiseBus
	----------------------------------------------------------------------------
	The central "sound" simulation. Anything that makes noise publishes an event
	here; the zombie AI subscribes. This decouples noise sources (footsteps,
	gunfire, breaking bottles, doors) from the listeners, which is what lets the
	blind Clicker work purely from sound.

	Noise events are also relayed to nearby clients for the minimap / debug view.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local NoiseBus = {}

export type Noise = {
	Position: Vector3,
	Radius: number,
	Kind: string,        -- "Footstep" | "Gunshot" | "Glass" | "Door" | "Impact" | "Scream"
	Source: Instance?,
	Player: Player?,
	Time: number,
}

local listeners: { (Noise) -> () } = {}

function NoiseBus.subscribe(fn: (Noise) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		for i, other in listeners do
			if other == fn then
				table.remove(listeners, i)
				break
			end
		end
	end
end

--[[
	Publishes a noise event. `radius` is the stud distance at which a listener
	with normal hearing can just barely detect it.
]]
function NoiseBus.emit(position: Vector3, radius: number, kind: string, source: Instance?, player: Player?)
	if radius <= 0 then
		return
	end
	local noise: Noise = {
		Position = position,
		Radius = radius,
		Kind = kind,
		Source = source,
		Player = player,
		Time = os.clock(),
	}

	for _, fn in listeners do
		local ok, err = pcall(fn, noise)
		if not ok then
			warn(("[NoiseBus] listener error: %s"):format(tostring(err)))
		end
	end

	-- Let clients render the noise ping for players they can see.
	for _, plr in Players:GetPlayers() do
		local character = plr.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - position).Magnitude < 140 then
			Net.fireClient(plr, "NoiseEmitted", position, radius, kind)
		end
	end
end

return NoiseBus
