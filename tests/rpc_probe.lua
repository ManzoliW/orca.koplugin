-- Calls, against the real desktop, every RPC the plugin's workspace/git/files
-- menus use, with the same params, and prints a short summary of each result.
--   cd /mnt/us/koreader && ./luajit <dir>/rpc_probe.lua <plugin_dir> <settings_lua> [mutate]
-- With "mutate": also creates a throwaway workspace, opens a shell tab in it,
-- reads its git/files and removes it again.
local plugin_dir, settings_path, mode = arg[1], arg[2], arg[3]
package.path = plugin_dir .. "/?.lua;common/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")
local socket = require("socket")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local c = Client.new({ offer = assert(Client.parsePairingUrl(dofile(settings_path).pairing_url)),
    proxy = { host = "127.0.0.1", port = 1055 } })
assert(c:connect())

-- Compact one-line shape of a value: keys, array lengths, short strings.
local function shape(v, depth)
    depth = depth or 0
    if type(v) == "string" then return string.format("%q", #v > 40 and v:sub(1, 40) .. "…" or v) end
    if type(v) ~= "table" then return tostring(v) end
    if depth >= 2 then return "{…}" end
    if #v > 0 then return "[" .. #v .. "× " .. shape(v[1], depth + 1) .. "]" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do
        if i > 12 then parts[#parts + 1] = "…" break end
        parts[#parts + 1] = k .. "=" .. shape(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, " ") .. "}"
end

local failures = 0
local function probe(method, params, timeout)
    local t0 = socket.gettime()
    local r, err = c:call(method, params, timeout or 60)
    local dt = socket.gettime() - t0
    if r then
        print(string.format("ok   %-38s %5.1fs %s", method, dt, shape(r)))
    else
        failures = failures + 1
        print(string.format("FAIL %-38s %5.1fs %s", method, dt, tostring(err):sub(1, 300)))
    end
    return r, err
end

local function sel(wt) return "id:" .. wt.worktreeId end

local repos = probe("repo.list")
repos = repos and (repos.repos or repos) or {}
local worktrees = assert(c:listWorktrees())
-- The worktree for this project, else the first one with a path.
local wt
for _, w in ipairs(worktrees) do
    if tostring(w.path):lower():match("kindle$") then wt = w end
end
wt = wt or worktrees[1]
print("using worktree", wt.worktreeId, wt.path, "repo", wt.repoId)

probe("stats.summary", nil, 30)
local acc = c:call("accounts.list", { refreshUsage = false }, 30)
print("     accounts.list rateLimits.claude:", acc and shape(acc.rateLimits and acc.rateLimits.claude) or "FAIL")
probe("github.listWorkItems", { repo = "id:" .. wt.repoId, limit = 5, query = "" })

local status = probe("git.status", { worktree = sel(wt), includeLineStats = true })
probe("git.upstreamStatus", { worktree = sel(wt) }, 30)
local entry = status and status.entries and status.entries[1]
if entry then
    probe("git.diff", { worktree = sel(wt), filePath = entry.path, staged = entry.area == "staged" }, 30)
end
probe("hostedReview.getCreationEligibility", { repo = "id:" .. wt.repoId, branch = wt.branch, worktree = sel(wt) })
local dir = probe("files.readDir", { worktree = sel(wt), relativePath = "", limit = 1000 }, 30)
probe("files.read", { worktree = sel(wt), relativePath = "README.md" }, 30)

-- Candidates for the next features.
probe("settings.getTerminalQuickCommands", nil, 30)
local terms = c:listTerminals(wt.worktreeId) or {}
if terms[1] then
    probe("session.readTerminalScrollback", { terminal = terms[1].handle }, 30)
    probe("terminal.read", { terminal = terms[1].handle, limit = 2000 }, 30)
end
probe("notifications.getMissedSince", { since = (os.time() - 86400) * 1000 }, 30)

-- Is the orca CLI reachable from a desktop shell? (clone / new project rely on it)
local r = probe("terminal.create", {
    worktree = sel(wt), command = "git --version; orca --version",
    title = "kindle-probe", presentation = "background",
    startupCommandDelivery = "shell-ready", clientMutationId = "kindle-probe-" .. os.time(),
})
if r and r.terminal then
    socket.sleep(8)
    local t = c:readTerminal(r.terminal.handle, false, 40)
    for _, line in ipairs(t and t.tail or {}) do
        if line:match("%S") then print("     | " .. line) end
    end
    probe("terminal.close", { terminal = r.terminal.handle }, 30)
end

if mode == "mutate" then
    local name = "kindle-probe-" .. os.date("%H%M%S")
    local created = probe("worktree.create", {
        repo = "id:" .. wt.repoId, name = name, setupDecision = "inherit",
        clientMutationId = "kindle-" .. name,
    }, 600)
    local nwt = created and created.worktree
    if nwt and nwt.id and not nwt.worktreeId then nwt.worktreeId = nwt.id end
    if nwt and nwt.worktreeId then
        local tab = probe("session.tabs.createTerminal", {
            worktree = sel(nwt), activate = false, select = true, navigation = "caller",
            clientMutationId = "kindle-tab-" .. os.time(),
        })
        print("     tab.terminal:", tab and tab.tab and shape(tab.tab.terminal))
        socket.sleep(3)
        print("     terminals now:", #(c:listTerminals(nwt.worktreeId) or {}))
        probe("git.status", { worktree = sel(nwt), includeLineStats = true })
        probe("worktree.sleep", { worktree = sel(nwt) })
        probe("worktree.rm", { worktree = sel(nwt), deleteBranch = true }, 120)
    end
end

c:close()
print(failures == 0 and "ALL OK" or (failures .. " FAILED"))
