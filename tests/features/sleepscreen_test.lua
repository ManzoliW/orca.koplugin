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
