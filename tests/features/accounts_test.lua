-- Account and usage screen.
local H = require("tests.harness")

local HOUR = 3600 * 1000

local function snapshot()
    local now = os.time() * 1000
    return {
        claude = {
            accounts = {
                { id = "a1", email = "will@work.com", authMethod = "subscription-oauth", organizationName = "Work" },
                { id = "a2", email = "will@home.com", authMethod = "subscription-oauth" },
            },
            activeAccountId = "a1",
            systemDefaultEmail = "will@pc.com",
        },
        codex = { accounts = {}, activeAccountId = nil },
        rateLimits = { claude = {
            session = { usedPercent = 42.4, resetsAt = now + 2 * HOUR + 46 * 60 * 1000 + 30000 },
            weekly = { usedPercent = 91, resetsAt = now + 3 * 24 * HOUR + 4 * HOUR + 60000 },
        } },
    }
end

local function opened(extra)
    local r = { ["accounts.list"] = snapshot(), ["accounts.selectClaude"] = { accounts = {} },
                ["stats.summary"] = { totalAgentsSpawned = 4, totalPRsCreated = 1, totalAgentTimeMs = 7200000 } }
    for k, v in pairs(extra or {}) do r[k] = v end
    local app, t = H.app{ results = r, quiet = true }
    app.accounts:open()
    t.settle()
    return app, t
end

H.test("usage, accounts and Orca totals", function()
    local _, t = opened()
    local top = t.top()
    H.eq(top.title, "Account and usage")
    H.eq(top.sections[1].title, "Usage")
    H.eq(t.row("5-hour limit").title, "5-hour limit: 42% used")
    H.eq(t.row("5-hour limit").detail, "resets in 2h 46m")
    H.eq(t.row("Weekly limit").detail, "resets in 3d 4h")
    H.eq(t.row("Weekly limit").bold, true)
    H.eq(top.sections[2].title, "Claude accounts")
    H.eq(t.row("will@work.com").glyph, "✓")
    H.eq(t.row("will@work.com").subtitle, "Work · Subscription")
    H.eq(t.row("System default").subtitle, "will@pc.com")
    H.eq(t.row("Agent time").detail, "2.0 h")
    H.eq(t.row("Agents started").detail, "4")
    H.eq(t.lastCall("accounts.list").params.refreshUsage, true)
end)

H.test("switching accounts is confirmed and sent once", function()
    local _, t = opened()
    H.eq(t.row("will@work.com").callback, nil, "active account has nothing to do")
    t.tap("will@home.com")
    local c = t.lastCard()
    H.eq(c.kind, "confirm")
    H.eq(c.title, "Switch to will@home.com?")
    H.eq(c.ok_text, "Switch")
    t.press("Switch")
    H.eq(t.lastCall("accounts.selectClaude").params.accountId, "a2")
    H.eq(t.toasts[#t.toasts], "Switched to will@home.com")
    H.eq(#t.called("accounts.list"), 2, "reloaded")
end)

H.test("System default sends a null account id", function()
    local api = require("orca.api.accounts")
    local _, t = opened()
    t.tap("System default")
    t.press("Switch")
    local call = t.lastCall("accounts.selectClaude")
    H.eq(call.params.accountId, api.null)
end)

H.test("a failed stats call still shows the accounts", function()
    local _, t = opened{ ["stats.summary"] = false }
    t.row("will@work.com")
    for _, s in ipairs(t.top().sections) do H.eq(s.title ~= "Orca", true) end
end)

H.test("errors land in the screen", function()
    local _, t = opened{ ["accounts.list"] = function() return nil, "connection refused" end }
    H.has(t.top().empty, "Can't reach your PC")
end)
