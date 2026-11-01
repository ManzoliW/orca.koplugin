-- This week: reading, pull requests and agents over the last 7 days.
local H = require("tests.harness")

local DAY = 86400
local NOW = os.time{ year = 2026, month = 11, day = 2, hour = 9 }   -- a Monday

local function day(ago) return os.date("%Y-%m-%d", NOW - ago * DAY) end

local function items(section)
    local out = {}
    for _, item in ipairs(section.card.items) do out[item.label] = item end
    return out
end

H.test("reading this week, on how many days, against the week before", function()
    local app = H.app({ quiet = true })
    local kindle = { days = { [day(0)] = 1800, [day(2)] = 3600, [day(9)] = 1200 } }
    local section = app.week:section(kindle, nil, NOW)
    H.eq(section.title, "This week")
    H.eq(section.card.type, "figures")
    local reading = items(section)["Reading"]
    H.eq(reading.value, "1 h 30")
    H.eq(reading.note, "2 of 7 days · 1 h 10 more than the week before")

    kindle.days = { [day(1)] = 600, [day(8)] = 1800 }
    H.eq(items(app.week:section(kindle, nil, NOW))["Reading"].note, "1 of 7 days · 20 min less than the week before")
    H.eq(app.week:section({ days = {} }, nil, NOW), nil, "nothing to show")
end)

H.test("agent time is today's totals minus the ones kept from a week ago", function()
    local app = H.app({ quiet = true })
    -- Totals first seen on each day; later sightings the same day don't count.
    app.week:record({ totalAgentsSpawned = 200, totalAgentTimeMs = 50 * 3600000 }, NOW - 8 * DAY)
    app.week:record({ totalAgentsSpawned = 210, totalAgentTimeMs = 60 * 3600000 }, NOW - 6 * DAY)
    app.week:record({ totalAgentsSpawned = 999, totalAgentTimeMs = 999 * 3600000 }, NOW - 6 * DAY + 3600)
    app.week:record({ totalAgentsSpawned = 260, totalAgentTimeMs = 101 * 3600000 }, NOW - 20 * DAY + 3600 * 24 * 20)
    local stats = { totalAgentsSpawned = 260, totalAgentTimeMs = 101 * 3600000 }
    local agents = items(app.week:section(nil, stats, NOW))["Agent time"]
    H.eq(agents.value, "41 h 00")
    H.eq(agents.note, "50 agents started")

    -- Old days are dropped.
    app.week:record({ totalAgentsSpawned = 1, totalAgentTimeMs = 1 }, NOW + 10 * DAY)
    H.eq(app.settings:get("stats_days")[day(8)], nil)
end)

H.test("with less than a week kept, agents count from the oldest day", function()
    local app = H.app({ quiet = true })
    app.week:record({ totalAgentsSpawned = 10, totalAgentTimeMs = 0 }, NOW - 2 * DAY)
    local agents = items(app.week:section(nil, { totalAgentsSpawned = 14, totalAgentTimeMs = 1800000 }, NOW))["Agent time"]
    H.eq(agents.value, "30 min")
    H.eq(agents.note, "4 agents started · since Sat")

    local fresh = H.app({ quiet = true })
    fresh.week:record({ totalAgentsSpawned = 10, totalAgentTimeMs = 0 }, NOW)
    H.eq(fresh.week:section(nil, { totalAgentsSpawned = 10, totalAgentTimeMs = 0 }, NOW), nil, "kept only since today")
end)

H.test("pull requests merged, with this week's GitHub contributions", function()
    local app = H.app({ quiet = true })
    app.settings:set("github_user", "me")
    app.settings:set("github_calendar", { user = "me", total = 50,
        days = { [os.date("%Y-%m-%d")] = 7, [os.date("%Y-%m-%d", os.time() - DAY)] = 5,
                 [os.date("%Y-%m-%d", os.time() - 9 * DAY)] = 40 } })
    H.eq(items(app.week:section(nil, nil))["GitHub contributions"].value, "12")
    app.github.merged = 26
    local prs = items(app.week:section(nil, nil))["Pull requests merged"]
    H.eq(prs.value, "26")
    H.eq(prs.note, "12 contributions on GitHub")
end)

H.test("Home shows the week after the activity numbers, and keeps the day's totals", function()
    local app, t = H.app({ results = {
        ["stats.summary"] = { totalAgentsSpawned = 183, totalPRsCreated = 15, totalAgentTimeMs = 13 * 3600000 } } })
    app.week:record({ totalAgentsSpawned = 170, totalAgentTimeMs = 3600000 }, os.time() - 3 * DAY)
    app.home:open()
    t.settle()
    local titles = {}
    for _, s in ipairs(t.top().sections) do table.insert(titles, s.title or "") end
    H.has(table.concat(titles, ","), "Activity,This week")
    H.eq(app.settings:get("stats_days")[os.date("%Y-%m-%d")].agents, 183)
end)

H.test("the sleep picture puts the week under the question when it has the totals", function()
    G_reader_settings = H.store{}
    local app = H.app({ quiet = true })
    app.week:record({ totalAgentsSpawned = 1, totalAgentTimeMs = 0 }, os.time() - 7 * DAY)
    local spec = app.sleep:posterSpec({ states = {}, stats = { totalAgentsSpawned = 5, totalAgentTimeMs = 7200000 } })
    H.eq(spec.sections[1].title, "This week")
    H.eq(app.sleep:posterSpec({ states = {} }).sections[1].title == "This week", false, "only with the totals (Mondays)")
end)
