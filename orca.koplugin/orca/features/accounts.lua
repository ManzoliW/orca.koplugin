--[[
    Account and usage: the agent's 5-hour and weekly limits, which signed-in
    account new sessions use (with a switch), and Orca's own totals.
--]]

local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local api = require("orca.api.accounts")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Accounts = {}
Accounts.__index = Accounts

local TITLE = _("Account and usage")

function Accounts.new(app)
    return setmetatable({ app = app }, Accounts)
end

-- ms timestamp -> "2h 46m", "35m", "3d 4h"
function Accounts.untilText(reset_ms, now)
    local s = util.num(reset_ms) / 1000 - (now or os.time())
    if s <= 60 then return _("any moment") end
    local m = math.floor(s / 60)
    if m < 60 then return T(_("%1m"), m) end
    local h = math.floor(m / 60)
    if h < 24 then return T(_("%1h %2m"), h, m % 60) end
    return T(_("%1d %2h"), math.floor(h / 24), h % 24)
end

local function usageRow(label, window)
    if type(window) ~= "table" then return nil end
    local pct = math.floor(util.num(window.usedPercent) + 0.5)
    local detail
    if util.num(window.resetsAt) > 0 then
        detail = T(_("resets in %1"), Accounts.untilText(window.resetsAt))
    elseif util.str(window.resetDescription) ~= "" then
        detail = T(_("resets %1"), window.resetDescription)
    end
    return { title = T(_("%1: %2% used"), label, pct), detail = detail, bold = pct >= 90 }
end

function Accounts:usageRows(limits)
    local rows = {}
    if type(limits) ~= "table" then return rows end
    local session = usageRow(_("5-hour limit"), limits.session)
    local weekly = usageRow(_("Weekly limit"), limits.weekly)
    -- Some plans have a separate weekly limit for the Fable model.
    local fable = usageRow(_("Weekly Fable limit"), limits.fableWeekly)
    if session then table.insert(rows, session) end
    if weekly then table.insert(rows, weekly) end
    if fable then table.insert(rows, fable) end
    if #rows == 0 and util.str(limits.error) ~= "" then
        table.insert(rows, { glyph = style.glyph.error, title = _("Usage unavailable"),
                             subtitle = util.str(limits.error) })
    end
    return rows
end

local AUTH = { ["subscription-oauth"] = _("Subscription") }

function Accounts:switchTo(provider, id, label)
    self.app.dialog.confirm{
        title = T(_("Switch to %1?"), label),
        text = T(_("New %1 sessions will use this account. Running sessions keep theirs."),
            self.app:agentName(provider)),
        ok_text = _("Switch"),
        on_ok = function()
            self.app:request{
                once = true,
                busy = T(_("Switching to %1…"), label),
                run = function(c)
                    if provider == "codex" then return api.selectCodex(c, id) end
                    return api.selectClaude(c, id)
                end,
                done = function()
                    self.app:toast(T(_("Switched to %1"), label))
                    self:load()
                end,
            }
        end,
    }
end

function Accounts:accountRows(provider, state)
    local list = util.tbl(state.accounts)
    if #list == 0 then return nil end
    local active = util.str(state.activeAccountId)
    local rows = {}
    for _i, a in ipairs(list) do
        local id, email = util.str(a.id), util.str(a.email)
        local parts = {}
        local org = util.str(a.organizationName) ~= "" and util.str(a.organizationName) or util.str(a.workspaceLabel)
        if org ~= "" then table.insert(parts, org) end
        if AUTH[util.str(a.authMethod)] then table.insert(parts, AUTH[a.authMethod]) end
        if a.needsSignIn == true then table.insert(parts, _("needs sign-in on your PC")) end
        local is_active = id == active
        table.insert(rows, {
            glyph = is_active and style.glyph.check or " ",
            title = email ~= "" and email or id,
            subtitle = table.concat(parts, " · "),
            bold = is_active,
            detail = is_active and _("In use") or nil,
            callback = not is_active and function() self:switchTo(provider, id, email ~= "" and email or id) end or nil,
        })
    end
    local default_active = active == ""
    local default_email = util.str(state.systemDefaultEmail)
    if default_email == "" and type(state.systemDefault) == "table" then
        default_email = util.str(state.systemDefault.email)
    end
    table.insert(rows, {
        glyph = default_active and style.glyph.check or " ",
        title = _("System default"),
        subtitle = default_email ~= "" and default_email or _("The login on your PC"),
        bold = default_active,
        detail = default_active and _("In use") or nil,
        callback = not default_active and function() self:switchTo(provider, nil, _("System default")) end or nil,
    })
    return rows
end

function Accounts:statsRows(s)
    if type(s) ~= "table" then return nil end
    local hours = util.num(s.totalAgentTimeMs) / 3600000
    return {
        { title = _("Agents started"), detail = tostring(math.floor(util.num(s.totalAgentsSpawned))) },
        { title = _("Pull requests"), detail = tostring(math.floor(util.num(s.totalPRsCreated))) },
        { title = _("Agent time"), detail = T(_("%1 h"), string.format("%.1f", hours)) },
    }
end

function Accounts:screen(r)
    local limits = r.snapshot.rateLimits
    local sections = {}
    local function add(title, rows)
        if rows and #rows > 0 then table.insert(sections, { title = title, rows = rows }) end
    end
    local claude = self.app:agentName("claude")
    local codex = self.app:agentName("codex")
    local codex_accounts = self:accountRows("codex", r.snapshot.codex)

    add(codex_accounts and T(_("%1 usage"), claude) or _("Usage"), self:usageRows(limits.claude))
    add(T(_("%1 accounts"), claude), self:accountRows("claude", r.snapshot.claude))
    if codex_accounts then
        add(T(_("%1 usage"), codex), self:usageRows(limits.codex))
        add(T(_("%1 accounts"), codex), codex_accounts)
    end
    add(_("Orca"), self:statsRows(r.stats))
    return {
        title = TITLE,
        sections = sections,
        empty = _("Orca has no usage or accounts to show yet. Start a session on your PC, then refresh."),
        refresh = function() self:load() end,
    }
end

function Accounts:load()
    local page = self.page
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = TITLE, loading = _("Checking usage…") }
        self.page = page
    end
    self.app:request{
        run = function(c)
            local snapshot, err = api.list(c, true)
            if not snapshot then return nil, err end
            -- Totals are a nicety; a failure here shouldn't hide the accounts.
            return { snapshot = snapshot, stats = api.stats(c) }
        end,
        done = function(r) page:set(self:screen(r)) end,
        on_error = function(err)
            page:set{ title = TITLE, empty = self.app:explain(err), refresh = function() self:load() end }
        end,
    }
end

function Accounts:open()
    self.app.online(function()
        self.page = nil
        self:load()
    end)
end

return Accounts
