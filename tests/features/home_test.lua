-- Home dashboard, workspace list and workspace screens.
local H = require("tests.harness")

local function section(spec, title)
    for _, s in ipairs(spec.sections) do
        if s.title == title then return s end
    end
    error("no section '" .. title .. "'", 2)
end

local USAGE = { rateLimits = { claude = {
    session = { usedPercent = 32.4, resetsAt = (os.time() + 2 * 3600 + 46 * 60) * 1000 },
    weekly = { usedPercent = 5 },
} } }

H.test("home leads with the session that needs you, its question and answers", function()
    local app, t = H.app()
    app.home:open()
    t.settle()
    local top = t.top()
    H.eq(top.title, "Orca")
    H.has(top.subtitle, "1 needs you")
    local hero = top.sections[1].card
    H.eq(hero.type, "hero")
    H.eq(hero.title, "Claude needs you in kindle")
    H.has(hero.mono, "Do you want to proceed?")
    H.eq(hero.buttons[1][1].text, "1 Yes")
    H.eq(hero.buttons[1][2].text, "2 No")
    H.eq(hero.buttons[1][3].text, "Esc")

    hero.buttons[1][1].callback()
    t.settle()
    H.eq(t.lastCall("terminal.send").params.text, "1")
    H.eq(t.lastCall("terminal.send").params.terminal, "t1")
    H.has(t.toasts[#t.toasts], "Sent 1 Yes")
end)

H.test("home groups active workspaces and links to the rest", function()
    local app, t = H.app()
    app.home:open()
    t.settle()
    local top = t.top()
    H.eq(section(top, "Needs you").rows[1].title, "kindle")
    H.eq(section(top, "Needs you").rows[1].glyph, "●")
    H.has(section(top, "Needs you").rows[1].subtitle, "main · 2 sessions")
    H.eq(section(top, "Working").rows[1].title, "faxa")
    top.tabs[2].callback()
    t.settle()
    H.eq(t.top().title, "Workspaces")
    H.eq(t.top().sections[1].rows[1].title, "kindle")
end)

H.test("home shows usage bars, today's numbers and tabs", function()
    local today = os.date("!%Y-%m-%dT%H:%M:%S.000Z")
    local app, t = H.app({ results = {
        ["accounts.list"] = USAGE,
        ["stats.summary"] = { totalAgentsSpawned = 183, totalPRsCreated = 15, totalAgentTimeMs = 13 * 3600000 },
        ["aiVault.listSessions"] = { sessions = { { updatedAt = today }, { updatedAt = "2020-01-01T00:00:00.000Z" } } },
    } })
    app.home:open()
    t.settle()
    local top = t.top()
    local gauges = section(top, "Claude usage").card
    H.eq(gauges.items[1].label, "5h")
    H.eq(gauges.items[1].percent, 32.4)
    H.has(gauges.items[1].detail, "resets 2h")
    H.eq(gauges.items[2].label, "Week")
    local tiles = section(top, "Activity").card.items
    H.eq(tiles[1].value, "1"); H.eq(tiles[1].label, "chats today")
    H.eq(tiles[2].value, "183")
    H.eq(tiles[3].value, "15")
    H.eq(tiles[4].value, "13 h")
    H.eq(top.tabs[1].text, "Home"); H.eq(top.tabs[1].selected, true)
    top.tabs[3].callback()
    t.settle()
    H.eq(t.top().title, "Conversations")
end)

H.test("home reuses usage and conversations for a while, and redraws the last dashboard first", function()
    local app, t = H.app({ results = { ["accounts.list"] = USAGE, ["aiVault.listSessions"] = { sessions = {} } } })
    app.home:open()
    t.settle()
    H.eq(#t.called("aiVault.listSessions"), 1)
    app.nav:close()
    local first
    local push = app.nav.push
    app.nav.push = function(nav, spec) first = first or spec; return push(nav, spec) end
    app.home:open()
    t.settle()
    H.eq(first.subtitle, "Updating…")
    H.eq(section(first, "Claude usage").card.type, "gauges")
    H.eq(#t.called("aiVault.listSessions"), 1)
    H.eq(#t.called("accounts.list"), 1)
    t.top().refresh()
    t.settle()
    H.eq(#t.called("accounts.list"), 2)
end)

H.test("home without usage or totals still shows workspaces", function()
    local app, t = H.app()
    app.home:open()
    t.settle()
    for _, s in ipairs(t.top().sections) do
        H.eq(s.title == "Claude usage" or s.title == "Activity", false, "section " .. tostring(s.title))
    end
end)

local function fakeLibrary(opened)
    local today = os.date("%Y-%m-%d")
    local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
    return {
        recent = function() return { { file = "/b/spidercat.azw3", title = "Spider Cat", authors = "A. Writer",
                                       percent = 64 } } end,
        readingDays = function() return { [today] = 22 * 60, [yesterday] = 3600 } end,
        files = function() return {
            { file = "/b/spidercat.azw3", title = "Spider Cat", percent = 64, time = os.time() },
            { file = "/docs/plan.epub", title = "Plan", time = os.time() - 7200 },
            { file = "/docs/diff.epub", title = "Diff", percent = 100, status = "complete", time = os.time() - 3 * 86400 },
        } end,
        cover = function() return nil end,
        open = function(file) table.insert(opened, file) end,
    }
end

H.test("home shows the book being read, reading days and Claude's shelf", function()
    local opened = {}
    local app, t = H.app({ library = fakeLibrary(opened) })
    app.home:open()
    t.settle()
    local top = t.top()
    local book = section(top, "Continue reading").card
    H.eq(book.type, "book")
    H.eq(book.title, "Spider Cat")
    H.eq(book.percent, 64)
    H.eq(book.detail, "64% read · 22 min today")
    local reading = section(top, "Reading").card
    H.eq(reading.type, "heatmap")
    H.has(reading.caption, "2-day streak · 22 min today")
    local shelf = section(top, "From Claude").rows
    H.eq(#shelf, 2)                         -- the book being read isn't repeated
    H.eq(shelf[1].title, "Plan"); H.has(shelf[1].subtitle, "New")
    H.has(shelf[2].subtitle, "Finished")
    book.callback()
    H.eq(opened[1], "/b/spidercat.azw3")
    H.eq(#t.stack, 0)
end)

H.test("home still shows the Kindle's side when the PC can't be reached", function()
    local app, t = H.app({ library = fakeLibrary({}),
        results = { ["worktree.ps"] = function() return nil, "proxy: connection refused" end } })
    app.home:open()
    t.settle()
    local top = t.top()
    H.eq(top.sections[1].card.title, "Can't reach your PC")
    H.eq(section(top, "Continue reading").card.title, "Spider Cat")
end)

H.test("reading caption says when you last read once the streak is over", function()
    local app = H.app()
    local card = app.home:readingCard({ [os.date("%Y-%m-%d", os.time() - 5 * 86400)] = 600 })
    H.has(card.caption, "last read " .. os.date("%a %d %b", os.time() - 5 * 86400))
end)

H.test("Home.duration", function()
    local Home = require("orca.features.home")
    H.eq(Home.duration(540), "9 min")
    H.eq(Home.duration(7500), "2 h 05")
    H.eq(Home.duration(nil), "0 min")
end)

H.test("workspace lists sessions with state words and places to go", function()
    local app, t = H.app()
    app.home:open()
    t.settle()
    t.tap("kindle")
    local top = t.top()
    H.eq(top.title, "kindle")
    H.eq(t.row("Claude").detail, "Needs you")
    t.row("Git"); t.row("Files")
    t.back()
    H.eq(t.top().title, "Orca")
end)

H.test("pick mode hands back the chosen session", function()
    local app, t = H.app()
    local picked
    app.home:open({ title = "Send to which session?", on_pick = function(term) picked = term end })
    t.settle()
    H.eq(t.top().add, nil)
    H.eq(t.top().tabs, nil)
    t.tap("kindle")
    t.tap("zsh")
    H.eq(picked.handle, "t2")
end)

H.test("connection errors show in the screen with a refresh", function()
    local app, t = H.app({ results = { ["worktree.ps"] = function() return nil, "proxy: connection refused" end } })
    app.home:open()
    t.settle()
    H.has(t.top().empty, "Can't reach your PC")
    H.eq(type(t.top().refresh), "function")
end)
