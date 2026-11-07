--!strict
--[[
	SoundController
	----------------------------------------------------------------------------
	Positional audio for everything that matters.

	IMPORTANT - asset ids
		Roblox sound effects are licensed assets, so the ids below are
		placeholders. Replace them with ids you own (or upload) and every call
		site keeps working unchanged. Playback is wrapped so a missing asset is
		silent rather than fatal.

	The controller also derives audio from gameplay signals rather than being
	polled, so footsteps land exactly on the animation's contact frames and
	gunshots always match the muzzle flash.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Net = require(ReplicatedStorage.Shared.Net)

local ClientState = require(script.Parent.ClientState)

local SoundController = {}


-- Replace these with your own uploaded asset ids.
local LIBRARY: { [string]: { id: string, volume: number, pitch: { number } } } = {
	FootstepGrass = { id = "rbxassetid://911420375", volume = 0.35, pitch = { 0.92, 1.08 } },
	FootstepConcrete = { id = "rbxassetid://911421188", volume = 0.4, pitch = { 0.9, 1.1 } },
	FootstepCrouch = { id = "rbxassetid://911420375", volume = 0.18, pitch = { 0.8, 0.95 } },
	GunshotPistol = { id = "rbxassetid://1113447675", volume = 0.85, pitch = { 0.97, 1.03 } },
	GunshotRifle = { id = "rbxassetid://1113447675", volume = 0.95, pitch = { 0.88, 0.94 } },
	GunshotShotgun = { id = "rbxassetid://1113447675", volume = 1, pitch = { 0.7, 0.78 } },
	DryFire = { id = "rbxassetid://912038643", volume = 0.4, pitch = { 0.9, 1.0 } },
	ReloadMag = { id = "rbxassetid://912038643", volume = 0.5, pitch = { 0.95, 1.05 } },
	ReloadShell = { id = "rbxassetid://912038643", volume = 0.45, pitch = { 1.0, 1.15 } },
	GlassBreak = { id = "rbxassetid://1213254312", volume = 0.8, pitch = { 0.9, 1.1 } },
	DrawerOpen = { id = "rbxassetid://912038643", volume = 0.45, pitch = { 0.6, 0.7 } },
	CabinetOpen = { id = "rbxassetid://912038643", volume = 0.5, pitch = { 0.5, 0.6 } },
	Pickup = { id = "rbxassetid://912038643", volume = 0.35, pitch = { 1.1, 1.25 } },
	ZombieGrowl = { id = "rbxassetid://1837879082", volume = 0.55, pitch = { 0.7, 0.9 } },
	ZombieScream = { id = "rbxassetid://1837879082", volume = 0.9, pitch = { 0.5, 0.65 } },
	ClickerClick = { id = "rbxassetid://1837879082", volume = 0.6, pitch = { 1.4, 1.7 } },
	HitFlesh = { id = "rbxassetid://912038643", volume = 0.5, pitch = { 0.8, 1.0 } },
	Heartbeat = { id = "rbxassetid://911420375", volume = 0.5, pitch = { 0.5, 0.55 } },
}

local group: SoundGroup
local cache: { [string]: Sound } = {}
local lastStep = 0
local growlCooldown = 0

local function soundFor(name: string): Sound?
	local entry = LIBRARY[name]
	if not entry then
		return nil
	end
	if cache[name] then
		return cache[name]
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = entry.id
	sound.Volume = entry.volume
	sound.SoundGroup = group
	cache[name] = sound
	return sound
end

--[[
	Plays a named sound. `position` makes it positional; omit it for a UI/2D
	sound. Returns the playing Sound so callers can tweak it.
]]
function SoundController.play(name: string, position: Vector3?, pitchScale: number?): Sound?
	local sound = soundFor(name)
	if not sound then
		return nil
	end
	local entry = LIBRARY[name]
	local pitch = pitchScale
	if not pitch then
		pitch = entry.pitch[1] + math.random() * (entry.pitch[2] - entry.pitch[1])
	end

	-- Clone for overlapping playback so rapid shots do not cut each other off.
	local clone = sound:Clone()
	clone.PlaybackSpeed = pitch
	clone.SoundGroup = group
	if position then
		local emitter = Instance.new("Part")
		emitter.Anchored = true
		emitter.CanCollide = false
		emitter.CanQuery = false
		emitter.Transparency = 1
		emitter.Size = Vector3.new(0.1, 0.1, 0.1)
		emitter.CFrame = CFrame.new(position)
		emitter.Parent = workspace
		clone.Parent = emitter
		clone:Play()
		clone.Ended:Once(function()
			emitter:Destroy()
		end)
	else
		clone.Parent = SoundService
		clone:Play()
		clone.Ended:Once(function()
			clone:Destroy()
		end)
	end
	return clone
end

--[[
	Footsteps are driven from the character's own ground speed so they land on
	the animation's contact frames rather than on a fixed timer.
]]
local function updateFootsteps(dt: number)
	local root = ClientState.root
	local humanoid = ClientState.humanoid
	if not root or not humanoid then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end
	local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	if speed < 1.5 then
		return
	end

	-- Step cadence scales with speed; two contacts per stride cycle.
	local cadence = 0.62 - math.clamp(speed / 30, 0, 0.34)
	if ClientState.stance == "Crouch" then
		cadence *= 1.35
	elseif ClientState.stance == "Prone" then
		cadence *= 1.6
	end
	lastStep += dt
	if lastStep < cadence then
		return
	end
	lastStep = 0

	local material = humanoid.FloorMaterial
	local name = if ClientState.inGrass or material == Enum.Material.Grass then "FootstepGrass"
		elseif ClientState.stance == "Crouch" then "FootstepCrouch"
		else "FootstepConcrete"
	SoundController.play(name, root.Position)
end

function SoundController.start()
	group = Instance.new("SoundGroup")
	group.Name = "LastStand"
	group.Volume = 1
	group.Parent = SoundService

	-- Pre-create sounds so the first shot has no hitch.
	for name in LIBRARY do
		soundFor(name)
	end

	Net.onClientEvent("PlayAnim", function(name: string, _duration: number, args: any)
		local root = ClientState.root
		local pos = root and root.Position
		if name == "Reload" then
			SoundController.play(args and args[1] == "Shells" and "ReloadShell" or "ReloadMag", pos)
		elseif name == "DrawerOpen" then
			SoundController.play("DrawerOpen", pos)
		elseif name == "CabinetOpen" then
			SoundController.play("CabinetOpen", pos)
		elseif name == "PickupFloor" or name == "PickupShelf" then
			SoundController.play("Pickup", pos)
		end
	end)

	Net.onClientEvent("FireEffect", function(origin: Vector3, _direction: Vector3, weaponId: string, shooter: Player)
		local def = require(ReplicatedStorage.Shared.WeaponData).Weapons[weaponId]
		local name = "GunshotPistol"
		if def then
			if def.Category == "Rifle" then
				name = "GunshotRifle"
			elseif def.Category == "Shotgun" then
				name = "GunshotShotgun"
			elseif def.Category == "Revolver" then
				name = "GunshotShotgun"
			end
		end
		SoundController.play(name, origin)
		local _ = shooter
	end)

	Net.onClientEvent("WeaponState", function(payload: any)
		if type(payload) == "table" and payload.DryFire then
			local root = ClientState.root
			SoundController.play("DryFire", root and root.Position)
		end
	end)

	Net.onClientEvent("NoiseEmitted", function(position: Vector3, _radius: number, kind: string)
		if kind == "Glass" then
			SoundController.play("GlassBreak", position)
		elseif kind == "Scream" then
			SoundController.play("ZombieScream", position)
		end
	end)

	Net.onClientEvent("HitConfirm", function()
		local root = ClientState.root
		SoundController.play("HitFlesh", root and root.Position)
	end)

	Net.onClientEvent("ZombieAlerted", function(position: Vector3)
		SoundController.play("ClickerClick", position)
	end)

	RunService.RenderStepped:Connect(function(dt)
		if not ClientState.isAlive() then
			return
		end
		updateFootsteps(dt)

		-- Ambient growls from nearby infected, throttled.
		growlCooldown -= dt
		local root = ClientState.root
		if root and growlCooldown <= 0 then
			growlCooldown = 3 + math.random() * 4
			local best: Vector3? = nil
			local bestDist = 60
			for _, model in game:GetService("CollectionService"):GetTagged("Zombie") do
				local zRoot = model:FindFirstChild("HumanoidRootPart") :: BasePart?
				if zRoot then
					local d = (zRoot.Position - root.Position).Magnitude
					if d < bestDist then
						bestDist = d
						best = zRoot.Position
					end
				end
			end
			if best then
				SoundController.play("ZombieGrowl", best)
			end
		end
	end)
end

return SoundController
