--!strict
--[[
	init.client
	----------------------------------------------------------------------------
	Client bootstrap. Starts every controller in dependency order and disables the
	default Roblox control module so our own movement controller is authoritative.

	Start order
		1. disable default controls
		2. wait for the first character
		3. attach the R6 animator to the character
		4. start camera -> movement -> weapons -> interaction -> HUD -> sound

	Every controller is independent once started; they communicate through
	ClientState rather than direct calls, so ordering only matters for the
	animator (which everything else drives).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local R6Animator = require(ReplicatedStorage.Shared.R6Animator)
local Config = require(ReplicatedStorage.Shared.Config)

local ClientState = require(script.ClientState)
local CameraController = require(script.CameraController)
local MovementController = require(script.MovementController)
local WeaponController = require(script.WeaponController)
local InteractionController = require(script.InteractionController)
local HUDController = require(script.HUDController)
local SoundController = require(script.SoundController)

local player = Players.LocalPlayer

--[[
	Disables the stock control module. Without this, the default controller
	fights our own Humanoid:Move calls and the camera would be driven twice.
]]
local function disableDefaultControls()
	local playerScripts = player:WaitForChild("PlayerScripts", 30)
	if not playerScripts then
		return
	end
	local playerModule = playerScripts:WaitForChild("PlayerModule", 30)
	if not playerModule then
		return
	end
	local ok, controls = pcall(function()
		return require(playerModule :: any):GetControls()
	end)
	if ok and controls and controls.Disable then
		controls:Disable()
	end
end

local function attachAnimator(character: Model)
	local animator = R6Animator.new(character)
	if animator then
		animator:setEnabled(true)
		ClientState.animator = animator
		ClientState.setCharacter(character)
		-- Drive the animator from the render step so it is always in sync with
		-- the camera and the character's transform.
		game:GetService("RunService").RenderStepped:Connect(function(dt)
			if ClientState.isAlive() then
				animator:step(dt)
			end
		end)
	end
end

local function main()
	disableDefaultControls()

	local character = player.Character or player.CharacterAdded:Wait()
	attachAnimator(character)

	player.CharacterAdded:Connect(function(newCharacter)
		task.wait(0.1)
		attachAnimator(newCharacter)
	end)

	CameraController.start()
	MovementController.start()
	WeaponController.start()
	InteractionController.start()
	HUDController.start()
	SoundController.start()

	-- Expose the tuned config so the README's tuning section maps to real code.
	local _ = Config
	local _ = StarterPlayer
end

main()
