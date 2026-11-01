--[[
    Activity heatmaps: per-day values in, shade levels and streaks out.
    No widgets, so it runs in the PC tests.

    Levels split the days that have any activity at their 25th, 50th and
    75th percentiles, so one long day doesn't wash out the rest:
    0 = nothing, 1–4 = light to dark.
--]]

local heat = {}

heat.LEVELS = 4

function heat.day(t)
    return os.date("%Y-%m-%d", t)
end

-- values = { ["YYYY-MM-DD"] = number } -> thresholds { q25, q50, q75 }
function heat.thresholds(values)
    local list = {}
    for _, v in pairs(values or {}) do
        if v > 0 then table.insert(list, v) end
    end
    table.sort(list)
    if #list == 0 then return {} end
    local function at(p) return list[math.max(1, math.ceil(#list * p))] end
    return { at(0.25), at(0.5), at(0.75) }
end

function heat.level(v, thresholds)
    if not v or v <= 0 then return 0 end
    local level = 1
    for _, limit in ipairs(thresholds) do
        if v > limit then level = level + 1 end
    end
    return math.min(level, heat.LEVELS)
end

-- Days in a row with activity, ending today (or yesterday, when today
-- has none yet: the streak isn't broken before the day is over).
function heat.streak(values, now)
    now = now or os.time()
    local t = now
    if not ((values[heat.day(t)] or 0) > 0) then t = t - 86400 end
    local n = 0
    while (values[heat.day(t)] or 0) > 0 do
        n = n + 1
        t = t - 86400
    end
    return n
end

--[[
    The grid: `weeks` columns of 7 days (Sunday on top), the last column
    holding today. Returns columns of { day, value, level, future } cells.
--]]
function heat.grid(values, weeks, now)
    now = now or os.time()
    local thresholds = heat.thresholds(values)
    local today = os.date("*t", now)
    -- Noon avoids skipping or repeating a day across DST changes.
    local noon = os.time{ year = today.year, month = today.month, day = today.day, hour = 12 }
    local start = noon - ((weeks - 1) * 7 + (today.wday - 1)) * 86400
    local columns = {}
    for w = 1, weeks do
        local column = {}
        for d = 1, 7 do
            local t = start + ((w - 1) * 7 + (d - 1)) * 86400
            local key = heat.day(t)
            local value = values[key]
            column[d] = { day = key, value = value, level = heat.level(value, thresholds), future = t > noon }
        end
        columns[w] = column
    end
    return columns
end

local function timeOf(key)
    local y, m, d = key:match("^(%d+)-(%d+)-(%d+)$")
    return y and os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 } or nil
end

-- The latest day with activity, as a time (noon), or nil.
function heat.last(values)
    local last
    for key, v in pairs(values or {}) do
        if v > 0 and (not last or key > last) then last = key end
    end
    return last and timeOf(last)
end

-- Columns where a month begins, for labels under the grid: { {column, label} }.
function heat.months(columns)
    local found, previous = {}, nil
    for w, days in ipairs(columns) do
        local month = days[1].day:sub(1, 7)
        if previous and month ~= previous then
            table.insert(found, { column = w, label = os.date("%b", timeOf(month .. "-01")) })
        end
        previous = month
    end
    return found
end

return heat
