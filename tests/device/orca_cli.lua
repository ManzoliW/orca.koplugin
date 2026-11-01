-- Headless smoke test of the Orca client, run on the Kindle with KOReader's LuaJIT:
--   cd /mnt/us/koreader && ./luajit <dir>/orca_cli.lua <plugin_dir> <pairing_file> [handle]
-- Uses the Tailscale SOCKS5 proxy on localhost:1055.
local plugin_dir, pairing_file, handle = arg[1], arg[2], arg[3]
package.path = plugin_dir .. "/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath

local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local url = assert(io.open(pairing_file)):read("*a")
local offer = assert(Client.parsePairingUrl(url))
print("endpoint:", offer.endpoint, "scope:", offer.scope)

local client = Client.new({ offer = offer, proxy = { host = "127.0.0.1", port = 1055 } })
local t0 = os.time()
assert(client:connect())
print("authenticated in", os.time() - t0, "s")

if not handle then
    local worktrees = assert(client:listWorktrees())
    for _, wt in ipairs(worktrees) do
        print(string.format("worktree %s  branch=%s  terminals=%s  path=%s",
            wt.worktreeId, tostring(wt.branch), tostring(wt.liveTerminalCount), tostring(wt.path)))
        if (tonumber(wt.liveTerminalCount) or 0) > 0 then
            for _, t in ipairs(assert(client:listTerminals(wt.worktreeId))) do
                print(string.format("  terminal %s  %s", t.handle, tostring(t.title)))
            end
        end
    end
else
    local term = assert(client:readTerminal(handle, true))
    print("source:", term.source, "lines:", #(term.tail or {}))
    for _, line in ipairs(term.tail or {}) do print("| " .. line) end
end
client:close()
