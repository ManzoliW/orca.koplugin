--[[
    Selectors and shared constants for Orca RPC calls. Every api/*.lua
    function takes the connected client first and runs inside a job:

        local result, err = api.git.status(c, wt)

    They return plain Lua data (or nil, err) and never touch the UI.
--]]

local util = require("orca.core.util")

local common = {}

common.TIMEOUT = {
    default = 15,
    slow = 60,       -- git push/pull, GitHub queries, usage refreshes
    create = 600,    -- worktree.create may clone or run setup hooks
}

-- "id:<worktreeId>" for worktree-scoped methods.
function common.wt(wt)
    return "id:" .. util.str(wt.worktreeId)
end

-- The repo id is the part of a worktree id before "::"; nil if absent.
function common.repoId(wt)
    return util.str(wt.worktreeId):match("^(.-)::")
end

function common.repo(wt)
    local id = common.repoId(wt)
    return id and ("id:" .. id) or nil
end

-- Cooperative sleep inside a job: keeps the socket serviced while waiting.
function common.wait(c, seconds, now)
    local deadline = now() + seconds
    while now() < deadline do
        c:pump(deadline - now())
    end
end

-- Agent / workspace states, most urgent first.
common.STATES = {
    permission = { rank = 1, key = "needs" },
    blocked = { rank = 1, key = "needs" },
    waiting = { rank = 1, key = "needs" },
    working = { rank = 2, key = "working" },
    done = { rank = 3, key = "done" },
}

function common.state(state)
    return common.STATES[util.str(state)] or { rank = 4, key = "idle" }
end

return common
