--[[
    Scheduled agent runs on the desktop (automation.* methods).

        local list = automations.list(c)               -- { automation, … }
        automations.runNow(c, id)                      -- { id, status, … }
        automations.setEnabled(c, id, false)
        local runs = automations.runs(c, id, 10)       -- newest first
--]]

local common = require("orca.api.common")
local util = require("orca.core.util")

local automations = {}

function automations.list(c)
    local result, err = c:call("automation.list", {})
    if not result then return nil, err end
    return util.tbl(result.automations)
end

-- Starting a run may create a workspace first.
function automations.runNow(c, id)
    local result, err = c:call("automation.runNow", { id = id }, common.TIMEOUT.slow)
    if not result then return nil, err end
    return util.tbl(result.run)
end

function automations.setEnabled(c, id, enabled)
    local result, err = c:call("automation.update", { id = id, updates = { enabled = enabled and true or false } })
    if not result then return nil, err end
    return util.tbl(result.automation)
end

function automations.runs(c, id, limit)
    local result, err = c:call("automation.runs", { automationId = id, limit = limit })
    if not result then return nil, err end
    local runs = util.tbl(result.runs)
    table.sort(runs, function(a, b)
        return util.num(a.scheduledFor) > util.num(b.scheduledFor)
    end)
    return runs
end

return automations
