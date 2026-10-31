-- Recent conversations: list, transcript, read as book, continue on desktop.
local H = require("tests.harness")

local SESSIONS = { sessions = {
    { title = "Older chat", cwd = "C:\\elsewhere\\proj", agent = "claude", updatedAt = "2026-10-30T10:00:00.000Z",
      id = "local:claude:11111111-2222-3333-4444-555555555555:C:\\x.jsonl", totalTokens = 5200 },
    { title = "KOReader and Tailscale on Kindle with a long title", cwd = "C:\\p\\kindle", agent = "claude",
      sessionId = "9ff43156-23bc-477a-8316-03474ed4a803", updatedAt = "2026-10-31T14:37:08.173Z",
      messageCount = 1546, totalTokens = 156321186, branch = "main", previewMessagesTruncated = true,
      previewMessages = { { role = "user", text = "kindle wake", timestamp = "2026-10-31T14:30:13.706Z" },
                          { role = "assistant", text = "Plugin instalado", timestamp = "2026-10-31T14:32:28.973Z" } } },
    { title = "Codex thing", cwd = "C:\\p\\faxa", agent = "codex", sessionId = "abc", updatedAt = "2026-10-29T10:00:00.000Z" },
} }

local function setup()
    local app, t = H.app({ results = { ["aiVault.listSessions"] = SESSIONS }, quiet = true })
    t.desktop = {}
    app.create = { runOnDesktop = function(_, title, commands, cwd)
        table.insert(t.desktop, { title = title, commands = commands, cwd = cwd })
    end }
    return app, t
end

H.test("lists conversations newest first with project, age and size", function()
    local app, t = setup()
    app.conversations:open()
    t.settle()
    H.eq(t.top().title, "Conversations")
    local rows = t.rows()
    H.eq(rows[1].title, "KOReader and Tailscale on Kindle with a long title")
    H.has(rows[1].subtitle, "kindle · ")
    H.eq(rows[1].detail, "156M")
    H.eq(rows[1].chevron, true)
    H.eq(rows[2].detail, "5.2k")
    H.eq(t.lastCall("aiVault.listSessions").params.limit, 30)
end)

H.test("a conversation reads as text with its messages", function()
    local app, t = setup()
    app.conversations:open(); t.settle()
    t.tap("KOReader")
    local r = t.reads[#t.reads]
    H.has(r.text, "kindle · Claude · 1546 messages · 156M tokens")
    H.has(r.text, "only the latest messages")
    H.has(r.text, "You · ")
    H.has(r.text, "Claude · ")
    H.has(r.text, "Plugin instalado")
    H.eq(r.actions[1].text, "Read as book")
    r.actions[1].callback()
    H.has(t.books[#t.books].name, "conversation-kindle-KOReader")
    H.has(t.books[#t.books].body, "Plugin instalado")
end)

H.test("continue on desktop resumes Claude in the conversation folder", function()
    local app, t = setup()
    app.conversations:open(); t.settle()
    t.tap("KOReader")
    local r = t.reads[#t.reads]
    H.eq(r.actions[2].text, "Continue on desktop")
    r.actions[2].callback()
    local d = t.desktop[1]
    H.eq(d.commands[1], "claude --resume 9ff43156-23bc-477a-8316-03474ed4a803")
    H.eq(d.cwd, "C:\\p\\kindle")
    t.tap("Older chat")
    t.reads[#t.reads].actions[2].callback()
    H.eq(t.desktop[2].commands[1], "claude --resume 11111111-2222-3333-4444-555555555555")
    t.tap("Codex thing")
    H.eq(#t.reads[#t.reads].actions, 1, "only Claude conversations can be resumed")
end)

H.test("latest() returns the newest conversation", function()
    local app, t = setup()
    local latest = app.conversations:latest(t.client)
    H.eq(latest.sessionId, "9ff43156-23bc-477a-8316-03474ed4a803")
    H.results["aiVault.listSessions"] = false
    H.eq(app.conversations:latest(t.client), nil)
end)

H.test("errors and empty lists show in the screen", function()
    local app, t = setup()
    H.results["aiVault.listSessions"] = { sessions = {} }
    app.conversations:open(); t.settle()
    H.has(t.top().empty, "No conversations yet")
    t.back()
    H.results["aiVault.listSessions"] = function() return nil, "timed out" end
    app.conversations:open(); t.settle()
    H.has(t.top().empty, "Can't reach your PC")
end)
