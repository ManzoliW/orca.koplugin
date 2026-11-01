--[[
    Owns the desktop connection: builds the client from the pairing, connects
    on demand, re-runs the registered `onConnect` hooks after every new socket
    (the desktop drops a connection's subscriptions when it closes), and hands
    stream frames to the handler registered for their request id.

    While something needs the socket kept open (a notification stream, an
    open session), `keepAlive` reads it periodically: the desktop pings every
    15 s and closes connections that stop answering.
--]]

local Connection = {}
Connection.__index = Connection

local PUMP_EVERY = 10 -- s

-- opts: settings, Client (class), proxy, schedule(delay, fn), unschedule(fn), log, load_error
function Connection.new(opts)
    return setmetatable({
        settings = opts.settings,
        Client = opts.Client,
        proxy = opts.proxy,
        schedule = opts.schedule,
        unschedule = opts.unschedule,
        log = opts.log or function() end,
        load_error = opts.load_error,
        hooks = {},       -- key -> fn(client), runs inside a job after connecting
        handlers = {},    -- stream request id -> fn(result, msg)
        keepers = {},     -- key -> true while something needs the socket open
    }, Connection)
end

function Connection:client()
    if self.load_error then
        return nil, "crypto library failed to load: " .. self.load_error
    end
    if not self.instance then
        local url = self.settings:get("pairing_url")
        if not url then return nil, "not paired" end
        local offer, err = self.Client.parsePairingUrl(url)
        if not offer then return nil, err end
        self.instance = self.Client.new({
            offer = offer,
            proxy = self.settings:get("use_proxy") and self.proxy or nil,
            host_override = self.settings:get("host_override"),
            client_id = self.settings:clientId(),
        })
    end
    return self.instance
end

function Connection:isConnected()
    return self.instance ~= nil and self.instance:isConnected()
end

-- Inside a job: returns a connected client, connecting (and re-running the
-- hooks) when needed.
function Connection:ensure()
    local client, err = self:client()
    if not client then return nil, err end
    if client:isConnected() then return client end
    local ok, cerr = client:connect()
    if not ok then
        self.log("connect failed:", cerr)
        return nil, cerr
    end
    local keys = {}
    for key in pairs(self.hooks) do table.insert(keys, key) end
    table.sort(keys)
    self.log("connected; running hooks:", table.concat(keys, ", "))
    self.handlers = {}
    for key, hook in pairs(self.hooks) do
        local hook_ok, herr = pcall(hook, client)
        if not hook_ok then self.log("connect hook failed:", key, herr) end
    end
    return client
end

-- Closes the socket and forgets the client (pairing or address changed, or
-- the Kindle woke up and the old socket is stale).
-- reason is only logged.
function Connection:reset(reason)
    if self.instance then
        if self.instance:isConnected() then self.log("closing connection:", reason or "reset") end
        self.instance:close()
    end
    self.instance = nil
    self.handlers = {}
end

function Connection:onConnect(key, hook)
    self.hooks[key] = hook
end

-- Inside a job: starts a stream and routes its later frames to handler.
-- Returns request id, first result; or nil, err.
function Connection:stream(client, method, params, handler, timeout)
    local id, first = client:startStream(method, params, timeout)
    if id then
        self.handlers[id] = handler
        self.log("stream started:", method)
    else
        self.log("stream failed:", method, first)
    end
    return id, first
end

function Connection:stopStream(client, id)
    self.handlers[id] = nil
    if client then client:stopStream(id) end
end

-- On the UI loop: delivers frames taken from the client.
function Connection:dispatch(events)
    for _, msg in ipairs(events or {}) do
        local handler = self.handlers[msg.id]
        if handler and type(msg.result) == "table" then
            local ok, err = pcall(handler, msg.result, msg)
            if not ok then self.log("stream handler failed:", err) end
        end
    end
end

-- Reads whatever arrived and dispatches it. Runs as a background job.
function Connection:pump(jobs, on_done)
    if not self:isConnected() then
        if on_done then on_done(false) end
        return
    end
    jobs:run{
        background = true,
        run = function(c)
            c:pump(0)
            return c:takeEvents()
        end,
        done = function(events)
            self:dispatch(events)
            if on_done then on_done(events ~= nil) end
        end,
    }
end

-- keepAlive(key, true) while something needs the socket read regularly.
function Connection:keepAlive(jobs, key, on)
    self.keepers[key] = on or nil
    if next(self.keepers) and not self.pumper then
        self.pumper = function()
            self.schedule(PUMP_EVERY, self.pumper)
            if not jobs:isBusy() then self:pump(jobs) end
        end
        self.schedule(PUMP_EVERY, self.pumper)
    elseif not next(self.keepers) and self.pumper then
        self.unschedule(self.pumper)
        self.pumper = nil
    end
end

function Connection:stop()
    if self.pumper then self.unschedule(self.pumper) end
    self.pumper = nil
    self.keepers = {}
    self:reset("plugin closing")
end

return Connection
