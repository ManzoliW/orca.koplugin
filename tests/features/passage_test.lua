-- Highlight → agent: question dialog, session picker, paste and Enter.
local H = require("tests.harness")

local opened
local function setup(settings)
    local app, t = H.app({ settings = settings, quiet = true })
    opened = nil
    app.session = { open = function(_, term, wt) opened = { term = term, wt = wt } end,
                    close = function() end, isShowing = function() return false end }
    app.plugin = { ui = {
        doc_props = { title = "Dune", authors = "Frank Herbert" },
        getCurrentPage = function() return 12 end,
        toc = { getTocTitleByPage = function() return "Book One" end },
    } }
    return app, t
end

H.test("asks with presets, picks a session, pastes then presses Enter", function()
    local app, t = setup()
    app.passage:ask("  The spice\n must flow. ")
    local ask = t.asks[#t.asks]
    H.eq(ask.title, "Send to Claude")
    H.eq(ask.description, "The spice must flow.")
    H.eq(ask.rows[1][1].text, "Explain")
    H.eq(ask.rows[1][3].text, "Save note")
    ask.rows[1][1].callback("")
    t.settle()
    H.eq(t.top().title, "Send to which session?")
    t.tap("kindle")
    t.tap("Claude")
    H.eq(#t.stack, 0, "picker closed after choosing")
    local sends = t.called("terminal.send")
    H.eq(#sends, 2)
    H.eq(sends[1].params.terminal, "t1")
    H.has(sends[1].params.text, "\27[200~From Dune by Frank Herbert, chapter \"Book One\":")
    H.has(sends[1].params.text, "\"The spice must flow.\"\n\nExplain this passage")
    H.has(sends[1].params.text, "\27[201~")
    H.eq(sends[1].params.enter, false)
    H.eq(sends[2].params.text, "")
    H.eq(sends[2].params.enter, true)
    H.eq(opened.term.handle, "t1")
    H.eq(opened.wt.worktreeId, H.WT.worktreeId)
    local last = app.settings:get("last_terminal")
    H.eq(last.handle, "t1"); H.eq(last.workspace, "kindle")
end)

H.test("own question, and an empty one gets a default", function()
    local app, t = setup()
    app.passage:ask("Fear is the mind-killer.")
    t.answer("  Who says this? ")
    t.tap("kindle"); t.tap("Claude")
    H.has(t.called("terminal.send")[1].params.text, "\n\nWho says this?\27[201~")
    app.passage:ask("Fear is the mind-killer.")
    t.answer("")
    t.press("Send")
    local sends = t.called("terminal.send")
    H.has(sends[#sends - 1].params.text, "What do you make of this passage?")
end)

H.test("the last session is offered first", function()
    local app, t = setup({ pairing_url = "x", last_terminal = {
        handle = "t1", title = "Claude", workspace = "kindle", worktreeId = H.WT.worktreeId, path = H.WT.path } })
    app.passage:ask("passage")
    t.answer("q")
    local card = t.lastCard()
    H.eq(card.text, "Send to Claude (kindle)?")
    t.press("Send")
    H.eq(t.lastCall("terminal.send").params.enter, true)
    H.eq(opened.term.handle, "t1")
    H.eq(opened.wt.worktreeId, H.WT.worktreeId)

    app.passage:ask("passage")
    t.answer("q")
    t.press("Choose another…")
    H.eq(t.top().title, "Send to which session?")
    t.tap("faxa"); t.tap("Claude")
    H.eq(app.settings:get("last_terminal").workspace, "faxa")

    local before = #t.called("terminal.send")
    app.passage:ask("passage")
    t.answer("q")
    t.press("Cancel")
    H.eq(#t.called("terminal.send"), before)
end)

H.test("a session that's gone is forgotten", function()
    local app, t = setup({ pairing_url = "x", last_terminal = { handle = "t9", title = "Old", workspace = "kindle" } })
    H.results["terminal.send"] = function() return nil, "terminal not found" end
    app.passage:ask("passage")
    t.answer("q")
    t.press("Send")
    H.eq(app.settings:get("last_terminal"), nil)
    H.eq(t.lastCard().kind, "alert")
    H.eq(opened, nil)
end)

H.test("an empty highlight does nothing", function()
    local app, t = setup()
    app.passage:ask("   ")
    H.eq(#t.asks, 0)
end)
