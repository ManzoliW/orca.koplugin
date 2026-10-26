--[[
    Orca mobile-runtime client: pairing-URL parsing, the legacy E2EE handshake
    (NaCl box, base64(nonce || ciphertext) frames) and JSON-RPC calls.
    Mirrors mobile/scripts/test-subscribe.ts in the Orca repository.
--]]

local Base64 = require("orcaclient.base64")
local NaCl = require("orcaclient.nacl")
local WebSocket = require("orcaclient.websocket")
local json = require("rapidjson")
local socket = require("socket")

local Client = {}
Client.__index = Client

-- Accepts "orca://pair?code=..." (or a bare code) and returns the offer table.
function Client.parsePairingUrl(url)
    url = (url or ""):gsub("%s", "")
    local code = url:match("[?&#]code=([^&]+)") or url:match("pairing=([^&]+)") or url
    code = code:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    local decoded = Base64.decode(code)
    if not decoded then
        return nil, "pairing code is not valid base64"
    end
    local ok, offer = pcall(json.decode, decoded)
    if not ok or type(offer) ~= "table" then
        return nil, "pairing code is not valid JSON"
    end
    if type(offer.endpoint) ~= "string" or type(offer.deviceToken) ~= "string"
            or type(offer.publicKeyB64) ~= "string" then
        return nil, "pairing code is missing endpoint, deviceToken or publicKeyB64"
    end
    return offer
end

-- opts: offer, proxy = { host, port } (optional), host_override (optional)
function Client.new(opts)
    local host, port = opts.offer.endpoint:match("^wss?://%[?([^%]/]-)%]?:(%d+)")
    if not host then
        host = opts.offer.endpoint:match("^wss?://([^:/]+)")
        port = 6768
    end
    return setmetatable({
        offer = opts.offer,
        host = opts.host_override or host,
        port = tonumber(port),
        proxy = opts.proxy,
        next_id = 0,
        events = {},
    }, Client)
end

function Client:isConnected()
    return self.ws ~= nil and self.ws:isOpen()
end

function Client:close()
    if self.ws then
        self.ws:close()
        self.ws = nil
    end
end

function Client:encrypt(plaintext)
    local nonce = NaCl.randomBytes(NaCl.NONCE_BYTES)
    return Base64.encode(nonce .. NaCl.after(plaintext, nonce, self.shared))
end

function Client:decrypt(opcode, payload)
    local bundle = opcode == WebSocket.OP_BINARY and payload or Base64.decode(payload)
    if not bundle or #bundle < NaCl.NONCE_BYTES + NaCl.OVERHEAD then
        return nil
    end
    return NaCl.openAfter(bundle:sub(NaCl.NONCE_BYTES + 1), bundle:sub(1, NaCl.NONCE_BYTES), self.shared)
end

local function closeReason(err, code, reason)
    if code == 4001 then return "authentication rejected (pairing revoked or wrong token)" end
    if code == 4002 then return "handshake timed out" end
    if code == 4003 then return "decryption failures" end
    if code then return string.format("connection closed (%d %s)", code, reason or "") end
    return tostring(err)
end

function Client:connect()
    self:close()
    local ws, err = WebSocket.connect({
        host = self.host,
        port = self.port,
        proxy = self.proxy,
        timeout = 15,
        randomBytes = NaCl.randomBytes,
    })
    if not ws then
        return nil, err
    end
    self.ws = ws

    local public_key, secret_key = NaCl.keyPair()
    local server_key = Base64.decode(self.offer.publicKeyB64)
    if not server_key or #server_key ~= NaCl.KEY_BYTES then
        self:close()
        return nil, "pairing code has an invalid public key"
    end
    self.shared = NaCl.before(server_key, secret_key)

    ws:send(json.encode({ type = "e2ee_hello", publicKeyB64 = Base64.encode(public_key) }))
    local opcode, payload, code, reason = ws:receive(10)
    if not opcode then
        self:close()
        return nil, "hello: " .. closeReason(payload, code, reason)
    end
    local ok, msg = pcall(json.decode, payload)
    if not ok or type(msg) ~= "table" or msg.type ~= "e2ee_ready" then
        self:close()
        return nil, "unexpected hello reply: " .. tostring(payload):sub(1, 200)
    end

    ws:send(self:encrypt(json.encode({ type = "e2ee_auth", deviceToken = self.offer.deviceToken })))
    opcode, payload, code, reason = ws:receive(10)
    if not opcode then
        self:close()
        return nil, "auth: " .. closeReason(payload, code, reason)
    end
    local plaintext = self:decrypt(opcode, payload)
    ok, msg = pcall(json.decode, plaintext or "")
    if not ok or type(msg) ~= "table" or msg.type ~= "e2ee_authenticated" then
        self:close()
        return nil, "authentication failed: " .. tostring(plaintext or payload):sub(1, 200)
    end
    return true
end

-- Receives one decrypted message; returns the decoded table, or nil, err.
function Client:receiveMessage(timeout)
    local opcode, payload, code, reason = self.ws:receive(timeout)
    if not opcode then
        if payload == "timeout" then return nil, "timeout" end
        self:close()
        return nil, closeReason(payload, code, reason)
    end
    local plaintext = self:decrypt(opcode, payload)
    if not plaintext then
        return nil, "undecryptable frame"
    end
    local ok, msg = pcall(json.decode, plaintext)
    if not ok then
        return nil, "invalid JSON from server"
    end
    return msg
end

-- Sends an RPC request and waits for its final response. Streaming events for
-- other requests are queued in self.events. Returns result, or nil, err.
function Client:call(method, params, timeout)
    if not self:isConnected() then
        local ok, err = self:connect()
        if not ok then return nil, err end
    end
    self.next_id = self.next_id + 1
    local id = "kindle-" .. self.next_id
    local request = { id = id, method = method, deviceToken = self.offer.deviceToken }
    if params then request.params = params end
    local sent, err = self.ws:send(self:encrypt(json.encode(request)))
    if not sent then
        self:close()
        return nil, "send failed: " .. tostring(err)
    end

    local deadline = socket.gettime() + (timeout or 15)
    while true do
        local remaining = deadline - socket.gettime()
        if remaining <= 0 then
            return nil, method .. " timed out"
        end
        local msg, rerr = self:receiveMessage(remaining)
        if not msg then
            if rerr ~= "timeout" and rerr ~= "undecryptable frame" then
                return nil, rerr
            end
        elseif msg.id == id and not msg.streaming then
            if msg.ok then
                return msg.result or {}
            end
            local e = type(msg.error) == "table" and msg.error or {}
            return nil, (e.code or "error") .. ": " .. tostring(e.message or "")
        else
            table.insert(self.events, msg)
        end
    end
end

-- Starts a streaming request and waits for its first event (or error).
-- Returns request id, first result; or nil, err. Later events land in self.events.
function Client:startStream(method, params, timeout)
    if not self:isConnected() then
        local ok, err = self:connect()
        if not ok then return nil, err end
    end
    self.next_id = self.next_id + 1
    local id = "kindle-" .. self.next_id
    local sent, err = self.ws:send(self:encrypt(json.encode({
        id = id, method = method, params = params, deviceToken = self.offer.deviceToken,
    })))
    if not sent then
        self:close()
        return nil, "send failed: " .. tostring(err)
    end
    local deadline = socket.gettime() + (timeout or 15)
    while socket.gettime() < deadline do
        local msg, rerr = self:receiveMessage(deadline - socket.gettime())
        if not msg then
            if rerr ~= "timeout" and rerr ~= "undecryptable frame" then return nil, rerr end
        elseif msg.id == id then
            if not msg.ok then
                local e = type(msg.error) == "table" and msg.error or {}
                return nil, (e.code or "error") .. ": " .. tostring(e.message or "")
            end
            return id, msg.result or {}
        else
            table.insert(self.events, msg)
        end
    end
    return nil, method .. " timed out"
end

-- Removes and returns all queued events.
function Client:takeEvents()
    local events = self.events
    self.events = {}
    return events
end

-- Services the socket (answers keepalive pings) without blocking long.
function Client:pump(timeout)
    if not self:isConnected() then return end
    while true do
        local msg = self:receiveMessage(timeout or 0)
        if not msg then return end
        table.insert(self.events, msg)
        timeout = 0
    end
end

-- Convenience wrappers ------------------------------------------------------

function Client:listWorktrees()
    local result, err = self:call("worktree.ps")
    if not result then return nil, err end
    return result.worktrees or {}
end

function Client:listTerminals(worktree_id)
    local result, err = self:call("terminal.list", {
        worktree = "id:" .. worktree_id,
        includeVisualLayouts = false,
    })
    if not result then return nil, err end
    return result.terminals or {}
end

-- screen = true returns the rendered current frame (ideal for TUIs);
-- otherwise the accumulated output stream, newest `limit` lines.
function Client:readTerminal(handle, screen, limit)
    local params = { terminal = handle }
    if screen then
        params.screen = true
    else
        params.limit = limit
    end
    local result, err = self:call("terminal.read", params)
    if not result then return nil, err end
    return result.terminal or {}
end

function Client:sendText(handle, text, enter)
    return self:call("terminal.send", { terminal = handle, text = text, enter = enter and true or false })
end

-- Live view of a terminal. With a viewport, the desktop resizes the PTY to it
-- (as a "desktop viewer", so desktop typing stays unlocked) and restores its
-- own size when the stream ends. Returns subscription request id, or nil, err.
function Client:subscribeTerminal(handle, viewport)
    local params = { terminal = handle, client = { id = self.offer.deviceToken, type = "desktop" } }
    if viewport then
        params.viewport = viewport
    end
    return self:startStream("terminal.subscribe", params)
end

-- Re-applies our size after the desktop took it back (user typed or resized there).
function Client:claimViewport(handle, viewport)
    return self:call("terminal.updateViewport", {
        terminal = handle,
        client = { id = self.offer.deviceToken, type = "desktop" },
        viewport = viewport,
        claim = true,
    })
end

function Client:unsubscribeTerminal(handle, request_id)
    return self:call("terminal.unsubscribe", {
        subscriptionId = handle .. ":" .. self.offer.deviceToken,
        client = { id = self.offer.deviceToken },
        requestId = request_id,
    })
end

-- Returns { [terminal handle] = agentStatus table } for every live terminal.
function Client:agentStates()
    local result, err = self:call("session.tabs.listAll")
    if not result then return nil, err end
    local states = {}
    for _, snapshot in ipairs(result.snapshots or {}) do
        for _, tab in ipairs(type(snapshot.tabs) == "table" and snapshot.tabs or {}) do
            local status = tab.agentStatus
            if type(tab.terminal) == "string" and type(status) == "table" then
                states[tab.terminal] = status
            end
        end
    end
    return states
end

return Client
