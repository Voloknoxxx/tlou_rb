--!strict
--[[
	Bootstrap (StarterPlayerScripts)
	Starts every client controller in dependency order. Put this in
	StarterPlayerScripts as a LocalScript, with the "Controllers" folder
	as a sibling.

	Order matters: State -> Network -> Movement -> Camera -> Effects ->
	Weapon -> HUD. Camera must exist before Weapon (it forwards recoil),
	and State must exist before anything else.
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
local CameraController = require(Controllers:WaitForChild("CameraController"))
local EffectsController = require(Controllers:WaitForChild("EffectsController"))
local WeaponController = require(Controllers:WaitForChild("WeaponController"))
local HUDController = require(Controllers:WaitForChild("HUDController"))

-- Expose State globally so other scripts (and the console) can inspect it.
_G.TLoUState = State

HUDController.init()
NetworkController.init()
MovementController.init()
CameraController.init()
EffectsController.init()
WeaponController.init()

-- Tell the server we are ready and ask for a fresh copy of our state.
-- This covers the spawn race where the loadout was sent before our
-- listeners existed.
Net.toServer("Ready")

-- Keep the camera reference fresh if the viewport changes.
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	State.camera = workspace.CurrentCamera
end)

print("[TLoU] Client mechanics online.")
