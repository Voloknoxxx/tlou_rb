--!strict
--[[
	Util
	Small shared helpers used by both the client and the server.
]]

local Util = {}

function Util.clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

function Util.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--[[
	Frame-rate independent exponential smoothing.
	`speed` is roughly "how many e-folds per second".
]]
function Util.damp(current: number, target: number, speed: number, dt: number): number
	return target + (current - target) * math.exp(-speed * dt)
end

--[[
	A critically-damped spring, the classic Game Programming Gems formulation.
	Great for camera work because it never overshoots.
]]
function Util.smoothDamp(current: number, target: number, velocity: number, smoothTime: number, dt: number): (number, number)
	local omega = 2 / math.max(smoothTime, 1e-4)
	local x = omega * dt
	local exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	local temp = (velocity + omega * change) * dt
	velocity = (velocity - omega * temp) * exp
	local output = target + (change + temp) * exp
	return output, velocity
end

function Util.smoothDampVec3(current: Vector3, target: Vector3, velocity: Vector3, smoothTime: number, dt: number): (Vector3, Vector3)
	local x, vx = Util.smoothDamp(current.X, target.X, velocity.X, smoothTime, dt)
	local y, vy = Util.smoothDamp(current.Y, target.Y, velocity.Y, smoothTime, dt)
	local z, vz = Util.smoothDamp(current.Z, target.Z, velocity.Z, smoothTime, dt)
	return Vector3.new(x, y, z), Vector3.new(vx, vy, vz)
end

--[[
	Shortest-path angle interpolation (degrees in, degrees out).
]]
function Util.lerpAngle(a: number, b: number, t: number): number
	local delta = ((b - a + 180) % 360) - 180
	return a + delta * t
end

--[[
	Deterministic-ish value noise in [-1, 1] from a seed and a time.
	Cheap and smooth; used for camera sway and zombie idle jitter.
]]
function Util.noise(seed: number, t: number): number
	local x = math.sin((seed * 127.1 + t * 311.7)) * 43758.5453
	return (x - math.floor(x)) * 2 - 1
end

function Util.round(n: number, decimals: number?): number
	local m = 10 ^ (decimals or 0)
	return math.floor(n * m + 0.5) / m
end

function Util.isAlive(character: Model?): boolean
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function Util.getRoot(character: Model?): BasePart?
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
	Raycasts straight down and returns the surface position + normal, or nil.
	Used for ground snapping, grass checks and mantle probing.
]]
function Util.raycastDown(origin: Vector3, distance: number, ignore: { Instance }?): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore or {}
	params.IgnoreWater = true
	return workspace:Raycast(origin, Vector3.new(0, -distance, 0), params)
end

function Util.raycast(from: Vector3, dir: Vector3, ignore: { Instance }?, collisionGroup: string?): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore or {}
	params.IgnoreWater = true
	if collisionGroup then
		params.CollisionGroup = collisionGroup
	end
	return workspace:Raycast(from, dir, params)
end

--[[
	Builds a raycast filter that ignores every descendant of the given models.
]]
function Util.filterFor(models: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = models
	params.IgnoreWater = true
	return params
end

function Util.waitForChild(parent: Instance, name: string, timeout: number?): Instance?
	local deadline = os.clock() + (timeout or 5)
	repeat
		local child = parent:FindFirstChild(name)
		if child then
			return child
		end
		task.wait(0.05)
	until os.clock() > deadline
	return nil
end

return Util
