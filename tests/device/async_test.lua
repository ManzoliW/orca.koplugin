-- Drives the client inside a coroutine, as the plugin does, and checks it yields.
--   cd /mnt/us/koreader && ./luajit <dir>/async_test.lua <plugin_dir> <settings_lua>
local plugin_dir, settings_path = arg[1], arg[2]
package.path = plugin_dir .. "/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")
local socket = require("socket")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local offer = assert(Client.parsePairingUrl(dofile(settings_path).pairing_url))
local c = Client.new({ offer = offer, proxy = { host = "127.0.0.1", port = 1055 } })

local yields, result, err = 0, nil, nil
local co = coroutine.create(function()
    assert(c:connect())
    return c:listWorktrees()
end)
local t0 = socket.gettime()
while coroutine.status(co) ~= "dead" do
    local ok, a, b = coroutine.resume(co)
    if not ok then error(a) end
    if coroutine.status(co) == "dead" then result, err = a, b else yields = yields + 1 end
    socket.sleep(0.02) -- the UI loop would run here
end
print(string.format("worktrees=%s err=%s yields=%d elapsed=%.2fs",
    result and #result or "nil", tostring(err), yields, socket.gettime() - t0))
c:close()
os.exit(result and yields > 0 and 0 or 1)
