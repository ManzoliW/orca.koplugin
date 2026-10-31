-- Automations list and detail.
local H = require("tests.harness")

local function list()
    local now = os.time() * 1000
    return { automations = {
        { id = "au1", name = "Morning triage", prompt = "Look at new issues and label them.", agentId = "claude",
          enabled = true, rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timezone = "Europe/Rome",
          nextRunAt = now + 3 * 3600 * 1000 + 60000, lastRunAt = now - 2 * 3600 * 1000, workspaceId = H.WT.worktreeId },
        { id = "au2", name = "Weekly report", prompt = "Summarise the week.", agentId = "codex",
          enabled = false, rrule = "FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=30", nextRunAt = now + 86400000,
          workspaceId = nil },
    } }
end

local function opened(extra)
    local now = os.time() * 1000
    local r = {
        ["automation.list"] = list(),
        ["automation.runs"] = { runs = {
            { id = "r1", automationId = "au1", title = "Morning triage", status = "dispatch_failed", trigger = "scheduled",
              scheduledFor = now - 86400000, startedAt = nil, workspaceId = nil, error = "Agent not installed", runNumber = 1 },
            { id = "r2", automationId = "au1", title = "Morning triage", status = "dispatched", trigger = "manual",
              scheduledFor = now - 3600000, startedAt = now - 3600000, workspaceId = H.WT.worktreeId, runNumber = 2 },
        } },
        ["automation.runNow"] = { run = { id = "r3", status = "dispatched" } },
        ["automation.update"] = { automation = { id = "au1", enabled = false } },
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    local app, t = H.app{ results = r, quiet = true }
    app.automations:open()
    t.settle()
    return app, t
end

H.test("schedules read like a person wrote them", function()
    local A = require("orca.features.automations")
    H.eq(A.schedule("FREQ=DAILY;BYHOUR=9;BYMINUTE=0"), "Daily 09:00")
    H.eq(A.schedule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=15"), "Weekdays 08:15")
    H.eq(A.schedule("FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=30"), "Fridays 17:30")
    H.eq(A.schedule("FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=7;BYMINUTE=0"), "Mon, Thu 07:00")
    H.eq(A.schedule("FREQ=HOURLY;BYMINUTE=5"), "Hourly at :05")
    H.eq(A.schedule("FREQ=MONTHLY;BYMONTHDAY=1"), "FREQ=MONTHLY;BYMONTHDAY=1")
end)

H.test("list shows schedule, next run and on/off", function()
    local _, t = opened()
    H.eq(t.top().title, "Automations")
    local row = t.row("Morning triage")
    H.eq(row.subtitle, "Daily 09:00 · next in 3 h")
    H.eq(row.detail, "On")
    H.eq(t.row("Weekly report").detail, "Off")
    H.eq(t.row("Weekly report").subtitle, "Fridays 17:30")
    H.eq(t.rows()[1].title, "Morning triage", "enabled first")
end)

H.test("automation screen: facts, actions and recent runs", function()
    local _, t = opened()
    t.tap("Morning triage")
    local top = t.top()
    H.eq(top.title, "Morning triage")
    H.eq(t.lastCall("automation.runs").params.automationId, "au1")
    H.eq(t.lastCall("automation.runs").params.limit, 10)
    H.eq(t.row("Agent").detail, "Claude")
    H.eq(t.row("Workspace").detail, "kindle")
    H.eq(t.row("Last run").detail, "2 h ago")
    H.eq(t.row("Turn off").title, "Turn off")
    H.eq(top.sections[3].title, "Recent runs")
    H.eq(top.sections[3].rows[1].title, "Run 2", "newest first")
    H.eq(top.sections[3].rows[1].glyph, "✓")
    H.eq(top.sections[3].rows[1].detail, "Started")
    H.eq(top.sections[3].rows[2].glyph, "✕")
    H.eq(top.sections[3].rows[2].detail, "Failed")
end)

H.test("Run now is confirmed and sent once", function()
    local _, t = opened()
    t.tap("Morning triage")
    t.tap("Run now")
    local c = t.lastCard()
    H.eq(c.title, "Run Morning triage now?")
    H.eq(c.ok_text, "Run")
    H.has(c.text, "Claude session in kindle")
    t.press("Run")
    H.eq(t.lastCall("automation.runNow").params.id, "au1")
    H.eq(t.toasts[#t.toasts], "Started Morning triage")
end)

H.test("Turn off updates without asking", function()
    local _, t = opened()
    t.tap("Morning triage")
    t.tap("Turn off")
    local call = t.lastCall("automation.update")
    H.eq(call.params.id, "au1")
    H.eq(call.params.updates.enabled, false)
    H.eq(t.toasts[#t.toasts], "Turned off Morning triage")
end)

H.test("a started run opens its workspace; a failed one explains", function()
    local app, t = opened()
    local opened_wt
    app.workspace = { open = function(_, wt) opened_wt = wt end }
    t.tap("Morning triage")
    t.tap("Run 2")
    H.eq(opened_wt.worktreeId, H.WT.worktreeId)
    t.tap("Run 1")
    H.has(t.lastCard().text, "Agent not installed")
end)

H.test("empty list says where to create one", function()
    local _, t = opened{ ["automation.list"] = { automations = {} } }
    H.has(t.top().empty, "Create one in Orca")
end)
