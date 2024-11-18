local SignalConnection = {}
SignalConnection.ClassName = "Signal"
SignalConnection.__index = SignalConnection

function SignalConnection.new(container, index, handler)
    local self = setmetatable({}, SignalConnection)
    self._container = container
    self._index = index
    self._handler = handler
    return self
end

function SignalConnection:Disconnect()
	if self._container then
		self._container[self._index] = nil
	end
end

local Signal = {}
Signal.ClassName = "Signal"
Signal.__index = Signal

function Signal.new()
    local self = setmetatable({}, Signal)
    self._waits = {}
    self._handlers = {}
    return self
end

function Signal:Fire(...)
	for i, v in ipairs(self._waits) do
		coroutine.resume(v, ...)
		table.remove(self._waits, i)
	end

	for i, v in pairs(self._handlers) do
		local thread = coroutine.create(v._handler)
		coroutine.resume(thread, ...)
	end
end

function Signal:Connect(handler)
	assert(type(handler) == "function", "Passed value is not a function")

	local index = #self._handlers + 1
	local connection = SignalConnection.new(self._handlers, index, handler)

	table.insert(self._handlers, index, connection)
	return connection
end

function Signal:Wait()
	table.insert(self._waits, coroutine.running())
	return coroutine.yield()
end

function Signal:Destroy()
	for i, v in ipairs(self._waits) do
		coroutine.resume(v)
		table.remove(self._waits, i)
	end

	for i, connection in pairs(self._handlers) do
		connection:Disconnect()
	end
end

local TerminalProccessHandler = {}
TerminalProccessHandler.__index = TerminalProccessHandler

function TerminalProccessHandler:new(terminal)
    local self = setmetatable({}, self)
    self.terminal = terminal
    self.running_proccesses = {}

    self.proccess_runned = Signal.new()
    self.proccess_killed = Signal.new()
    return table.freeze(self)
end

function TerminalProccessHandler:get_proccess_id(object: any): string
    local _, id = table.unpack(string.split(tostring(object), ": "))
    return id
end

function TerminalProccessHandler:get_proccess(proccess_id: string): thread
    assert(proccess_id, `Proccess id is nil`)
    local proccess = self.running_proccesses[proccess_id]

    if not proccess then warn(`Proccess "{proccess_id}" isn't exists`) end
    return proccess
end

function TerminalProccessHandler:run(func: (...any) -> (), ...): string
    assert(func, "Proccess function is nil")
    local new_proccess = coroutine.create(func)
    local new_proccess_id = self:get_proccess_id(new_proccess)

    self.running_proccesses[new_proccess_id] = new_proccess
    coroutine.resume(new_proccess, self.terminal, ...)

    self.proccess_runned:Fire(new_proccess_id)
    return new_proccess_id
end

function TerminalProccessHandler:kill(proccess_id: string)
    local proccess = self:get_proccess(proccess_id)
    if not proccess then return end

    coroutine.close(proccess)
    self.running_proccesses[proccess_id] = nil
    self.proccess_killed:Fire(proccess_id)
end

local TerminalFileSystem = {}
TerminalFileSystem.__index = TerminalFileSystem

function TerminalFileSystem:new(terminal, file_system)
    local self = setmetatable({}, self)
    self.terminal = terminal
    self.file_system = file_system or FileSystem.new()
    return table.freeze(self)
end

function TerminalFileSystem:make_directory(path)
    self.file_system:mkdir(path)
end

function TerminalFileSystem:write(path: string, contents: {} | string, attributes: FileAttributes)
    assert(path, "Path is nil")
    assert(contents, "Contents is nil")
    local node: FileSystemFile | FileSystemDevice

    if typeof(contents) == "table" then
        node = RawFileSystem.Device(contents, attributes or {})
    elseif typeof(contents) == "string" then
        node = RawFileSystem.File(contents, attributes or {})
    else
        error("Content type is invalid")
    end

    RawFileSystem:write(self.file_system, path, node)
end

function TerminalFileSystem:read(path: string)
    local data = RawFileSystem:read(self.file_system, path)

    if data then
        if data.kind == "device" then
            data = data.device
        elseif data.kind == "file" then
            data = data.contents
        elseif data.kind == "directory" then
            data = self.file_system:readdir(path)
        end
    end

    return data
end

function TerminalFileSystem:remove(path)
    FileSystem.rename(self.file_system, path, nil)
end

local TerminalProccess = {}
TerminalProccess.__index = TerminalProccess

function TerminalProccess:new(id, func)
    local self = setmetatable({}, self)
    self.id = id
    self.func = func
    return self
end

local Terminal = {}
Terminal.__index = Terminal

function Terminal:new()
    local self = setmetatable({}, self)
    self.proccess_handler = TerminalProccessHandler:new(self)
    self.file_system = TerminalFileSystem:new(self)

    self.input_event = Signal.new()
    self.output_event = Signal.new()
    return table.freeze(self)
end

function Terminal:assert(value, message_on_error)
    assert(coroutine.running(), "Called outside of process")
    local proccess_id = self.proccess_handler:get_proccess_id(coroutine.running())
    local success, error_message = pcall(assert, value, message_on_error)

    if not success then
        self:output(`({proccess_id}) got an error: {error_message}`)
        self.proccess_handler:kill(proccess_id)
    end
end

function Terminal:input(...)
    self.input_event:Fire(...)
end

function Terminal:output(...)
    self.output_event:Fire(...)
    print(...)
end

local a = Terminal:new()

a.proccess_handler:run(function(terminal)
    for _,v in terminal.proccess_handler.running_proccesses do
        a.proccess_handler:kill(a.proccess_handler:get_proccess_id(v))
    end
end)
