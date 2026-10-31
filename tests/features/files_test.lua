-- File browser and asking the agent about a file.
local H = require("tests.harness")

local RESULTS = {
    ["files.readDir"] = { { name = "README.md", isDirectory = false, size = 2300 },
                          { name = "src", isDirectory = true }, { name = "a.lua", isDirectory = false } },
    ["files.read"] = { content = "hello\n", truncated = false },
    ["session.tabs.createTerminal"] = { tab = { terminal = "t6", title = "Claude" } },
}

local function setup(extra)
    local results = {}
    for k, v in pairs(RESULTS) do results[k] = v end
    for k, v in pairs(extra or {}) do results[k] = v end
    local app, t = H.app({ results = results, quiet = true })
    t.opened = {}
    app.session = { open = function(_, term, wt) table.insert(t.opened, { term = term, wt = wt }) end }
    return app, t
end

H.test("files: folders first with chevrons, files with sizes", function()
    local app, t = setup()
    app.files:open(H.WT)
    t.settle()
    local top = t.top()
    H.eq(top.title, "kindle")
    local rows = t.rows()
    H.eq(rows[1].title, "src"); H.eq(rows[1].chevron, true)
    H.eq(rows[2].title, "a.lua"); H.eq(rows[2].detail, nil)
    H.eq(rows[3].title, "README.md"); H.eq(rows[3].detail, "2.2 KB"); H.eq(rows[3].chevron, nil)
    local p = t.lastCall("files.readDir").params
    H.eq(p.worktree, "id:repo1::C:/p/kindle"); H.eq(p.relativePath, ""); H.eq(p.limit, 1000)
end)

H.test("files: drilling into a folder and refreshing in place", function()
    local app, t = setup()
    app.files:open(H.WT); t.settle()
    t.tap("src")
    H.eq(t.lastCall("files.readDir").params.relativePath, "src")
    H.eq(t.top().title, "src"); H.eq(#t.stack, 2)
    t.top().refresh(); t.settle()
    H.eq(#t.stack, 2)
end)

H.test("files: entries wrapper, more-not-shown and empty folder", function()
    local app, t = setup({ ["files.readDir"] = { entries = { { name = "x" } }, hasMore = true, total = 5 } })
    app.files:open(H.WT); t.settle()
    H.eq(t.row("4 more not shown").dim, true)
    H.results["files.readDir"] = { entries = {} }
    app.files:open(H.WT, "empty"); t.settle()
    H.eq(#t.rows(), 0); H.has(t.top().empty, "empty")
end)

H.test("file opens as text with book and ask actions", function()
    local app, t = setup()
    app.files:open(H.WT); t.settle()
    t.tap("README.md")
    local v = t.reads[#t.reads]
    H.eq(v.text, "hello\n"); H.eq(v.mono, true)
    H.eq(t.lastCall("files.read").params.relativePath, "README.md")
    H.eq(v.actions[1].text, "Open as book"); H.eq(v.actions[2].text, "Ask Claude…")
    v.actions[1].callback()
    H.eq(t.books[1].name, "kindle-README.md"); H.eq(#t.stack, 0)
end)

H.test("truncated file says so", function()
    local app, t = setup({ ["files.read"] = { content = "big", truncated = true } })
    app.files:open(H.WT); t.settle(); t.tap("README.md")
    H.has(t.reads[#t.reads].text, "truncated")
end)

H.test("ask about a file: new session gets the question as its prompt", function()
    local app, t = setup()
    app.files:askAbout(H.WT, "README.md")
    H.has(t.asks[1].title, "README.md")
    t.answer("What is this?")
    H.eq(t.lastCard().kind, "sheet")
    t.press("New Claude session")
    local p = t.lastCall("session.tabs.createTerminal").params
    H.eq(p.agent, "claude")
    H.eq(p.agentPrompt, "In workspace kindle (C:/p/kindle), about README.md:\n\nWhat is this?")
    H.eq(t.opened[1].term.handle, "t6")
end)

H.test("ask about a file: send to a running session pastes and submits", function()
    local app, t = setup()
    app.files:askAbout(H.WT, "README.md")
    t.answer("Why?")
    t.press("A running session")
    H.eq(t.top().title, "Send to which session?")
    t.tap("kindle")
    t.tap("zsh")
    local sends = t.called("terminal.send")
    H.eq(#sends, 2)
    H.eq(sends[1].params.terminal, "t2")
    H.has(sends[1].params.text, "\27[200~In workspace kindle")
    H.eq(sends[1].params.enter, false)
    H.eq(sends[2].params.text, ""); H.eq(sends[2].params.enter, true)
    H.eq(t.opened[1].term.handle, "t2")
    H.eq(#t.stack, 0)
    H.eq(app.settings:get("last_terminal").handle, "t2")
end)

H.test("empty question sends nothing", function()
    local app, t = setup()
    app.files:askAbout(H.WT, "x")
    t.answer("   ")
    H.eq(#t.cards, 0)
end)

H.test("size formatting", function()
    local Files = require("orca.features.files")
    H.eq(Files.size(12), "12 B"); H.eq(Files.size(2048), "2.0 KB"); H.eq(Files.size(5 * 1024 * 1024), "5.0 MB")
    H.eq(Files.size(nil), nil); H.eq(Files.size(newproxy()), nil)
end)
