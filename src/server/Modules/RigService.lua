--!strict
--[[
	RigService
	Guarantees every player spawns as a classic R6 character.

	The place itself is generated with R6 as the avatar type, so in a normal
	game this service has nothing to do. It exists for the cases where that
	is not enough:

	* The place setting can be overridden per experience, and a player who
	  joined an R15 experience first can carry an R15 body in.
	* Group places, Team Create sessions and cloned places routinely drift
	  away from the intended avatar type.

	So the rule here is simple: whatever arrives, the player leaves with an
	R6 body. We check the rig, and if it is not R6 we rebuild it in place,
	preserving position, velocity and health.

	We also disable the stock "Animate" script. It plays R15-style
	animation tracks that would fight our animator for control of the same
	Motor6Ds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Config = require(Shared.Config)
local R6Rig = require(Shared.R6Rig)

local RigService = {}

local RIG = Config.Rig

--- Stops Roblox's default animation script from driving the joints.
local function disableDefaultAnimate(character: Model)
	if not RIG.DisableDefaultAnimate then
		return
	end

	local function suppress()
		local animate = character:FindFirstChild("Animate")
		if animate then
			animate:Destroy()
		end
		local animator = character:FindFirstChildOfClass("Animator")
		if animator then
			-- Our animator drives Motor6D.Transform. The Animator instance would
			-- keep any playing tracks alive and blend them into the same joints,
			-- so stop them.
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0)
			end
		end
	end

	suppress()

	-- The `Animate` script is parented to the character a moment after it
	-- spawns, so it is often absent when this first runs. Keep watching, or it
	-- starts on every client and its tracks make the Animator rewrite every
	-- Motor6D.Transform - which silently discards our pose. The client animator
	-- repeats this check for the same reason.
	local connection
	connection = character.ChildAdded:Connect(function(child)
		if child.Name == "Animate" or child:IsA("Animator") then
			suppress()
		end
	end)
	character.Destroying:Connect(function()
		if connection then
			connection:Disconnect()
		end
	end)
end

--- Applies R6 rules to a character that is already the right rig.
local function prepareR6(character: Model)
	disableDefaultAnimate(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- R6 keeps its feet on the floor through the part positions alone;
		-- a non-zero HipHeight would float the character.
		humanoid.HipHeight = 0
		humanoid.AutoRotate = false
		humanoid.UseJumpPower = true
		humanoid.JumpPower = Config.Movement.JumpPower
		humanoid.BreakJointsOnDeath = false
	end

	-- Hide accessories and layered clothing that assume an R15 body; on R6
	-- they float around the torso.
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Accessory") or descendant:IsA("Accoutrement") then
			descendant:Destroy()
		elseif descendant:IsA("Shirt") or descendant:IsA("Pants") or descendant:IsA("ShirtGraphic") then
			-- These are fine on R6; leave them.
			continue
		end
	end
end

--- Rebuilds a non-R6 character as R6 and hands the player the new body.
local function enforceR6(player: Player, character: Model): Model
	if R6Rig.isR6(character) then
		prepareR6(character)
		return character
	end

	local converted = R6Rig.convertToR6(character)
	if not converted then
		-- Could not convert (a body with no HumanoidRootPart, say). Leave
		-- the character alone rather than deleting it.
		return character
	end

	prepareR6(converted)
	player.Character = converted
	return converted
end

--- Sets the player's character to R6, however it arrives.
function RigService.setupCharacter(player: Player, character: Model)
	-- The rig can be assembled asynchronously, so wait for the Humanoid
	-- before deciding anything.
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	if RIG.ForceR6 then
		character = enforceR6(player, character)
	end

	-- Re-announce the character so controllers that bound to the old model
	-- pick up the new one. Setting player.Character already fires
	-- CharacterAdded, so this is only needed when the model did not change.
	character:SetAttribute("RigType", "R6")
end

function RigService.init()
	if not RIG.ForceR6 then
		return
	end

	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			RigService.setupCharacter(player, character)
		end)
		if player.Character then
			RigService.setupCharacter(player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(watch)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
end

return RigService
