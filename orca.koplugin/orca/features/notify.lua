--[[
    Notify: pops up over the book when an agent needs a decision or finishes,
    with the question and buttons to answer it right there.

    Events come from the desktop's notifications.subscribe stream. After every
    new socket (and on wake) it catches up with getMissedSince from a
    watermark {seq, epoch} kept in settings, and reports what happened
    meanwhile in a single popup. Desktops without the stream are polled
    (session.tabs.listAll every watch_interval seconds, backing off on errors).

    One popup at a time: later events wait in a queue (one entry per pane, the
    newest wins). Inside Orca's screens a toast replaces the popup.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local ansi = require("orca.render.ansi")
local api = require("orca.api.notifications")
local common = require("orca.api.common")
local util = require("orca.core.util")

local Notify = {}
Notify.__index = Notify

local KEY_ESC = "\27"
local BACKOFF_MAX = 600       -- s between polls after repeated failures
local RETRY_MAX = 120         -- s between connect attempts while Wi-Fi comes back
local CATCHUP_MAX_AGE = 12 * 3600 -- replayed events older than this are stale news
local SEEN_MAX = 500

function Notify.new(app)
    return setmetatable({ app = app, queue = {}, seen = {}, seen_count = 0 }, Notify)
end

function Notify:enabled()
    local s = self.app.settings
    return s:get("watch_enabled") and s:isPaired()
end

function Notify:schedule(delay, fn) self.app.connection.schedule(delay, fn) end
function Notify:unschedule(fn) if fn then self.app.connection.unschedule(fn) end end

function Notify:start()
    self:stop()
    if not self:enabled() then return end
    self.active = true
    self.app.connection:onConnect("notify", function(c) self:subscribe(c) end)
    self.app.connection:keepAlive(self.app.jobs, "notify", true)
    self:connect()
end

function Notify:stop()
    self.active = false
    self:stopPolling()
    self:unschedule(self.retry)
    self.retry = nil
    local connection = self.app.connection
    connection:onConnect("notify", nil)
    connection:keepAlive(self.app.jobs, "notify", false)
    local sub = self.sub
    self.sub = nil
    if sub then
        connection:stopStream(nil, sub.id)
        if connection:isConnected() then
            self.app:run{
                background = true,
                run = function(c)
                    c:stopStream(sub.id)
                    return api.unsubscribe(c, sub.subscriptionId)
                end,
            }
        end
    end
end

-- KOReader stops timers while asleep and the socket goes stale.
function Notify:suspend()
    self:stopPolling()
    self:unschedule(self.retry)
    self.retry = nil
    self.sub = nil
    self.app.connection:keepAlive(self.app.jobs, "notify", false)
end

-- The connection was reset on wake: reconnecting resubscribes and catches up.
function Notify:resume()
    if not self.active or not self:enabled() then return end
    self.sub = nil
    self.app.connection:keepAlive(self.app.jobs, "notify", true)
    self:connect()
end

-- Connects in the background (the onConnect hook subscribes); retries with
-- backoff while the network is still coming up.
function Notify:connect(attempt)
    attempt = attempt or 0
    self.app:run{
        background = true,
        run = function(c)
            if not self.sub and not self.poller then self:subscribe(c) end
            return c:takeEvents()
        end,
        done = function(events)
            if not self.active then return end
            if events then
                self.app.connection:dispatch(events)
                return
            end
            if self.poller then return end
            self.retry = function()
                self.retry = nil
                if self.active and not self.sub then self:connect(attempt + 1) end
            end
            self:schedule(math.min(RETRY_MAX, 5 * 2 ^ attempt), self.retry)
        end,
    }
end

-- Stream ----------------------------------------------------------------------------

-- Inside a job: opens the stream and queues the missed events behind it, so
-- they arrive through the same handler on the next dispatch.
function Notify:subscribe(c)
    if not self.active then return end
    self.sub = nil
    local id, ready = api.subscribe(self.app.connection, c, function(result, msg) self:onFrame(result, msg) end)
    if not id then
        self.app.log("notify: subscribe failed, polling instead:", ready)
        self:startPolling()
        return
    end
    self:stopPolling()
    self.sub = { id = id, subscriptionId = ready.subscriptionId, epoch = ready.epoch }
    self.app.log("notify: listening")

    local watermark = self.app.settings:get("notify_watermark")
    local missed = api.missedSince(c, watermark or { seq = 0, epoch = ready.epoch })
    if not missed then return end
    if not watermark then
        -- First run: what happened before the Kindle was watching isn't news.
        local seq = 0
        for _i, ev in ipairs(missed.notifications) do seq = math.max(seq, util.num(ev.notificationSeq)) end
        self:saveWatermark(seq, missed.epoch ~= "" and missed.epoch or ready.epoch)
        return
    end
    self.app.log("notify: catching up on", #missed.notifications, "events")
    for _i, ev in ipairs(missed.notifications) do
        c:keep{ id = id, result = ev, catchup = true }
    end
    c:keep{ id = id, result = { type = "caught-up" }, catchup = true }
end

function Notify:saveWatermark(seq, epoch)
    self.app.settings:set("notify_watermark", { seq = seq, epoch = epoch })
end

-- Records an event's sequence; false when it was already handled.
function Notify:markSeen(ev)
    local epoch = util.str(ev.notificationEpoch)
    if epoch == "" and self.sub then epoch = self.sub.epoch end
    local seq = util.num(ev.notificationSeq, -1)
    local keys = {}
    if util.str(ev.notificationId) ~= "" then table.insert(keys, "id:" .. ev.notificationId .. ":" .. tostring(ev.type)) end
    if seq >= 0 then table.insert(keys, "seq:" .. epoch .. ":" .. seq) end
    for _i, k in ipairs(keys) do
        if self.seen[k] then return false end
    end
    if self.seen_count > SEEN_MAX then self.seen, self.seen_count = {}, 0 end
    for _i, k in ipairs(keys) do self.seen[k] = true; self.seen_count = self.seen_count + 1 end
    if seq >= 0 then
        local wm = self.app.settings:get("notify_watermark") or {}
        if util.str(wm.epoch) ~= epoch or seq > util.num(wm.seq) then self:saveWatermark(seq, epoch) end
    end
    return true
end

function Notify:itemFor(ev)
    local kind = api.kind(ev)
    if not kind then return nil end
    return {
        kind = kind,
        id = util.str(ev.notificationId),
        worktreeId = util.str(ev.worktreeId),
        paneKey = util.str(ev.paneKey),
        title = util.str(ev.title),
        body = util.str(ev.body),
        at = util.num(ev.emittedAt),
        more = 0,
    }
end

function Notify:onFrame(ev, msg)
    if not self.active or type(ev) ~= "table" then return end
    if ev.type == "end" then
        -- The desktop dropped the subscription while the socket stayed up.
        self.app.log("notify: desktop ended the stream; resubscribing")
        self.sub = nil
        if self.app.connection:isConnected() then self:connect() end
        return
    end
    if msg and msg.catchup then return self:onCatchup(ev) end
    if ev.type == "dismiss" then
        if self:markSeen(ev) then self:dismiss(util.str(ev.notificationId)) end
        return
    end
    if ev.type ~= "notification" or not self:markSeen(ev) then return end
    local item = self:itemFor(ev)
    if item then
        self:enqueue(item)
        self:showNext()
    end
end

-- Missed events arrive one by one, then "caught-up": collapse them into one popup.
function Notify:onCatchup(ev)
    self.batch = self.batch or {}
    if ev.type ~= "caught-up" then
        if (ev.type == "notification" or ev.type == "dismiss") and self:markSeen(ev) then
            table.insert(self.batch, ev)
        end
        return
    end
    local batch = self.batch
    self.batch = nil
    local now_ms = os.time() * 1000
    local latest, order = {}, {}
    for _i, e in ipairs(batch) do
        if e.type == "dismiss" then
            for key, item in pairs(latest) do
                if item.id ~= "" and item.id == util.str(e.notificationId) then latest[key] = nil end
            end
        else
            local item = self:itemFor(e)
            local stale = item and item.at > 0 and now_ms - item.at > CATCHUP_MAX_AGE * 1000
            if item and not stale then
                local key = item.paneKey ~= "" and item.paneKey or (item.worktreeId ~= "" and item.worktreeId) or item.id
                if not latest[key] then table.insert(order, key) end
                latest[key] = item
            end
        end
    end
    local pick, count = nil, 0
    for _i, key in ipairs(order) do
        local item = latest[key]
        if item then
            count = count + 1
            -- Most urgent first, then the most recent.
            if not pick or (item.kind == "needs" and pick.kind ~= "needs")
                    or (item.kind == pick.kind) then
                pick = item
            end
        end
    end
    if not pick then return end
    pick.more = count - 1
    self:enqueue(pick)
    self:showNext()
end

-- Queue and popup ---------------------------------------------------------------------

local function sameTarget(a, b)
    if a.handle and b.handle then return a.handle == b.handle end
    if a.paneKey ~= "" or b.paneKey ~= "" then return a.paneKey == b.paneKey end
    return a.worktreeId ~= "" and a.worktreeId == b.worktreeId
end

function Notify:enqueue(item)
    for i = #self.queue, 1, -1 do
        if sameTarget(self.queue[i], item) then
            item.more = math.max(item.more, self.queue[i].more)
            table.remove(self.queue, i)
        end
    end
    table.insert(self.queue, item)
end

function Notify:dismiss(id)
    if id == "" then return end
    for i = #self.queue, 1, -1 do
        if self.queue[i].id == id then table.remove(self.queue, i) end
    end
    if self.card and self.card_item and self.card_item.id == id then
        self.app.dialog.close(self.card)
        self.card, self.card_item = nil, nil
        self:showNext()
    end
end

function Notify:isShowing()
    if self.card and self.app.dialog.isShown(self.card) then return true end
    self.card, self.card_item = nil, nil
    return false
end

-- Needs-you first, otherwise the oldest.
function Notify:takeNext()
    for i, item in ipairs(self.queue) do
        if item.kind == "needs" then return table.remove(self.queue, i) end
    end
    return table.remove(self.queue, 1)
end

local function workspaceName(item, term)
    local path = item.worktreeId:match("::(.+)$")
    if path then return util.basename(path) end
    if term and util.str(term.worktreePath) ~= "" then return util.basename(term.worktreePath) end
    return item.worktreeId ~= "" and util.basename(item.worktreeId) or _("a session")
end

function Notify:headline(item, term)
    if item.kind == "info" then
        return item.title ~= "" and item.title or _("Orca")
    end
    local agent = self.app:agentName(term and util.str(term.agentIdentity) ~= "" and term.agentIdentity or nil)
    local where = workspaceName(item, term)
    if item.kind == "needs" then return T(_("%1 needs you in %2"), agent, where) end
    return T(_("%1 finished in %2"), agent, where)
end

function Notify:moreText(item)
    local n = item.more + #self.queue
    return n > 0 and T(_("(+%1 more)"), n) or nil
end

function Notify:showNext()
    if not self.active or self.preparing or self:isShowing() then return end
    local item = self:takeNext()
    if not item then return end

    if self.app.nav:isOpen() then
        -- Already in Orca: the screens show states; a toast is enough.
        local text = self:headline(item)
        local more = self:moreText(item)
        self.queue = {}
        self.app:toast(more and (text .. " " .. more) or text)
        return
    end

    self.preparing = true
    self.app:run{
        background = true,
        run = function(c)
            local term = item.handle and { handle = item.handle, title = item.term_title,
                                           agentIdentity = item.agent } or nil
            if not term and item.kind ~= "info" then
                term = api.terminalFor(c, item.worktreeId, item.paneKey, item.kind == "needs" and "needs" or nil)
            end
            local excerpt
            if term and item.kind == "needs" then
                local screen = c:readTerminal(term.handle, true)
                excerpt = screen and ansi.promptExcerpt(screen.tail) or nil
            end
            return { term = term, excerpt = excerpt }
        end,
        done = function(r)
            self.preparing = false
            r = r or {}
            local session = self.app.session
            if r.term and session and session.isShowing and session:isShowing(r.term.handle) then
                return self:showNext()
            end
            if self.app.nav:isOpen() then
                table.insert(self.queue, 1, item)
                return self:showNext()
            end
            self:popup(item, r.term, r.excerpt)
        end,
    }
end

function Notify:closed()
    self.card, self.card_item = nil, nil
    self:showNext()
end

function Notify:answerButton(term, key, label)
    local shown = label and (key .. " " .. util.ellipsize(label, 12)) or key
    return {
        text = shown,
        mono = label == nil,
        callback = function()
            self.card, self.card_item = nil, nil
            self.app:request{
                once = true,
                run = function(c) return c:sendText(term.handle, key == "Esc" and KEY_ESC or key, false) end,
                done = function()
                    self.app:toast(T(_("Sent %1"), shown))
                    self:showNext()
                end,
                on_error = function(err)
                    self.app:fail(err)
                    self:showNext()
                end,
            }
        end,
    }
end

function Notify:popup(item, term, excerpt)
    local lines = {}
    local headline = self:headline(item, term)
    if item.body ~= "" and item.body ~= headline and item.body ~= item.title then
        table.insert(lines, util.ellipsize(util.collapse(item.body), 240))
    end
    local more = self:moreText(item)
    if more then table.insert(lines, more) end
    local buttons = {}

    if item.kind == "info" then
        buttons = { { { text = _("Close"), callback = function() self:closed() end } } }
    else
        if item.kind == "needs" and term then
            local row = {}
            for _i, choice in ipairs(ansi.choices(excerpt)) do
                if #row == 3 then break end
                table.insert(row, self:answerButton(term, choice.key, choice.label))
            end
            if #row == 0 then
                for _i, key in ipairs({ "1", "2", "3" }) do table.insert(row, self:answerButton(term, key)) end
            end
            table.insert(row, self:answerButton(term, "Esc"))
            table.insert(buttons, row)
        end
        local wt = {
            worktreeId = item.worktreeId,
            path = term and util.str(term.worktreePath) ~= "" and term.worktreePath
                or item.worktreeId:match("::(.+)$") or item.worktreeId,
            branch = term and util.str(term.branch) or nil,
        }
        table.insert(buttons, {
            { text = _("Later"), callback = function() self:closed() end },
            { text = _("Open"), primary = true, callback = function()
                self.card, self.card_item = nil, nil
                if term and self.app.session then
                    self.app.session:open({ handle = term.handle, title = util.str(term.title) }, wt)
                elseif item.worktreeId ~= "" then
                    self.app.workspace:open(wt)
                end
                self:showNext()
            end },
        })
    end

    self.card_item = item
    self.card = self.app.dialog.card{
        title = headline,
        text = table.concat(lines, "\n"),
        mono = excerpt,
        buttons = buttons,
        on_dismiss = function() self:closed() end,
    }
end

-- Polling fallback ---------------------------------------------------------------------

function Notify:startPolling()
    if self.poller or not self.active then return end
    self.poll_failures = 0
    self.poll_states = nil
    self.poller = function()
        if not self.active or self.sub then self.poller = nil; return end
        local delay = util.num(self.app.settings:get("watch_interval"), 30)
        if self.poll_failures > 0 then
            delay = math.min(BACKOFF_MAX, delay * 2 ^ self.poll_failures)
        end
        self:schedule(delay, self.poller)
        if self.app.nav:isOpen() or self.app.jobs:isBusy() or self:isShowing() then return end
        self.app:run{
            background = true,
            run = function(c) return c:agentStates() end,
            done = function(states)
                if not states then
                    self.poll_failures = self.poll_failures + 1
                    return
                end
                self.poll_failures = 0
                self:checkStates(states)
            end,
        }
    end
    self:schedule(util.num(self.app.settings:get("watch_interval"), 30), self.poller)
end

function Notify:stopPolling()
    self:unschedule(self.poller)
    self.poller = nil
end

-- Compares with the previous poll; the first one only takes a snapshot.
function Notify:checkStates(states)
    local previous = self.poll_states
    local current = {}
    for handle, status in pairs(states) do
        local state = util.str(status.state)
        current[handle] = state
        local before = previous and previous[handle]
        local key = common.state(state).key
        -- idle→done flips happen on reconnects and are not news.
        if previous and before ~= state
                and (key == "needs" or (key == "done" and before == "working")) then
            self:enqueue{
                kind = key, id = "", handle = handle, term_title = util.str(status.title),
                agent = util.str(status.agentType) ~= "" and status.agentType or nil,
                worktreeId = util.str(status.worktree), paneKey = "", title = "", body = "", at = 0, more = 0,
            }
        end
    end
    self.poll_states = current
    self:showNext()
end

return Notify
