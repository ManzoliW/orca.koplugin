-- Notifications while reading: stream, catch-up, popups and the polling fallback.
local H = require("tests.harness")

local PANE = "tab1:11111111-1111-4111-8111-111111111111"
local PANE2 = "tab2:22222222-2222-4222-8222-222222222222"

local function results(extra)
    local r = {
        ["notifications.subscribe"] = { type = "ready", subscriptionId = "notifications-c1-1", epoch = "e1" },
        ["notifications.getMissedSince"] = { notifications = {}, epoch = "e1" },
        ["notifications.unsubscribe"] = { unsubscribed = true },
        ["terminal.list"] = { terminals = {
            { handle = "t1", title = "Claude", tabId = "tab1", leafId = "11111111-1111-4111-8111-111111111111",
              worktreePath = "C:\\p\\kindle", agentIdentity = "claude" },
            { handle = "t2", title = "zsh", tabId = "tab2", leafId = "22222222-2222-4222-8222-222222222222" },
        } },
        ["terminal.read"] = { terminal = { tail = {
            "Do you want to make this edit?", "❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No", "Esc to cancel" } } },
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

local function event(seq, state, extra)
    local ev = { type = "notification", source = "agent-task-complete", title = "Claude Code", body = "Edit main.lua?",
                 worktreeId = H.WT.worktreeId, paneKey = PANE, notificationId = "n" .. seq,
                 notificationSeq = seq, notificationEpoch = "e1", agentState = state }
    for k, v in pairs(extra or {}) do ev[k] = v end
    return ev
end

local function push(app, t, ev, id)
    table.insert(t.client.events, { id = id or "s1", result = ev })
    app.connection:dispatch(t.client:takeEvents())
    t.settle()
end

local function started(opts)
    opts = opts or {}
    local settings = { pairing_url = "orca://pair?code=x" }
    for k, v in pairs(opts.settings or {}) do settings[k] = v end
    local app, t = H.app{ results = results(opts.results), settings = settings, quiet = true }
    app.session = { opened = {}, showing = nil,
                    open = function(self, term, wt) table.insert(self.opened, { term = term, wt = wt }) end,
                    isShowing = function(self, handle) return self.showing == handle end }
    app.notify:start()
    t.settle()
    return app, t
end

local function cards(t)
    local n = 0
    for _, c in ipairs(t.cards) do if c.kind == "card" then n = n + 1 end end
    return n
end

H.test("start subscribes, catches up and sets a first watermark silently", function()
    local app, t = started{ results = { ["notifications.getMissedSince"] = {
        notifications = { event(7, "done") }, epoch = "e1" } } }
    H.eq(t.lastCall("notifications.subscribe").params.includeDesktopSuppressed, true)
    H.eq(t.lastCall("notifications.getMissedSince").params.lastSeenSeq, 0)
    H.eq(app.settings:get("notify_watermark").seq, 7)
    H.eq(cards(t), 0, "old news on first run")
end)

H.test("needs-you pops up with the question and its choices; answering sends once", function()
    local app, t = started()
    push(app, t, event(1, "waiting"))
    local c = t.lastCard()
    H.eq(c.title, "Claude needs you in kindle")
    H.has(c.text, "Edit main.lua?")
    H.has(c.mono, "1. Yes")
    H.eq(c.buttons[1][1].text, "1 Yes")
    H.eq(c.buttons[1][2].text, "2 Yes, and do…")
    H.eq(c.buttons[1][4].text, "Esc")
    H.eq(c.buttons[2][1].text, "Later")
    H.eq(c.buttons[2][2].text, "Open")
    t.press("1 Yes")
    local send = t.lastCall("terminal.send")
    H.eq(send.params.terminal, "t1")
    H.eq(send.params.text, "1")
    H.eq(send.params.enter, false)
    H.eq(t.toasts[#t.toasts], "Sent 1 Yes")
    H.eq(app.settings:get("notify_watermark").seq, 1)
end)

H.test("Esc sends the escape key", function()
    local app, t = started()
    push(app, t, event(1, "blocked"))
    t.press("Esc")
    H.eq(t.lastCall("terminal.send").params.text, "\27")
end)

H.test("duplicates are dropped and later events wait their turn", function()
    local app, t = started()
    push(app, t, event(1, "waiting"))
    push(app, t, event(1, "waiting"))
    H.eq(cards(t), 1)
    push(app, t, event(2, "done", { paneKey = PANE2, worktreeId = H.WT2.worktreeId }))
    H.eq(cards(t), 1, "no stacking")
    t.press("Later")
    H.eq(cards(t), 2)
    local c = t.lastCard()
    H.eq(c.title, "Claude finished in faxa")
    H.eq(#c.buttons, 1, "finished: Later and Open only")
end)

H.test("Open shows the session; the session on screen gets no popup", function()
    local app, t = started()
    push(app, t, event(1, "done"))
    t.press("Open")
    H.eq(app.session.opened[1].term.handle, "t1")
    H.eq(app.session.opened[1].wt.worktreeId, H.WT.worktreeId)
    app.session.showing = "t1"
    push(app, t, event(2, "waiting"))
    H.eq(cards(t), 1)
end)

H.test("inside Orca a toast replaces the popup", function()
    local app, t = started()
    app.nav:push{ title = "Orca" }
    push(app, t, event(1, "waiting"))
    H.eq(cards(t), 0)
    H.eq(t.toasts[#t.toasts], "Claude needs you in kindle")
end)

H.test("a dismissal closes the popup", function()
    local app, t = started()
    push(app, t, event(1, "waiting"))
    local c = t.lastCard()
    push(app, t, { type = "dismiss", notificationId = "n1" })
    H.eq(c.closed, true)
end)

H.test("waking up reports what happened in one popup", function()
    local app, t = started{ settings = { notify_watermark = { seq = 3, epoch = "e1" } } }
    H.results["notifications.getMissedSince"] = { epoch = "e1", notifications = {
        event(4, "done", { paneKey = PANE2, worktreeId = H.WT2.worktreeId }),
        event(5, "waiting"),
        event(6, "done", { paneKey = "tab9:x", worktreeId = H.WT2.worktreeId, notificationId = "n6" }),
    } }
    app.notify:suspend()
    app.connection:reset()
    app.notify:resume()
    t.settle()
    local missed = t.lastCall("notifications.getMissedSince").params
    H.eq(missed.epoch, "e1")
    H.eq(cards(t), 1)
    local c = t.lastCard()
    H.eq(c.title, "Claude needs you in kindle")
    H.has(c.text, "(+2 more)")
    H.eq(app.settings:get("notify_watermark").seq, 6)
end)

H.test("older desktops without the stream are polled", function()
    local app, t = started{ results = { ["notifications.subscribe"] = false } }
    H.eq(type(app.notify.poller), "function")
    H.results["session.tabs.listAll"] = { snapshots = { { worktree = H.WT.worktreeId, tabs = {
        { terminal = "t1", title = "Claude", agentStatus = { state = "working" } } } } } }
    app.notify.poller(); t.settle()
    H.eq(cards(t), 0, "first poll is a snapshot")
    H.results["session.tabs.listAll"] = { snapshots = { { worktree = H.WT.worktreeId, tabs = {
        { terminal = "t1", title = "Claude", agentStatus = { state = "permission" } } } } } }
    app.notify.poller(); t.settle()
    H.eq(t.lastCard().title, "Claude needs you in kindle")
    t.press("2 Yes")
    H.eq(t.lastCall("terminal.send").params.text, "2")
end)

H.test("turning it off unsubscribes", function()
    local app, t = started()
    app.settings:set("watch_enabled", false)
    app.notify:start()
    t.settle()
    H.eq(t.lastCall("notifications.unsubscribe").params.subscriptionId, "notifications-c1-1")
    push(app, t, event(1, "waiting"))
    H.eq(cards(t), 0)
end)
