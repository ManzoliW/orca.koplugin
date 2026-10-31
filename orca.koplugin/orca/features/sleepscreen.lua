--[[
    Claude status on the sleep screen. On a Kindle the screensaver is drawn
    before plugins hear about the suspend, so there's no time to fetch then:
    instead we keep KOReader's screensaver message up to date in the
    background (Claude's session/weekly limits from Orca's accounts.list, the
    latest conversation, and which sessions need you), and KOReader draws it
    when the Kindle sleeps.

    Turning it off restores the message settings the user had before.
--]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local common = require("orca.api.common")
local util = require("orca.core.util")

local Sleep = {}
Sleep.__index = Sleep

local FIRST = 5            -- s after start before the first update
local REFRESH = 300        -- s between updates while awake
local USAGE_REFRESH = 900  -- s between asking the desktop to re-fetch usage
local NAME_CHARS = 17      -- about 31 characters fit on a line of the message box

function Sleep.new(app)
    return setmetatable({ app = app }, Sleep)
end

function Sleep:enabled()
    return self.app.settings:get("sleep_status") == true and self.app.settings:isPaired()
end

function Sleep:setEnabled(on)
    local gs = G_reader_settings
    local settings = self.app.settings
    if on and not settings:has("saved_screensaver") then
        settings:set("saved_screensaver", {
            show = gs:isTrue("screensaver_show_message"),
            message = gs:readSetting("screensaver_message"),
        })
    elseif not on then
        local saved = settings:get("saved_screensaver")
        if type(saved) == "table" then
            gs:saveSetting("screensaver_show_message", saved.show and true or false)
            gs:saveSetting("screensaver_message", saved.message)
            settings:set("saved_screensaver", nil)
        end
    end
    settings:set("sleep_status", on and true or nil)
    if on then self:start() else self:stop() end
end

local function countdown(resets_at_ms)
    local at = util.num(resets_at_ms) / 1000
    local s = at - os.time()
    if s <= 0 then return _("now") end
    if s < 3600 then return T(_("%1 min"), math.ceil(s / 60)) end
    if s < 86400 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    return os.date("%a %H:%M", math.floor(at))
end

-- Workspace name from a worktree id ("<uuid>::<path>"), falling back to the tab title.
local function workspaceName(status)
    local path = util.str(status.worktree):match("::(.+)$")
    if path then return util.basename(path) end
    return util.str(status.title) ~= "" and status.title or _("a session")
end

local STATE_LABELS = { needs = _("needs you"), working = _("working"), done = _("done") }

--[[
    Text for the sleep screen. Avoid "%" directly before a letter: KOReader
    expands %T, %p, … in screensaver messages.
--]]
function Sleep:message(usage, states, latest)
    local lines = { T(_("Claude · %1"), os.date("%H:%M")) }
    local claude = util.tbl(util.tbl(util.tbl(usage).rateLimits).claude)
    -- Literal labels: KOReader translates "Session" but not "Week", which mixed languages.
    for _i, w in ipairs({ { "session", "5h" }, { "weekly", "Week" } }) do
        local win = claude[w[1]]
        if type(win) == "table" and tonumber(win.usedPercent) then
            local line = T(_("%1: %2% used"), w[2], math.floor(tonumber(win.usedPercent) + 0.5))
            if tonumber(win.resetsAt) then line = line .. T(_(" · resets %1"), countdown(win.resetsAt)) end
            table.insert(lines, line)
        end
    end
    if util.str(claude.error) ~= "" and #lines == 1 then
        table.insert(lines, T(_("usage: %1"), claude.error))
    end
    -- The conversation that ran last, and how big it has grown.
    if type(latest) == "table" then
        table.insert(lines, T(_("%1 tokens: %2"), util.shortCount(latest.totalTokens),
            util.ellipsize(util.str(latest.title), NAME_CHARS)))
    end
    local groups = {}
    for _i, status in pairs(states or {}) do
        if type(status) == "table" then
            local key = common.state(status.state).key
            if STATE_LABELS[key] then
                local group = groups[key] or { seen = {} }
                groups[key] = group
                local name = workspaceName(status)
                if not group.seen[name] then
                    group.seen[name] = true
                    table.insert(group, name)
                end
            end
        end
    end
    for _i, key in ipairs({ "needs", "working", "done" }) do
        if groups[key] then
            table.sort(groups[key])
            table.insert(lines, STATE_LABELS[key] .. ": " .. table.concat(groups[key], ", "))
        end
    end
    return table.concat(lines, "\n")
end

function Sleep:refresh()
    local app = self.app
    if not self:enabled() or app.jobs:isBusy() or not app.isOnline() then return end
    local refresh_usage = os.time() - (self.usage_fetched_at or 0) >= USAGE_REFRESH
    app:run{
        background = true,
        run = function(c)
            local usage, err = c:call("accounts.list", { refreshUsage = refresh_usage }, refresh_usage and 60 or 20)
            if not usage then return nil, err end
            local latest = self.latest
            if (refresh_usage or not latest) and app.conversations then
                local newest = app.conversations:latest(c)
                if newest and (not latest or util.str(newest.updatedAt) > util.str(latest.updatedAt)) then
                    latest = newest
                end
            end
            return { usage = usage, states = c:agentStates() or {}, latest = latest }
        end,
        done = function(r)
            if not r then return end
            if refresh_usage then self.usage_fetched_at = os.time() end
            self.latest = r.latest
            G_reader_settings:makeTrue("screensaver_show_message")
            G_reader_settings:saveSetting("screensaver_message", self:message(r.usage, r.states, r.latest))
        end,
    }
end

function Sleep:start()
    self:stop()
    if not self:enabled() then return end
    self.refresher = function()
        UIManager:scheduleIn(REFRESH, self.refresher)
        self:refresh()
    end
    UIManager:scheduleIn(FIRST, self.refresher)
end

function Sleep:stop()
    if self.refresher then
        UIManager:unschedule(self.refresher)
        self.refresher = nil
    end
end

return Sleep
