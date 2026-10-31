--[[
    Agent accounts and usage limits on the desktop, plus Orca's own totals.

        local snap = accounts.list(c, true)        -- {claude, codex, rateLimits}
        accounts.selectClaude(c, id)               -- id nil = System default
        local s = accounts.stats(c)                -- stats.summary
--]]

local common = require("orca.api.common")
local util = require("orca.core.util")

local accounts = {}

-- accountId is required and may be JSON null (System default). rapidjson drops
-- nil-valued keys, so a plain nil would fail validation ("Missing accountId");
-- rapidjson.null encodes as null.
local ok, json = pcall(require, "rapidjson")
accounts.null = ok and type(json) == "table" and json.null or nil

-- refresh: ask the desktop to fetch fresh usage before answering (slower).
function accounts.list(c, refresh)
    local result, err = c:call("accounts.list", { refreshUsage = refresh and true or false },
        refresh and common.TIMEOUT.slow or common.TIMEOUT.default)
    if not result then return nil, err end
    return {
        claude = util.tbl(result.claude),
        codex = util.tbl(result.codex),
        rateLimits = util.tbl(result.rateLimits),
    }
end

local function select(c, method, id)
    local account_id = util.str(id) ~= "" and id or accounts.null
    return c:call(method, { accountId = account_id })
end

function accounts.selectClaude(c, id) return select(c, "accounts.selectClaude", id) end
function accounts.selectCodex(c, id) return select(c, "accounts.selectCodex", id) end

-- {totalAgentsSpawned, totalPRsCreated, totalAgentTimeMs}
function accounts.stats(c)
    return c:call("stats.summary", nil, common.TIMEOUT.slow)
end

return accounts
