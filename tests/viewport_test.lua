-- Verifies phone-fit via a desktop-viewer JSON subscription, plus status calls.
-- Uses a scratch terminal it creates and closes.
--   cd /mnt/us/koreader && ./luajit <dir>/viewport_test.lua <plugin_dir> <settings_lua> <worktreeId>
local plugin_dir, settings_path, worktree_id = arg[1], arg[2], arg[3]
package.path = plugin_dir .. "/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")
local json = require("rapidjson")
local socket = require("socket")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local offer = assert(Client.parsePairingUrl(dofile(settings_path).pairing_url))
local c = Client.new({ offer = offer, proxy = { host = "127.0.0.1", port = 1055 } })
assert(c:connect())
local token = offer.deviceToken

local h = assert(c:call("terminal.create", { worktree = "id:" .. worktree_id, title = "kindle-viewport-test" })).terminal.handle
print("scratch terminal", h)
socket.sleep(3)

local function width()
    c:sendText(h, "Write-Output (\"COLS=\" + [Console]::WindowWidth + \" ROWS=\" + [Console]::WindowHeight)", true)
    socket.sleep(2)
    local t = assert(c:readTerminal(h, true))
    local last
    for _, l in ipairs(t.tail or {}) do last = l:match("^COLS=%d+ ROWS=%d+") or last end
    return last, #(t.tail or {})
end

print("before:", width())

-- Subscribe as a desktop viewer with a Kindle-sized viewport.
c.next_id = c.next_id + 1
local sub_id = "kindle-" .. c.next_id
c.ws:send(c:encrypt(json.encode({ id = sub_id, method = "terminal.subscribe", deviceToken = token,
    params = { terminal = h, client = { id = token, type = "desktop" }, viewport = { cols = 52, rows = 38 } } })))
local deadline = socket.gettime() + 5
while socket.gettime() < deadline do
    local m = c:receiveMessage(1)
    if m and m.id == sub_id then
        local r = m.result or {}
        print("subscribe event:", m.ok, r.type, r.cols, r.rows, m.error and json.encode(m.error) or "")
        if not m.ok or r.type == "scrollback" then break end
    end
end
local w, lines = width()
print("while subscribed:", w, "screen lines:", lines)

-- Status calls.
local tabs, err = c:call("session.tabs.listAll")
if tabs then
    local n = 0
    for _, snap in ipairs(tabs.snapshots or {}) do
        for _, tab in ipairs(snap.tabs or {}) do
            n = n + 1
            if n <= 6 then
                print("tab:", tostring(tab.terminal), tostring(tab.title), tab.agentStatus and json.encode(tab.agentStatus):sub(1, 160) or "-")
            end
        end
    end
    print("session.tabs.listAll ok; snapshots:", #(tabs.snapshots or {}), "tabs:", n)
    if n == 0 then print("raw:", json.encode(tabs):sub(1, 600)) end
else
    print("session.tabs.listAll failed:", err)
end
local ps = assert(c:call("worktree.ps"))
for _, wt in ipairs(ps.worktrees or {}) do
    print("worktree:", tostring(wt.path), "status=" .. tostring(wt.status), "agents=" .. #(type(wt.agents) == "table" and wt.agents or {}))
    for _, a in ipairs(type(wt.agents) == "table" and wt.agents or {}) do
        print("   agent:", tostring(a.paneKey), tostring(a.state), tostring(a.agentType))
    end
end
print("snapshotId:", tostring(ps.snapshotId))
local st = c:call("terminal.agentStatus", { terminal = h })
print("agentStatus(scratch):", st and json.encode(st) or "failed")

-- Leave: the desktop should take its size back.
print("unsubscribe:", json.encode(c:call("terminal.unsubscribe",
    { subscriptionId = h .. ":" .. token, client = { id = token }, requestId = sub_id }) or {}))
socket.sleep(1)
print("after:", width())
print("close:", c:call("terminal.close", { terminal = h }) and "ok" or "failed")
c:close()
