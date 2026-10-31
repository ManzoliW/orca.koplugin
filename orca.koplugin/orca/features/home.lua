--[[
    Home: the workspace list, grouped by what needs attention first
    (Needs you → Working → Done → the rest), then shortcuts to
    conversations, automations and the account.

    In pick mode (choosing where to send a passage) it shows workspaces only
    and opens the chosen workspace's sessions for picking.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local common = require("orca.api.common")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Home = {}
Home.__index = Home

function Home.new(app)
    return setmetatable({ app = app }, Home)
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

function Home:screen(worktrees, pick)
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

    local sections = {
        { title = style.status.needs.label, rows = groups.needs },
        { title = style.status.working.label, rows = groups.working },
        { title = style.status.done.label, rows = groups.done },
        { title = _("Workspaces"), rows = groups.idle },
    }
    local subtitle
    if #groups.needs > 0 then
        subtitle = #groups.needs == 1 and _("1 needs you") or T(_("%1 need you"), #groups.needs)
    end
    if not pick then
        table.insert(sections, { title = _("More"), rows = {
            { title = _("Recent conversations"), chevron = true,
              callback = function() self.app.conversations:open() end },
            { title = _("Automations"), chevron = true,
              callback = function() self.app.automations:open() end },
            { title = _("Account and usage"), chevron = true,
              callback = function() self.app.accounts:open() end },
        } })
    end
    return {
        title = pick and pick.title or _("Orca"),
        subtitle = subtitle,
        sections = sections,
        empty = _("No workspaces yet. Tap + to start one."),
        add = not pick and function() self.app.create:open() end or nil,
        refresh = function() self:load(pick) end,
    }
end

-- Loads the list into the home screen (pushing it when the window is closed).
function Home:load(pick, page)
    page = page or self.page
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = pick and pick.title or _("Orca"), loading = _("Connecting to your PC…") }
        self.page = page
    end
    self.app:request{
        run = function(c) return c:listWorktrees() end,
        done = function(worktrees)
            page:set(self:screen(worktrees, pick))
        end,
        on_error = function(err)
            page:set{
                title = pick and pick.title or _("Orca"),
                empty = self.app:explain(err),
                refresh = function() self:load(pick) end,
            }
        end,
    }
end

--[[
    Opens the workspace list. pick = { title, on_pick(term, wt) } turns it into
    a session picker. jump_to opens straight on that workspace.
--]]
function Home:open(pick, jump_to)
    self.app.online(function()
        self.page = nil
        self:load(pick)
        if jump_to then self.app.workspace:open(jump_to, pick) end
    end)
end

return Home
