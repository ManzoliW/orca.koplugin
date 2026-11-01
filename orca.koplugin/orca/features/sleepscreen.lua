--[[
    Claude status on the sleep screen. On a Kindle the screensaver is drawn
    before plugins hear about the suspend, so there's no time to fetch then:
    instead we keep it up to date in the background (Claude's session/weekly
    limits from Orca's accounts.list, the latest conversation, and which
    sessions need you), and KOReader draws it when the Kindle sleeps.

    It is drawn as a picture: Home's cards (usage, sessions, the book you're
    reading, the reading and GitHub heatmaps) in a PNG the size of the
    screen, in a folder of its own that KOReader's "random image" sleep
    screen picks from. KOReader's sleep message is kept up to date too, and
    is what shows if the picture can't be drawn.

    Turning it off restores the sleep screen settings the user had before.
--]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local common = require("orca.api.common")
local lfs = require("libs/libkoreader-lfs")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Sleep = {}
Sleep.__index = Sleep

local FIRST = 5            -- s after start before the first update
local REFRESH = 300        -- s between updates while awake
local USAGE_REFRESH = 900  -- s between asking the desktop to re-fetch usage
local NAME_CHARS = 17      -- about 31 characters fit on a line of the message box
local IMAGE = "orca.png"
local SESSION_ROWS = 2     -- sessions on the picture; more would push the book off it

-- The user's sleep screen settings that turning this on changes.
local function current()
    local gs = G_reader_settings
    return {
        show = gs:isTrue("screensaver_show_message"),
        message = gs:readSetting("screensaver_message"),
        type = gs:readSetting("screensaver_type"),
        dir = gs:readSetting("screensaver_dir"),
        image = true,
    }
end

local function put(key, value)
    if value == nil then G_reader_settings:delSetting(key) else G_reader_settings:saveSetting(key, value) end
end

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
        settings:set("saved_screensaver", current())
    elseif not on then
        local saved = settings:get("saved_screensaver")
        if type(saved) == "table" then
            gs:saveSetting("screensaver_show_message", saved.show and true or false)
            gs:saveSetting("screensaver_message", saved.message)
            -- Saved before pictures existed: type and folder were never changed.
            if saved.image then
                put("screensaver_type", saved.type)
                put("screensaver_dir", saved.dir)
            end
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

function Sleep:imagePath()
    local dir = self.app.sleep_dir
    return dir and (dir .. "/" .. IMAGE) or nil
end

-- The workspaces with an agent at work, most urgent first: { row, ... }
function Sleep:sessionRows(states)
    local rows, seen = {}, {}
    for _i, key in ipairs({ "needs", "working", "done" }) do
        local names = {}
        for _j, status in pairs(states or {}) do
            if type(status) == "table" and common.state(status.state).key == key then
                local name = workspaceName(status)
                if not seen[name] then
                    seen[name] = true
                    table.insert(names, name)
                end
            end
        end
        table.sort(names)
        local st = style.status[key]
        for _j, name in ipairs(names) do
            table.insert(rows, { glyph = st.glyph, title = name, detail = st.label, bold = st.bold })
        end
    end
    while #rows > SESSION_ROWS do table.remove(rows) end
    return rows
end

-- What the picture shows, as a screen spec (see ui/poster.lua). Sections
-- that don't fit are left out, so the order is the priority.
function Sleep:posterSpec(r)
    local app, home = self.app, self.app.home
    local sections = {}
    local gauges = home and home:gaugesCard(r.usage)
    if gauges then
        gauges.callback = nil
        table.insert(sections, { title = _("Claude usage"), card = gauges })
    end
    table.insert(sections, { title = _("Sessions"), rows = self:sessionRows(r.states) })
    local kindle = home and home:loadKindle()
    if kindle then
        if kindle.books[1] then
            table.insert(sections, { title = _("Continue reading"), card = home:bookCard(kindle.books[1], kindle.days) })
        end
        local reading = home:readingCard(kindle.days)
        if reading then table.insert(sections, { title = _("Reading"), card = reading }) end
    end
    local calendar = app.github and app.github:sections().calendar
    if calendar then table.insert(sections, calendar) end
    return {
        title = _("Orca"),
        subtitle = T(_("As of %1"), os.date("%a %d %b · %H:%M")),
        sections = sections,
    }
end

-- Draws the picture and points the sleep screen at it; false if it couldn't.
function Sleep:drawImage(r)
    local path = self:imagePath()
    if not path or not self.app.poster then return false end
    pcall(lfs.mkdir, self.app.sleep_dir)
    local ok, err = self.app.poster(self:posterSpec(r), path)
    if not ok then
        self.app.log("sleep picture:", err)
        return false
    end
    local gs = G_reader_settings
    gs:saveSetting("screensaver_type", "random_image")
    gs:saveSetting("screensaver_dir", self.app.sleep_dir)
    gs:makeFalse("screensaver_show_message")
    return true
end

-- Back to the text message, on the user's own sleep screen.
function Sleep:useMessage()
    local gs = G_reader_settings
    local saved = self.app.settings:get("saved_screensaver")
    if type(saved) == "table" and saved.image and gs:readSetting("screensaver_dir") == self.app.sleep_dir then
        put("screensaver_type", saved.type)
        put("screensaver_dir", saved.dir)
    end
    gs:makeTrue("screensaver_show_message")
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
            G_reader_settings:saveSetting("screensaver_message", self:message(r.usage, r.states, r.latest))
            if not self:drawImage(r) then self:useMessage() end
        end,
    }
end

function Sleep:start()
    self:stop()
    if not self:enabled() then return end
    -- Turned on before pictures existed: remember the type and folder too.
    local saved = self.app.settings:get("saved_screensaver")
    if type(saved) == "table" and not saved.image then
        local now = current()
        now.show, now.message = saved.show, saved.message
        self.app.settings:set("saved_screensaver", now)
    end
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
