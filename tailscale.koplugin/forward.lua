--[[
    Local port forwarder for Tailscale userspace-networking mode.

    tailscaled without TUN exposes the tailnet only through its SOCKS5 proxy,
    which KOReader's own HTTP code (OPDS catalogs, Calibre, wallabag…) does not
    use. This script listens on local ports and relays each connection through
    the proxy to a tailnet host, so KOReader can simply talk to 127.0.0.1.

    usage: cd <koreader dir> && ./luajit forward.lua LOCALPORT HOST PORT [LOCALPORT HOST PORT ...]
--]]

local socket = require("socket")

local PROXY_HOST, PROXY_PORT = "127.0.0.1", 1055
local CHUNK = 16384

local function log(...)
    io.stderr:write(os.date("%H:%M:%S "), table.concat({ ... }, " "), "\n")
end

local function socks5Connect(host, port)
    local sock = socket.tcp()
    sock:settimeout(10)
    local ok, err = sock:connect(PROXY_HOST, PROXY_PORT)
    if not ok then sock:close(); return nil, "proxy: " .. tostring(err) end
    sock:send("\5\1\0")
    if sock:receive(2) ~= "\5\0" then sock:close(); return nil, "proxy: auth negotiation failed" end
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    local addr = a and ("\1" .. string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d)))
        or ("\3" .. string.char(#host) .. host)
    sock:send("\5\1\0" .. addr .. string.char(math.floor(port / 256), port % 256))
    local head = sock:receive(4)
    if not head then sock:close(); return nil, "proxy: no reply" end
    if head:byte(2) ~= 0 then sock:close(); return nil, "proxy: cannot reach " .. host .. ":" .. port .. " (code " .. head:byte(2) .. ")" end
    local atyp = head:byte(4)
    local skip = atyp == 1 and 4 or atyp == 4 and 16 or (sock:receive(1) or "\0"):byte(1)
    sock:receive(skip + 2)
    sock:settimeout(0)
    return sock
end

local listeners, targets = {}, {}
local args = { ... }
for i = 1, #args, 3 do
    local lport, host, port = tonumber(args[i]), args[i + 1], tonumber(args[i + 2])
    if not (lport and host and port) then
        log("bad forward spec, expected LOCALPORT HOST PORT")
        os.exit(2)
    end
    local server = assert(socket.bind("127.0.0.1", lport))
    server:settimeout(0)
    listeners[#listeners + 1] = server
    targets[server] = { host = host, port = port }
    log(string.format("listening 127.0.0.1:%d -> %s:%d", lport, host, port))
end
if #listeners == 0 then os.exit(2) end

local peer = {}    -- socket -> socket on the other side
local pending = {} -- socket -> unsent bytes for it

local function drop(sock)
    local other = peer[sock]
    for _, s in ipairs({ sock, other }) do
        if s then
            peer[s] = nil
            pending[s] = nil
            s:close()
        end
    end
end

local function flush(sock)
    local buf = pending[sock]
    if not buf or #buf == 0 then pending[sock] = nil; return true end
    local sent, err, partial = sock:send(buf)
    if sent then
        pending[sock] = nil
    elseif err == "timeout" then
        pending[sock] = buf:sub((partial or 0) + 1)
    else
        return nil, err
    end
    return true
end

while true do
    local readers, writers = {}, {}
    for _, server in ipairs(listeners) do readers[#readers + 1] = server end
    for sock in pairs(peer) do
        if pending[sock] then writers[#writers + 1] = sock else readers[#readers + 1] = sock end
    end
    local readable, writable = socket.select(readers, writers, 30)

    for _, sock in ipairs(writable) do
        if peer[sock] and not flush(sock) then drop(sock) end
    end

    for _, sock in ipairs(readable) do
        local target = targets[sock]
        if target then
            local client = sock:accept()
            if client then
                client:settimeout(0)
                local remote, err = socks5Connect(target.host, target.port)
                if remote then
                    peer[client], peer[remote] = remote, client
                else
                    log(err)
                    client:close()
                end
            end
        elseif peer[sock] then
            local data, err, partial = sock:receive(CHUNK)
            local chunk = data or partial
            local other = peer[sock]
            if chunk and #chunk > 0 then
                pending[other] = (pending[other] or "") .. chunk
                if not flush(other) then drop(sock) end
            end
            if not data and err ~= "timeout" then
                drop(sock)
            end
        end
    end
end
