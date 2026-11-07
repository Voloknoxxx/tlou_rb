--!strict
--[[
	WorldBuilder
	----------------------------------------------------------------------------
	Generates the playable level entirely from code so the game runs the moment
	you press Play - no imported models required.

	It produces
		* a foggy overgrown ground plane with dirt paths and rubble
		* a small ruined town of enterable buildings
		* street furniture: drawers, cabinets, shelves, cars, fences
		* grass clumps (tagged "Grass", used by the stealth system)
		* loot spawn points and zombie spawn points

	Everything is deterministic per seed so a given Place file always produces
	the same town.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Util = require(ReplicatedStorage.Shared.Util)

local WorldBuilder = {}

WorldBuilder.GRASS_TAG = "Grass"
WorldBuilder.INTERACTABLE_TAG = "Interactable"
WorldBuilder.LOOT_TAG = "LootSpawn"
WorldBuilder.ZOMBIE_TAG = "ZombieSpawn"
WorldBuilder.BLOCKER_TAG = "ParkourBlocker"

local rng = Random.new(20240517)

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.Material = Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

local function colour(hex: string): Color3
	return Color3.fromHex(hex)
end

local function randRange(lo: number, hi: number): number
	return lo + rng:NextNumber() * (hi - lo)
end

-- --------------------------------------------------------------- structures --

local function buildGround(parent: Instance): Part
	local size = Config.World.GroundSize
	local ground = part({
		Name = "Ground",
		Size = Vector3.new(size, 8, size),
		CFrame = CFrame.new(0, -4, 0),
		Color = colour("#3b3f33"),
		Material = Enum.Material.Grass,
		CanCollide = true,
		Parent = parent,
	})
	ground:SetAttribute("IsGround", true)

	-- A few dirt patches for visual variety.
	for _ = 1, 18 do
		local patch = part({
			Name = "Dirt",
			Size = Vector3.new(randRange(20, 46), 0.4, randRange(20, 46)),
			CFrame = CFrame.new(randRange(-size / 2, size / 2), 0.1, randRange(-size / 2, size / 2))
				* CFrame.Angles(0, rng:NextNumber() * math.pi, 0),
			Color = colour("#4a4234"),
			Material = Enum.Material.Ground,
			CanCollide = false,
			Parent = parent,
		})
		patch.CanQuery = false
	end
	return ground
end

--[[
	A simple enterable building. Returns a table describing its footprint so the
	caller can place furniture inside.
]]
local function buildBuilding(parent: Instance, centre: Vector3, w: number, d: number, h: number): { Vector3 }
	parent = parent
	local wallT = 0.8
	local mat = Enum.Material.Brick
	local wallColor = colour("#6b6459")

	local walls = {
		{ Vector3.new(w, h, wallT), Vector3.new(0, h / 2, -d / 2) },
		{ Vector3.new(w, h, wallT), Vector3.new(0, h / 2, d / 2) },
		{ Vector3.new(wallT, h, d), Vector3.new(-w / 2, h / 2, 0) },
		{ Vector3.new(wallT, h, d), Vector3.new(w / 2, h / 2, 0) },
	}

	-- Leave a doorway in the front wall by splitting it in two.
	local doorWidth = 8
	local doorHeight = 10
	for index, wall in walls do
		if index == 2 then
			local sideW = (w - doorWidth) / 2
			for _, sign in { -1, 1 } do
				part({
					Name = "Wall",
					Size = Vector3.new(sideW, h, wallT),
					CFrame = CFrame.new(centre + Vector3.new(sign * (doorWidth / 2 + sideW / 2), h / 2, d / 2)),
					Color = wallColor,
					Material = mat,
					Parent = parent,
				})
			end
			part({
				Name = "Wall",
				Size = Vector3.new(doorWidth, h - doorHeight, wallT),
				CFrame = CFrame.new(centre + Vector3.new(0, doorHeight + (h - doorHeight) / 2, d / 2)),
				Color = wallColor,
				Material = mat,
				Parent = parent,
			})
		else
			part({
				Name = "Wall",
				Size = wall[1],
				CFrame = CFrame.new(centre + wall[2]),
				Color = wallColor,
				Material = mat,
				Parent = parent,
			})
		end
	end

	-- Windows: punch light through with translucent panes (decorative only).
	part({
		Name = "Floor",
		Size = Vector3.new(w, 0.6, d),
		CFrame = CFrame.new(centre + Vector3.new(0, 0.3, 0)),
		Color = colour("#544e46"),
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})
	part({
		Name = "Roof",
		Size = Vector3.new(w + 2, 0.8, d + 2),
		CFrame = CFrame.new(centre + Vector3.new(0, h, 0)),
		Color = colour("#3a352f"),
		Material = Enum.Material.Slate,
		Parent = parent,
	})

	-- Return the interior volume so furniture can be placed.
	local inset = 5
	return {
		Vector3.new(centre.X - w / 2 + inset, 0.6, centre.Z - d / 2 + inset),
		Vector3.new(centre.X + w / 2 - inset, 0.6, centre.Z + d / 2 - inset),
	}
end

--[[
	A waist-high crate / barrier used to exercise the vault mechanic.
]]
local function buildVaultBarrier(parent: Instance, pos: Vector3, size: Vector3): Part
	local barrier = part({
		Name = "VaultBarrier",
		Size = size,
		CFrame = CFrame.new(pos) * CFrame.Angles(0, rng:NextNumber() * math.pi, 0),
		Color = colour("#5a5348"),
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})
	CollectionService:AddTag(barrier, WorldBuilder.BLOCKER_TAG)
	barrier:SetAttribute("Vaultable", size.Y <= Config.Movement.VaultMaxHeight)
	return barrier
end

--[[
	A chest-high ledge used to exercise the mantle mechanic.
]]
local function buildLedge(parent: Instance, pos: Vector3, size: Vector3): Part
	local ledge = part({
		Name = "Ledge",
		Size = size,
		CFrame = CFrame.new(pos) * CFrame.Angles(0, rng:NextNumber() * math.pi, 0),
		Color = colour("#6d675c"),
		Material = Enum.Material.Concrete,
		Parent = parent,
	})
	CollectionService:AddTag(ledge, WorldBuilder.BLOCKER_TAG)
	ledge:SetAttribute("Vaultable", false)
	return ledge
end

-- ------------------------------------------------------------- interactables --

--[[
	A two-part drawer: an anchored carcass and a sliding box. The interaction
	service tweens the box along `direction` by `travel` studs.
]]
local function buildDrawer(parent: Instance, pos: Vector3, yaw: number, low: boolean): Model
	local model = Instance.new("Model")
	model.Name = "Drawer"
	model.Parent = parent

	local height = if low then 3.2 else 5.0
	local width = 6
	local depth = 5

	local carcass = part({
		Name = "Base",
		Size = Vector3.new(width, height, depth),
		CFrame = CFrame.new(pos + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, yaw, 0),
		Color = colour("#7a6a52"),
		Material = Enum.Material.Wood,
		Parent = model,
	})

	local slideCF = carcass.CFrame * CFrame.new(0, 0, depth / 2 + 0.35)
	local slide = part({
		Name = "Slide",
		Size = Vector3.new(width - 1, height - 1.2, 0.7),
		CFrame = slideCF,
		Color = colour("#8a7a60"),
		Material = Enum.Material.Wood,
		Parent = model,
	})
	local knob = part({
		Name = "Knob",
		Size = Vector3.new(2.2, 0.5, 0.5),
		CFrame = slideCF * CFrame.new(0, 0, 0.6),
		Color = colour("#3c3630"),
		Material = Enum.Material.Metal,
		Parent = slide,
	})
	local knobWeld = Instance.new("WeldConstraint")
	knobWeld.Part0 = slide
	knobWeld.Part1 = knob
	knobWeld.Parent = slide

	model.PrimaryPart = slide
	model:SetAttribute("Type", "Drawer")
	model:SetAttribute("Open", false)
	model:SetAttribute("Low", low)
	model:SetAttribute("ClosedCFrame", slideCF)
	-- The drawer front faces +Z in the carcass's local space, which is the
	-- opposite of its LookVector (-Z), so the slide travels along -LookVector.
	model:SetAttribute("Direction", -carcass.CFrame.LookVector)
	model:SetAttribute("Travel", depth * 0.7)
	model:SetAttribute("Label", if low then "Открыть ящик (внизу)" else "Открыть ящик")
	CollectionService:AddTag(model, WorldBuilder.INTERACTABLE_TAG)
	return model
end

--[[
	A cabinet with one or two hinged doors.
]]
local function buildCabinet(parent: Instance, pos: Vector3, yaw: number, doors: number): Model
	local model = Instance.new("Model")
	model.Name = "Cabinet"
	model.Parent = parent

	local height = 11
	local width = 9
	local depth = 4

	local frame = part({
		Name = "Base",
		Size = Vector3.new(width, height, depth),
		CFrame = CFrame.new(pos + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, yaw, 0),
		Color = colour("#6f5f47"),
		Material = Enum.Material.Wood,
		Parent = model,
	})
	part({
		Name = "Shelf",
		Size = Vector3.new(width - 1, 0.4, depth - 0.6),
		CFrame = frame.CFrame * CFrame.new(0, 0, 0),
		Color = colour("#5c4f3c"),
		Material = Enum.Material.Wood,
		Parent = frame,
	})

	for i = 1, doors do
		local doorW = width / doors - 0.6
		-- For a single door the hinge is on the left; for a pair the doors
		-- hinge outward from the centre.
		local side = if doors == 1 then -1 elseif i == 1 then -1 else 1
		local hinge = frame.CFrame * CFrame.new(side * (width / 2), 0, depth / 2 + 0.35)
		-- The door hangs half its width inboard of the hinge, so it pivots
		-- about its edge rather than its centre.
		local offset = CFrame.new(-side * doorW / 2, 0, 0)
		local door = part({
			Name = "Door" .. i,
			Size = Vector3.new(doorW, height - 1, 0.5),
			CFrame = hinge * offset,
			Color = colour("#7d6c52"),
			Material = Enum.Material.Wood,
			Parent = model,
		})
		door.CanCollide = true
		door:SetAttribute("Hinge", hinge)
		door:SetAttribute("HingeOffset", offset)
		door:SetAttribute("Side", side)
		door:SetAttribute("DoorIndex", i)
	end

	model.PrimaryPart = frame
	model:SetAttribute("Type", "Cabinet")
	model:SetAttribute("Open", false)
	model:SetAttribute("Doors", doors)
	model:SetAttribute("Label", "Открыть шкаф")
	CollectionService:AddTag(model, WorldBuilder.INTERACTABLE_TAG)
	return model
end

--[[
	A shelf unit with attachment points where loot is placed.
]]
local function buildShelf(parent: Instance, pos: Vector3, yaw: number): Model
	local model = Instance.new("Model")
	model.Name = "Shelf"
	model.Parent = parent

	local height = 12
	local width = 10
	local depth = 3.5
	local baseCF = CFrame.new(pos + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, yaw, 0)

	local frame = part({
		Name = "Base",
		Size = Vector3.new(width, height, depth),
		CFrame = baseCF,
		Color = colour("#63543f"),
		Material = Enum.Material.Wood,
		Parent = model,
	})
	for level = 1, 3 do
		local y = -height / 2 + 2.6 + (level - 1) * 4.2
		part({
			Name = "Board" .. level,
			Size = Vector3.new(width - 0.8, 0.4, depth - 0.6),
			CFrame = baseCF * CFrame.new(0, y, 0),
			Color = colour("#52452f"),
			Material = Enum.Material.Wood,
			Parent = frame,
		})
		-- Attachments must hang off a BasePart for WorldPosition to be
		-- meaningful, so they ride the frame rather than a folder.
		local attach = Instance.new("Attachment")
		attach.Name = "Loot" .. level
		attach.CFrame = CFrame.new(0, y + 1.2, 0)
		attach.Parent = frame
	end

	model.PrimaryPart = frame
	model:SetAttribute("Type", "Shelf")
	model:SetAttribute("Label", "Обыскать полку")
	CollectionService:AddTag(model, WorldBuilder.INTERACTABLE_TAG)
	return model
end

-- ---------------------------------------------------------------- vegetation --

--[[
	Grass clumps. Each clump is a folder of thin anchored blades tagged "Grass"
	so the stealth service can test containment cheaply with a bounding box.
]]
local function buildGrass(parent: Instance, pos: Vector3, radius: number)
	local clump = Instance.new("Model")
	clump.Name = "GrassClump"
	clump.Parent = parent

	local blades = rng:NextInteger(6, 11)
	for _ = 1, blades do
		local height = randRange(2.4, 4.2)
		local blade = part({
			Name = "Blade",
			Size = Vector3.new(randRange(1.6, 3.0), height, randRange(0.15, 0.3)),
			CFrame = CFrame.new(
				pos + Vector3.new(randRange(-radius, radius), height / 2, randRange(-radius, radius))
			) * CFrame.Angles(randRange(-0.14, 0.14), rng:NextNumber() * math.pi, randRange(-0.2, 0.2)),
			Color = Color3.fromRGB(rng:NextInteger(60, 92), rng:NextInteger(84, 116), rng:NextInteger(48, 70)),
			Material = Enum.Material.Grass,
			CanCollide = false,
			Parent = clump,
		})
		blade.CanQuery = false
		blade.CanTouch = false
		blade.CastShadow = false
	end

	-- An invisible bounding volume drives the "am I in grass" test.
	local volume = part({
		Name = "Volume",
		Size = Vector3.new(radius * 2.4, 5, radius * 2.4),
		CFrame = CFrame.new(pos + Vector3.new(0, 2.5, 0)),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = clump,
	})
	volume:SetAttribute("GrassVolume", true)
	CollectionService:AddTag(volume, WorldBuilder.GRASS_TAG)
end

-- -------------------------------------------------------------- scatter pass --

local function scatterLootSpawns(parent: Instance, buildings: { { Vector3 } }, ground: Part)
	local folder = Instance.new("Folder")
	folder.Name = "LootSpawns"
	folder.Parent = parent

	local placed = 0
	local attempts = 0
	while placed < Config.World.LootSpawns and attempts < Config.World.LootSpawns * 12 do
		attempts += 1
		local x = randRange(-200, 200)
		local z = randRange(-200, 200)
		local hit = Util.raycastDown(Vector3.new(x, 200, z), 260, { ground })
		local y = if hit then hit.Position.Y else 0
		if not hit then
			y = ground.Position.Y + ground.Size.Y / 2
		end
		local point = part({
			Name = "LootSpawn",
			Size = Vector3.new(1, 1, 1),
			CFrame = CFrame.new(x, y + 0.6, z),
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Parent = folder,
		})
		point:SetAttribute("Used", false)
		CollectionService:AddTag(point, WorldBuilder.LOOT_TAG)
		placed += 1
	end
	return folder
end

local function scatterZombieSpawns(parent: Instance, ground: Part)
	local folder = Instance.new("Folder")
	folder.Name = "ZombieSpawns"
	folder.Parent = parent
	for _ = 1, Config.World.SpawnZombiesOnStart do
		local x = randRange(-280, 280)
		local z = randRange(-280, 280)
		local point = part({
			Name = "ZombieSpawn",
			Size = Vector3.new(1, 1, 1),
			CFrame = CFrame.new(x, 3, z),
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Parent = folder,
		})
		CollectionService:AddTag(point, WorldBuilder.ZOMBIE_TAG)
	end
	return folder
end

--[[
	The main entry point. Wipes any previously generated world (so re-running in
	Studio never stacks two towns) and rebuilds from scratch.
]]
function WorldBuilder.build(): Folder
	local existing = workspace:FindFirstChild("World")
	if existing then
		existing:Destroy()
	end
	-- Also remove a default Baseplate if one exists.
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		baseplate:Destroy()
	end

	local world = Instance.new("Folder")
	world.Name = "World"
	world.Parent = workspace

	local structures = Instance.new("Folder")
	structures.Name = "Structures"
	structures.Parent = world
	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = world
	local vegetation = Instance.new("Folder")
	vegetation.Name = "Vegetation"
	vegetation.Parent = world

	local ground = buildGround(world)

	-- ---- town layout -------------------------------------------------------
	local buildingCount = rng:NextInteger(7, 10)
	local buildingPositions: { Vector3 } = {}
	local buildingVolumes: { { Vector3 } } = {}
	local gridStep = 90
	local cols = 3
	for i = 1, buildingCount do
		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)
		local w = randRange(34, 54)
		local d = randRange(34, 54)
		local h = randRange(14, 22)
		local centre = Vector3.new(
			(col - (cols - 1) / 2) * gridStep + randRange(-10, 10),
			0,
			(row - 1) * gridStep + randRange(-10, 10)
		)
		table.insert(buildingPositions, centre)
		local volume = buildBuilding(structures, centre, w, d, h)
		table.insert(buildingVolumes, volume)

		-- Interior furniture.
		local min, max = volume[1], volume[2]
		local interior = CFrame.new((min.X + max.X) / 2, 0.6, (min.Z + max.Z) / 2)
		local roomW = math.max(6, max.X - min.X)
		local roomD = math.max(6, max.Z - min.Z)
		local propCount = rng:NextInteger(3, 6)
		for _ = 1, propCount do
			local localPos = Vector3.new(
				randRange(-roomW / 2 + 3, roomW / 2 - 3),
				0.6,
				randRange(-roomD / 2 + 3, roomD / 2 - 3)
			)
			local worldPos = interior:ToWorldSpace(CFrame.new(localPos)).Position
			local yaw = rng:NextNumber() * math.pi * 2
			local roll = rng:NextNumber()
			if roll < 0.4 then
				buildDrawer(props, worldPos, yaw, rng:NextNumber() < 0.5)
			elseif roll < 0.7 then
				buildCabinet(props, worldPos, yaw, if rng:NextNumber() < 0.5 then 1 else 2)
			else
				buildShelf(props, worldPos, yaw)
			end
		end
	end

	-- ---- street furniture, barriers and ledges -----------------------------
	for _ = 1, 26 do
		local pos = Vector3.new(randRange(-260, 260), 0, randRange(-260, 260))
		local yaw = rng:NextNumber() * math.pi * 2
		local roll = rng:NextNumber()
		if roll < 0.35 then
			buildDrawer(props, pos, yaw, rng:NextNumber() < 0.4)
		elseif roll < 0.6 then
			buildCabinet(props, pos, yaw, if rng:NextNumber() < 0.5 then 1 else 2)
		elseif roll < 0.8 then
			buildShelf(props, pos, yaw)
		else
			buildVaultBarrier(structures, pos + Vector3.new(0, 2.2, 0), Vector3.new(randRange(6, 12), randRange(3.5, 4.6), 2.5))
		end
	end

	-- Ledge clusters that invite mantling onto rooftops and containers.
	for _ = 1, 16 do
		local pos = Vector3.new(randRange(-240, 240), 0, randRange(-240, 240))
		local h = randRange(Config.Movement.MantleHeightMin + 0.6, Config.Movement.MantleHeightMax - 0.4)
		buildLedge(structures, pos + Vector3.new(0, h / 2, 0), Vector3.new(randRange(12, 20), h, randRange(10, 16)))
	end

	-- ---- grass -------------------------------------------------------------
	for _ = 1, Config.World.GrassClumps do
		local pos = Vector3.new(randRange(-320, 320), 0.2, randRange(-320, 320))
		-- Keep grass out of building interiors by rejecting points too close to
		-- a building centre.
		local tooClose = false
		for _, centre in buildingPositions do
			if (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(centre.X, 0, centre.Z)).Magnitude < 30 then
				tooClose = true
				break
			end
		end
		if not tooClose then
			buildGrass(vegetation, pos, randRange(4, 7))
		end
	end

	-- ---- spawn points ------------------------------------------------------
	scatterLootSpawns(world, buildingVolumes, ground)
	scatterZombieSpawns(world, ground)

	-- Player spawn markers so people do not start inside a wall.
	local spawnFolder = Instance.new("Folder")
	spawnFolder.Name = "PlayerSpawns"
	spawnFolder.Parent = world
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		local sp = Instance.new("SpawnLocation")
		sp.Name = "PlayerSpawn" .. i
		sp.Size = Vector3.new(6, 1, 6)
		sp.CFrame = CFrame.new(math.cos(angle) * 40, 2, math.sin(angle) * 40)
		sp.Anchored = true
		sp.Transparency = 1
		sp.CanCollide = false
		sp.CanQuery = false
		sp.Neutral = true
		sp.Duration = 0
		sp.Parent = spawnFolder
	end

	-- Remove the default spawn so our own markers are used.
	for _, child in workspace:GetChildren() do
		if child:IsA("SpawnLocation") and child.Parent == workspace then
			child:Destroy()
		end
	end

	return world
end

return WorldBuilder
