--[[
    One workspace: its sessions (with each agent's state) and the places to
    go from there: Git, Files, and workspace actions.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local common = require("orca.api.common")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Workspace = {}
Workspace.__index = Workspace

function Workspace.new(app)
    return setmetatable({ app = app }, Workspace)
end

function Workspace:sessionRow(term, states, wt, pick)
    local agent = states[term.handle]
    local status = style.status[common.state(agent and agent.state).key]
    local title = util.str(term.title) ~= "" and util.str(term.title) or util.str(term.handle)
    return {
        glyph = status.glyph or " ",
        title = title,
        detail = status.label,
        bold = status.bold,
        chevron = true,
        callback = function()
            if pick then return pick.on_pick(term, wt) end
            self.app.session:open(term, wt)
        end,
    }
end

function Workspace:screen(wt, result, pick)
    local sessions = {}
    for _, term in ipairs(result.terminals) do
        table.insert(sessions, self:sessionRow(term, result.states, wt, pick))
    end
    local branch = util.str(wt.branch):gsub("^refs/heads/", "")
    local spec = {
        title = pick and pick.title or util.basename(wt.path),
        subtitle = pick and util.basename(wt.path) or (branch ~= "" and branch or nil),
        sections = { { title = _("Sessions"), rows = sessions } },
        empty = _("No sessions running here."),
        refresh = function() self:load(wt, pick) end,
    }
    if pick then return spec end

    local agent = self.app:agentName()
    spec.add = function()
        self.app.dialog.sheet{
            title = _("New session"),
            actions = {
                { text = T(_("%1 session…"), agent), callback = function() self.app.create:newSession(wt) end },
                { text = _("Shell"), callback = function() self.app.create:newShell(wt) end },
            },
        }
    end
    if #sessions == 0 then
        table.insert(sessions, {
            title = T(_("Start a %1 session"), agent), glyph = style.glyph.add,
            callback = function() self.app.create:newSession(wt) end,
        })
    end
    table.insert(spec.sections, { title = _("Workspace"), rows = {
        { title = _("Git"), subtitle = _("Changes, commit, push, pull request"), chevron = true,
          callback = function() self.app.git:open(wt) end },
        { title = _("Files"), subtitle = util.unixPath(wt.path), truncate_left = true, chevron = true,
          callback = function() self.app.files:open(wt) end },
        { title = _("Sleep or remove…"),
          callback = function() self.app.create:manage(wt) end },
    } })
    return spec
end

function Workspace:load(wt, pick, page)
    page = page or self.pages[wt.worktreeId]
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = util.basename(wt.path), loading = _("Loading sessions…") }
        self.pages[wt.worktreeId] = page
    end
    self.app:request{
        run = function(c)
            local terminals, err = c:listTerminals(wt.worktreeId)
            if not terminals then return nil, err end
            -- Agent states are a nicety; a failure here shouldn't hide the list.
            return { terminals = terminals, states = c:agentStates() or {} }
        end,
        done = function(result) page:set(self:screen(wt, result, pick)) end,
        on_error = function(err)
            page:set{ title = util.basename(wt.path), empty = self.app:explain(err),
                      refresh = function() self:load(wt, pick) end }
        end,
    }
end

function Workspace:open(wt, pick)
    self.pages = self.pages or {}
    self.pages[wt.worktreeId] = nil
    self:load(wt, pick)
end

return Workspace
