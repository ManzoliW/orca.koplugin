-- Session view: subscribe/fit, keys, live refresh, reconnect, errors, close.
local H = require("tests.harness")

-- Stands in for orca/ui/terminal (KOReader widgets don't run on a PC).
local FakeView = {}
FakeView.__index = FakeView
function FakeView.new(opts)
    local v = setmetatable({ opts = opts, texts = {}, subtitle = opts.subtitle }, FakeView)
    FakeView.last = v
    return v
end
function FakeView:setText(text) self.text = text; table.insert(self.texts, text) end
function FakeView:setSubtitle(s) self.subtitle = s end
function FakeView:viewport() return { cols = 60, rows = 30 } end
function FakeView:close()
    if self.closed then return end
    self.closed = true
    if self.opts.on_close then self.opts.on_close() end
end
function FakeView:press(id) self.opts.on_key(id) end
function FakeView:rotate() self.rotated = true end

local TERM = { handle = "t1", title = "Claude" }

local function open(opts)
    opts = opts or {}
    local results = { ["terminal.subscribe"] = { cols = 60, rows = 30 },
                      ["terminal.unsubscribe"] = { ok = true },
                      ["terminal.updateViewport"] = { ok = true } }
    for k, v in pairs(opts.results or {}) do results[k] = v end
    local app, t = H.app({ results = results, settings = opts.settings, quiet = true })
    local clock = 1000
    app.now = function() return clock end
    t.advance = function(s) clock = clock + s end
    app.session.View = FakeView
    app.session:open(TERM, H.WT)
    t.settle()
    return app, t, FakeView.last
end

-- Delivers a stream frame the way connection:pump would.
local function frame(app, result)
    app.connection:dispatch({ { id = app.session.current.request_id, result = result } })
end

H.test("opening subscribes with the Kindle's viewport and shows the screen", function()
    local app, t, view = open()
    local sub = t.lastCall("terminal.subscribe")
    H.eq(sub.params.terminal, "t1")
    H.eq(sub.params.client.id, "kindle-test")
    H.eq(sub.params.client.type, "desktop")
    H.eq(sub.params.viewport.cols, 60)
    H.eq(sub.params.viewport.rows, 90, "three screens tall, for swiping back")
    H.eq(t.lastCall("terminal.read").params.screen, true)
    H.has(view.text, "Do you want to proceed?")
    H.eq(view.opts.title, "Claude")
    H.eq(view.subtitle, "kindle · ● Needs you")
    H.eq(app.session:isShowing("t1"), true)
    H.eq(app.session:isShowing("t2"), false)
    app.session:close()
end)

H.test("no fit and no live updates: no subscription", function()
    local app, t, view = open({ settings = { pairing_url = "x", fit_viewport = false, live_updates = false } })
    H.eq(#t.called("terminal.subscribe"), 0)
    H.has(view.text, "1. Yes")
    app.session:close()
    H.eq(#t.called("terminal.unsubscribe"), 0)
end)

H.test("without history the terminal is just the Kindle's height", function()
    local app, t = open({ settings = { pairing_url = "x", session_history = false } })
    H.eq(t.lastCall("terminal.subscribe").params.viewport.rows, 30)
    app.session:close()
end)

H.test("Rotate turns the screen, and the view is rebuilt at the new size", function()
    local app, t, view = open()
    view:press("rotate")
    H.eq(view.rotated, true)
    H.eq(#t.called("terminal.send"), 0)
    FakeView.viewport = function() return { cols = 90, rows = 20 } end
    view.opts.on_resize(); t.settle()
    FakeView.viewport = function() return { cols = 60, rows = 30 } end
    H.eq(view.closed, true)
    H.eq(t.lastCall("terminal.unsubscribe").params.subscriptionId, "t1:kindle-test")
    local sub = t.lastCall("terminal.subscribe")
    H.eq(sub.params.viewport.cols, 90)
    H.eq(sub.params.viewport.rows, 60)
    H.eq(app.session:isShowing("t1"), true)
    H.eq(FakeView.last.opts.title, "Claude")
    app.session:close()
end)

H.test("keys are sent once each with the right bytes", function()
    local app, t, view = open()
    local function sent() return t.lastCall("terminal.send").params end
    view:press("1"); t.settle()
    H.eq(sent().text, "1"); H.eq(sent().terminal, "t1"); H.eq(sent().enter, nil)
    view:press("esc"); t.settle(); H.eq(sent().text, "\27")
    view:press("ctrl-c"); t.settle(); H.eq(sent().interrupt, true)
    view:press("up"); t.settle(); H.eq(sent().text, "\27[A")
    view:press("shift-tab"); t.settle(); H.eq(sent().text, "\27[Z")
    view:press("enter"); t.settle(); H.eq(sent().text, ""); H.eq(sent().enter, true)
    H.eq(#t.called("terminal.send"), 6)
    app.session:close()
end)

H.test("Type… sends text with or without Enter", function()
    local app, t, view = open()
    view:press("type")
    local ask = t.asks[#t.asks]
    H.eq(ask.title, "Send to Claude")
    H.eq(ask.multiline, true)
    H.eq(ask.ok_text, "Send")
    t.answer("hello")
    H.eq(t.lastCall("terminal.send").params.text, "hello")
    H.eq(t.lastCall("terminal.send").params.enter, true)
    view:press("type")
    t.asks[#t.asks].extra[1].callback("draft"); t.settle()
    H.eq(t.lastCall("terminal.send").params.text, "draft")
    H.eq(t.lastCall("terminal.send").params.enter, false)
    app.session:close()
end)

H.test("output refreshes the screen once it goes quiet", function()
    local app, t, view = open()
    local reads = #t.called("terminal.read")
    H.results["terminal.read"] = { terminal = { tail = { "new output" } } }
    frame(app, { type = "data" })
    app.session:tick(app.session.current); t.settle()
    H.eq(#t.called("terminal.read"), reads, "no refresh while output is fresh")
    t.advance(2)
    app.session:tick(app.session.current); t.settle()
    H.eq(#t.called("terminal.read"), reads + 1)
    H.eq(view.text, "new output")
    app.session:close()
end)

H.test("desktop taking the size back is reclaimed before the next key", function()
    local app, t, view = open()
    frame(app, { type = "fit-override-changed", cols = 120 })
    view:press("2"); t.settle()
    local claim = t.lastCall("terminal.updateViewport")
    H.eq(claim.params.claim, true)
    H.eq(claim.params.viewport.cols, 60)
    H.eq(claim.params.client.id, "kindle-test")
    view:press("3"); t.settle()
    H.eq(#t.called("terminal.updateViewport"), 1)
    app.session:close()
end)

H.test("a new connection resubscribes", function()
    local app, t, view = open()
    t.client.connected = false
    app.session:tick(app.session.current); t.settle()
    H.eq(#t.called("terminal.subscribe"), 2)
    -- Frames on the new stream still reach the session.
    frame(app, { type = "data" })
    H.eq(app.session.current.dirty, true)
    app.session:close()
end)

H.test("after a reconnect the Kindle's size is claimed again once the old socket is gone", function()
    local app, t = open()
    t.client.connected = false
    app.session:tick(app.session.current); t.settle()
    H.eq(#t.called("terminal.updateViewport"), 0, "not right away")
    t.advance(21)
    app.session:tick(app.session.current); t.settle()
    local claim = t.lastCall("terminal.updateViewport")
    H.eq(claim and claim.params.claim, true)
    H.eq(claim.params.viewport.cols, 60)
    t.advance(25)
    app.session:tick(app.session.current); t.settle()
    H.eq(#t.called("terminal.updateViewport"), 2, "and once more for a slow cleanup")
    t.advance(60)
    app.session:tick(app.session.current); t.settle()
    H.eq(#t.called("terminal.updateViewport"), 2, "then never again on its own")
    app.session:close()
end)

H.test("errors show in the text area, not as popups", function()
    local app, t, view = open({ results = { ["terminal.read"] = function() return nil, "proxy: connection refused" end } })
    H.has(view.text, "Can't read this session")
    H.has(view.text, "Can't reach your PC")
    H.eq(#t.cards, 0)
    H.results["terminal.read"] = { terminal = { tail = { "screen" } } }
    H.results["terminal.send"] = false
    view.opts.on_refresh(); t.settle()
    view:press("1"); t.settle()
    H.has(view.text, "screen")
    H.has(view.text, "didn't reach the session")
    H.eq(#t.cards, 0)
    app.session:close()
end)

H.test("closing unsubscribes and stops; closing twice is safe", function()
    local app, t, view = open()
    view:close()
    t.settle()
    local un = t.lastCall("terminal.unsubscribe")
    H.eq(un.params.subscriptionId, "t1:kindle-test")
    H.eq(app.session.current, nil)
    H.eq(app.session.ticker, nil)
    H.eq(next(app.connection.keepers), nil)
    app.session:close()
    H.eq(#t.called("terminal.unsubscribe"), 1)
    local app2 = H.app({ quiet = true })
    app2.session:close()
end)

H.test("opening another session closes the first", function()
    local app, t, first = open()
    app.session:open({ handle = "t2", title = "zsh" }, H.WT)
    t.settle()
    H.eq(first.closed, true)
    H.eq(app.session:isShowing("t2"), true)
    H.eq(t.lastCall("terminal.unsubscribe").params.subscriptionId, "t1:kindle-test")
    app.session:close()
end)
