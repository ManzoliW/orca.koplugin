--[[
    The session view: one terminal on screen, kept current and driven from
    the key bar.

    Live updates subscribe to the terminal (terminal.subscribe) and refresh
    the screen once its output goes quiet; without them the screen is read
    every few seconds and after each key. Fitting asks the desktop to resize
    the terminal to the Kindle while the view is open (the subscription's
    viewport); when someone types or resizes on the desktop it takes the size
    back, and the next key from the Kindle claims it again. With history on,
    the terminal is made a few screens taller than the Kindle: the rendered
    screen is the only clean text Orca has (its stream repeats every redraw),
    so the extra rows are what you see when you swipe up.

    Errors show in the text area: a popup over a terminal you're watching
    hides the very thing you're looking at.
--]]

local UIManager = require("ui/uimanager")
local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local ansi = require("orca.render.ansi")
local common = require("orca.api.common")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Session = {}
Session.__index = Session

-- Live view: refresh once output has been quiet this long (s), but never
-- wait longer than MAX_DELAY while output keeps streaming.
local QUIET = 1.5
local MAX_DELAY = 6
local TICK = 1
local RETRY = 10          -- s between reconnect attempts while the view is open
local STATES_EVERY = 5    -- s between agent-state reads for the subtitle
local SCROLLBACK = 200    -- lines read when the desktop can't render the screen
-- After a reconnect (e.g. waking up) the desktop notices the dead socket only
-- later, and dropping its subscription gives the terminal back its desktop
-- size. Claim the Kindle's size again once that cleanup has happened.
local RECLAIM_AFTER = { 20, 45 }
local HISTORY_SCREENS = 3 -- terminal height in Kindle screens, with history on
local MAX_ROWS = 500

local KEY_BYTES = {
    ["1"] = "1", ["2"] = "2", ["3"] = "3",
    esc = "\27",
    up = "\27[A",
    down = "\27[B",
    tab = "\t",
    ["shift-tab"] = "\27[Z",
}

function Session.new(app)
    local self = setmetatable({ app = app, current = nil }, Session)
    -- A new socket has none of the old one's subscriptions.
    app.connection:onConnect("session", function(c)
        local s = self.current
        if s and s.subscribed then
            s.subscribed = false
            app.log("session: resubscribing after reconnect")
            if self:subscribe(c, s) and s.fit then
                local t = app.now()
                s.reclaim = {}
                for _i, delay in ipairs(RECLAIM_AFTER) do table.insert(s.reclaim, t + delay) end
            end
        end
    end)
    return self
end

function Session:isShowing(handle)
    return self.current ~= nil and self.current.handle == handle
end

local function workspaceName(term, wt)
    if wt and util.str(wt.path) ~= "" then return util.basename(wt.path) end
    return util.str(term.workspace)
end

function Session:subtitle(s)
    local parts = {}
    if s.workspace ~= "" then table.insert(parts, s.workspace) end
    local status = style.status[common.state(s.state).key]
    if status.glyph then table.insert(parts, status.glyph .. " " .. status.label) end
    return table.concat(parts, " · ")
end

function Session:open(term, wt)
    self:close()
    self.View = self.View or require("orca.ui.terminal")
    local settings = self.app.settings
    local handle = util.str(term.handle)
    local s = {
        term = term,
        wt = wt,
        handle = handle,
        title = util.str(term.title) ~= "" and util.str(term.title) or handle,
        workspace = workspaceName(term, wt),
        live = settings:get("live_updates"),
        fit = settings:get("fit_viewport"),
        dirty = false,
        last_refresh = 0,
        states_at = 0,
    }
    self.current = s
    s.view = self.View.new{
        title = s.title,
        subtitle = self:subtitle(s),
        font_size = settings:get("font_size"),
        status = self.app.status,
        on_status = self.app.network and function() self.app.network:open() end,
        on_key = function(id) self:key(s, id) end,
        on_refresh = function() self:refresh(s) end,
        on_close = function() self:finish(s) end,
        on_resize = function() self:reopen(s) end,
    }
    s.viewport = s.view:viewport()
    if s.fit and settings:get("session_history") then
        s.viewport.rows = math.min(s.viewport.rows * HISTORY_SCREENS, MAX_ROWS)
    end
    self.app.connection:keepAlive(self.app.jobs, "session", true)

    self.app:run{
        run = function(c)
            if (s.live or s.fit) and not s.subscribed then
                local ok, err = self:subscribe(c, s)
                if not ok then return nil, err end
            end
            return self:read(c, s)
        end,
        done = function(result, err) self:show(s, result, err) end,
    }
    self:startTicker(s)
end

-- Inside a job.
function Session:subscribe(c, s)
    local params = { terminal = s.handle, client = { id = c.client_id, type = "desktop" } }
    if s.fit then params.viewport = s.viewport end
    local id, first = self.app.connection:stream(c, "terminal.subscribe", params, function(result)
        self:onFrame(s, result)
    end)
    if not id then return nil, first end
    s.request_id = id
    s.subscribed = true
    s.fit_lost = false
    return true
end

-- Inside a job: the rendered screen, or recent output when the desktop
-- can't render one; plus agent states now and then for the subtitle.
function Session:read(c, s)
    local screen, err = c:readTerminal(s.handle, true)
    local raw = false
    if screen and util.str(screen.source) == "screen-unavailable" then
        screen, err = c:readTerminal(s.handle, false, SCROLLBACK)
        raw = true
    end
    if not screen then return nil, err end
    local result = { screen = screen, raw = raw }
    local t = self.app.now()
    if t - s.states_at >= STATES_EVERY then
        s.states_at = t
        result.states = c:agentStates()
    end
    return result
end

function Session:onFrame(s, result)
    if s ~= self.current then return end
    local kind = util.str(result.type)
    if kind == "data" or kind == "scrollback" then
        local t = self.app.now()
        if not s.dirty then s.dirty_since = t end
        s.dirty = true
        s.last_output = t
    elseif kind == "fit-override-changed" and s.viewport then
        if util.num(result.cols, -1) ~= s.viewport.cols then
            self.app.log("session: desktop took the size back:", result.cols, "cols")
            s.fit_lost = true
        end
    end
end

function Session:showError(s, message)
    local text = s.text and (s.text .. "\n\n") or ""
    s.view:setText(text .. style.glyph.error .. " " .. message)
end

function Session:show(s, result, err)
    if s ~= self.current then return end
    s.last_refresh = self.app.now()
    s.dirty = false
    if not result then
        return self:showError(s, T(_("Can't read this session. Tap ↻ to try again.\n%1"), self.app:explain(err)))
    end
    local screen = result.screen
    -- Rendered screens come clean; raw output still has escape codes.
    local strip = result.raw or util.str(screen.source) == "screen-unavailable"
    local text = ansi.formatLines(util.tbl(screen.tail), strip)
    s.text = text ~= "" and text or _("(empty screen)")
    s.view:setText(s.text)
    if type(result.states) == "table" then
        local agent = result.states[s.handle]
        s.state = type(agent) == "table" and util.str(agent.state) or nil
        s.view:setSubtitle(self:subtitle(s))
    end
end

function Session:refresh(s)
    s = s or self.current
    if not s or s ~= self.current or s.refresh_queued then return end
    s.refresh_queued = true
    self.app:run{
        run = function(c) return self:read(c, s) end,
        done = function(result, err)
            s.refresh_queued = false
            self:show(s, result, err)
        end,
    }
end

function Session:send(s, params)
    params.terminal = s.handle
    self.app:run{
        once = true,
        run = function(c)
            if s.fit and s.fit_lost and s.subscribed then
                c:claimViewport(s.handle, s.viewport)
                s.fit_lost = false
            end
            return c:call("terminal.send", params)
        end,
        done = function(result, err)
            if s ~= self.current then return end
            if not result then
                return self:showError(s, T(_("That key didn't reach the session.\n%1"), self.app:explain(err)))
            end
            if not s.live then
                -- Give the program a moment to redraw before reading the screen.
                UIManager:scheduleIn(1, function() self:refresh(s) end)
            end
        end,
    }
end

function Session:key(s, id)
    if s ~= self.current then return end
    if id == "type" then return self:type(s) end
    if id == "rotate" then return s.view:rotate() end
    if id == "ctrl-c" then return self:send(s, { interrupt = true }) end
    if id == "enter" then return self:send(s, { text = "", enter = true }) end
    local bytes = KEY_BYTES[id]
    if bytes then self:send(s, { text = bytes }) end
end

function Session:type(s)
    self.app.text.ask{
        title = T(_("Send to %1"), s.title),
        multiline = true,
        ok_text = _("Send"),
        on_ok = function(value) self:send(s, { text = value, enter = true }) end,
        extra = { { text = _("Type only"), callback = function(value)
            self:send(s, { text = value, enter = false })
        end } },
    }
end

-- Once a second while the view is open: read the socket, and refresh when
-- the screen changed (live) or the interval passed.
function Session:tick(s)
    if s ~= self.current then return end
    local app = self.app
    if app.jobs:isBusy() then return end
    local t = app.now()
    if not app.connection:isConnected() then
        -- Dropped (Wi-Fi off after sleep, desktop restarted…): a refresh
        -- reconnects, and the connect hook resubscribes. Back off meanwhile.
        if t >= (s.retry_at or 0) then
            s.retry_at = t + RETRY
            self:refresh(s)
        end
        return
    end
    app.connection:pump(app.jobs)
    if s.reclaim and s.reclaim[1] and t >= s.reclaim[1] then
        table.remove(s.reclaim, 1)
        self:reclaim(s)
        return
    end
    if s.live then
        if s.dirty and (t - (s.last_output or 0) >= QUIET or t - (s.dirty_since or t) >= MAX_DELAY) then
            self:refresh(s)
        end
    elseif t - s.last_refresh >= app.settings:get("refresh_interval") then
        self:refresh(s)
    end
end

-- Takes the terminal's size back for the Kindle and redraws.
function Session:reclaim(s)
    self.app:run{
        once = true,
        run = function(c)
            if not (s.fit and s.subscribed) then return true end
            local ok, err = c:claimViewport(s.handle, s.viewport)
            self.app.log("session: claimed the Kindle's size again:", ok and "ok" or err)
            if ok then s.fit_lost = false end
            return ok, err
        end,
        -- The program redraws at the new size; read it once that settles.
        done = function() UIManager:scheduleIn(QUIET, function() self:refresh(s) end) end,
    }
end

function Session:startTicker(s)
    self:stopTicker()
    self.ticker = function()
        if s ~= self.current then return end
        UIManager:scheduleIn(TICK, self.ticker)
        self:tick(s)
    end
    UIManager:scheduleIn(TICK, self.ticker)
end

function Session:stopTicker()
    if self.ticker then
        UIManager:unschedule(self.ticker)
        self.ticker = nil
    end
end

-- Leaves the session: ends the stream so the desktop restores the
-- terminal's own size.
function Session:finish(s)
    if not s or s ~= self.current then return end
    self.current = nil
    self:stopTicker()
    local app = self.app
    app.connection:keepAlive(app.jobs, "session", false)
    s.view:close()
    -- Without a socket the desktop already dropped the subscription.
    if s.subscribed and app.connection:isConnected() then
        -- Not background: reopening the same terminal right away must
        -- unsubscribe before the new subscription, which has the same id.
        app:run{
            once = true,
            run = function(c)
                app.connection:stopStream(c, s.request_id)
                return c:unsubscribeTerminal(s.handle, s.request_id)
            end,
        }
    end
end

-- The screen turned: a new view at the new size, subscribed with its
-- viewport (the old subscription ends first).
function Session:reopen(s)
    if s ~= self.current then return end
    self.app.log("session: screen rotated; reopening")
    self:open(s.term, s.wt)
end

function Session:close()
    self:finish(self.current)
end

return Session
