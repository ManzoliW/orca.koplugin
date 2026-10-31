-- Starting things: workspaces, issues/PRs, clone, new project, sessions, sleep/remove.
local H = require("tests.harness")

local RESULTS = {
    ["repo.list"] = { repos = {
        { id = "repo2", path = "C:\\p\\zeta", displayName = "zeta" },
        { id = "repo1", path = "C:\\p\\kindle", displayName = "kindle" },
    } },
    ["worktree.create"] = { worktree = { displayName = "fix-it" }, agentTerminalHandle = "t9" },
    ["github.listWorkItems"] = { items = {
        { type = "issue", number = 7, title = "Crash", url = "u7", state = "open" },
        { type = "pr", number = 8, title = "Feat", url = "u8", state = "open", branchName = "feat", baseRefName = "main" },
        { type = "issue", number = 9, title = "Old", url = "u9", state = "closed" },
    } },
    ["worktree.resolvePrBase"] = { baseBranch = "main", compareBaseRef = "origin/main", pushTarget = "origin" },
    ["terminal.create"] = { terminal = { handle = "t5" } },
    ["session.tabs.createTerminal"] = { tab = { terminal = "t6", title = "Claude" } },
    ["worktree.sleep"] = { worktreeId = "w" },
    ["worktree.rm"] = { removed = true },
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

H.test("start screen offers the four ways in, agent-aware", function()
    local app, t = setup()
    app.settings:set("agent", "codex")
    app.create:open()
    H.eq(t.top().title, "Start something new")
    H.eq(t.row("New workspace with Codex").chevron, true)
    t.row("From a GitHub issue or PR"); t.row("Clone from GitHub"); t.row("New empty project")
end)

H.test("new workspace: repo picker sorted, prompt becomes name and startup prompt", function()
    local app, t = setup()
    app.create:open()
    t.tap("New workspace with Claude")
    H.eq(t.rows()[1].title, "kindle")
    t.tap("kindle")
    H.has(t.asks[1].title, "kindle")
    t.answer("  Fix the login bug please now ok ")
    local p = t.lastCall("worktree.create").params
    H.eq(p.repo, "id:repo1"); H.eq(p.startupAgent, "claude"); H.eq(p.createdWithAgent, "claude")
    H.eq(p.name, "fix-the-login-bug-please"); H.eq(p.startupPrompt, "Fix the login bug please now ok")
    H.eq(p.setupDecision, "inherit")
    H.eq(t.opened[1].term.handle, "t9")
    H.eq(#t.stack, 0)
end)

H.test("new workspace retries a name clash as name-2", function()
    local n = 0
    local app, t = setup({ ["worktree.create"] = function(p)
        n = n + 1
        if n == 1 then return nil, "conflict: worktree already exists" end
        return { worktree = { displayName = p.name } }
    end })
    app.create:open(); t.tap("New workspace"); t.tap("kindle"); t.answer("")
    H.eq(t.lastCall("worktree.create").params.name:match("%-2$"), "-2")
    H.eq(t.lastCall("worktree.create").params.startupPrompt, nil)
    H.has(t.toasts[#t.toasts], "created")
end)

H.test("issue workspace links the issue and starts with its prompt", function()
    local app, t = setup()
    app.create:open(); t.tap("GitHub issue"); t.tap("kindle")
    H.eq(t.top().title, "Issues and PRs")
    local ok = pcall(t.row, "#9 Old")
    H.eq(ok, false, "closed items hidden")
    t.tap("#7 Crash")
    H.has(t.asks[#t.asks].input, "u7")
    t.answer(t.asks[#t.asks].input)
    local p = t.lastCall("worktree.create").params
    H.eq(p.linkedIssue, 7); H.eq(p.name, "issue-7"); H.eq(p.displayName, "#7 Crash")
    H.eq(p.displayNameKind, "generated"); H.eq(p.startupDraft, "u7")
end)

H.test("PR workspace resolves the base first", function()
    local app, t = setup()
    app.create:open(); t.tap("GitHub issue"); t.tap("kindle"); t.tap("#8 Feat")
    local r = t.lastCall("worktree.resolvePrBase").params
    H.eq(r.repo, "id:repo1"); H.eq(r.prNumber, 8); H.eq(r.headRefName, "feat"); H.eq(r.baseRefName, "main")
    t.answer("Review it")
    local p = t.lastCall("worktree.create").params
    H.eq(p.linkedPR, 8); H.eq(p.baseBranch, "main"); H.eq(p.name, "pr-8"); H.eq(p.compareBaseRef, "origin/main")
    H.eq(p.pushTarget, "origin")
end)

H.test("work item search reloads the same screen", function()
    local app, t = setup()
    app.create:open(); t.tap("GitHub issue"); t.tap("kindle")
    local depth = #t.stack
    t.tap("Search")
    t.answer("crash ")
    H.eq(t.lastCall("github.listWorkItems").params.query, "crash")
    H.eq(t.lastCall("github.listWorkItems").params.limit, 40)
    H.eq(#t.stack, depth)
    H.has(t.top().subtitle, "crash")
end)

H.test("clone runs git clone and orca repo add on the desktop", function()
    local app, t = setup()
    app.create:open(); t.tap("Clone from GitHub")
    H.has(t.asks[1].description, "Folder: C:/p")
    t.answer("octo/hello-world")
    local p = t.lastCall("terminal.create").params
    H.eq(p.command, "git clone https://github.com/octo/hello-world.git C:/p/hello-world; orca repo add --path C:/p/hello-world")
    H.eq(p.worktree, "id:" .. H.WT.worktreeId); H.eq(p.presentation, "background")
    H.eq(p.startupCommandDelivery, "shell-ready"); H.eq(p.title, "Clone hello-world")
    H.eq(t.opened[1].term.handle, "t5")
end)

H.test("clone quotes a folder with spaces and rejects non-URLs", function()
    local app, t = setup()
    app.settings:set("projects_dir", "C:/My Projects")
    app.create:open(); t.tap("Clone from GitHub")
    t.answer("https://github.com/octo/x")
    H.eq(t.lastCall("terminal.create").params.command,
        "git clone https://github.com/octo/x.git 'C:/My Projects/x'; orca repo add --path 'C:/My Projects/x'")
    app.create:open(); t.tap("Clone from GitHub"); t.answer("not a url")
    H.eq(t.lastCard().title, "Not a repository")
end)

H.test("folder button sets the projects folder, then asks again", function()
    local app, t = setup({ ["repo.list"] = { repos = {} } })
    app.create:open(); t.tap("New empty project")
    H.has(t.asks[1].description, "not set")
    t.answer("My Tool")             -- no folder yet: asks for it first
    H.eq(t.asks[2].title, "Projects folder on the PC")
    t.answer("C:\\work\\")
    H.eq(app.settings:get("projects_dir"), "C:/work")
    H.eq(t.asks[3].input, "My Tool")
    t.answer("My Tool")
    local cmd = t.lastCall("terminal.create").params.command
    H.eq(cmd, "git init C:/work/my-tool; git -C C:/work/my-tool commit --allow-empty -m 'Initial commit'; "
        .. "orca repo add --path C:/work/my-tool")
end)

H.test("runOnDesktop: matching workspace, else cd first", function()
    local app, t = setup()
    app.create:runOnDesktop("Resume", { "claude --resume abc" }, "c:/P/faxa/")
    t.settle()
    local p = t.lastCall("terminal.create").params
    H.eq(p.worktree, "id:" .. H.WT2.worktreeId); H.eq(p.command, "claude --resume abc")
    app.create:runOnDesktop("Resume", { "claude --resume abc" }, "C:\\elsewhere\\my proj")
    t.settle()
    p = t.lastCall("terminal.create").params
    H.eq(p.worktree, "id:" .. H.WT.worktreeId)
    H.eq(p.command, "cd 'C:/elsewhere/my proj'; claude --resume abc")
    H.eq(t.opened[2].term.title, "Resume")
end)

H.test("new session sends the agent and optional prompt", function()
    local app, t = setup()
    app.create:newSession(H.WT)
    H.has(t.asks[1].title, "kindle")
    t.answer(" write tests ")
    local p = t.lastCall("session.tabs.createTerminal").params
    H.eq(p.agent, "claude"); H.eq(p.agentPrompt, "write tests"); H.eq(p.worktree, "id:repo1::C:/p/kindle")
    H.eq(p.activate, false); H.eq(p.select, true); H.eq(p.navigation, "caller")
    H.eq(t.opened[1].term.handle, "t6")
    app.create:newSession(H.WT); t.answer("")
    H.eq(t.lastCall("session.tabs.createTerminal").params.agentPrompt, nil)
    app.create:newShell(H.WT); t.settle()
    H.eq(t.lastCall("session.tabs.createTerminal").params.agent, nil)
end)

H.test("pending tab is picked up from the terminal list", function()
    local lists = 0
    local app, t = setup({
        ["session.tabs.createTerminal"] = { tab = { terminal = { pending = true } } },
        ["terminal.list"] = function()
            lists = lists + 1
            if lists == 1 then return { terminals = { { handle = "t1" } } } end
            return { terminals = { { handle = "t1" }, { handle = "t7", title = "Claude" } } }
        end,
    })
    app.create:newShell(H.WT); t.settle()
    H.eq(t.opened[1].term.handle, "t7")
end)

H.test("manage: sleep, and remove is confirmed and keeps the branch", function()
    local app, t = setup()
    app.create:manage(H.WT)
    H.eq(t.lastCard().kind, "sheet")
    t.press("Sleep workspace")
    H.eq(t.lastCall("worktree.sleep").params.worktree, "id:repo1::C:/p/kindle")
    H.has(t.toasts[#t.toasts], "asleep")
    app.create:manage(H.WT)
    t.press("Remove workspace…")
    local box = t.lastCard()
    H.eq(box.kind, "confirm"); H.eq(box.destructive, true); H.eq(box.ok_text, "Remove")
    t.press("Cancel")
    H.eq(#t.called("worktree.rm"), 0)
    app.create:manage(H.WT); t.press("Remove workspace…"); t.press("Remove")
    H.eq(t.lastCall("worktree.rm").params.deleteBranch, false)
end)

H.test("failed create shows the error without Retry", function()
    local app, t = setup({ ["worktree.create"] = false })
    app.create:open(); t.tap("New workspace"); t.tap("kindle"); t.answer("x")
    H.eq(t.lastCard().kind, "alert"); H.eq(t.lastCard().retry, nil)
end)
