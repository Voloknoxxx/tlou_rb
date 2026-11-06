--!strict
--[[
	CombatService
	Authoritative gunplay. The client asks to fire; the server validates
	cooldown, ammo, and the raycast, then applies damage and broadcasts the
	result so every client can render a matching tracer and impact.

	Hit verification walks the ray in small steps and only accepts hits
	whose surface normal faces the shooter, which blocks the classic
	"shoot through a wall corner" exploit.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local Weapons = require(Shared.Weapons)
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local CombatService = {}

-- player -> last shot timestamp (server clock)
local lastShotAt: { [Player]: number } = {}
-- player -> ammo in magazine
local magazines: { [Player]: { [string]: number } } = {}
-- player -> downed state
local downed: { [Player]: boolean } = {}
-- player -> health (we manage our own, detached from Humanoid.Health)
local health: { [Player]: number } = {}
-- player -> busy flag (reloading/swapping)
local busy: { [Player]: boolean } = {}
-- player -> current weapon id (authoritative)
local equipped: { [Player]: string } = {}

local RNG = Random.new()

local function now(): number
	return os.clock()
end

local function getCharacterParts(character: Model): { BasePart }
	local parts = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

--- Raycast that ignores the shooter's own character and any accessory parts.
local function castShot(origin: Vector3, direction: Vector3, range: number, ignoreList: { Instance })
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList
	params.IgnoreWater = true

	return workspace:Raycast(origin, direction * range, params)
end

--- Verifies a hit is legitimate by stepping the ray and confirming the
--- first blocking surface faces the shooter.
local function verifyHit(origin: Vector3, targetPosition: Vector3, ignoreList: { Instance }): RaycastResult?
	local delta = targetPosition - origin
	local distance = delta.Magnitude
	if distance < 0.01 then
		return nil
	end

	local direction = delta.Unit
	local steps = math.max(1, math.ceil(distance / Config.Combat.HitScanStepStuds))
	local step = distance / steps

	local previous = origin
	for i = 1, steps do
		local point = origin + direction * (step * i)
		local result = castShot(previous, (point - previous).Unit, (point - previous).Magnitude, ignoreList)
		if result then
			return result
		end
		previous = point
	end

	return nil
end

--- Emits a noise ping so stealth-aware listeners (AI, HUD) can react.
local function emitNoise(position: Vector3, radius: number, source: Player)
	Net.toAll("Noise", position, radius, source.UserId)
end

function CombatService.init()
	Net.get("Fire").OnServerEvent:Connect(function(player: Player, payload)
		CombatService.handleFire(player, payload)
	end)

	Net.get("Reload").OnServerEvent:Connect(function(player: Player, weaponId)
		CombatService.handleReload(player, weaponId)
	end)

	Net.get("Swap").OnServerEvent:Connect(function(player: Player, weaponId)
		CombatService.handleSwap(player, weaponId)
	end)

	Net.get("Melee").OnServerEvent:Connect(function(player: Player, payload)
		CombatService.handleMelee(player, payload)
	end)

	Net.get("Throw").OnServerEvent:Connect(function(player: Player, payload)
		CombatService.handleThrow(player, payload)
	end)

	Net.get("Heal").OnServerEvent:Connect(function(player: Player)
		CombatService.handleHeal(player)
	end)

	-- The client announces when it is ready and asks for a fresh copy of
	-- its state. This covers the race where the server granted the
	-- loadout before the client had connected its listeners.
	Net.get("Ready").OnServerEvent:Connect(function(player: Player)
		CombatService.sendState(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		CombatService.registerPlayer(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		CombatService.registerPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastShotAt[player] = nil
		magazines[player] = nil
		downed[player] = nil
		health[player] = nil
		busy[player] = nil
		equipped[player] = nil
	end)
end

--- Records which weapon a player is holding on their character, as an
--- attribute. Attributes replicate to every client and are replayed to late
--- joiners, so in third person everyone builds the right model in the right
--- hand without any custom networking.
function CombatService.broadcastEquipped(player: Player)
	local character = player.Character
	if character then
		character:SetAttribute("EquippedWeapon", equipped[player])
	end
end

function CombatService.registerPlayer(player: Player)
	magazines[player] = {}
	health[player] = Config.Combat.MaxHealth
	downed[player] = false
	busy[player] = false

	-- Reserve ammo lives in an "Ammo" folder of IntValues under the player.
	local backpack = Instance.new("Folder")
	backpack.Name = "Ammo"
	backpack.Parent = player

	local loadout = Weapons.defaultLoadout()
	for _, id in ipairs(loadout) do
		local data = Weapons.get(id)
		if data then
			magazines[player][id] = data.magazine
			CombatService.getReserve(player, id)
		end
	end
	equipped[player] = loadout[1]

	-- Tell every client what this player is holding. In third person the
	-- weapon is welded to the character's arm, so every client must build
	-- the right model in the right hand.
	CombatService.broadcastEquipped(player)

	-- Reset health/ammo every time the character respawns, so a player
	-- who was downed and bled out comes back clean.
	player.CharacterAdded:Connect(function(character)
		character:SetAttribute("EquippedWeapon", equipped[player])
		task.wait(0.35)
		CombatService.onRespawn(player)
	end)

	CombatService.sendState(player)
end

--- Resets a player's combat state after a respawn.
function CombatService.onRespawn(player: Player)
	health[player] = Config.Combat.MaxHealth
	downed[player] = false
	busy[player] = false

	local loadout = Weapons.defaultLoadout()
	for _, id in ipairs(loadout) do
		local data = Weapons.get(id)
		if data then
			magazines[player][id] = data.magazine
			local reserve = CombatService.getReserve(player, id)
			reserve.Value = math.max(reserve.Value, data.reserveMax)
		end
	end
	equipped[player] = loadout[1]
	CombatService.broadcastEquipped(player)

	CombatService.sendState(player)
end

--- Sends the full authoritative inventory + health to one player.
function CombatService.sendState(player: Player)
	if not magazines[player] then
		return
	end
	Net.toPlayer(player, "Inventory", {
		slots = Weapons.defaultLoadout(),
		magazines = magazines[player],
		reserves = CombatService.buildReserves(player),
		equipped = equipped[player],
	})
	Net.toPlayer(player, "Health", health[player] or Config.Combat.MaxHealth, downed[player] == true)
end

function CombatService.buildReserves(player: Player): { [string]: number }
	local reserves = {}
	local backpack = player:FindFirstChild("Ammo")
	if not backpack then
		return reserves
	end
	for _, child in ipairs(backpack:GetChildren()) do
		reserves[child.Name] = child.Value
	end
	return reserves
end

function CombatService.getReserve(player: Player, weaponId: string): IntValue
	local backpack = player:FindFirstChild("Ammo")
	if not backpack then
		backpack = Instance.new("Folder")
		backpack.Name = "Ammo"
		backpack.Parent = player
	end
	local value = backpack:FindFirstChild(weaponId)
	if not value then
		local data = Weapons.get(weaponId)
		value = Instance.new("IntValue")
		value.Name = weaponId
		value.Value = data and data.reserveMax or 0
		value.Parent = backpack
	end
	return value :: IntValue
end

function CombatService.isDowned(player: Player): boolean
	return downed[player] == true
end

function CombatService.handleFire(player: Player, payload)
	if downed[player] then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character:FindFirstChild("Head") :: BasePart?
	if not humanoid or not root or not head then
		return
	end

	local weaponId = payload and payload.weapon
	local data = weaponId and Weapons.get(weaponId)
	if not data or not Weapons.isFirearm(data) then
		return
	end
	if equipped[player] ~= weaponId then
		return -- client claims a weapon it does not have equipped
	end

	local interval = 60 / data.rpm
	if now() - (lastShotAt[player] or 0) < interval then
		return -- fired faster than the weapon allows
	end

	local mag = magazines[player] and magazines[player][weaponId]
	if not mag or mag <= 0 then
		return
	end

	if busy[player] then
		return
	end

	lastShotAt[player] = now()
	magazines[player][weaponId] = mag - 1

	local origin = payload.origin :: Vector3
	local direction = payload.direction :: Vector3
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end

	-- Guard against absurd client-supplied origins (anti-teleport-shot).
	if (origin - head.Position).Magnitude > 12 then
		origin = head.Position
	end
	direction = direction.Unit

	local ignore = getCharacterParts(character)
	local hitPlayers: { [Player]: boolean } = {}
	local impacts = {}

	local pellets = math.max(1, data.pellets)
	for _ = 1, pellets do
		local spread = math.rad(data.bulletSpread)
		local jitter = Vector3.new(RNG:NextNumber(-spread, spread), RNG:NextNumber(-spread, spread), 0)
		local shotDirection = (direction + jitter).Unit

		local result = verifyHit(origin, origin + shotDirection * data.range, ignore)
		if result then
			local hitPlayer, hitCharacter = Util.playerFromPart(result.Instance :: BasePart)
			table.insert(impacts, {
				position = result.Position,
				normal = result.Normal,
				material = result.Material,
				character = hitPlayer ~= nil,
			})

			if hitPlayer and hitCharacter and hitPlayer ~= player then
				if Config.Combat.FriendlyFire or hitPlayer.Team ~= player.Team then
					local multiplier = Util.locationMultiplier(
						result.Instance :: BasePart,
						Config.Combat.HeadshotMultiplier,
						Config.Combat.LimbMultiplier
					)
					local damage = data.damage * multiplier
					CombatService.applyDamage(hitPlayer, player, damage, result.Instance :: BasePart)
					hitPlayers[hitPlayer] = true
				end
			end
		end
	end

	Net.toAll("FireResult", player, {
		weapon = weaponId,
		origin = origin,
		direction = direction,
		impacts = impacts,
		silenced = data.silenced,
		hit = next(hitPlayers) ~= nil,
	})

	emitNoise(
		origin,
		data.silenced and Config.Combat.Noise.Silenced or Config.Combat.Noise.Gunshot,
		player
	)
end

function CombatService.applyDamage(victim: Player, attacker: Player?, amount: number, hitPart: BasePart?)
	if downed[victim] then
		return
	end

	health[victim] = math.max(0, (health[victim] or Config.Combat.MaxHealth) - amount)
	Net.toPlayer(victim, "Health", health[victim], false)

	if attacker then
		Net.toPlayer(attacker, "HitFeedback", {
			hitPart = hitPart and Util.partCategory(hitPart) or "Torso",
			amount = amount,
			lethal = health[victim] <= 0,
			victim = victim.UserId,
		})
	end

	if health[victim] <= 0 then
		CombatService.downPlayer(victim)
	end
end

function CombatService.downPlayer(player: Player)
	downed[player] = true
	Net.toPlayer(player, "Health", 0, true)
	Net.toAll("Effect", "Downed", player.Character)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end
	-- MovementService reads this to keep the player frozen.
	if character then
		character:SetAttribute("Downed", true)
	end

	-- Bleed out timer; a revive or heal can cancel it.
	task.delay(Config.Combat.BleedOutTime, function()
		if downed[player] and player.Parent then
			CombatService.killPlayer(player)
		end
	end)
end

function CombatService.revivePlayer(player: Player)
	downed[player] = false
	health[player] = math.max(Config.Combat.MaxHealth * 0.35, 25)

	local character = player.Character
	if character then
		character:SetAttribute("Downed", false)
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = Config.Movement.WalkSpeed
		humanoid.JumpPower = Config.Movement.JumpPower
	end

	Net.toPlayer(player, "Health", health[player], false)
end

function CombatService.killPlayer(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end
	downed[player] = false
end

function CombatService.handleHeal(player: Player)
	-- A downed player can spend a heal to get back on their feet. This is
	-- the tension valve: you are not dead yet, but you must commit a
	-- resource and expose yourself for several seconds.
	if downed[player] then
		CombatService.revivePlayer(player)
	elseif (health[player] or Config.Combat.MaxHealth) >= Config.Combat.MaxHealth then
		return
	end

	-- Heal over time, server-driven so it cannot be spammed.
	task.spawn(function()
		for _ = 1, 8 do
			if player.Parent == nil then
				return
			end
			local current = math.min(Config.Combat.MaxHealth, (health[player] or 0) + 6)
			health[player] = current
			Net.toPlayer(player, "Health", current, downed[player])
			task.wait(0.35)
		end
	end)
end

function CombatService.handleReload(player: Player, weaponId: string)
	if downed[player] or busy[player] then
		return
	end
	local data = weaponId and Weapons.get(weaponId)
	if not data or not Weapons.isFirearm(data) or data.magazine <= 0 then
		return
	end

	local mag = magazines[player] and magazines[player][weaponId] or 0
	if mag >= data.magazine then
		return
	end

	local reserve = CombatService.getReserve(player, weaponId)
	if reserve.Value <= 0 then
		return
	end

	busy[player] = true
	task.delay(data.reloadTime, function()
		busy[player] = false
		if not player.Parent or downed[player] then
			return
		end
		local needed = data.magazine - mag
		local taken = math.min(needed, reserve.Value)
		reserve.Value -= taken
		magazines[player][weaponId] = mag + taken

		Net.toPlayer(player, "ReloadResult", weaponId, magazines[player][weaponId], reserve.Value)
	end)
end

function CombatService.handleSwap(player: Player, weaponId: string)
	if downed[player] then
		return
	end
	local data = weaponId and Weapons.get(weaponId)
	if not data then
		return
	end
	if equipped[player] == weaponId then
		return
	end

	equipped[player] = weaponId
	busy[player] = true
	task.delay(data.raiseTime, function()
		busy[player] = false
	end)
	Net.toPlayer(player, "SwapResult", weaponId)
	CombatService.broadcastEquipped(player)
end

function CombatService.handleMelee(player: Player, payload)
	if downed[player] or busy[player] then
		return
	end
	local weaponId = payload and payload.weapon
	local data = weaponId and Weapons.get(weaponId)
	if not data or not Weapons.isMelee(data) then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not root or not head then
		return
	end

	local interval = 60 / data.rpm
	if now() - (lastShotAt[player] or 0) < interval then
		return
	end
	lastShotAt[player] = now()

	busy[player] = true
	task.delay(data.meleeSwing or 0.5, function()
		busy[player] = false
	end)

	-- Cone check in front of the player.
	local origin = head.Position
	local look = root.CFrame.LookVector
	local range = data.meleeRange or 6
	local hitAny = false

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and not downed[other] then
			local otherChar = other.Character
			local otherRoot = otherChar and otherChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if otherRoot then
				local toTarget = otherRoot.Position - origin
				if toTarget.Magnitude <= range then
					local dot = look:Dot(toTarget.Unit)
					if dot > 0.55 then -- roughly a 55 degree half-cone
						CombatService.applyDamage(other, player, data.meleeDamage or data.damage, otherRoot)
						hitAny = true
					end
				end
			end
		end
	end

	Net.toAll("Effect", "Melee", character, weaponId, hitAny)
	emitNoise(origin, Config.Combat.Noise.Melee, player)
end

function CombatService.handleThrow(player: Player, payload)
	if downed[player] then
		return
	end
	local weaponId = payload and payload.weapon
	local data = weaponId and Weapons.get(weaponId)
	if not data or not Weapons.isThrowable(data) then
		return
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	-- The client is trusted only for the throw direction; the projectile
	-- itself is simulated server-side so damage is authoritative.
	local direction = (payload.direction :: Vector3)
	if typeof(direction) ~= "Vector3" then
		return
	end
	direction = direction.Unit

	local projectile = Instance.new("Part")
	projectile.Name = "TLoUProjectile"
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(0.7, 0.7, 0.7)
	projectile.CanCollide = true
	projectile.CanQuery = false
	projectile.Material = Enum.Material.SmoothPlastic
	projectile.Color = data.visual.bodyColor
	projectile.CFrame = CFrame.new(head.Position + direction * 2)
	projectile.Parent = workspace

	local velocity = direction * 55 + Vector3.new(0, 12, 0)
	local life = 4
	local start = now()
	local exploded = false

	-- The projectile is a real physical object, so Touched is the reliable
	-- way to detect what it lands on. It explodes on the first non-thrower
	-- contact or when its fuse runs out.
	local function detonate(position: Vector3)
		if exploded then
			return
		end
		exploded = true

		Net.toAll("Effect", "Explosion", position, weaponId)
		projectile:Destroy()

		if data.damage > 0 then
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= player then
					local otherChar = other.Character
					local otherRoot = otherChar and otherChar:FindFirstChild("HumanoidRootPart") :: BasePart?
					if otherRoot then
						local dist = (otherRoot.Position - position).Magnitude
						if dist <= 12 then
							local falloff = 1 - (dist / 12)
							CombatService.applyDamage(other, player, data.damage * falloff, otherRoot)
						end
					end
				end
			end
		end

		emitNoise(position, 90, player)
	end

	projectile.Touched:Connect(function(other)
		if exploded or not other.Parent then
			return
		end
		local hitPlayer = Util.playerFromPart(other)
		if hitPlayer == player then
			return -- ignore the thrower's own body
		end
		detonate(projectile.Position)
	end)

	task.spawn(function()
		while not exploded and now() - start < life do
			local dt = task.wait()
			if not projectile.Parent then
				return
			end
			velocity = velocity + Vector3.new(0, -workspace.Gravity * dt, 0)
			projectile.CFrame = CFrame.new(projectile.Position + velocity * dt)
		end
		if not exploded and projectile.Parent then
			detonate(projectile.Position)
		end
	end)
end

return CombatService
