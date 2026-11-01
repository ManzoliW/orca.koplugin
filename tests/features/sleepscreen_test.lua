-- Sleep screen status: message format, refresh, and restoring the user's message.
local H = require("tests.harness")

local USAGE = { rateLimits = { claude = { status = "ok",
    session = { usedPercent = 61.6, resetsAt = (os.time() + 5420) * 1000 },
    weekly = { usedPercent = 35, resetsAt = (os.time() + 3 * 86400) * 1000 } } } }
local STATES = { snapshots = {
    { worktree = "r::C:/p/kindle", tabs = { { terminal = "t1", title = "Claude", agentStatus = { state = "waiting" } } } },
    { worktree = "r::C:/p/novo", tabs = { { terminal = "t2", agentStatus = { state = "working" } },
                                          { terminal = "t3", agentStatus = { state = "working" } } } },
} }
local VAULT = { sessions = {
    { title = "Older", updatedAt = "2026-10-30T10:00:00.000Z", totalTokens = 10 },
    { title = "KOReader and Tailscale on Kindle", updatedAt = "2026-10-31T14:37:08.173Z", totalTokens = 156321186 },
} }

local function setup(settings)
    G_reader_settings = H.store{ screensaver_message = "Sleeping" }
    return H.app({ settings = settings, quiet = true, results = {
        ["accounts.list"] = USAGE, ["session.tabs.listAll"] = STATES, ["aiVault.listSessions"] = VAULT } })
end

local function lines(msg)
    local out = {}
    for l in (msg .. "\n"):gmatch("([^\n]*)\n") do table.insert(out, l) end
    return out
end

H.test("message lists usage, latest conversation and states", function()
    local app = setup()
    local msg = app.sleep:message(USAGE, {
        t1 = { state = "waiting", worktree = "r::C:/p/kindle" },
        t2 = { state = "working", worktree = "r::C:/p/novo" },
        t3 = { state = "working", worktree = "r::C:/p/novo" },
        t4 = { state = "done", title = "zsh" },
        t5 = { state = "idle", worktree = "r::C:/p/quiet" },
    }, VAULT.sessions[2])
    local l = lines(msg)
    H.eq(l[1], "Claude · " .. os.date("%H:%M"))
    H.has(l[2], "5h: 62% used · resets 1h 30m")
    H.has(l[3], "Week: 35% used · resets ")
    H.eq(l[4], "156M tokens: KOReader and Tai…")
    H.eq(l[5], "needs you: kindle")
    H.eq(l[6], "working: novo")
    H.eq(l[7], "done: zsh")
    H.eq(#l, 7)
    H.eq(msg:find("%%%a"), nil, "no %letter tokens")
end)

H.test("titles are cut without splitting a character", function()
    local app = setup()
    local msg = app.sleep:message(nil, nil, { title = "Ação é ótima ação já é", totalTokens = 1500 })
    H.has(msg, "1.5k tokens: Ação é ótima açã…")
    H.eq(#lines(msg), 2)
end)

H.test("a usage error shows when there are no limits", function()
    local app = setup()
    local msg = app.sleep:message({ rateLimits = { claude = { error = "token expired" } } }, {})
    H.has(msg, "usage: token expired")
end)

H.test("enabling saves the user's message, refreshes it, disabling restores it", function()
    local app, t = setup()
    G_reader_settings:saveSetting("screensaver_show_message", false)
    app.sleep:setEnabled(true)
    H.eq(app.settings:get("sleep_status"), true)
    H.eq(app.settings:get("saved_screensaver").message, "Sleeping")
    app.sleep:refresh(); t.settle()
    local msg = G_reader_settings:readSetting("screensaver_message")
    H.has(msg, "5h: 62% used")
    H.has(msg, "156M tokens: KOReader and Tai…")
    H.has(msg, "needs you: kindle")
    H.has(msg, "working: novo")
    H.eq(G_reader_settings:isTrue("screensaver_show_message"), true)
    H.eq(t.lastCall("accounts.list").params.refreshUsage, true)
    app.sleep:refresh(); t.settle()
    H.eq(t.lastCall("accounts.list").params.refreshUsage, false)
    H.eq(#t.called("aiVault.listSessions"), 1, "conversation cached between usage refreshes")

    app.sleep:setEnabled(false)
    H.eq(G_reader_settings:readSetting("screensaver_message"), "Sleeping")
    H.eq(G_reader_settings:isTrue("screensaver_show_message"), false)
    H.eq(app.settings:has("saved_screensaver"), false)
    H.eq(app.sleep.refresher, nil)
end)

H.test("start schedules only when enabled and paired", function()
    local app = setup({ pairing_url = "x", sleep_status = true })
    app.sleep:start()
    H.eq(type(app.sleep.refresher), "function")
    app.sleep:stop()
    H.eq(app.sleep.refresher, nil)
    local unpaired = setup({ sleep_status = true })
    unpaired.sleep:start()
    H.eq(unpaired.sleep.refresher, nil)
end)

local function setupImage(draw, settings)
    G_reader_settings = H.store{ screensaver_message = "Sleeping", screensaver_type = "cover",
                                 screensaver_show_message = true }
    local drawn = {}
    local app, t = H.app({ settings = settings, quiet = true, sleep_dir = "/tmp/orca-sleep",
        poster = function(spec, path)
            table.insert(drawn, { spec = spec, path = path })
            if draw == false then return nil, "no framebuffer" end
            return true
        end,
        results = { ["accounts.list"] = USAGE, ["session.tabs.listAll"] = STATES, ["aiVault.listSessions"] = VAULT } })
    return app, t, drawn
end

local function sectionTitles(spec)
    local titles = {}
    for _, s in ipairs(spec.sections) do table.insert(titles, s.title) end
    return table.concat(titles, ", ")
end

H.test("the sleep screen becomes a picture of usage and sessions, and turning off restores the user's", function()
    local app, t, drawn = setupImage()
    app.sleep:setEnabled(true)
    app.sleep:refresh(); t.settle()
    H.eq(drawn[1].path, "/tmp/orca-sleep/orca.png")
    local spec = drawn[1].spec
    H.has(spec.subtitle, "As of ")
    H.has(sectionTitles(spec), "Claude usage, Sessions")
    H.eq(spec.sections[2].card.items[1].percent, 61.6)
    H.eq(spec.sections[2].card.callback, nil)
    local rows = spec.sections[3].rows
    H.eq(rows[1].title, "kindle"); H.eq(rows[1].detail, "Needs you")
    H.eq(rows[2].title, "novo")
    H.eq(G_reader_settings:readSetting("screensaver_type"), "random_image")
    H.eq(G_reader_settings:readSetting("screensaver_dir"), "/tmp/orca-sleep")
    H.eq(G_reader_settings:isTrue("screensaver_show_message"), false)
    H.has(G_reader_settings:readSetting("screensaver_message"), "5h: 62% used")

    app.sleep:setEnabled(false)
    H.eq(G_reader_settings:readSetting("screensaver_type"), "cover")
    H.eq(G_reader_settings:readSetting("screensaver_dir"), nil)
    H.eq(G_reader_settings:readSetting("screensaver_message"), "Sleeping")
    H.eq(G_reader_settings:isTrue("screensaver_show_message"), true)
end)

H.test("when the picture can't be drawn the message shows on the user's own sleep screen", function()
    local app, t = setupImage(false)
    app.sleep:setEnabled(true)
    G_reader_settings:saveSetting("screensaver_type", "random_image")
    G_reader_settings:saveSetting("screensaver_dir", "/tmp/orca-sleep")
    app.sleep:refresh(); t.settle()
    H.eq(G_reader_settings:readSetting("screensaver_type"), "cover")
    H.eq(G_reader_settings:isTrue("screensaver_show_message"), true)
end)

H.test("turned on before pictures existed: the type is remembered on start", function()
    local app = setupImage(true, { pairing_url = "x", sleep_status = true,
        saved_screensaver = { show = true, message = "Old" } })
    app.sleep:start()
    app.sleep:stop()
    local saved = app.settings:get("saved_screensaver")
    H.eq(saved.image, true); H.eq(saved.type, "cover"); H.eq(saved.message, "Old"); H.eq(saved.show, true)
end)

H.test("the picture adds the book and the heatmaps when there is room for them", function()
    local app, t, drawn = setupImage()
    app.library = {
        recent = function() return { { file = "/b.epub", title = "B", percent = 10 } } end,
        readingDays = function() return { [os.date("%Y-%m-%d")] = 600 } end,
        files = function() return {} end,
        cover = function() return nil end,
    }
    app.settings:set("github_user", "me")
    app.settings:set("github_calendar", { user = "me", at = os.time(), total = 5, days = { [os.date("%Y-%m-%d")] = 5 } })
    app.sleep:setEnabled(true)
    app.sleep:refresh(); t.settle()
    H.eq(sectionTitles(drawn[1].spec), "Claude usage, Sessions, Continue reading, Reading, GitHub · me")
end)

H.test("the picture leads with the question a session is waiting on", function()
    local app, t, drawn = setupImage()
    app.sleep:setEnabled(true)
    app.sleep:refresh(); t.settle()
    local hero = drawn[1].spec.sections[1].card
    H.eq(hero.type, "hero")
    H.eq(hero.title, "Claude needs you in kindle")
    H.has(hero.mono, "Do you want to proceed?")
    H.eq(#hero.buttons, 1, "answers only: nothing on a sleep screen can be tapped")
    H.eq(hero.buttons[1][1].text, "1 Yes")
end)

H.test("waking on a picture with a question opens Home on it", function()
    local app, t = setupImage()
    app.sleep:setEnabled(true)
    app.sleep:refresh(); t.settle()
    app.sleep:wake()
    t.flush(1); t.settle()
    H.eq(t.top().title, "Orca")
    H.eq(t.top().sections[1].card.title, "Claude needs you in kindle")
end)

H.test("waking doesn't open Home without a question, over Orca, or when turned off", function()
    local app, t = setupImage()
    app.sleep:setEnabled(true)
    app.sleep:wake(); t.flush(1); t.settle()
    H.eq(app.nav:isOpen(), false, "no picture with a question yet")

    app.sleep:refresh(); t.settle()
    app.settings:set("wake_to_question", false)
    app.sleep:wake(); t.flush(1); t.settle()
    H.eq(app.nav:isOpen(), false, "turned off")

    app.settings:set("wake_to_question", true)
    app.automations:open(); t.settle()
    local top = t.top()
    app.sleep:wake(); t.flush(1); t.settle()
    H.eq(t.top(), top, "Orca was already open")
end)

H.test("a popup with a question holds the wake back; a finished one doesn't", function()
    local app, t = setupImage()
    app.sleep:setEnabled(true)
    app.sleep:refresh(); t.settle()
    app.notify.card, app.notify.card_item = {}, { kind = "needs" }
    app.sleep:wake(); t.flush(1); t.settle()
    H.eq(app.nav:isOpen(), false)
    app.notify.card_item = { kind = "done" }
    app.sleep:wake(); t.flush(1); t.settle()
    H.eq(t.top().title, "Orca")
end)
