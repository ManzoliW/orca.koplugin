--[[
    Projects, workspaces, terminals and files: repo.list, worktree.*,
    terminal.create / session.tabs.createTerminal, github.listWorkItems,
    files.*, stats.summary. Params and timeouts are the ones verified
    against the desktop (tests/device/rpc_probe.lua).
--]]

local common = require("orca.api.common")
local util = require("orca.core.util")

local workspaces = {}

local NEW_TERMINAL_WAIT = 15 -- s for a pending tab to get its terminal

function workspaces.repoName(repo)
    local name = util.str(repo.displayName)
    return name ~= "" and name or util.basename(repo.path)
end

-- Projects sorted by name.
function workspaces.repos(c)
    local r, err = c:call("repo.list")
    if not r then return nil, err end
    local repos = {}
    for _i, repo in ipairs(util.tbl(r.repos)) do repos[#repos + 1] = repo end
    table.sort(repos, function(a, b)
        return workspaces.repoName(a):lower() < workspaces.repoName(b):lower()
    end)
    return repos
end

function workspaces.isRemote(repo)
    local host = util.str(repo.executionHostId)
    return host ~= "" and host ~= "local"
end

-- worktree.create; on a name clash retries as name-2, name-3.
function workspaces.create(c, params)
    local base, result, err = params.name, nil, nil
    for attempt = 1, 3 do
        result, err = c:call("worktree.create", params, common.TIMEOUT.create)
        if result or not tostring(err):lower():match("exist") then break end
        params.name = base .. "-" .. (attempt + 1)
        params.clientMutationId = util.mutationId("wt")
    end
    return result, err
end

function workspaces.workItems(c, repo, query)
    local r, err = c:call("github.listWorkItems",
        { repo = "id:" .. util.str(repo.id), limit = 40, query = query or "" }, common.TIMEOUT.slow)
    if not r then return nil, err end
    return util.tbl(r.items)
end

-- Where a PR workspace starts (it checks out the PR's branch).
function workspaces.resolvePrBase(c, repo, item)
    local base, err = c:call("worktree.resolvePrBase", {
        repo = "id:" .. util.str(repo.id), prNumber = item.number,
        headRefName = item.branchName, baseRefName = item.baseRefName,
    }, common.TIMEOUT.slow)
    if not base then return nil, err end
    if util.str(base.error) ~= "" then return nil, base.error end
    return base
end

-- A background terminal running `command` in wt (clone, new project, resume).
function workspaces.runCommand(c, wt, command, title)
    local r, err = c:call("terminal.create", {
        worktree = common.wt(wt),
        command = command,
        title = title,
        presentation = "background",
        startupCommandDelivery = "shell-ready",
        clientMutationId = util.mutationId("term"),
    }, common.TIMEOUT.slow)
    if not r then return nil, err end
    local term = util.tbl(r.terminal)
    if util.str(term.handle) == "" then return nil, "the desktop returned no terminal" end
    return term
end

-- Waits for a terminal that wasn't in `before` to show up in wt.
local function waitForNewTerminal(c, wt, before, now)
    local deadline = now() + NEW_TERMINAL_WAIT
    while now() < deadline do
        for _i, term in ipairs(c:listTerminals(wt.worktreeId) or {}) do
            if not before[term.handle] then return term end
        end
        common.wait(c, 1.5, now)
    end
end

-- A new tab in wt: an agent (params.agent, params.agentPrompt) or a shell.
-- Returns { handle, title }.
function workspaces.createTab(c, wt, params, now)
    local before = {}
    for _i, term in ipairs(c:listTerminals(wt.worktreeId) or {}) do before[term.handle] = true end
    params.worktree = common.wt(wt)
    params.activate = false
    params.select = true
    params.navigation = "caller"
    params.clientMutationId = util.mutationId("tab")
    local r, err = c:call("session.tabs.createTerminal", params, common.TIMEOUT.slow)
    if not r then return nil, err end
    local tab = util.tbl(r.tab)
    if type(tab.terminal) == "string" then return { handle = tab.terminal, title = util.str(tab.title) } end
    -- The tab is still waiting for its terminal; pick it up from the list.
    local term = waitForNewTerminal(c, wt, before, now)
    if term then return term end
    return nil, "the new terminal didn't appear yet; refresh in a moment"
end

function workspaces.sleep(c, wt)
    return c:call("worktree.sleep", { worktree = common.wt(wt) }, common.TIMEOUT.slow)
end

-- Deletes the checkout; the branch is kept.
function workspaces.remove(c, wt)
    return c:call("worktree.rm", { worktree = common.wt(wt), deleteBranch = false }, 120)
end

-- Returns entries (folders first, then by name), hasMore, total.
function workspaces.readDir(c, wt, rel)
    local r, err = c:call("files.readDir", { worktree = common.wt(wt), relativePath = rel, limit = 1000 }, 30)
    if not r then return nil, err end
    local list = type(r.entries) == "table" and r.entries or r
    local entries = {}
    for _i, e in ipairs(list) do entries[#entries + 1] = e end
    table.sort(entries, function(a, b)
        local da, db = a.isDirectory == true, b.isDirectory == true
        if da ~= db then return da end
        return util.str(a.name):lower() < util.str(b.name):lower()
    end)
    return { entries = entries, hasMore = r.hasMore == true, total = util.num(r.total) }
end

-- Returns { content, truncated }.
function workspaces.readFile(c, wt, rel, timeout)
    local f, err = c:call("files.read", { worktree = common.wt(wt), relativePath = rel }, timeout or 60)
    if not f then return nil, err end
    return { content = util.str(f.content), truncated = f.truncated == true }
end

function workspaces.stats(c)
    return c:call("stats.summary", nil, 30)
end

return workspaces
