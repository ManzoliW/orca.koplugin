--[[
    Claude status on the sleep screen. On a Kindle the screensaver is drawn
    before plugins hear about the suspend, so there's no time to fetch then:
    instead we keep KOReader's screensaver message up to date in the
    background (Claude's session/weekly limits from Orca's accounts.list, and
    which sessions need you), and KOReader draws it when the Kindle sleeps.

    Turning it off restores the message settings the user had before.
--]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local REFRESH = 300 -- s between updates while awake
local USAGE_REFRESH = 900 -- s between asking the desktop to re-fetch usage

return function(Orca, h)
    function Orca:sleepStatusEnabled()
        return self.settings:isTrue("sleep_status") and self.settings:has("pairing_url")
    end

    function Orca:setSleepStatus(on)
        local gs = G_reader_settings
        if on and not self.settings:has("saved_screensaver") then
            self.settings:saveSetting("saved_screensaver", {
                show = gs:isTrue("screensaver_show_message"),
                message = gs:readSetting("screensaver_message"),
            })
        elseif not on then
            local saved = self.settings:readSetting("saved_screensaver")
            if saved then
                gs:saveSetting("screensaver_show_message", saved.show and true or false)
                gs:saveSetting("screensaver_message", saved.message)
                self.settings:delSetting("saved_screensaver")
            end
        end
        self.settings:saveSetting("sleep_status", on and true or nil)
        self.settings:flush()
        if on then self:startSleepStatus() else self:stopSleepStatus() end
    end

    local function countdown(resets_at_ms)
        local s = (tonumber(resets_at_ms) or 0) / 1000 - os.time()
        if s <= 0 then return _("now") end
        if s < 3600 then return T(_("%1 min"), math.ceil(s / 60)) end
        if s < 86400 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
        return os.date("%a %H:%M", math.floor(resets_at_ms / 1000))
    end

    -- Text for the sleep screen. Avoid "%" directly before a letter: KOReader
    -- expands %T, %p, … in screensaver messages.
    function Orca:sleepMessage(usage, states, latest)
        local lines = { T(_("Claude · %1"), os.date("%H:%M")) }
        local claude = type(usage) == "table" and type(usage.rateLimits) == "table" and usage.rateLimits.claude
        if type(claude) == "table" then
            -- Not gettext: KOReader translates "Session" but not "Week", which mixed languages.
            for _i, w in ipairs({ { "session", "5h" }, { "weekly", "Week" } }) do
                local win = claude[w[1]]
                if type(win) == "table" and win.usedPercent then
                    local line = T(_("%1: %2% used"), w[2], math.floor(tonumber(win.usedPercent) + 0.5))
                    if win.resetsAt then line = line .. T(_(" · resets %1"), countdown(win.resetsAt)) end
                    lines[#lines + 1] = line
                end
            end
            if type(claude.error) == "string" and #lines == 1 then lines[#lines + 1] = T(_("usage: %1"), tostring(claude.error)) end
        end
        -- The conversation that ran last, and how big it has grown.
        if type(latest) == "table" then
            local name = h.str(latest.title)
            -- About 31 characters fit on a line of the sleep message box.
            if #name > 17 then name = name:sub(1, 16):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…" end
            lines[#lines + 1] = T(_("%1 tokens: %2"), self.shortCount(latest.totalTokens), name)
        end
        local groups = {}
        for _i, status in pairs(states or {}) do
            local label = h.stateInfo(status.state).label
            if label ~= "" then
                groups[label] = groups[label] or {}
                local name = h.workspaceName(status)
                if not groups[label][name] then
                    groups[label][name] = true
                    table.insert(groups[label], name)
                end
            end
        end
        for _i, label in ipairs({ _("needs you"), _("working"), _("done") }) do
            if groups[label] then
                table.sort(groups[label])
                lines[#lines + 1] = label .. ": " .. table.concat(groups[label], ", ")
            end
        end
        return table.concat(lines, "\n")
    end

    function Orca:refreshSleepStatus()
        if not self:sleepStatusEnabled() or self:isBusy() or not NetworkMgr:isConnected() then return end
        local refresh_usage = os.time() - (self.usage_fetched_at or 0) >= USAGE_REFRESH
        self:queue{
            run = function(c)
                local usage, err = c:call("accounts.list", { refreshUsage = refresh_usage }, refresh_usage and 60 or 20)
                if not usage then return nil, err end
                local latest = self.latest_conversation
                if refresh_usage or not latest then
                    local vault = c:call("aiVault.listSessions", { limit = 5 }, 60)
                    local sessions = type(vault) == "table" and type(vault.sessions) == "table" and vault.sessions
                    for _i, s in ipairs(sessions or {}) do
                        if not latest or h.str(s.updatedAt) > h.str(latest.updatedAt) then latest = s end
                    end
                end
                return { usage = usage, states = c:agentStates() or {}, latest = latest }
            end,
            done = function(r)
                if not r then return end
                if refresh_usage then self.usage_fetched_at = os.time() end
                self.latest_conversation = r.latest
                local message = self:sleepMessage(r.usage, r.states, r.latest)
                G_reader_settings:makeTrue("screensaver_show_message")
                G_reader_settings:saveSetting("screensaver_message", message)
            end,
        }
    end

    function Orca:startSleepStatus()
        self:stopSleepStatus()
        if not self:sleepStatusEnabled() then return end
        self.sleep_refresher = function()
            UIManager:scheduleIn(REFRESH, self.sleep_refresher)
            self:refreshSleepStatus()
        end
        UIManager:scheduleIn(5, self.sleep_refresher)
    end

    function Orca:stopSleepStatus()
        if self.sleep_refresher then
            UIManager:unschedule(self.sleep_refresher)
            self.sleep_refresher = nil
        end
    end
end
