--!strict
--[[
	WeaponVisualController
	Puts a weapon model in every other player's hand.

	In first person you only ever see your own gun, so this did not need to
	exist. In third person every character is on screen, and a character
	walking around with empty hands while the server says they are holding a
	rifle breaks the illusion instantly.

	The server records what each player holds as an "EquippedWeapon"
	attribute on their character. Attributes replicate and are replayed to
	players who join later, so this controller needs no networking of its
	own - it just watches the attribute and rebuilds the model when it
	changes.

	The local player's own weapon is handled by WeaponController (which also
	drives firing), so this one skips them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)

local State = require(script.Parent.State)

local WeaponVisualController = {}

local player = Players.LocalPlayer

--- character -> { model, weld, connection }
local attached: { [Model]: any } = {}

--- The same grip offset WeaponController uses, so the local player's weapon
--- and everyone else's sit in the hand identically.
local function gripOffsetFor(data): CFrame
	local align = CFrame.Angles(math.rad(-90), 0, 0)
	if data.category == "Melee" then
		return CFrame.new(0, -1.1, -0.1) * align * CFrame.Angles(math.rad(-20), 0, 0)
	elseif data.model == "Pistol" or data.model == "Revolver" then
		return CFrame.new(0, -0.85, 0.05) * align
	end
	return CFrame.new(0, -1, 0) * align
end

local function detach(character: Model)
	local entry = attached[character]
	if not entry then
		return
	end
	if entry.connection then
		entry.connection:Disconnect()
	end
	if entry.model then
		entry.model:Destroy()
	end
	attached[character] = nil
end

local function attach(character: Model, weaponId: string?)
	detach(character)

	if not weaponId then
		return
	end
	local data = Weapons.get(weaponId)
	if not data or data.category == "Throwable" then
		return
	end

	local arm = character:FindFirstChild("Right Arm")
	if not arm or not arm:IsA("BasePart") then
		return
	end

	local model = WeaponModels.build(data)
	model.Parent = character
	local handle = model.PrimaryPart
	if not handle then
		model:Destroy()
		return
	end

	local weld = Instance.new("Weld")
	weld.Name = "TLoUWeaponWeld"
	weld.Part0 = arm
	weld.Part1 = handle
	weld.C0 = gripOffsetFor(data)
	weld.C1 = CFrame.new()
	weld.Parent = arm

	local entry = { model = model, weld = weld, connection = nil }

	-- If the arm is replaced (a respawn or a rig swap), the weld dies with
	-- it. Re-attach rather than leaving the weapon floating.
	entry.connection = arm.Destroying:Connect(function()
		if attached[character] == entry then
			attached[character] = nil
			entry.model:Destroy()
		end
	end)

	attached[character] = entry
end

local function watch(character: Model)
	if not character:IsA("Model") then
		return
	end
	if character == player.Character then
		return -- the local player's weapon is WeaponController's job
	end
	if not character:FindFirstChildOfClass("Humanoid") then
		return
	end

	-- Wait for the arm to exist before welding anything to it.
	task.spawn(function()
		local arm = character:WaitForChild("Right Arm", 5)
		if not arm then
			return
		end
		attach(character, character:GetAttribute("EquippedWeapon"))

		character:GetAttributeChangedSignal("EquippedWeapon"):Connect(function()
			if attached[character] then
				detach(character)
			end
			attach(character, character:GetAttribute("EquippedWeapon"))
		end)
	end)
end

function WeaponVisualController.init()
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other.Character then
			watch(other.Character)
		end
		other.CharacterAdded:Connect(watch)
	end

	Players.PlayerAdded:Connect(function(other)
		other.CharacterAdded:Connect(watch)
		if other.Character then
			watch(other.Character)
		end
	end)

	Players.PlayerRemoving:Connect(function(other)
		if other.Character then
			detach(other.Character)
		end
	end)

	workspace.ChildRemoved:Connect(function(child)
		if child:IsA("Model") and attached[child] then
			detach(child)
		end
	end)
end

return WeaponVisualController
