--!strict
--[[
	Bootstrap (StarterPlayerScripts)
	Starts every client controller in dependency order. Put this in
	StarterPlayerScripts as a LocalScript, with the "Controllers" folder
	as a sibling.

	Order matters: State -> Network -> Movement -> Animator -> Camera ->
	Effects -> Weapon -> HUD. The animator must exist before the camera
	(the camera turns the body, and the animator reads the resulting turn
	rate), and State must exist before anything else.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TLoU = ReplicatedStorage:WaitForChild("TLoU")
local Shared = TLoU:WaitForChild("Shared")

local Net = require(Shared.Net) -- ensures remotes exist before use

local Controllers = script.Parent:WaitForChild("Controllers")

local State = require(Controllers:WaitForChild("State"))
local NetworkController = require(Controllers:WaitForChild("NetworkController"))
local MovementController = require(Controllers:WaitForChild("MovementController"))
local AnimatorController = require(Controllers:WaitForChild("AnimatorController"))
local CameraController = require(Controllers:WaitForChild("CameraController"))
local EffectsController = require(Controllers:WaitForChild("EffectsController"))
local WeaponController = require(Controllers:WaitForChild("WeaponController"))
local WeaponVisualController = require(Controllers:WaitForChild("WeaponVisualController"))
local HUDController = require(Controllers:WaitForChild("HUDController"))

-- Expose State globally so other scripts (and the console) can inspect it.
_G.TLoUState = State

HUDController.init()
NetworkController.init()
MovementController.init()
AnimatorController.init()
CameraController.init()
EffectsController.init()
WeaponController.init()
WeaponVisualController.init()

-- Tell the server we are ready and ask for a fresh copy of our state.
-- This covers the spawn race where the loadout was sent before our
-- listeners existed.
Net.toServer("Ready")

-- Keep the camera reference fresh if the viewport changes.
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	State.camera = workspace.CurrentCamera
end)

print("[TLoU] Client mechanics online.")
