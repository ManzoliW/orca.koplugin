--[[
    Orca's notification feed: a stream of agent events (needs you, finished)
    plus a replay of what was missed while the socket was closed.

        local id, ready = notifications.subscribe(connection, c, handler)
        local missed = notifications.missedSince(c, watermark)
        local term = notifications.terminalFor(c, worktreeId, paneKey)
--]]

local common = require("orca.api.common")
local util = require("orca.core.util")

local notifications = {}

-- The desktop also mutes notifications it showed itself; the Kindle wants them all.
local PARAMS = { includeDesktopSuppressed = true }

-- Returns stream id, ready frame {subscriptionId, epoch}; or nil, err.
function notifications.subscribe(connection, c, handler)
    local id, first = connection:stream(c, "notifications.subscribe", PARAMS, handler)
    if not id then return nil, first end
    if type(first) ~= "table" or first.type ~= "ready" then
        connection:stopStream(c, id)
        return nil, "notifications.subscribe: unexpected first frame"
    end
    return id, { subscriptionId = util.str(first.subscriptionId), epoch = util.str(first.epoch) }
end

function notifications.unsubscribe(c, subscription_id)
    return c:call("notifications.unsubscribe", { subscriptionId = subscription_id })
end

-- watermark = { seq, epoch } of the last event seen (epoch may be "").
-- Returns { notifications = {...}, epoch }.
function notifications.missedSince(c, watermark)
    local params = {
        lastSeenSeq = math.max(0, math.floor(util.num(watermark and watermark.seq))),
        includeDesktopSuppressed = true,
    }
    local epoch = util.str(watermark and watermark.epoch)
    if epoch ~= "" then params.epoch = epoch end
    local result, err = c:call("notifications.getMissedSince", params)
    if not result then return nil, err end
    return { notifications = util.tbl(result.notifications), epoch = util.str(result.epoch) }
end

-- "needs" (asks a question), "done" (finished a turn), "info" (test or plugin
-- message) or nil (terminal bells, dismissals, anything else).
function notifications.kind(event)
    if type(event) ~= "table" or event.type ~= "notification" then return nil end
    local source = util.str(event.source)
    if source == "agent-task-complete" then
        local state = util.str(event.agentState)
        if state == "blocked" or state == "waiting" then return "needs" end
        if state == "working" then return nil end
        -- Desktops before agentState only sent this on finish.
        return "done"
    end
    if source == "test" or source == "plugin" then return "info" end
    return nil
end

-- The terminal behind a paneKey ("<tabId>:<leafId>"): terminal.list rows carry
-- both halves. Falls back to the agent status rows, then to the one agent in
-- the workspace that is in the wanted state. Returns a terminal table
-- {handle, title, worktreePath?, agentIdentity?} or nil.
function notifications.terminalFor(c, worktree_id, pane_key, wanted)
    worktree_id, pane_key = util.str(worktree_id), util.str(pane_key)
    local terminals = {}
    if worktree_id ~= "" then
        terminals = c:listTerminals(worktree_id) or {}
        for _i, t in ipairs(terminals) do
            if pane_key ~= "" and util.str(t.tabId) .. ":" .. util.str(t.leafId) == pane_key then
                return t
            end
        end
    end
    local states = c:agentStates() or {}
    local function byHandle(handle, status)
        for _i, t in ipairs(terminals) do
            if t.handle == handle then return t end
        end
        return { handle = handle, title = status.title, agentIdentity = status.agentType }
    end
    for handle, status in pairs(states) do
        if pane_key ~= "" and util.str(status.paneKey) == pane_key then return byHandle(handle, status) end
    end
    for handle, status in pairs(states) do
        if util.str(status.worktree) == worktree_id and (not wanted or common.state(status.state).key == wanted) then
            return byHandle(handle, status)
        end
    end
    return nil
end

return notifications
