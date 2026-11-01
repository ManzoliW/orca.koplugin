--[[
    PC test harness: builds the real app (features, jobs, settings) against a
    fake Orca and fake UI, so screens can be driven and checked in plain luajit.

        local H = require("tests.harness")
        local app, t = H.app()            -- t: tester helpers
        app.home:open()
        t.tap("kindle")                    -- tap the row titled "kindle" on the top screen
        t.expect(t.top().title == "kindle")

    Fakes:
      nav     records the screen stack (specs); t.tap / t.back / t.rows / t.top
      dialog  records cards; t.press("Merge") presses a button on the last card
      text    records ask/read/book; t.answer("text") submits the last ask
      client  canned results per RPC method (H.results); calls in t.calls
    Jobs and timers run synchronously via t.flush().
--]]

package.path = "orca.koplugin/?.lua;tests/?.lua;" .. package.path

local H = {}

local timers = {}
local function template(fmt, ...)
    local args = { ... }
    return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local stubs = {
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = template },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end,
                   err = function(...) print("logger.err", ...) end },
    ["ui/uimanager"] = {
        scheduleIn = function(_, d, fn) table.insert(timers, { delay = d, fn = fn }) end,
        unschedule = function(_, fn)
            for i = #timers, 1, -1 do if timers[i].fn == fn then table.remove(timers, i) end end
        end,
        setDirty = function() end, show = function() end, close = function() end,
        isWidgetShown = function() return true end,
    },
    ["ui/network/manager"] = { runWhenOnline = function(_, f) f() end, isConnected = function() return true end },
    ["ui/time"] = { now = function() return os.time() end, to_s = function(t) return t end },
    ["libs/libkoreader-lfs"] = { mkdir = function() end, attributes = function() return nil end },
    ["util"] = { cleanupSelectedText = function(s) return s end },
    -- ui/style.lua's tokens (features read its glyphs and status words).
    ["ffi/blitbuffer"] = { gray = function(v) return { gray = v } end, COLOR_BLACK = "black", COLOR_WHITE = "white" },
    ["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end },
    ["rapidjson"] = { null = {} }, ["socket"] = { gettime = os.time },
    ["orcaclient.nacl"] = { load = function() end },
    ["orcaclient.websocket"] = {},
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } },
}
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end

-- Global KOReader settings (sleep screen message lives there).
local function store(initial)
    local data = initial or {}
    return {
        data = data,
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        delSetting = function(_, k) data[k] = nil end,
        has = function(_, k) return data[k] ~= nil end,
        isTrue = function(_, k) return data[k] == true end,
        nilOrTrue = function(_, k) return data[k] == nil or data[k] == true end,
        makeTrue = function(_, k) data[k] = true end,
        flush = function() end,
    }
end
H.store = store
G_reader_settings = store{ screensaver_message = "Sleeping" }

-- Canned RPC results; tests may override entries (function(params) or table).
H.WT = { worktreeId = "repo1::C:/p/kindle", path = "C:\\p\\kindle", branch = "refs/heads/main",
         status = "permission", liveTerminalCount = 2 }
H.WT2 = { worktreeId = "repo1::C:/p/faxa", path = "C:\\p\\faxa", branch = "refs/heads/fix", status = "working",
          liveTerminalCount = 1 }
H.results = {}
function H.reset()
    H.results = {
        ["worktree.ps"] = { worktrees = { H.WT, H.WT2 } },
        ["terminal.list"] = { terminals = { { handle = "t1", title = "Claude" }, { handle = "t2", title = "zsh" } } },
        ["session.tabs.listAll"] = { snapshots = { { worktree = H.WT.worktreeId, tabs = {
            { terminal = "t1", title = "Claude", agentStatus = { state = "permission" } } } } } },
        ["terminal.read"] = { terminal = { tail = { "Do you want to proceed?", "1. Yes", "2. No" } } },
        ["terminal.send"] = { ok = true },
    }
end
H.reset()

-- Fake client: the subset of orcaclient.client the features use.
local function fakeClient(t)
    local c = { connected = true, streams = {}, events = {}, next_id = 0 }
    function c:isConnected() return self.connected end
    function c:connect() self.connected = true; return true end
    function c:close() self.connected = false end
    function c:call(method, params)
        table.insert(t.calls, { method = method, params = params })
        local r = H.results[method]
        if type(r) == "function" then return r(params) end
        if r == nil then return nil, "unexpected method " .. method end
        if r == false then return nil, "failed: " .. method end
        return r
    end
    function c:startStream(method, params)
        local r, err = self:call(method, params)
        if not r then return nil, err end
        self.next_id = self.next_id + 1
        local id = "s" .. self.next_id
        self.streams[id] = true
        return id, r
    end
    function c:stopStream(id) self.streams[id] = nil end
    function c:pump() end
    function c:takeEvents() local e = self.events; self.events = {}; return e end
    -- The real client's convenience wrappers (listWorktrees, agentStates, …).
    local Client = require("orcaclient.client")
    for k, v in pairs(Client) do
        if type(v) == "function" and c[k] == nil then c[k] = v end
    end
    c.client_id = "kindle-test"
    return c
end

function H.app(opts)
    opts = opts or {}
    H.reset()
    for k, v in pairs(opts.results or {}) do H.results[k] = v end
    local t = { calls = {}, cards = {}, asks = {}, reads = {}, books = {}, toasts = {} }

    local Settings = require("orca.core.settings")
    local Jobs = require("orca.core.jobs")
    local Connection = require("orca.core.connection")
    local App = require("orca.app")

    local settings = Settings.new(store(opts.settings or { pairing_url = "orca://pair?code=x" }))
    local client = fakeClient(t)
    t.client = client
    local connection = Connection.new{
        settings = settings,
        Client = { parsePairingUrl = function() return {} end, new = function() return client end },
        schedule = function(d, fn) table.insert(timers, { delay = d, fn = fn }) end,
        unschedule = function(fn) stubs["ui/uimanager"]:unschedule(fn) end,
    }
    local jobs = Jobs.new{
        connection = connection,
        schedule = function(d, fn) table.insert(timers, { delay = d, fn = fn }) end,
        busy = function() return function() end end,
        log = function(...) print("job log:", ...) end,
    }

    -- Fake navigation.
    local stack = {}
    local nav = {}
    local Page = {}
    Page.__index = Page
    function Page:isShown() for _, s in ipairs(stack) do if s == self.spec then return true end end return false end
    function Page:set(spec)
        for i, s in ipairs(stack) do
            if s == self.spec then
                spec.on_close = spec.on_close or s.on_close
                stack[i] = spec; self.spec = spec; return
            end
        end
    end
    function nav:push(spec) table.insert(stack, spec); return setmetatable({ spec = spec }, Page) end
    function nav:replace(spec)
        if #stack == 0 then return nav:push(spec) end
        local p = setmetatable({ spec = stack[#stack] }, Page); p:set(spec); return p
    end
    function nav:pop()
        local s = table.remove(stack)
        if s and s.on_close then s.on_close() end
    end
    function nav:close() while #stack > 0 do nav:pop() end end
    function nav:isOpen() return #stack > 0 end
    function nav:top() return stack[#stack] end
    t.stack = stack

    -- Fake dialogs.
    local dialog = {}
    local function card(kind, o)
        o.kind = kind; o.closed = false
        table.insert(t.cards, o)
        return o
    end
    function dialog.card(o) return card("card", o) end
    function dialog.confirm(o) return card("confirm", o) end
    function dialog.sheet(o) return card("sheet", o) end
    function dialog.alert(o) return card("alert", o) end
    function dialog.toast(text) table.insert(t.toasts, text); return card("toast", { text = text }) end
    function dialog.close(o) if o then o.closed = true end end
    function dialog.isShown(o) return o ~= nil and not o.closed end

    local text = {}
    function text.ask(o) table.insert(t.asks, o); return o end
    function text.read(o) table.insert(t.reads, o); return o end
    function text.book(dir, name, body) table.insert(t.books, { dir = dir, name = name, body = body }); return true end

    local app = App.new{
        settings = settings, connection = connection, jobs = jobs, nav = nav,
        dialog = dialog, text = text,
        online = function(fn) fn() end,
        isOnline = function() return true end,
        now = function() return os.time() end,
        log = function() end,
        docs_dir = "/tmp/docs",
        library = opts.library,
        web = opts.web,
    }
    for _, name in ipairs(opts.features or {
        "home", "workspace", "session", "create", "git", "files", "conversations",
        "notify", "accounts", "automations", "sleep", "passage", "github" }) do
        local module = name == "sleep" and "orca.features.sleepscreen" or ("orca.features." .. name)
        local ok, mod = pcall(require, module)
        if ok then
            app[name] = mod.new(app)
        elseif not opts.quiet then
            print("(feature " .. name .. " not loaded: " .. tostring(mod):match("^[^\n]*") .. ")")
        end
    end

    -- Tester helpers -------------------------------------------------------------
    function t.flush(max)
        for _ = 1, max or 50 do
            if #timers == 0 then return end
            local batch = timers
            timers = {}
            for _, tm in ipairs(batch) do tm.fn() end
        end
    end
    -- Only fires timers with delay <= d (jobs step at 0.1 s).
    function t.settle()
        for _ = 1, 200 do
            local ran = false
            for i, tm in ipairs(timers) do
                if tm.delay <= 0.5 then table.remove(timers, i); tm.fn(); ran = true; break end
            end
            if not ran then return end
        end
    end
    t.timers = function() return timers end
    function t.top() return stack[#stack] end
    function t.rows(spec)
        spec = spec or t.top()
        local rows = {}
        for _, s in ipairs(spec.sections or { { rows = spec.rows or {} } }) do
            for _, r in ipairs(s.rows or {}) do table.insert(rows, r) end
        end
        return rows
    end
    function t.row(pattern, spec)
        for _, r in ipairs(t.rows(spec)) do
            if (r.title or ""):find(pattern, 1, true) then return r end
        end
        local titles = {}
        for _, r in ipairs(t.rows(spec)) do table.insert(titles, r.title) end
        error("no row '" .. pattern .. "' in [" .. table.concat(titles, " | ") .. "]", 2)
    end
    function t.tap(pattern) t.row(pattern).callback(); t.settle() end
    function t.back() nav:pop() end
    function t.lastCard() return t.cards[#t.cards] end
    -- Presses the button labelled `label` on the last card (any row; sheets: actions).
    function t.press(label, c)
        c = c or t.lastCard()
        assert(c, "no card shown")
        c.closed = true
        local function try(b)
            if b.text == label or b.text and b.text:find(label, 1, true) == 1 then
                if b.callback then b.callback() end
                return true
            end
        end
        if c.kind == "confirm" then
            if label == (c.cancel_text or "Cancel") then if c.on_cancel then c.on_cancel() end t.settle() return end
            if c.ok_text == label then c.on_ok(); t.settle(); return end
        end
        for _, a in ipairs(c.actions or {}) do if try(a) then t.settle() return end end
        for _, row in ipairs(c.buttons or {}) do
            for _, b in ipairs(row) do if try(b) then t.settle() return end end
        end
        if label == "Retry" and c.retry then c.retry(); t.settle(); return end
        error("no button '" .. label .. "' on " .. c.kind .. " card '" .. tostring(c.title or c.text) .. "'", 2)
    end
    function t.answer(value, ask)
        ask = ask or t.asks[#t.asks]
        assert(ask, "no input dialog shown")
        ask.on_ok(value)
        t.settle()
    end
    function t.called(method)
        local found = {}
        for _, c in ipairs(t.calls) do if c.method == method then table.insert(found, c) end end
        return found
    end
    function t.lastCall(method)
        local found = t.called(method)
        return found[#found]
    end
    return app, t
end

-- Tiny test runner -------------------------------------------------------------------
H.failures = 0
H.passed = 0
function H.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        H.passed = H.passed + 1
        print("  ok   " .. name)
    else
        H.failures = H.failures + 1
        print("  FAIL " .. name .. "\n" .. tostring(err))
    end
end

function H.eq(a, b, what)
    if a ~= b then error((what or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

function H.has(s, needle, what)
    if not tostring(s):find(needle, 1, true) then
        error((what or "text") .. ": expected to contain '" .. needle .. "' in:\n" .. tostring(s), 2)
    end
end

return H
