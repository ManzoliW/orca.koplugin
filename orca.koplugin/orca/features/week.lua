--[[
    This week: the last 7 days, next to the 7 before them where it says
    something. Reading time from the Kindle's statistics, merged pull
    requests and contributions from GitHub, agents and agent time from
    Orca's totals. Shown on Home, and on Mondays on the sleep picture.

    Orca only reports totals since its first event, so the Kindle keeps the
    totals it first sees each day (settings stats_days) and subtracts the
    ones from a week ago. Until it has a week of them, agent numbers count
    from the oldest ("since Sat").
--]]

local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local heat = require("orca.render.heat")
local util = require("orca.core.util")

local Week = {}
Week.__index = Week

local KEEP_DAYS = 15
local DAY = 86400

function Week.new(app)
    return setmetatable({ app = app }, Week)
end

local function timeOf(day)
    local y, m, d = day:match("^(%d+)-(%d+)-(%d+)$")
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

-- Sum and number of days with any, from `from` to `to` days ago.
local function sum(values, now, from, to)
    local total, days = 0, 0
    for i = from, to do
        local v = tonumber(values[heat.day(now - i * DAY)])
        if v and v > 0 then total, days = total + v, days + 1 end
    end
    return total, days
end

-- Remembers Orca's totals the first time they are seen each day.
function Week:record(stats, now)
    if type(stats) ~= "table" or not tonumber(stats.totalAgentTimeMs) then return end
    now = now or os.time()
    local days = util.tbl(self.app.settings:get("stats_days"))
    local today = heat.day(now)
    if days[today] then return end
    local kept, oldest = {}, heat.day(now - KEEP_DAYS * DAY)
    for day, v in pairs(days) do
        if day >= oldest then kept[day] = v end
    end
    kept[today] = { agents = util.num(stats.totalAgentsSpawned), ms = util.num(stats.totalAgentTimeMs) }
    self.app.settings:set("stats_days", kept)
end

-- The totals at the start of the week (6 days ago, or the closest before
-- it); else the oldest kept, with partial = true.
function Week:baseline(now)
    local days = util.tbl(self.app.settings:get("stats_days"))
    local start = heat.day(now - 6 * DAY)
    local before, after
    for day in pairs(days) do
        if day <= start then
            if not before or day > before then before = day end
        elseif not after or day < after then
            after = day
        end
    end
    local day = before or after
    return day and days[day], day, before == nil
end

-- The "This week" section for Home or the sleep picture, or nil.
function Week:section(kindle, stats, now)
    now = now or os.time()
    local app, items = self.app, {}
    local duration = app.home.duration

    local days = kindle and kindle.days or {}
    local read, read_days = sum(days, now, 0, 6)
    local before = sum(days, now, 7, 13)
    if read > 0 or before > 0 then
        local note = T(_("%1 of 7 days"), read_days)
        local diff = read - before
        if before > 0 and math.abs(diff) >= 60 then
            local more = diff > 0 and _("%1 more than the week before") or _("%1 less than the week before")
            note = note .. " · " .. T(more, duration(math.abs(diff)))
        end
        table.insert(items, { value = duration(read), label = _("Reading"), note = note })
    end

    local github = app.github
    local merged = github and github.merged
    local cal = github and github:calendar()
    local contributions = cal and sum(util.tbl(cal.days), now, 0, 6)
    if merged then
        table.insert(items, { value = tostring(merged), label = _("Pull requests merged"),
                              note = contributions and T(_("%1 contributions on GitHub"), contributions) or nil })
    elseif contributions then
        table.insert(items, { value = tostring(contributions), label = _("GitHub contributions") })
    end

    if type(stats) == "table" and tonumber(stats.totalAgentTimeMs) then
        local base, day, partial = self:baseline(now)
        -- Kept only since today: nothing to compare yet.
        if base and day ~= heat.day(now) then
            local ms = math.max(0, util.num(stats.totalAgentTimeMs) - util.num(base.ms))
            local agents = math.max(0, util.num(stats.totalAgentsSpawned) - util.num(base.agents))
            local note = T(_("%1 agents started"), math.floor(agents))
            if partial then note = note .. " · " .. T(_("since %1"), _.date("%a", timeOf(day))) end
            table.insert(items, { value = duration(ms / 1000), label = _("Agent time"), note = note,
                                  callback = function() app.accounts:open() end })
        end
    end

    if #items == 0 then return nil end
    return { title = _("This week"), card = { type = "figures", items = items } }
end

return Week
