--[[
    Automations: the desktop's scheduled agent runs. The list shows each
    one's schedule and next run; an automation's screen runs it now, turns it
    on or off, and lists its recent runs (a started run opens its workspace).
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local api = require("orca.api.automations")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Automations = {}
Automations.__index = Automations

local TITLE = _("Automations")

function Automations.new(app)
    return setmetatable({ app = app }, Automations)
end

local DAYS = { MO = _("Mon"), TU = _("Tue"), WE = _("Wed"), TH = _("Thu"), FR = _("Fri"), SA = _("Sat"), SU = _("Sun") }
local DAYS_LONG = { MO = _("Mondays"), TU = _("Tuesdays"), WE = _("Wednesdays"), TH = _("Thursdays"),
                    FR = _("Fridays"), SA = _("Saturdays"), SU = _("Sundays") }

-- "FREQ=DAILY;BYHOUR=9;BYMINUTE=0" -> "Daily 09:00"; anything unusual stays raw.
function Automations.schedule(rrule)
    local raw = util.str(rrule):gsub("^RRULE:", "")
    local f = {}
    for k, v in raw:gmatch("([%u]+)=([^;]+)") do f[k] = v end
    local function time()
        local h, m = tonumber(f.BYHOUR), tonumber(f.BYMINUTE) or 0
        if not h or f.BYHOUR:find(",") then return nil end
        return string.format("%02d:%02d", h, m)
    end
    if f.INTERVAL and f.INTERVAL ~= "1" then return raw end
    if f.FREQ == "HOURLY" and not f.BYDAY then
        return T(_("Hourly at :%1"), string.format("%02d", tonumber(f.BYMINUTE) or 0))
    end
    local at = time()
    if not at then return raw end
    if f.FREQ == "DAILY" and not f.BYDAY then return T(_("Daily %1"), at) end
    if f.FREQ == "WEEKLY" and f.BYDAY then
        if f.BYDAY == "MO,TU,WE,TH,FR" then return T(_("Weekdays %1"), at) end
        if DAYS_LONG[f.BYDAY] then return T(_("%1 %2"), DAYS_LONG[f.BYDAY], at) end
        local names = {}
        for d in f.BYDAY:gmatch("[^,]+") do
            if not DAYS[d] then return raw end
            table.insert(names, DAYS[d])
        end
        return T(_("%1 %2"), table.concat(names, ", "), at)
    end
    return raw
end

-- Future epoch ms -> "in 5 min", "in 3 h", "in 2 days".
function Automations.inText(ms, now)
    local s = util.num(ms) / 1000 - (now or os.time())
    if util.num(ms) <= 0 then return "" end
    if s < 60 then return _("any moment") end
    if s < 3600 then return T(_("in %1 min"), math.floor(s / 60)) end
    if s < 86400 then return T(_("in %1 h"), math.floor(s / 3600)) end
    local d = math.floor(s / 86400)
    return d == 1 and _("tomorrow") or T(_("in %1 days"), d)
end

local RUN_STATUS = {
    pending = { glyph = style.glyph.pending, label = _("Waiting") },
    dispatching = { glyph = style.glyph.pending, label = _("Starting") },
    dispatched = { glyph = style.glyph.check, label = _("Started") },
    completed = { glyph = style.glyph.check, label = _("Done") },
    dispatch_failed = { glyph = style.glyph.cross, label = _("Failed") },
    skipped_precheck = { glyph = style.glyph.skipped, label = _("Skipped") },
    skipped_missed = { glyph = style.glyph.skipped, label = _("Missed") },
    skipped_unavailable = { glyph = style.glyph.skipped, label = _("Skipped") },
    skipped_needs_interactive_auth = { glyph = style.glyph.skipped, label = _("Needs sign-in") },
}

local function workspaceLabel(id, names, fallback)
    id = util.str(id)
    if names[id] then return names[id] end
    if util.str(fallback) ~= "" then return util.str(fallback) end
    local path = id:match("::(.+)$")
    return path and util.basename(path) or nil
end

-- List ------------------------------------------------------------------------------

function Automations:row(a, names)
    local enabled = a.enabled == true
    local parts = { Automations.schedule(a.rrule) }
    if enabled then
        local next_run = Automations.inText(a.nextRunAt)
        if next_run ~= "" then table.insert(parts, T(_("next %1"), next_run)) end
    end
    return {
        title = util.str(a.name) ~= "" and util.str(a.name) or _("Untitled automation"),
        subtitle = table.concat(parts, " · "),
        detail = enabled and _("On") or _("Off"),
        dim = not enabled,
        chevron = true,
        callback = function() self:show(a, names) end,
    }
end

function Automations:listScreen(r)
    local rows = {}
    table.sort(r.automations, function(a, b)
        if (a.enabled == true) ~= (b.enabled == true) then return a.enabled == true end
        return util.num(a.nextRunAt) < util.num(b.nextRunAt)
    end)
    for _i, a in ipairs(r.automations) do table.insert(rows, self:row(a, r.names)) end
    return {
        title = TITLE,
        sections = { { rows = rows } },
        empty = _("No automations yet. Create one in Orca on your PC (Automations), then refresh."),
        refresh = function() self:load() end,
    }
end

-- Loads automations with workspace names (worktree.ps), which only label rows.
local function fetch(c)
    local list, err = api.list(c)
    if not list then return nil, err end
    local names, worktrees = {}, c:listWorktrees() or {}
    for _i, wt in ipairs(worktrees) do names[util.str(wt.worktreeId)] = util.basename(wt.path) end
    return { automations = list, names = names, worktrees = worktrees }
end

function Automations:load()
    local page = self.page
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = TITLE, loading = _("Loading automations…") }
        self.page = page
    end
    self.app:request{
        run = fetch,
        done = function(r)
            self.worktrees = r.worktrees
            page:set(self:listScreen(r))
        end,
        on_error = function(err)
            page:set{ title = TITLE, empty = self.app:explain(err), refresh = function() self:load() end }
        end,
    }
end

function Automations:open()
    self.app.online(function()
        self.page = nil
        self:load()
    end)
end

-- One automation --------------------------------------------------------------------------

function Automations:runRow(run, names)
    local status = RUN_STATUS[util.str(run.status)] or { glyph = " ", label = util.str(run.status) }
    local when = util.num(run.startedAt) > 0 and run.startedAt or run.scheduledFor
    local parts = { util.ago(when) }
    if util.str(run.trigger) == "manual" then table.insert(parts, _("run by hand")) end
    local where = workspaceLabel(run.workspaceId, names, run.workspaceDisplayName)
    if where then table.insert(parts, where) end
    local title = util.num(run.runNumber) > 0 and T(_("Run %1"), math.floor(util.num(run.runNumber)))
        or (util.str(run.title) ~= "" and util.str(run.title) or _("Run"))
    local row = {
        glyph = status.glyph,
        title = title,
        subtitle = table.concat(parts, " · "),
        detail = status.label,
    }
    if util.str(run.error) ~= "" then
        row.callback = function()
            self.app.dialog.alert{ title = T(_("%1: %2"), title, status.label), text = util.str(run.error) }
        end
    elseif util.str(run.workspaceId) ~= "" and (run.status == "dispatched" or run.status == "completed") then
        row.chevron = true
        row.callback = function() self:openWorkspace(run.workspaceId) end
    end
    return row
end

function Automations:openWorkspace(id)
    for _i, wt in ipairs(self.worktrees or {}) do
        if util.str(wt.worktreeId) == id then return self.app.workspace:open(wt) end
    end
    self.app:request{
        run = function(c) return c:listWorktrees() end,
        done = function(worktrees)
            self.worktrees = worktrees
            for _i, wt in ipairs(worktrees) do
                if util.str(wt.worktreeId) == id then return self.app.workspace:open(wt) end
            end
            self.app:toast(_("That workspace no longer exists."))
        end,
    }
end

function Automations:detailScreen(a, runs, names)
    local name = util.str(a.name) ~= "" and util.str(a.name) or _("Untitled automation")
    local enabled = a.enabled == true
    local facts = {}
    local prompt = util.collapse(a.prompt)
    if prompt ~= "" then
        table.insert(facts, { title = _("Prompt"), subtitle = util.ellipsize(prompt, 160),
            callback = function() self.app.text.read{ title = name, text = util.str(a.prompt) } end })
    end
    table.insert(facts, { title = _("Agent"), detail = self.app:agentName(util.str(a.agentId) ~= "" and a.agentId or nil) })
    local where = workspaceLabel(a.workspaceId, names)
    table.insert(facts, { title = _("Workspace"), detail = where or _("New workspace each run") })
    if enabled then
        table.insert(facts, { title = _("Next run"), detail = Automations.inText(a.nextRunAt) })
    end
    if util.num(a.lastRunAt) > 0 then
        table.insert(facts, { title = _("Last run"), detail = util.ago(a.lastRunAt) })
    end

    local actions = {
        { title = _("Run now…"), callback = function() self:runNow(a, where) end },
        { title = enabled and _("Turn off") or _("Turn on"), callback = function() self:setEnabled(a, not enabled) end },
    }
    local run_rows = {}
    for _i, run in ipairs(runs or {}) do table.insert(run_rows, self:runRow(run, names)) end
    if #run_rows == 0 then
        table.insert(run_rows, { title = _("No runs yet"), dim = true })
    end
    return {
        title = name,
        subtitle = Automations.schedule(a.rrule) .. " · " .. (enabled and _("On") or _("Off")),
        sections = {
            { rows = facts },
            { title = _("Actions"), rows = actions },
            { title = _("Recent runs"), rows = run_rows },
        },
        refresh = function() self:show(a, names, self.detail) end,
    }
end

function Automations:show(a, names, page)
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = util.str(a.name), loading = _("Loading recent runs…") }
    end
    self.detail = page
    self.current = { a = a, names = names }
    self.app:request{
        run = function(c) return api.runs(c, a.id, 10) end,
        done = function(runs) page:set(self:detailScreen(a, runs, names)) end,
        on_error = function(err)
            page:set{ title = util.str(a.name), empty = self.app:explain(err),
                      refresh = function() self:show(a, names, page) end }
        end,
    }
end

-- Reloads the automation (its state changed) and both screens.
function Automations:reload(id)
    self.app:request{
        background = true,
        run = fetch,
        done = function(r)
            self.worktrees = r.worktrees
            if self.page and self.page:isShown() then self.page:set(self:listScreen(r)) end
            for _i, a in ipairs(r.automations) do
                if util.str(a.id) == id and self.detail and self.detail:isShown() then
                    self:show(a, r.names, self.detail)
                end
            end
        end,
    }
end

function Automations:runNow(a, where)
    local name = util.str(a.name)
    local agent = self.app:agentName(util.str(a.agentId) ~= "" and a.agentId or nil)
    self.app.dialog.confirm{
        title = T(_("Run %1 now?"), name),
        text = where and T(_("Starts a %1 session in %2."), agent, where)
            or T(_("Starts a %1 session in a new workspace."), agent),
        ok_text = _("Run"),
        on_ok = function()
            self.app:request{
                once = true,
                busy = T(_("Starting %1…"), name),
                run = function(c) return api.runNow(c, a.id) end,
                done = function()
                    self.app:toast(T(_("Started %1"), name))
                    self:reload(a.id)
                end,
            }
        end,
    }
end

function Automations:setEnabled(a, on)
    local name = util.str(a.name)
    self.app:request{
        once = true,
        busy = on and T(_("Turning on %1…"), name) or T(_("Turning off %1…"), name),
        run = function(c) return api.setEnabled(c, a.id, on) end,
        done = function()
            self.app:toast(on and T(_("Turned on %1"), name) or T(_("Turned off %1"), name))
            self:reload(a.id)
        end,
    }
end

return Automations
