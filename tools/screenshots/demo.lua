--[[
    Demo data for README screenshots: appended to a deployed copy of
    orcaclient/client.lua (see tools/screenshots/README.md), it answers the
    read calls the screens make with made-up projects, sessions and pull
    requests, and gives Home a reading history, so screenshots show no
    private work. Anything else still goes to the real desktop; sending
    text to a session is swallowed.

    Never ship it: deploying the plugin again removes it.
--]]

local DEMO_NOW = os.time()
local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", DEMO_NOW - ago) end
local function ms(from_now) return (DEMO_NOW + from_now) * 1000 end

local WT = {
    { worktreeId = "r1::C:/dev/storefront-checkout", path = "C:\\dev\\storefront-checkout", repoId = "r1",
      branch = "refs/heads/feat/checkout-redesign", status = "permission", liveTerminalCount = 2 },
    { worktreeId = "r2::C:/dev/api-rate-limit", path = "C:\\dev\\api-rate-limit", repoId = "r2",
      branch = "refs/heads/fix/rate-limiter", status = "working", liveTerminalCount = 1 },
    { worktreeId = "r3::C:/dev/docs-site", path = "C:\\dev\\docs-site", repoId = "r3",
      branch = "refs/heads/docs/getting-started", status = "done", liveTerminalCount = 1 },
    { worktreeId = "r1::C:/dev/storefront", path = "C:\\dev\\storefront", repoId = "r1",
      branch = "refs/heads/main", liveTerminalCount = 0 },
}

local QUESTION = {
    "● I'll switch the address form to the new autocomplete and keep",
    "  the old fields as a fallback when the lookup fails.",
    "",
    "● Update(src/checkout/AddressForm.tsx)",
    "  ⎿  Updated with 24 additions and 9 removals",
    "",
    "● Now I'll run the checkout tests.",
    "",
    "──────────────────────────────────────────────────────────────",
    " Bash command",
    "",
    "   npm test -- checkout",
    "   Run the checkout test suite",
    "",
    " Do you want to proceed?",
    " ❯ 1. Yes",
    "   2. Yes, and don't ask again for npm test commands",
    "   3. No, and tell Claude what to do differently (esc)",
}

local WORKING = {
    "● Reading src/middleware/rateLimit.ts",
    "● The limiter counts per IP; search needs a per-key budget.",
    "",
    "● Update(src/middleware/rateLimit.ts)",
    "  ⎿  Updated with 31 additions and 4 removals",
    "",
    "✻ Writing tests for the token bucket… (2m 14s · ↓ 6.1k tokens)",
}

local PRS = {
    r1 = { number = 128, title = "Redesign the checkout address form", branchName = "feat/checkout-redesign",
           checks = "pending", ago = 2 * 3600 },
    r2 = { number = 57, title = "Rate-limit the public search endpoint", branchName = "fix/rate-limiter",
           checks = "success", ago = 26 * 3600 },
    r3 = { number = 19, title = "Getting started guide for the SDK", branchName = "docs/getting-started",
           checks = "failure", ago = 3 * 86400 },
}

local DEMO = {
    ["worktree.ps"] = function() return { worktrees = WT } end,
    ["session.tabs.listAll"] = function() return { snapshots = {
        { worktree = WT[1].worktreeId, tabs = {
            { terminal = "demo1", title = "Claude", agentStatus = { state = "permission", agentType = "claude" } },
            { terminal = "demo4", title = "zsh" } } },
        { worktree = WT[2].worktreeId, tabs = {
            { terminal = "demo2", title = "Claude", agentStatus = { state = "working", agentType = "claude" } } } },
        { worktree = WT[3].worktreeId, tabs = {
            { terminal = "demo3", title = "Claude", agentStatus = { state = "done", agentType = "claude" } } } },
    } } end,
    ["terminal.list"] = function(p)
        local id = tostring(p.worktree):gsub("^id:", "")
        if id == WT[1].worktreeId then
            return { terminals = {
                { handle = "demo1", title = "Claude", agentIdentity = "claude", worktreePath = WT[1].path },
                { handle = "demo4", title = "zsh", worktreePath = WT[1].path } } }
        elseif id == WT[2].worktreeId then
            return { terminals = { { handle = "demo2", title = "Claude", agentIdentity = "claude", worktreePath = WT[2].path } } }
        elseif id == WT[3].worktreeId then
            return { terminals = { { handle = "demo3", title = "Claude", agentIdentity = "claude", worktreePath = WT[3].path } } }
        end
        return { terminals = {} }
    end,
    ["terminal.read"] = function(p)
        return { terminal = { tail = p.terminal == "demo1" and QUESTION or WORKING } }
    end,
    ["terminal.send"] = function() return { ok = true } end,
    ["terminal.updateViewport"] = function() return { ok = true } end,
    ["terminal.unsubscribe"] = function() return { ok = true } end,
    ["accounts.list"] = function() return {
        claude = { accounts = {}, systemDefaultEmail = "you@example.com" },
        codex = { accounts = {} },
        rateLimits = { claude = {
            session = { usedPercent = 38, resetsAt = ms(2 * 3600 + 14 * 60) },
            weekly = { usedPercent = 61, resetsAt = ms(3 * 86400 + 5 * 3600) },
            fableWeekly = { usedPercent = 44, resetsAt = ms(3 * 86400 + 5 * 3600) },
        } },
    } end,
    ["stats.summary"] = function() return { totalAgentsSpawned = 412, totalPRsCreated = 96,
                                            totalAgentTimeMs = 186 * 3600000, firstEventAt = ms(-90 * 86400) } end,
    ["aiVault.listSessions"] = function() return { sessions = {
        { title = "Checkout address form redesign", cwd = WT[1].path, agent = "claude", updatedAt = iso(600),
          sessionId = "11111111-1111-4111-8111-111111111111", messageCount = 214, totalTokens = 3820000, branch = "feat/checkout-redesign" },
        { title = "Per-key budget for the search rate limiter", cwd = WT[2].path, agent = "claude", updatedAt = iso(1800),
          sessionId = "22222222-2222-4222-8222-222222222222", messageCount = 96, totalTokens = 1460000, branch = "fix/rate-limiter" },
        { title = "Getting started guide", cwd = WT[3].path, agent = "claude", updatedAt = iso(3 * 3600),
          sessionId = "33333333-3333-4333-8333-333333333333", messageCount = 58, totalTokens = 690000, branch = "docs/getting-started" },
        { title = "Flaky payment webhook test", cwd = "C:\\dev\\storefront", agent = "claude", updatedAt = iso(26 * 3600),
          sessionId = "44444444-4444-4444-8444-444444444444", messageCount = 131, totalTokens = 2210000, branch = "main" },
    } } end,
    ["repo.list"] = function() return { repos = {
        { id = "r1", path = "C:\\dev\\storefront" }, { id = "r2", path = "C:\\dev\\api" }, { id = "r3", path = "C:\\dev\\docs-site" },
    } } end,
    ["github.listWorkItems"] = function(p)
        local repo = tostring(p.repo):gsub("^id:", "")
        local pr = PRS[repo]
        if not pr then return { items = {} } end
        return { items = { { type = "pr", number = pr.number, title = pr.title, state = "open",
                             branchName = pr.branchName, headSha = "abc123", author = "ManzoliW",
                             url = "https://github.com/example/" .. repo .. "/pull/" .. pr.number,
                             updatedAt = iso(pr.ago) } } }
    end,
    ["github.prForBranch"] = function(p)
        for _, pr in pairs(PRS) do
            if pr.branchName == p.branch then
                return { kind = "found", pr = { number = pr.number, title = pr.title, state = "open",
                    checksStatus = pr.checks, mergeable = "MERGEABLE", headSha = "abc123", baseRefName = "main",
                    url = "https://github.com/example/pull/" .. pr.number, reviewDecision = "REVIEW_REQUIRED" } }
            end
        end
        return { kind = "no-pr" }
    end,
    ["github.countWorkItems"] = function(p)
        local n = { ["id:r1"] = 7, ["id:r2"] = 4, ["id:r3"] = 2 }
        return n[p.repo] or 0
    end,
    ["github.prChecks"] = function() return {
        { name = "lint", status = "completed", conclusion = "success", url = "u" },
        { name = "unit tests", status = "completed", conclusion = "success", url = "u" },
        { name = "e2e checkout", status = "in_progress", url = "u" },
        { name = "preview deploy", status = "queued", url = "u" },
    } end,
    ["git.status"] = function() return { branch = "refs/heads/feat/checkout-redesign", entries = {
        { path = "src/checkout/AddressForm.tsx", status = "modified", area = "unstaged", added = 24, removed = 9 },
        { path = "src/checkout/useAddressLookup.ts", status = "untracked", area = "untracked" },
        { path = "src/checkout/AddressForm.test.tsx", status = "modified", area = "unstaged", added = 41, removed = 3 },
    } } end,
    ["git.upstreamStatus"] = function() return { hasUpstream = true, ahead = 2, behind = 0 } end,
}

local real_call, real_stream = Client.call, Client.startStream
function Client:call(method, params, timeout)
    local demo = DEMO[method]
    if demo then return demo(params or {}) end
    return real_call(self, method, params, timeout)
end
function Client:startStream(method, params, timeout)
    if method == "terminal.subscribe" then return "demo-sub", {} end
    return real_stream(self, method, params, timeout)
end

-- Home's Kindle side: a book with a cover, a reading history and Claude's files.
local ok, library = pcall(require, "orca.core.library")
if ok and library then
    local real_files = library.files
    library.recent = function()
        for _, book in ipairs(real_files("/mnt/us/documents", 20)) do
            if book.file:match("spidercat") then
                book.percent = 64
                return { book }
            end
        end
        return {}
    end
    library.readingDays = function(since)
        local days = {}
        for i = 0, 300 do
            local t = DEMO_NOW - i * 86400
            -- Most evenings, longer at weekends, a gap now and then.
            local wday = tonumber(os.date("%w", t))
            local minutes = ((i * 37) % 11 < 3) and 0 or (15 + (i * 53) % 40 + ((wday == 0 or wday == 6) and 35 or 0))
            if i == 0 then minutes = 22 end
            if minutes > 0 then days[os.date("%Y-%m-%d", t)] = minutes * 60 end
        end
        return days
    end
    library.files = function(dir, n)
        if not dir:match("Claude$") then return real_files(dir, n) end
        return {
            { file = dir .. "/plan.epub", title = "Checkout redesign plan", time = DEMO_NOW - 40 * 60 },
            { file = dir .. "/review.epub", title = "Review: rate limiter", percent = 40, time = DEMO_NOW - 5 * 3600 },
            { file = dir .. "/report.epub", title = "Weekly engineering report", percent = 100, status = "complete",
              time = DEMO_NOW - 2 * 86400 },
        }
    end
end

-- `touch /tmp/orca-demo-notify` on the Kindle pops the waiting session's
-- question over the book, as a notification would.
local ok_notify, Notify = pcall(require, "orca.features.notify")
if ok_notify and Notify then
    local UIManager = require("ui/uimanager")
    local real_start = Notify.start
    function Notify:start(...)
        local notify = self
        local function check()
            -- Only the plugin instance that is running takes it (the file
            -- browser's stays scheduled after a book opens).
            if not notify.active then return end
            local f = io.open("/tmp/orca-demo-notify")
            if f then
                f:close()
                os.remove("/tmp/orca-demo-notify")
                notify:enqueue{ kind = "needs", id = "demo", handle = "demo1", term_title = "Claude", agent = "claude",
                                worktreeId = WT[1].worktreeId, paneKey = "", title = "Claude Code", body = "",
                                at = os.time() * 1000, more = 0 }
                notify:showNext()
            end
            UIManager:scheduleIn(3, check)
        end
        UIManager:scheduleIn(3, check)
        return real_start(self, ...)
    end
end

return Client
