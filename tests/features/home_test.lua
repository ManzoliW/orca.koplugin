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
    H.eq(t.row("All workspaces").detail, "2")
    t.tap("All workspaces")
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
