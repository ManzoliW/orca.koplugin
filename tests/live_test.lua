-- Live-update path: subscribeTerminal + pump(0) must surface output events.
--   cd /mnt/us/koreader && ./luajit <dir>/live_test.lua <plugin_dir> <settings_lua> <worktreeId>
local plugin_dir, settings_path, worktree_id = arg[1], arg[2], arg[3]
package.path = plugin_dir .. "/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")
local socket = require("socket")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local c = Client.new({ offer = assert(Client.parsePairingUrl(dofile(settings_path).pairing_url)),
    proxy = { host = "127.0.0.1", port = 1055 } })
assert(c:connect())
local h = assert(c:call("terminal.create", { worktree = "id:" .. worktree_id, title = "kindle-live-test" })).terminal.handle
socket.sleep(3)
local id, first = assert(c:subscribeTerminal(h, { cols = 60, rows = 30 }))
print("subscribed:", id, first.type, first.cols, first.rows)
c:takeEvents()
assert(c:sendText(h, "Write-Output LIVE_$((6*7))", true))
local data_events, saw = 0, false
local deadline = socket.gettime() + 5
while socket.gettime() < deadline do
    c:pump(0)
    for _, m in ipairs(c:takeEvents()) do
        if m.id == id and type(m.result) == "table" and m.result.type == "data" then
            data_events = data_events + 1
            if tostring(m.result.chunk):find("LIVE_42", 1, true) then saw = true end
        end
    end
    socket.sleep(0.2)
end
print("data events:", data_events, "saw output:", saw)
print("claim:", c:claimViewport(h, { cols = 60, rows = 30 }) and "ok" or "failed")
print("unsubscribe:", c:unsubscribeTerminal(h, id) and "ok" or "failed")
print("close:", c:call("terminal.close", { terminal = h }) and "ok" or "failed")
c:close()
os.exit(saw and 0 or 1)
