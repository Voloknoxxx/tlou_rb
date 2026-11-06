--!strict
--[[
	Signal
	Minimal synchronous event emitter. Good enough for intra-client
	controller coordination and has no dependencies.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = { Disconnect: (self: Connection) -> () }
export type Signal = typeof(setmetatable({} :: { _handlers: { (...any) -> () } }, Signal))

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler: (...any) -> ()): Connection
	table.insert(self._handlers, handler)
	local connection
	connection = {
		Disconnect = function()
			local index = table.find(self._handlers, handler)
			if index then
				table.remove(self._handlers, index)
			end
		end,
	}
	return connection
end

function Signal:Fire(...)
	for _, handler in ipairs(self._handlers) do
		task.spawn(handler, ...)
	end
end

return Signal
