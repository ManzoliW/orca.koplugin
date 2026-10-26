-- Creates a scratch terminal, exercises terminal.send, then closes it.
--   cd /mnt/us/koreader && ./luajit <dir>/send_test.lua <plugin_dir> <pairing_file> <worktreeId>
local plugin_dir, pairing_file, worktree_id = arg[1], arg[2], arg[3]
package.path = plugin_dir .. "/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")
local socket = require("socket")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local offer = assert(Client.parsePairingUrl(assert(io.open(pairing_file)):read("*a")))
local c = Client.new({ offer = offer, proxy = { host = "127.0.0.1", port = 1055 } })
assert(c:connect())

local created = assert(c:call("terminal.create", { worktree = "id:" .. worktree_id, title = "kindle-send-test" }))
local handle = created.terminal.handle
print("created", handle)
local function screen()
    local t = assert(c:readTerminal(handle, true))
    local out = {}
    for _, l in ipairs(t.tail or {}) do if l:match("%S") then out[#out + 1] = l end end
    return table.concat(out, "\n")
end
local function wait_for(pattern, secs)
    local deadline = socket.gettime() + secs
    repeat
        socket.sleep(0.5)
        local s = screen()
        if s:find(pattern, 1, true) then return true, s end
    until socket.gettime() > deadline
    return false, screen()
end

socket.sleep(3) -- let the shell start
local ok, err = c:sendText(handle, "echo KINDLE_SEND_$((40+2))", true)
print("send text+enter:", ok and "ok" or err)
local seen, s = wait_for("KINDLE_SEND_42", 10)
print("command executed:", seen)

-- Raw bytes: type a partial command, then Ctrl-C (interrupt) must cancel it.
c:sendText(handle, "echo SHOULD_NOT_RUN", false)
socket.sleep(1)
local r = c:call("terminal.send", { terminal = handle, interrupt = true })
print("interrupt:", r and "ok" or "failed")
c:sendText(handle, "echo AFTER_$((1+1))", true)
seen, s = wait_for("AFTER_2", 10)
print("after interrupt:", seen, "| interrupted cmd ran:", s:find("\nSHOULD_NOT_RUN", 1, true) ~= nil)
print("--- final screen ---\n" .. s)

print("close:", c:call("terminal.close", { terminal = handle }) and "ok" or "failed")
c:close()
