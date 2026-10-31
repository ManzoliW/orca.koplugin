-- Runs the plugin's menus and dialogs on a PC against stubbed KOReader widgets
-- and a fake Orca client, to catch nil errors and typos before deploying.
--   luajit tests/pc_ui_test.lua            (from the repo root)
package.path = "orca.koplugin/?.lua;" .. package.path

local shown, calls = {}, {}
local function widget(kind)
    local W = { kind = kind }
    W.__index = W
    function W:new(o)
        o = o or {}
        o.kind = kind
        return setmetatable(o, W)
    end
    function W:extend(o) o = o or {}; o.__index = o; return setmetatable(o, { __index = W }) end
    function W:getInputText() return self.test_input or self.input or "" end
    function W:onShowKeyboard() end
    function W:switchItemTable(title, items) self.title = title or self.title; self.item_table = items end
    function W:init() end
    return W
end

local UIManager = {
    show = function(_, w)
        if w.kind == "Menu" then w.item_table_stack = w.item_table_stack or {} end
        table.insert(shown, w)
    end,
    close = function(_, w) w.closed = true end,
    isWidgetShown = function(_, w) return not w.closed end,
    scheduleIn = function() end, unschedule = function() end, setDirty = function() end,
}
local stubs = {
    ["ui/widget/confirmbox"] = widget("ConfirmBox"),
    ["ui/widget/infomessage"] = widget("InfoMessage"),
    ["ui/widget/inputdialog"] = widget("InputDialog"),
    ["ui/widget/menu"] = widget("Menu"),
    ["ui/widget/textviewer"] = widget("TextViewer"),
    ["ui/widget/container/widgetcontainer"] = widget("WidgetContainer"),
    ["ui/uimanager"] = UIManager,
    ["ui/network/manager"] = { runWhenOnline = function(_, f) f() end, isConnected = function() return true end },
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/rendertext"] = {},
    ["ui/time"] = { now = function() return os.clock() end, to_s = function(t) return t end },
    ["device"] = { screen = { getWidth = function() return 600 end } },
    ["datastorage"] = { getSettingsDir = function() return "." end },
    ["luasettings"] = { open = function()
        local data = { pairing_url = "x" }
        return {
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            delSetting = function(_, k) data[k] = nil end,
            has = function(_, k) return data[k] ~= nil end,
            nilOrTrue = function(_, k) return data[k] == nil or data[k] == true end,
            isTrue = function(_, k) return data[k] == true end,
            makeTrue = function(_, k) data[k] = true end,
            flush = function() end,
        }
    end },
    ["logger"] = { dbg = function() end, err = function(...) print("logger.err", ...) end },
    ["util"] = {},
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end },
    ["libs/libkoreader-lfs"] = { mkdir = function() end },
    ["apps/reader/readerui"] = { showReader = function(_, p) table.insert(calls, { method = "showReader", params = p }) end },
    ["orcaclient.nacl"] = { load = function() end },
    ["rapidjson"] = {}, ["socket"] = {},
}
G_reader_settings = stubs["luasettings"].open()
G_reader_settings:saveSetting("screensaver_message", "Sleeping")
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end

-- Fake Orca: canned results per method.
local WT = { worktreeId = "repo1::C:/p/kindle", path = "C:\\p\\kindle", branch = "refs/heads/main" }
local results = {
    ["worktree.ps"] = { worktrees = { WT } },
    ["terminal.list"] = { terminals = { { handle = "t1", title = "Claude" } } },
    ["session.tabs.listAll"] = { snapshots = {} },
    ["repo.list"] = { repos = { { id = "repo1", path = "C:\\p\\kindle", displayName = "kindle" } } },
    ["worktree.create"] = { worktree = { displayName = "fix-it" }, agentTerminalHandle = "t9" },
    ["github.listWorkItems"] = { items = {
        { type = "issue", number = 7, title = "Crash", url = "u7", state = "open" },
        { type = "pr", number = 8, title = "Feat", url = "u8", state = "open", branchName = "feat" },
    } },
    ["worktree.resolvePrBase"] = { baseBranch = "main" },
    ["terminal.create"] = { terminal = { handle = "t5" } },
    ["session.tabs.createTerminal"] = { tab = { terminal = "t6", title = "Claude" } },
    ["git.status"] = { branch = "main", entries = {
        { path = "a.lua", status = "modified", area = "unstaged", added = 1, removed = 1 },
        { path = "new.txt", status = "untracked", area = "untracked" },
    } },
    ["git.upstreamStatus"] = { hasUpstream = true, ahead = 1, behind = 0 },
    ["git.diff"] = { kind = "text", originalContent = "x\ny\n", modifiedContent = "x\nz\n" },
    ["files.read"] = { content = "hello\n", truncated = false },
    ["files.readDir"] = { { name = "src", isDirectory = true }, { name = "README.md", isDirectory = false } },
    ["git.bulkStage"] = { ok = true },
    ["git.generateCommitMessage"] = { success = true, message = "Fix things" },
    ["git.commit"] = { success = true },
    ["git.push"] = { ok = true },
    ["git.pull"] = { ok = true },
    ["hostedReview.getCreationEligibility"] = { canCreate = true, provider = "github", defaultBaseRef = "main", title = "T" },
    ["hostedReview.create"] = { ok = true, number = 3, url = "https://x/pull/3" },
    ["worktree.sleep"] = { worktreeId = "w" },
    ["worktree.rm"] = { removed = true },
    ["terminal.send"] = { ok = true },
    ["github.prForBranch"] = { kind = "no-pr" },
    ["github.prChecks"] = {
        { name = "check", status = "completed", conclusion = "success", checkRunId = 1, workflowRunId = 10, url = "u1" },
        { name = "smoke", status = "completed", conclusion = "failure", checkRunId = 2, workflowRunId = 11, url = "u2" },
        { name = "deploy", status = "in_progress", url = "u3" },
    },
    ["github.prCheckDetails"] = { conclusion = "failure", title = "smoke failed", summary = "1 error",
        jobs = { { name = "smoke", conclusion = "failure", steps = {
            { name = "Install", conclusion = "success" }, { name = "Run smoke", conclusion = "failure" } } } },
        annotations = { { path = "app/x.ts", startLine = 12, message = "boom" } }, detailsUrl = "https://gh/run/2" },
    ["github.rerunPRChecks"] = { ok = true },
    ["github.mergePR"] = { ok = true },
    ["accounts.list"] = { rateLimits = { claude = { status = "ok",
        session = { usedPercent = 61.6, resetsAt = (os.time() + 5400) * 1000 },
        weekly = { usedPercent = 35, resetsAt = (os.time() + 3 * 86400) * 1000 } } } },
    ["stats.summary"] = { totalAgentsSpawned = 4, totalPRsCreated = 1, totalAgentTimeMs = 7200000 },
    ["aiVault.listSessions"] = { sessions = {
        { title = "Older chat", cwd = "C:\\elsewhere\\proj", agent = "claude", updatedAt = "2026-10-30T10:00:00.000Z",
          id = "local:claude:11111111-2222-3333-4444-555555555555:C:\\x.jsonl", totalTokens = 5200 },
        { title = "KOReader and Tailscale on Kindle with a long title", cwd = "C:\\p\\kindle", agent = "claude",
          sessionId = "9ff43156-23bc-477a-8316-03474ed4a803", updatedAt = "2026-10-31T14:37:08.173Z",
          messageCount = 1546, totalTokens = 156321186, branch = "main", previewMessagesTruncated = true,
          previewMessages = { { role = "user", text = "kindle wake", timestamp = "2026-10-31T14:30:13.706Z" },
                              { role = "assistant", text = "Plugin instalado", timestamp = "2026-10-31T14:32:28.973Z" } } },
    } },
}
local fake = {}
function fake:call(method, params)
    table.insert(calls, { method = method, params = params })
    local r = results[method]
    if not r then return nil, "unexpected method " .. method end
    return r
end
function fake:isConnected() return true end
function fake:connect() return true end
function fake:pump() end
function fake:listWorktrees() return self:call("worktree.ps").worktrees end
function fake:listTerminals() return self:call("terminal.list").terminals end
function fake:agentStates()
    return { t1 = { state = "waiting", worktree = "r::C:/p/kindle" }, t2 = { state = "working", worktree = "r::C:/p/novo" },
             t3 = { state = "working", worktree = "r::C:/p/novo" } }
end
function fake:takeEvents() return {} end
function fake:readTerminal()
    return { tail = { " ▐▛███▛█   Claude Code", " Bash command", "   rm -rf build", "", " Do you want to proceed?", " ❯ 1. Yes",
                      "   2. No, and tell Claude what to do differently (esc)", "", "Enter to select · ↑/↓ to navigate · Esc to cancel", "" } }
end
function fake:sendText(handle, text, enter)
    return self:call("terminal.send", { terminal = handle, text = text, enter = enter })
end

local Orca = dofile("orca.koplugin/main.lua")
local o = setmetatable({ path = ".", ui = { menu = { registerToMainMenu = function() end } } }, { __index = Orca })
o:init()
o.getClient = function() return fake end
o.docs_dir = os.getenv("TEMP") or "/tmp"
o.openSession = function(_, term) table.insert(calls, { method = "openSession", params = term }) end

local failures = 0
local function last(kind)
    for i = #shown, 1, -1 do if shown[i].kind == kind and not shown[i].closed then return shown[i] end end
end
local function called(method)
    for i = #calls, 1, -1 do if calls[i].method == method then return calls[i].params end end
end
local function check(name, cond, detail)
    if cond then print("ok   " .. name) else failures = failures + 1; print("FAIL " .. name, detail or "") end
end
local function tap(text)
    local m = assert(o.menu, "no menu")
    for _, item in ipairs(m.item_table) do
        if tostring(item.text):find(text, 1, true) then return item.callback() end
    end
    error("no menu item " .. text .. " in " .. tostring(m.title))
end
local function button(dialog, text)
    for _, row in ipairs(dialog.buttons or dialog.buttons_table or {}) do
        for _, b in ipairs(row) do if b.text == text then return b.callback() end end
    end
    error("no button " .. text)
end
local function noErrors(name)
    local err = last("InfoMessage")
    check(name .. " (no error popup)", not (err and tostring(err.text):match("^Orca:")), err and err.text)
end

-- Browse → + New → new workspace
o:openWorkspaces()
check("workspace list has + New", o.menu.item_table[2].text:find("new", 1, true))
tap("Start something new")
tap("New workspace with Claude")
tap("kindle")
local d = last("InputDialog"); d.test_input = "Fix the login bug please now ok"
button(d, "Start")
local p = called("worktree.create")
check("worktree.create params", p and p.repo == "id:repo1" and p.startupAgent == "claude"
    and p.startupPrompt and p.name == "fix-the-login-bug-please", p and p.name)
check("opens agent terminal", called("openSession") and called("openSession").handle == "t9")
noErrors("new workspace")

-- Issue / PR
o:openWorkspaces(); tap("Start something new"); tap("GitHub issue"); tap("kindle")
tap("#7 Crash"); d = last("InputDialog"); button(d, "Start")
p = called("worktree.create")
check("issue workspace", p.linkedIssue == 7 and p.name == "issue-7" and p.startupPrompt:find("u7"), p.name)
o:openWorkspaces(); tap("Start something new"); tap("GitHub issue"); tap("kindle")
tap("#8 Feat"); d = last("InputDialog"); button(d, "Start")
p = called("worktree.create")
check("pr workspace", p.linkedPR == 8 and p.baseBranch == "main" and p.name == "pr-8")
noErrors("issues")

-- Clone and new project
o.settings:saveSetting("projects_dir", nil)
o:openWorkspaces(); tap("Start something new"); tap("Clone from GitHub")
d = last("InputDialog"); d.test_input = "octo/hello-world"; button(d, "OK")
p = called("terminal.create")
check("clone command", p and p.command == "git clone https://github.com/octo/hello-world.git C:/p/hello-world; orca repo add --path C:/p/hello-world", p and p.command)
o:openWorkspaces(); tap("Start something new"); tap("New empty project")
d = last("InputDialog"); d.test_input = "My Tool"; button(d, "OK")
p = called("terminal.create")
check("new project command", p.command:find("git init C:/p/my%-tool") and p.command:find("orca repo add"), p.command)
noErrors("clone/new")

-- Inside a workspace
o:openWorkspaces(); tap("kindle")
check("workspace actions shown", o.menu.item_table[2].text:find("New Claude", 1, true))
tap("New Claude session"); d = last("InputDialog"); d.test_input = "write tests"; button(d, "Start")
p = called("session.tabs.createTerminal")
check("agent tab", p.agent == "claude" and p.agentPrompt == "write tests" and p.worktree == "id:repo1::C:/p/kindle")
check("opens new tab", called("openSession").handle == "t6")

o:openWorkspaces(); tap("kindle"); tap("Git:")
check("git summary", o.menu.item_table[2].text:find("↑1", 1, true), o.menu.item_table[2].text)
tap("M a.lua")
local v = last("TextViewer")
check("diff view", v and v.text:find("- y", 1, true) and v.text:find("+ z", 1, true), v and v.text)
tap("? new.txt"); v = last("TextViewer")
check("untracked diff", v.text:find("+ hello", 1, true), v.text)
tap("Commit all"); d = last("InputDialog")
check("commit message drafted", d.input == "Fix things")
button(d, "Commit & push")
check("committed and pushed", called("git.commit").message == "Fix things" and called("git.push"))
tap("Open a pull request"); d = last("InputDialog"); button(d, "Open PR")
p = called("hostedReview.create")
check("pr created", p and p.base == "main" and p.provider == "github" and p.title == "T")
tap("Read all changes as a book")
check("changes book", called("showReader") and called("showReader"):find("changes"))
noErrors("git")

o:openWorkspaces(); tap("kindle"); tap("Files"); tap("README.md")
v = last("TextViewer"); check("file view", v.text == "hello\n")
button(v, "Ask Claude…"); d = last("InputDialog")
check("ask dialog", d.title:find("README.md", 1, true))
o:openWorkspaces(); tap("kindle"); tap("Workspace:"); tap("Sleep")
check("sleep", called("worktree.sleep").worktree == "id:repo1::C:/p/kindle")
tap("Remove"); local box = last("ConfirmBox"); box.ok_callback()
check("remove keeps branch", called("worktree.rm").deleteBranch == false)
o:showStats()
check("stats", last("InfoMessage").text:find("Agent time: 2.0 h", 1, true), last("InfoMessage").text)

-- Pull request status, checks, merge
results["github.prForBranch"] = { kind = "found", pr = { number = 12, title = "Fix login", state = "open",
    url = "https://gh/pull/12", checksStatus = "failure", mergeable = "MERGEABLE", headSha = "abc" } }
o:openWorkspaces(); tap("kindle"); tap("Git:")
check("pr row replaces open-pr", o.menu.item_table[6] and o.menu.item_table[6].text == "Pull request #12: Fix login"
    and o.menu.item_table[6].mandatory == "checks ✗", o.menu.item_table[6] and o.menu.item_table[6].text)
tap("Pull request #12")
check("pr facts", o.menu.item_table[3].text == "open · mergeable", o.menu.item_table[3].text)
check("checks listed", o.menu.item_table[7].text == "✓ check" and o.menu.item_table[8].text == "✗ smoke"
    and o.menu.item_table[9].text == "… deploy", o.menu.item_table[8].text)
check("prChecks params", called("github.prChecks").prNumber == 12 and called("github.prChecks").headSha == "abc")
tap("✗ smoke"); v = last("TextViewer")
check("check details", v.text:find("Run smoke", 1, true) and v.text:find("app/x.ts:12  boom", 1, true)
    and not v.text:find("Install", 1, true), v.text)
tap("Re-run the failed check")
check("rerun failed only", called("github.rerunPRChecks").failedOnly == true and called("github.rerunPRChecks").prNumber == 12)
tap("Ask Claude to fix")
p = called("session.tabs.createTerminal")
check("fix prompt", p.agentPrompt:find("smoke", 1, true) and p.agentPrompt:find("gh pr checks 12", 1, true), p.agentPrompt)
o:openWorkspaces(); tap("kindle"); tap("Git:"); tap("Pull request #12"); tap("Merge"); tap("Squash and merge")
last("ConfirmBox").ok_callback()
check("merge squash", called("github.mergePR").method == "squash" and called("github.mergePR").prNumber == 12)
results["github.prCheckDetails"] = { summary = (function() end)() }
o:openWorkspaces(); tap("kindle"); tap("Git:"); tap("Pull request #12"); tap("✗ smoke"); v = last("TextViewer")
check("check without details", v.text:find("smoke · failure", 1, true) and v.text:find("no details", 1, true) and v.text:find("u2", 1, true), v.text)
noErrors("pr status")
results["github.prForBranch"] = { kind = "no-pr" }

-- Recent conversations
o:openWorkspaces(); tap("Recent conversations")
check("newest conversation first", o.menu.item_table[1].text:find("kindle · KOReader", 1, true) and o.menu.item_table[1].mandatory == "156M",
    o.menu.item_table[1].text .. " " .. tostring(o.menu.item_table[1].mandatory))
tap("kindle · KOReader"); v = last("TextViewer")
check("conversation view", v.text:find("1546 messages · 156M tokens", 1, true) and v.text:find("Plugin instalado", 1, true), v.text)
button(v, "Continue on desktop")
p = called("terminal.create")
check("resume in its workspace", p.command == "claude --resume 9ff43156-23bc-477a-8316-03474ed4a803"
    and p.worktree == "id:repo1::C:/p/kindle", p.command)
o:openWorkspaces(); tap("Recent conversations"); tap("proj · Older"); button(last("TextViewer"), "Continue on desktop")
check("resume elsewhere cds first", called("terminal.create").command
    == "cd \"C:/elsewhere/proj\"; claude --resume 11111111-2222-3333-4444-555555555555", called("terminal.create").command)
o:openWorkspaces(); tap("Recent conversations"); tap("kindle · KOReader"); button(last("TextViewer"), "Read as book")
check("conversation book", called("showReader"):find("conversation", 1, true))
noErrors("conversations")

-- Notification with a quick reply
o.notice = nil
o.watch_states = { t1 = "working" }
o:checkAgentChanges({ t1 = { state = "waiting", worktree = "r::C:/p/kindle", title = "Claude" } })
box = last("ConfirmBox")
check("prompt shown in popup", box and box.text:find("Do you want to proceed?", 1, true) and box.text:find("2. No", 1, true), box and box.text)
check("excerpt skips logo and footer", not box.text:find("▐", 1, true) and not box.text:find("Enter to select", 1, true), box.text)
check("answer buttons", box.other_buttons and box.other_buttons[1][1].text == "1")
box.other_buttons[1][1].callback()
p = called("terminal.send")
check("answer sent", p and p.terminal == "t1" and p.text == "1" and not p.enter)
o.watch_states = { t1 = "working" }; o.notice = nil
o:checkAgentChanges({ t1 = { state = "done", worktree = "r::C:/p/kindle" } })
check("done popup has no answer buttons", last("ConfirmBox").other_buttons == nil)

-- Picker mode (Send to Claude) must not show the create/manage rows.
o:openWorkspaces(function() end)
check("picker hides + New", not o.menu.item_table[2].text:find("new", 1, true))

-- Sleep screen: enable, refresh, disable restores the user's message.
o:setSleepStatus(true)
o:refreshSleepStatus()
local msg = G_reader_settings:readSetting("screensaver_message")
print(msg)
check("sleep message usage", msg:find("5h: 62% used · resets 1h 30m", 1, true), msg)
check("sleep message states", msg:find("needs you: kindle", 1, true) and msg:find("working: novo", 1, true), msg)
check("sleep message last conversation", msg:find("Last: KOReader and Tailscal… · 156M tokens", 1, true), msg)
check("no %letter tokens", not msg:find("%%%a"), msg)
check("show message on", G_reader_settings:isTrue("screensaver_show_message"))
o:setSleepStatus(false)
check("restored", G_reader_settings:readSetting("screensaver_message") == "Sleeping"
    and not G_reader_settings:isTrue("screensaver_show_message"))

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
