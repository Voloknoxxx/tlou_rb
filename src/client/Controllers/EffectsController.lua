--!strict
--[[
	EffectsController
	All cosmetic feedback: tracers, muzzle flashes, ejected shells,
	bullet impacts (decals + sparks + dust), blood, explosions, smoke and
	the camera shake that ties them together.

	Everything here is client-only and disposable - it never affects
	gameplay, so it can be dialled up or down freely for performance.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)

local State = require(script.Parent.State)

local EffectsController = {}

local camera = workspace.CurrentCamera

local MATERIAL_COLORS = {
	[Enum.Material.Metal] = Color3.fromRGB(200, 200, 205),
	[Enum.Material.Concrete] = Color3.fromRGB(170, 170, 165),
	[Enum.Material.Wood] = Color3.fromRGB(120, 90, 55),
	[Enum.Material.Brick] = Color3.fromRGB(150, 80, 66),
	[Enum.Material.Glass] = Color3.fromRGB(190, 220, 230),
	[Enum.Material.Fabric] = Color3.fromRGB(110, 100, 90),
	[Enum.Material.Grass] = Color3.fromRGB(80, 110, 60),
	[Enum.Material.Sand] = Color3.fromRGB(190, 170, 120),
	[Enum.Material.Slate] = Color3.fromRGB(90, 90, 95),
}

local function colorForMaterial(material: Enum.Material?): Color3
	if material and MATERIAL_COLORS[material] then
		return MATERIAL_COLORS[material]
	end
	return Color3.fromRGB(160, 160, 160)
end

--- A bright stretched beam from origin toward target.
function EffectsController.spawnTracer(origin: Vector3, target: Vector3, silenced: boolean)
	local delta = target - origin
	local distance = delta.Magnitude
	if distance < 0.1 then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "TLoUTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = silenced and Color3.fromRGB(120, 160, 200) or Color3.fromRGB(255, 220, 130)
	tracer.Size = Vector3.new(0.06, 0.06, distance)
	tracer.CFrame = CFrame.new(origin + delta * 0.5, target)
	tracer.Transparency = 0.25
	tracer.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = tracer.Color
	light.Range = 6
	light.Brightness = 1
	light.Parent = tracer

	Debris:AddItem(tracer, Config.Visual.TracerTime)
end

--- Short-lived star of neon at the muzzle.
function EffectsController.spawnMuzzleFlash(muzzle: BasePart)
	if not muzzle then
		return
	end

	local flash = Instance.new("Part")
	flash.Name = "TLoUMuzzleFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 200, 90)
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(0.45, 0.45, 0.45)
	flash.CFrame = muzzle.CFrame
	flash.Transparency = 0.05
	flash.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 190, 110)
	light.Range = 12
	light.Brightness = 3
	light.Parent = flash

	Debris:AddItem(flash, Config.Visual.MuzzleFlashTime)
end

--- Ejects a small brass shell that tumbles away from the weapon.
function EffectsController.ejectShell(weaponHandle: BasePart?, data): void
	if not weaponHandle or not data then
		return
	end
	-- Only firearms eject brass; bows and melee do not.
	if data.category ~= "Firearm" or data.model == "Bow" then
		return
	end

	local shell = Instance.new("Part")
	shell.Name = "TLoUShell"
	shell.Size = Vector3.new(0.06, 0.06, 0.22)
	shell.Color = Color3.fromRGB(200, 165, 70)
	shell.Material = Enum.Material.Metal
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CFrame = weaponHandle.CFrame * CFrame.new(0.25, 0.05, 0.2)
	shell.Parent = workspace

	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.Velocity = weaponHandle.CFrame.RightVector * Config.Visual.ShellEjectSpeed
		+ Vector3.new(0, 6, 0)
	bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bodyVelocity.Parent = shell

	local spin = Instance.new("BodyAngularVelocity")
	spin.AngularVelocity = Vector3.new(math.random(-20, 20), math.random(-20, 20), math.random(-20, 20))
	spin.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	spin.Parent = shell

	Debris:AddItem(shell, 2)
end

--- Bullet impact: dust puff, spark, decal and a puff of debris.
function EffectsController.spawnImpact(position: Vector3, normal: Vector3, material: Enum.Material?)
	local color = colorForMaterial(material)

	-- Dust puff.
	local puff = Instance.new("Part")
	puff.Name = "TLoUImpact"
	puff.Anchored = true
	puff.CanCollide = false
	puff.CanQuery = false
	puff.Material = Enum.Material.SmoothPlastic
	puff.Color = color
	puff.Shape = Enum.PartType.Ball
	puff.Size = Vector3.new(0.35, 0.35, 0.35)
	puff.CFrame = CFrame.new(position + normal * 0.1)
	puff.Transparency = 0.3
	puff.Parent = workspace

	local tween = game:GetService("TweenService"):Create(puff, TweenInfo.new(0.35), {
		Size = Vector3.new(1.2, 1.2, 1.2),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(puff, 0.4)

	-- Spark flash.
	local spark = Instance.new("Part")
	spark.Name = "TLoUSpark"
	spark.Anchored = true
	spark.CanCollide = false
	spark.CanQuery = false
	spark.Material = Enum.Material.Neon
	spark.Color = Color3.fromRGB(255, 230, 150)
	spark.Size = Vector3.new(0.12, 0.12, 0.12)
	spark.CFrame = CFrame.new(position)
	spark.Parent = workspace
	Debris:AddItem(spark, 0.08)

	-- Decal on the hit surface.
	local decal = Instance.new("Part")
	decal.Name = "TLoUBulletHole"
	decal.Anchored = true
	decal.CanCollide = false
	decal.CanQuery = false
	decal.Material = Enum.Material.SmoothPlastic
	decal.Color = Color3.fromRGB(20, 18, 16)
	decal.Size = Vector3.new(0.18, 0.18, 0.02)
	decal.CFrame = CFrame.new(position + normal * 0.02, position + normal * 0.02 + normal)
	decal.Transparency = 0.15
	decal.Parent = workspace
	Debris:AddItem(decal, Config.Visual.HitDecalLifetime)
end

--- Blood burst on a character hit.
function EffectsController.spawnBlood(position: Vector3, normal: Vector3)
	local blood = Instance.new("Part")
	blood.Name = "TLoUBlood"
	blood.Anchored = true
	blood.CanCollide = false
	blood.CanQuery = false
	blood.Material = Enum.Material.SmoothPlastic
	blood.Color = Color3.fromRGB(120, 20, 18)
	blood.Shape = Enum.PartType.Ball
	blood.Size = Vector3.new(0.4, 0.4, 0.4)
	blood.CFrame = CFrame.new(position + normal * 0.1)
	blood.Transparency = 0.15
	blood.Parent = workspace

	local tween = game:GetService("TweenService"):Create(blood, TweenInfo.new(Config.Visual.BloodTime), {
		Size = Vector3.new(0.9, 0.9, 0.9),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(blood, Config.Visual.BloodTime + 0.1)
end

--- Fireball + shockwave for explosives.
function EffectsController.spawnExplosion(position: Vector3, weaponId: string)
	local isSmoke = weaponId == "SmokeBomb"

	local core = Instance.new("Part")
	core.Name = "TLoUExplosion"
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.Material = Enum.Material.Neon
	core.Shape = Enum.PartType.Ball
	core.Color = isSmoke and Color3.fromRGB(200, 200, 200) or Color3.fromRGB(255, 140, 40)
	core.Size = Vector3.new(2, 2, 2)
	core.CFrame = CFrame.new(position)
	core.Transparency = 0.1
	core.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = core.Color
	light.Range = 24
	light.Brightness = 6
	light.Parent = core

	local tween = game:GetService("TweenService"):Create(core, TweenInfo.new(isSmoke and 1.2 or 0.5), {
		Size = Vector3.new(isSmoke and 14 or 8, isSmoke and 14 or 8, isSmoke and 14 or 8),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(core, isSmoke and 1.4 or 0.6)

	if isSmoke then
		for _ = 1, 10 do
			local puff = Instance.new("Part")
			puff.Anchored = true
			puff.CanCollide = false
			puff.CanQuery = false
			puff.Material = Enum.Material.SmoothPlastic
			puff.Color = Color3.fromRGB(180, 180, 180)
			puff.Shape = Enum.PartType.Ball
			puff.Size = Vector3.new(4, 4, 4)
			puff.CFrame = CFrame.new(position + Vector3.new(math.random(-5, 5), math.random(0, 4), math.random(-5, 5)))
			puff.Transparency = 0.5
			puff.Parent = workspace
			local puffTween = game:GetService("TweenService"):Create(puff, TweenInfo.new(4), {
				Size = Vector3.new(12, 12, 12),
				Transparency = 1,
			})
			puffTween:Play()
			Debris:AddItem(puff, 4.2)
		end
	end

	-- Camera shake scaled by distance.
	if camera then
		local distance = (camera.CFrame.Position - position).Magnitude
		local intensity = math.clamp(1 - distance / 40, 0, 1) * Config.Visual.CameraShakeIntensity * 3
		if intensity > 0.05 then
			State.Signals.Shake:Fire(intensity, 0.4)
		end
	end
end

--- Melee swing whoosh / hit spark.
function EffectsController.spawnMelee(character: Model?, weaponId: string, hit: boolean)
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local swing = Instance.new("Part")
	swing.Name = "TLoUMeleeArc"
	swing.Anchored = true
	swing.CanCollide = false
	swing.CanQuery = false
	swing.Material = Enum.Material.Neon
	swing.Color = hit and Color3.fromRGB(255, 200, 120) or Color3.fromRGB(180, 180, 180)
	swing.Size = Vector3.new(0.1, 0.1, 4)
	swing.CFrame = root.CFrame * CFrame.new(0, 0, -3)
	swing.Transparency = 0.5
	swing.Parent = workspace
	Debris:AddItem(swing, 0.12)
end

function EffectsController.init()
	State.Signals.HitFeedback:Connect(function(payload)
		-- Handled by the HUD for the hitmarker; blood is spawned below
		-- when we know the world position.
	end)
end

return EffectsController
