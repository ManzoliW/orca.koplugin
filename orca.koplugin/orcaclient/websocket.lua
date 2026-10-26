--[[
    Minimal RFC 6455 WebSocket client over LuaSocket, with an optional SOCKS5
    proxy (Tailscale userspace mode exposes the tailnet only through one).

    The socket is non-blocking. Whenever it would block, the client either
    yields (when running inside a coroutine, so KOReader's UI loop keeps
    running) or waits in socket.select (plain scripts and tests).
--]]

local Base64 = require("orcaclient.base64")
local bit = require("bit")
local ffi = require("ffi")
local socket = require("socket")

local band, bor, bxor, rshift = bit.band, bit.bor, bit.bxor, bit.rshift

local OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

local WebSocket = {
    OP_TEXT = OP_TEXT,
    OP_BINARY = OP_BINARY,
}
WebSocket.__index = WebSocket

local function u16(n)
    return string.char(band(rshift(n, 8), 0xFF), band(n, 0xFF))
end

local function canYield()
    local co, is_main = coroutine.running()
    return co ~= nil and not is_main
end

-- Waits until the socket is readable (or writable). Returns true, or nil, "timeout".
function WebSocket:waitFor(write, deadline)
    while true do
        -- Poll before checking the deadline, so a zero timeout still sees data
        -- that is already waiting.
        local remaining = math.max(0, deadline - socket.gettime())
        local wait = canYield() and 0 or remaining
        local readable, writable = socket.select(not write and { self.sock } or nil,
                                                  write and { self.sock } or nil, wait)
        if (write and #writable > 0) or (not write and #readable > 0) then
            return true
        end
        if socket.gettime() >= deadline then return nil, "timeout" end
        if canYield() then coroutine.yield() end
    end
end

function WebSocket:sendAll(data)
    local deadline = socket.gettime() + self.timeout
    local i = 1
    while i <= #data do
        local sent, err, partial = self.sock:send(data, i)
        if sent then
            i = sent + 1
        elseif err == "timeout" then
            i = (partial or i - 1) + 1
            local ok, werr = self:waitFor(true, deadline)
            if not ok then
                self:close()
                return nil, "send " .. werr
            end
        else
            self:close()
            return nil, err
        end
    end
    return true
end

-- Reads exactly n bytes. Once a frame has started it keeps waiting (up to the
-- socket timeout) so a frame never gets split.
function WebSocket:readExact(n, deadline)
    if n == 0 then return "" end
    deadline = deadline or socket.gettime() + self.timeout
    local parts, got = {}, 0
    while got < n do
        local data, err, partial = self.sock:receive(n - got)
        local chunk = data or partial or ""
        if #chunk > 0 then
            parts[#parts + 1] = chunk
            got = got + #chunk
        end
        if got < n then
            if err == "timeout" or data then
                local ok = self:waitFor(false, deadline)
                if not ok then
                    self:close()
                    return nil, "timeout"
                end
            else
                self:close()
                return nil, err or "closed"
            end
        end
    end
    return table.concat(parts)
end

function WebSocket:readLine(deadline)
    local line = {}
    while true do
        local c, err = self:readExact(1, deadline)
        if not c then return nil, err end
        if c == "\n" then
            return (table.concat(line):gsub("\r$", ""))
        end
        line[#line + 1] = c
    end
end

function WebSocket:socks5Connect(host, port)
    local deadline = socket.gettime() + self.timeout
    local ok, err = self:sendAll("\5\1\0") -- version 5, one method: no auth
    if not ok then return nil, err end
    local reply = self:readExact(2, deadline)
    if reply ~= "\5\0" then return nil, "socks5: auth negotiation failed" end

    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    local addr
    if a then
        addr = "\1" .. string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
    else
        addr = "\3" .. string.char(#host) .. host
    end
    ok, err = self:sendAll("\5\1\0" .. addr .. u16(port))
    if not ok then return nil, err end

    local head = self:readExact(4, deadline)
    if not head then return nil, "socks5: no reply (is Tailscale running?)" end
    if head:byte(2) ~= 0 then
        return nil, "socks5: cannot reach " .. host .. ":" .. port .. " (code " .. head:byte(2) .. ")"
    end
    local atyp, skip = head:byte(4), 0
    if atyp == 1 then
        skip = 4
    elseif atyp == 4 then
        skip = 16
    elseif atyp == 3 then
        skip = self:readExact(1, deadline):byte(1)
    end
    self:readExact(skip + 2, deadline) -- bound address and port
    return true
end

-- opts: host, port, path, timeout (s), proxy = { host, port }, randomBytes(n)
function WebSocket.connect(opts)
    local self = setmetatable({
        timeout = opts.timeout or 15,
        randomBytes = opts.randomBytes,
    }, WebSocket)

    local target_host = opts.proxy and opts.proxy.host or opts.host
    local target_port = opts.proxy and opts.proxy.port or opts.port
    local sock = socket.tcp()
    sock:settimeout(0)
    self.sock = sock
    local ok, err = sock:connect(target_host, target_port)
    if not ok and err == "timeout" then
        ok, err = self:waitFor(true, socket.gettime() + self.timeout)
        if ok and not sock:getpeername() then
            ok, err = nil, "connection refused"
        end
    end
    if not ok then
        self:close()
        if opts.proxy then
            return nil, "Tailscale proxy (" .. target_host .. ":" .. target_port .. ") not reachable: " .. tostring(err)
        end
        return nil, "connect " .. target_host .. ":" .. target_port .. ": " .. tostring(err)
    end
    if opts.proxy then
        ok, err = self:socks5Connect(opts.host, opts.port)
        if not ok then
            self:close()
            return nil, err
        end
    end

    local key = Base64.encode(self.randomBytes(16))
    ok, err = self:sendAll(table.concat({
        "GET " .. (opts.path or "/") .. " HTTP/1.1",
        "Host: " .. opts.host .. ":" .. opts.port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
        "", "",
    }, "\r\n"))
    if not ok then
        return nil, "handshake send: " .. tostring(err)
    end

    local deadline = socket.gettime() + self.timeout
    local status
    status, err = self:readLine(deadline)
    if not status or not status:match("^HTTP/1%.1 101") then
        self:close()
        return nil, "handshake: " .. tostring(status or err)
    end
    repeat
        local line
        line, err = self:readLine(deadline)
        if not line then
            return nil, "handshake headers: " .. tostring(err)
        end
    until line == ""
    return self
end

local function xorMask(payload, mask)
    local len = #payload
    local buf = ffi.new("uint8_t[?]", len)
    ffi.copy(buf, payload, len)
    local m = { mask:byte(1, 4) }
    for i = 0, len - 1 do
        buf[i] = bxor(buf[i], m[i % 4 + 1])
    end
    return ffi.string(buf, len)
end

function WebSocket:sendFrame(opcode, payload)
    if not self.sock then return nil, "closed" end
    payload = payload or ""
    local len = #payload
    local header
    if len < 126 then
        header = string.char(bor(0x80, opcode), bor(0x80, len))
    elseif len < 65536 then
        header = string.char(bor(0x80, opcode), 0xFE) .. u16(len)
    else
        header = string.char(bor(0x80, opcode), 0xFF, 0, 0, 0, 0,
            band(rshift(len, 24), 0xFF), band(rshift(len, 16), 0xFF),
            band(rshift(len, 8), 0xFF), band(len, 0xFF))
    end
    -- Clients must mask every frame.
    local mask = self.randomBytes(4)
    return self:sendAll(header .. mask .. xorMask(payload, mask))
end

function WebSocket:send(text)
    return self:sendFrame(OP_TEXT, text)
end

function WebSocket:sendBinary(data)
    return self:sendFrame(OP_BINARY, data)
end

-- Reads one frame. Returns fin, opcode, payload or nil, err.
function WebSocket:readFrame()
    local head, err = self:readExact(2)
    if not head then return nil, err end
    local b1, b2 = head:byte(1, 2)
    local fin = band(b1, 0x80) ~= 0
    local opcode = band(b1, 0x0F)
    local masked = band(b2, 0x80) ~= 0
    local len = band(b2, 0x7F)
    if len == 126 then
        local ext = self:readExact(2)
        if not ext then return nil, "closed" end
        local x1, x2 = ext:byte(1, 2)
        len = x1 * 256 + x2
    elseif len == 127 then
        local ext = self:readExact(8)
        if not ext then return nil, "closed" end
        len = 0
        for i = 1, 8 do
            len = len * 256 + ext:byte(i)
        end
    end
    local mask
    if masked then
        mask = self:readExact(4)
        if not mask then return nil, "closed" end
    end
    local payload
    payload, err = self:readExact(len)
    if not payload then return nil, err end
    if masked then
        payload = xorMask(payload, mask)
    end
    return fin, opcode, payload
end

-- Waits up to `timeout` seconds for a data message, answering pings on the way.
-- Returns opcode, payload; or nil, "timeout" / "closed" / error[, close code, reason].
function WebSocket:receive(timeout)
    if not self.sock then return nil, "closed" end
    local deadline = socket.gettime() + (timeout or self.timeout)
    local parts, msg_opcode = {}, nil
    while true do
        if #parts == 0 then
            local ready = self:waitFor(false, deadline)
            if not ready then return nil, "timeout" end
        end

        local fin, opcode, payload = self:readFrame()
        if fin == nil then
            return nil, opcode or "closed" -- readFrame returned nil, err
        end
        if opcode == OP_PING then
            self:sendFrame(OP_PONG, payload)
        elseif opcode == OP_CLOSE then
            pcall(self.sendFrame, self, OP_CLOSE, payload:sub(1, 2))
            self:close()
            local code = #payload >= 2 and payload:byte(1) * 256 + payload:byte(2) or nil
            return nil, "closed", code, payload:sub(3)
        elseif opcode ~= OP_PONG then
            if opcode ~= OP_CONT then
                msg_opcode = opcode
            end
            parts[#parts + 1] = payload
            if fin then
                return msg_opcode, table.concat(parts)
            end
        end
    end
end

function WebSocket:isOpen()
    return self.sock ~= nil
end

function WebSocket:close()
    if self.sock then
        self.sock:close()
        self.sock = nil
    end
end

return WebSocket
