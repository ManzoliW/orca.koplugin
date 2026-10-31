-- Git screen, diff, commit, push/pull, pull request create and status.
local H = require("tests.harness")

local PR = { number = 12, title = "Fix login", state = "open", url = "https://gh/pull/12",
             checksStatus = "failure", mergeable = "MERGEABLE", headSha = "abc", baseRefName = "main" }

local RESULTS = {
    ["git.status"] = { branch = "refs/heads/main", entries = {
        { path = "src/a.lua", status = "modified", area = "unstaged", added = 3, removed = 1 },
        { path = "new.txt", status = "untracked", area = "untracked" },
        { path = "b.lua", status = "renamed", area = "staged", oldPath = "old.lua" },
    } },
    ["git.upstreamStatus"] = { hasUpstream = true, ahead = 1, behind = 0 },
    ["github.prForBranch"] = { kind = "no-pr" },
    ["git.diff"] = { kind = "text", originalContent = "x\ny\n", modifiedContent = "x\nz\n" },
    ["files.read"] = { content = "hello\n", truncated = false },
    ["git.bulkStage"] = { ok = true },
    ["git.generateCommitMessage"] = { success = true, message = "Fix things" },
    ["git.commit"] = { success = true },
    ["git.push"] = { ok = true },
    ["git.pull"] = { ok = true },
    ["hostedReview.getCreationEligibility"] = { canCreate = true, provider = "github", defaultBaseRef = "main",
                                                title = "T", head = "main", body = "B" },
    ["hostedReview.create"] = { ok = true, number = 3, url = "https://x/pull/3" },
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

local function section(spec, title)
    for _, s in ipairs(spec.sections) do if s.title and s.title:find(title, 1, true) == 1 then return s end end
    error("no section " .. title)
end

H.test("git screen: branch line, changes with letters and line counts", function()
    local app, t = setup()
    app.git:open(H.WT)
    t.settle()
    local top = t.top()
    H.eq(top.title, "Git"); H.eq(top.subtitle, "main · ↑1 ↓0")
    local a = t.row("a.lua")
    H.eq(a.glyph, "M"); H.eq(a.subtitle, "src"); H.eq(a.detail, "+3 −1"); H.eq(a.chevron, true)
    H.eq(t.row("new.txt").glyph, "?"); H.eq(t.row("new.txt").subtitle, nil)
    H.eq(t.row("b.lua").detail, "staged")
    t.row("Create pull request…"); t.row("Commit…"); t.row("Commit and push…"); t.row("Push"); t.row("Pull")
    t.row("Read all changes as a book")
    local p = t.lastCall("git.status").params
    H.eq(p.worktree, "id:repo1::C:/p/kindle"); H.eq(p.includeLineStats, true)
    H.eq(t.lastCall("github.prForBranch").params.repo, "id:repo1")
    H.eq(t.lastCall("github.prForBranch").params.branch, "main")
end)

H.test("git screen: clean tree and no upstream", function()
    local app, t = setup({ ["git.status"] = { branch = "fix", entries = {} },
                           ["git.upstreamStatus"] = { hasUpstream = false } })
    app.git:open(H.WT); t.settle()
    H.eq(t.top().subtitle, "fix · not pushed yet")
    H.eq(t.row("Nothing to commit").dim, true)
    H.eq(pcall(t.row, "Commit…"), false)
end)

H.test("diff opens in mono with book and ask actions", function()
    local app, t = setup()
    app.git:open(H.WT); t.settle()
    t.tap("a.lua")
    local v = t.reads[#t.reads]
    H.eq(v.mono, true); H.has(v.text, "- y"); H.has(v.text, "+ z")
    H.eq(t.lastCall("git.diff").params.filePath, "src/a.lua"); H.eq(t.lastCall("git.diff").params.staged, false)
    v.actions[1].callback()
    H.has(t.books[1].name, "kindle-a.lua.diff")
    H.eq(#t.stack, 0)
    app.git:open(H.WT); t.settle()
    t.tap("new.txt")
    H.has(t.reads[#t.reads].text, "+ hello")
    t.tap("b.lua")
    H.eq(t.lastCall("git.diff").params.oldPath, "old.lua"); H.eq(t.lastCall("git.diff").params.staged, true)
    t.reads[#t.reads].actions[2].callback()
    H.has(t.asks[#t.asks].title, "my uncommitted changes to b.lua")
end)

H.test("commit and push: stages all paths, drafted message, keyboard dialog", function()
    local app, t = setup()
    app.git:open(H.WT); t.settle()
    t.tap("Commit and push…")
    local staged = t.lastCall("git.bulkStage").params.filePaths
    H.eq(table.concat(staged, ","), "src/a.lua,new.txt,b.lua,old.lua")
    local ask = t.asks[#t.asks]
    H.eq(ask.input, "Fix things"); H.eq(ask.ok_text, "Commit and push"); H.eq(ask.extra[1].text, "Commit")
    H.eq(ask.title, "Commit 3 files")
    t.answer("Fix things")
    H.eq(t.lastCall("git.commit").params.message, "Fix things")
    H.eq(#t.called("git.push"), 1)
    H.has(t.toasts[#t.toasts], "Committed and pushed")
    H.eq(t.top().title, "Git")
end)

H.test("commit only via the other button; failure has no Retry", function()
    local app, t = setup({ ["git.commit"] = { success = false, error = "nothing staged" } })
    app.git:open(H.WT); t.settle()
    t.tap("Commit…")
    local ask = t.asks[#t.asks]
    H.eq(ask.ok_text, "Commit")
    ask.on_ok("msg"); t.settle()
    H.eq(#t.called("git.push"), 0)
    H.eq(t.lastCard().kind, "alert"); H.has(t.lastCard().text, "nothing staged"); H.eq(t.lastCard().retry, nil)
end)

H.test("push and pull reload the screen", function()
    local app, t = setup()
    app.git:open(H.WT); t.settle()
    t.tap("Push")
    H.eq(t.lastCall("git.push").params.worktree, "id:repo1::C:/p/kindle")
    t.tap("Pull")
    H.eq(#t.called("git.pull"), 1)
    H.eq(#t.called("git.status"), 3)
    H.eq(#t.stack, 1)
end)

H.test("create pull request with the eligibility's params", function()
    local app, t = setup()
    app.git:open(H.WT); t.settle()
    t.tap("Create pull request…")
    local e = t.lastCall("hostedReview.getCreationEligibility").params
    H.eq(e.repo, "id:repo1"); H.eq(e.branch, "main"); H.eq(e.worktree, "id:repo1::C:/p/kindle")
    local ask = t.asks[#t.asks]
    H.eq(ask.input, "T"); H.eq(ask.ok_text, "Create"); H.eq(ask.extra[1].text, "Create draft")
    t.answer("My PR")
    local p = t.lastCall("hostedReview.create").params
    H.eq(p.base, "main"); H.eq(p.provider, "github"); H.eq(p.title, "My PR"); H.eq(p.draft, false)
    H.eq(p.head, "main"); H.eq(p.body, "B")
    H.has(t.toasts[#t.toasts], "#3")
end)

H.test("blocked pull request explains why", function()
    local app, t = setup({ ["hostedReview.getCreationEligibility"] = { canCreate = false, blockedReason = "no_upstream" } })
    app.git:open(H.WT); t.settle()
    t.tap("Create pull request…")
    H.has(t.lastCard().text, "Push the branch first")
end)

H.test("changes book collects every diff", function()
    local app, t = setup()
    app.git:open(H.WT); t.settle()
    t.tap("Read all changes as a book")
    H.has(t.books[1].name, "kindle-changes-")
    H.has(t.books[1].body, "src/a.lua"); H.has(t.books[1].body, "+ hello")
end)

H.test("PR row shows checks glyph and word; PR screen lists checks", function()
    local app, t = setup({ ["github.prForBranch"] = { kind = "found", pr = PR } })
    app.git:open(H.WT); t.settle()
    local row = t.row("#12 Fix login")
    H.eq(row.glyph, "✕"); H.eq(row.detail, "Checks fail"); H.eq(row.chevron, true)
    H.eq(pcall(t.row, "Create pull request"), false)
    t.tap("#12 Fix login")
    local top = t.top()
    H.eq(top.title, "#12"); H.eq(top.subtitle, "Open")
    H.eq(t.row("Fix login").subtitle, "mergeable")
    local checks = section(top, "Checks").rows
    H.eq(checks[1].glyph, "✓"); H.eq(checks[1].detail, "Passed")
    H.eq(checks[2].glyph, "✕"); H.eq(checks[2].title, "smoke"); H.eq(checks[2].detail, "Failed")
    H.eq(checks[3].glyph, "…"); H.eq(checks[3].detail, "Running")
    local p = t.lastCall("github.prChecks").params
    H.eq(p.prNumber, 12); H.eq(p.headSha, "abc"); H.eq(p.repo, "id:repo1")
    t.row("Merge…"); t.row("Re-run the failed check"); t.row("Ask Claude to fix…")
    top.refresh(); t.settle()
    H.eq(t.lastCall("github.prChecks").params.noCache, true)
end)

H.test("check details skip passing steps and fall back to the URL", function()
    local app, t = setup({ ["github.prForBranch"] = { kind = "found", pr = PR } })
    app.git:open(H.WT); t.settle(); t.tap("#12"); t.tap("smoke")
    local p = t.lastCall("github.prCheckDetails").params
    H.eq(p.checkRunId, 2); H.eq(p.workflowRunId, 11); H.eq(p.checkName, "smoke"); H.eq(p.url, "u2")
    local v = t.reads[#t.reads]
    H.has(v.text, "Run smoke"); H.has(v.text, "app/x.ts:12  boom"); H.has(v.text, "https://gh/run/2")
    H.eq(v.text:find("Install", 1, true), nil)
    H.results["github.prCheckDetails"] = { summary = newproxy(), jobs = newproxy() }
    t.tap("smoke")
    v = t.reads[#t.reads]
    H.has(v.text, "smoke · Failed"); H.has(v.text, "no details"); H.has(v.text, "u2")
end)

H.test("re-run failed checks and ask the agent to fix", function()
    local app, t = setup({ ["github.prForBranch"] = { kind = "found", pr = PR } })
    app.git:open(H.WT); t.settle(); t.tap("#12")
    t.tap("Re-run the failed check")
    local r = t.lastCall("github.rerunPRChecks").params
    H.eq(r.failedOnly, true); H.eq(r.prNumber, 12); H.eq(r.headSha, "abc")
    H.has(t.toasts[#t.toasts], "restarted")
    t.tap("Ask Claude to fix")
    H.has(t.asks[#t.asks].input, "gh pr checks 12")
    t.answer(t.asks[#t.asks].input)
    local p = t.lastCall("session.tabs.createTerminal").params
    H.eq(p.agent, "claude"); H.has(p.agentPrompt, "smoke"); H.has(p.agentPrompt, "https://gh/pull/12")
    H.eq(t.opened[1].term.handle, "t6")
end)

H.test("merge: method sheet, confirm with Merge verb, then merged", function()
    local pr = {}
    for k, v in pairs(PR) do pr[k] = v end
    local app, t = setup({ ["github.prForBranch"] = { kind = "found", pr = pr } })
    app.git:open(H.WT); t.settle(); t.tap("#12")
    t.tap("Merge…")
    H.eq(t.lastCard().kind, "sheet")
    t.press("Squash and merge")
    local box = t.lastCard()
    H.eq(box.kind, "confirm"); H.eq(box.title, "Merge #12 into main?"); H.eq(box.ok_text, "Merge")
    t.press("Merge")
    local p = t.lastCall("github.mergePR").params
    H.eq(p.method, "squash"); H.eq(p.prNumber, 12); H.eq(p.repo, "id:repo1")
    H.has(t.toasts[#t.toasts], "merged")
    H.eq(t.top().subtitle, "Merged")
    H.eq(pcall(t.row, "Merge…"), false)
end)

H.test("merge refused by GitHub shows its reason", function()
    local app, t = setup({ ["github.prForBranch"] = { kind = "found", pr = PR },
                           ["github.mergePR"] = { ok = false, error = "Base branch was modified" } })
    app.git:open(H.WT); t.settle(); t.tap("#12"); t.tap("Merge…")
    t.press("Rebase and merge"); t.press("Merge")
    H.eq(t.lastCall("github.mergePR").params.method, "rebase")
    H.has(t.lastCard().text, "Base branch was modified")
end)
