--[[
    Home: a dashboard that answers "does anything need me?" first.

      - the session waiting for you, with its question and answer buttons
      - workspaces with an agent at work (Needs you → Working → Done)
      - Claude's 5-hour and weekly limits as bars
      - today's numbers (conversations, agents, pull requests, agent time)
      - tabs: Home, Workspaces, Chats, Usage, Automations

    The last dashboard is drawn straight away while the new one loads.
    Workspaces and agent states come first; usage, totals and conversations
    follow in the background and are reused for a few minutes, since the
    conversation vault scans transcripts on disk.

    The workspace list groups every workspace the same way. In pick mode
    (choosing where to send a passage) it opens the chosen workspace's
    sessions for picking.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local ansi = require("orca.render.ansi")
local common = require("orca.api.common")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Home = {}
Home.__index = Home

local EXTRAS_FRESH = 300        -- s to reuse usage and totals
local CHATS_FRESH = 900         -- s to reuse the conversation list
local CHATS_LIMIT = 30
local CHATS_TIMEOUT = 60
local KEY_ESC = "\27"

function Home.new(app)
    return setmetatable({ app = app, extras = {} }, Home)
end

local function branchOf(wt)
    return util.str(wt.branch):gsub("^refs/heads/", "")
end

function Home:workspaceRow(wt, pick)
    local status = style.status[common.state(wt.status).key]
    local count = util.num(wt.liveTerminalCount)
    local parts = {}
    local branch = branchOf(wt)
    if branch ~= "" then table.insert(parts, branch) end
    if count > 0 then
        table.insert(parts, count == 1 and _("1 session") or T(_("%1 sessions"), count))
    end
    return {
        glyph = status.glyph or " ",
        title = util.basename(wt.path),
        subtitle = table.concat(parts, " · "),
        bold = status.bold,
        chevron = true,
        callback = function() self.app.workspace:open(wt, pick) end,
    }
end

-- Rows per state, most urgent first: { needs = {...}, working, done, idle }.
function Home:groups(worktrees, pick)
    local groups = { needs = {}, working = {}, done = {}, idle = {} }
    table.sort(worktrees, function(a, b)
        local ra, rb = common.state(a.status).rank, common.state(b.status).rank
        if ra ~= rb then return ra < rb end
        local ca, cb = util.num(a.liveTerminalCount), util.num(b.liveTerminalCount)
        if ca ~= cb then return ca > cb end
        return util.basename(a.path):lower() < util.basename(b.path):lower()
    end)
    for _, wt in ipairs(worktrees) do
        table.insert(groups[common.state(wt.status).key], self:workspaceRow(wt, pick))
    end
    return groups
end

local function needsText(n)
    return n == 1 and _("1 needs you") or T(_("%1 need you"), n)
end

-- Every workspace, grouped by state.
function Home:listScreen(worktrees, pick)
    local groups = self:groups(worktrees, pick)
    return {
        title = pick and pick.title or _("Workspaces"),
        subtitle = #groups.needs > 0 and needsText(#groups.needs) or nil,
        sections = {
            { title = style.status.needs.label, rows = groups.needs },
            { title = style.status.working.label, rows = groups.working },
            { title = style.status.done.label, rows = groups.done },
            { title = _("Workspaces"), rows = groups.idle },
        },
        empty = _("No workspaces yet. Tap + to start one."),
        add = not pick and function() self.app.create:open() end or nil,
        refresh = function() self:loadList(pick) end,
    }
end

-- Dashboard pieces --------------------------------------------------------------------

function Home:answer(waiting, key, label)
    self.app:request{
        once = true,
        run = function(c) return c:sendText(waiting.term.handle, key == "Esc" and KEY_ESC or key, false) end,
        done = function()
            self.app:toast(T(_("Sent %1"), label or key))
            self:load()
        end,
    }
end

function Home:heroCard(waiting)
    local name = util.basename(waiting.wt and waiting.wt.path or waiting.worktree)
    local agent = self.app:agentName(util.str(waiting.term.agentIdentity) ~= "" and waiting.term.agentIdentity or nil)
    local answers = {}
    for _i, choice in ipairs(ansi.choices(waiting.excerpt)) do
        if #answers == 3 then break end
        local label = choice.key .. " " .. util.ellipsize(choice.label, 10)
        table.insert(answers, { text = label, callback = function() self:answer(waiting, choice.key, label) end })
    end
    if #answers == 0 then
        for _i, key in ipairs({ "1", "2", "3" }) do
            table.insert(answers, { text = key, mono = true, callback = function() self:answer(waiting, key) end })
        end
    end
    table.insert(answers, { text = "Esc", mono = true, callback = function() self:answer(waiting, "Esc") end })
    return {
        type = "hero",
        title = T(_("%1 needs you in %2"), agent, name),
        mono = waiting.excerpt,
        buttons = {
            answers,
            { { text = _("Open session"), callback = function()
                self.app.session:open({ handle = waiting.term.handle, title = util.str(waiting.term.title) },
                    waiting.wt or { worktreeId = waiting.worktree, path = name })
            end } },
        },
    }
end

function Home:gaugesCard(usage)
    local claude = util.tbl(util.tbl(util.tbl(usage).rateLimits).claude)
    local items = {}
    for _i, w in ipairs({ { "session", _("5h") }, { "weekly", _("Week") }, { "fableWeekly", _("Fable") } }) do
        local win = claude[w[1]]
        if type(win) == "table" and tonumber(win.usedPercent) then
            local detail
            if util.num(win.resetsAt) > 0 then
                detail = T(_("resets %1"), self.app.accounts.untilText(win.resetsAt))
            end
            table.insert(items, { label = w[2], percent = tonumber(win.usedPercent), detail = detail })
        end
    end
    if #items == 0 then return nil end
    return { type = "gauges", items = items, callback = function() self.app.accounts:open() end }
end

-- Conversations touched today (local time).
local function chatsToday(sessions, now)
    local today = os.date("%Y-%m-%d", now)
    local n = 0
    for _i, s in ipairs(util.tbl(sessions)) do
        local t = type(s) == "table" and util.isoTime(s.updatedAt)
        if t and os.date("%Y-%m-%d", t) == today then n = n + 1 end
    end
    return n
end

function Home:tilesCard(extras)
    local items = {}
    local open_chats = function() self.app.conversations:open() end
    local open_usage = function() self.app.accounts:open() end
    if extras.chats then
        table.insert(items, { value = tostring(chatsToday(extras.chats, os.time())),
                              label = _("chats today"), callback = open_chats })
    end
    local s = extras.stats
    if type(s) == "table" then
        table.insert(items, { value = tostring(math.floor(util.num(s.totalAgentsSpawned))),
                              label = _("agents"), callback = open_usage })
        table.insert(items, { value = tostring(math.floor(util.num(s.totalPRsCreated))),
                              label = _("pull requests"), callback = open_usage })
        table.insert(items, { value = string.format("%.0f h", util.num(s.totalAgentTimeMs) / 3600000),
                              label = _("agent time"), callback = open_usage })
    end
    if #items == 0 then return nil end
    return { type = "tiles", items = items }
end

function Home:tabs()
    return {
        { text = _("Home"), selected = true },
        { text = _("Workspaces"), callback = function() self:openList() end },
        { text = _("Chats"), callback = function() self.app.conversations:open() end },
        { text = _("Usage"), callback = function() self.app.accounts:open() end },
        { text = _("Automations"), callback = function() self.app.automations:open() end },
    }
end

--[[
    data = { worktrees, waiting = { term, wt, worktree, excerpt } | nil }
    extras = { usage, stats, chats } (any may be missing)
--]]
function Home:dashboard(data, extras, updating)
    extras = extras or {}
    local groups = self:groups(data.worktrees)
    local sections = {}
    if data.waiting then table.insert(sections, { card = self:heroCard(data.waiting) }) end
    for _i, key in ipairs({ "needs", "working", "done" }) do
        table.insert(sections, { title = style.status[key].label, rows = groups[key] })
    end
    local gauges = self:gaugesCard(extras.usage)
    if gauges then table.insert(sections, { title = _("Claude usage"), card = gauges }) end
    local tiles = self:tilesCard(extras)
    if tiles then table.insert(sections, { title = _("Activity"), card = tiles }) end
    local active = #groups.needs + #groups.working + #groups.done
    table.insert(sections, { title = active == 0 and _("All quiet") or _("Workspaces"), rows = {
        { title = _("All workspaces"), detail = tostring(#data.worktrees), chevron = true,
          callback = function() self:openList() end },
    } })

    local subtitle
    if updating then
        subtitle = _("Updating…")
    elseif #groups.needs > 0 then
        subtitle = needsText(#groups.needs)
    else
        subtitle = os.date("%a %d %b · %H:%M")
    end
    return {
        title = _("Orca"),
        subtitle = subtitle,
        sections = sections,
        tabs = self:tabs(),
        add = function() self.app.create:open() end,
        refresh = function() self:load(true) end,
    }
end

-- Inside a job: the first session waiting for an answer, with its question.
local function findWaiting(c, worktrees, states)
    local handles = {}
    for handle, status in pairs(states) do
        if common.state(status.state).key == "needs" then table.insert(handles, handle) end
    end
    table.sort(handles)
    local handle = handles[1]
    if not handle then return nil end
    local status = states[handle]
    local wt
    for _i, w in ipairs(worktrees) do
        if w.worktreeId == status.worktree then wt = w; break end
    end
    local screen = c:readTerminal(handle, true)
    return {
        term = { handle = handle, title = status.title, agentIdentity = status.agentType },
        wt = wt,
        worktree = util.str(status.worktree),
        excerpt = screen and ansi.promptExcerpt(screen.tail) or nil,
    }
end

-- Usage, totals and conversations in the background; each may fail alone.
function Home:loadExtras(page, force)
    local now = os.time()
    local extras = self.extras
    local want_usage = force or now - (extras.at or 0) >= EXTRAS_FRESH
    local want_chats = self.app.conversations and (force or now - (extras.chats_at or 0) >= CHATS_FRESH)
    if not want_usage and not want_chats then return end
    self.app:request{
        background = true,
        run = function(c)
            local r = {}
            if want_usage then
                r.usage = c:call("accounts.list", { refreshUsage = false }, 20)
                r.stats = c:call("stats.summary", nil, common.TIMEOUT.slow)
            end
            if want_chats then
                local vault = c:call("aiVault.listSessions", { limit = CHATS_LIMIT }, CHATS_TIMEOUT)
                r.chats = type(vault) == "table" and util.tbl(vault.sessions) or nil
            end
            return r
        end,
        done = function(r)
            if want_usage then
                extras.at = now
                extras.usage = r.usage or extras.usage
                extras.stats = r.stats or extras.stats
            end
            if want_chats and r.chats then
                extras.chats_at = now
                extras.chats = r.chats
            end
            if self.data and page:isShown() then page:set(self:dashboard(self.data, extras)) end
        end,
    }
end

-- Loads the dashboard into the home screen (pushing it when the window is closed).
function Home:load(force)
    local page = self.page
    if not page or not page:isShown() then
        if self.data then
            page = self.app.nav:push(self:dashboard(self.data, self.extras, true))
        else
            page = self.app.nav:push{ title = _("Orca"), loading = _("Connecting to your PC…") }
        end
        self.page = page
    end
    self.app:request{
        run = function(c)
            local worktrees, err = c:listWorktrees()
            if not worktrees then return nil, err end
            local states = c:agentStates() or {}
            return { worktrees = worktrees, waiting = findWaiting(c, worktrees, states) }
        end,
        done = function(data)
            self.data = data
            page:set(self:dashboard(data, self.extras))
            self:loadExtras(page, force)
        end,
        on_error = function(err)
            page:set{
                title = _("Orca"),
                empty = self.app:explain(err),
                refresh = function() self:load(true) end,
                tabs = self:tabs(),
            }
        end,
    }
end

-- Loads the workspace list (pushing it when it isn't shown).
function Home:loadList(pick)
    local page = self.list_page
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = pick and pick.title or _("Workspaces"), loading = _("Connecting to your PC…") }
        self.list_page = page
    end
    self.app:request{
        run = function(c) return c:listWorktrees() end,
        done = function(worktrees) page:set(self:listScreen(worktrees, pick)) end,
        on_error = function(err)
            page:set{
                title = pick and pick.title or _("Workspaces"),
                empty = self.app:explain(err),
                refresh = function() self:loadList(pick) end,
            }
        end,
    }
end

function Home:openList(pick)
    self.list_page = nil
    self:loadList(pick)
end

--[[
    Opens the dashboard. pick = { title, on_pick(term, wt) } opens the
    workspace list as a session picker instead. jump_to opens straight on
    that workspace.
--]]
function Home:open(pick, jump_to)
    self.app.online(function()
        if pick then
            self:openList(pick)
        else
            self.page = nil
            self:load()
        end
        if jump_to then self.app.workspace:open(jump_to, pick) end
    end)
end

return Home
