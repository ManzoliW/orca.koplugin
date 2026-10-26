--[[
    Orca for KOReader: browse Orca desktop workspaces and drive their terminal
    sessions (e.g. Claude Code) from an e-ink screen.

    Speaks Orca's mobile runtime protocol directly (legacy E2EE framing, see
    orcaclient/client.lua), reaching the desktop over Tailscale's SOCKS5 proxy.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local RenderText = require("ui/rendertext")
local Screen = require("device").screen
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Loaded while the plugin directory is on package.path (only true at load time).
local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")

local PAIRING_FILE = "/mnt/us/orca-pairing.txt"
local PROXY = { host = "127.0.0.1", port = 1055 }

-- Raw bytes for the special-key buttons.
local KEY_ESC = "\27"
local KEY_UP = "\27[A"
local KEY_DOWN = "\27[B"
local KEY_TAB = "\t"
local KEY_SHIFT_TAB = "\27[Z"

-- Live view: refresh once output has been quiet this long (s), but never
-- wait longer than LIVE_MAX_DELAY while output keeps streaming.
local LIVE_QUIET = 1.5
local LIVE_MAX_DELAY = 6
local TICK = 1

-- Watch mode: while you read, poll workspace states this often (s) and pop up
-- when a session starts needing you or finishes. Backs off after failures.
local WATCH_BACKOFF_MAX = 300

-- Bracketed paste, so a multi-line message reaches the agent as one input.
local PASTE_START, PASTE_END = "\27[200~", "\27[201~"

-- Agent / workspace states, most urgent first.
local STATE_LABELS = {
    permission = { rank = 1, label = _("needs you") },
    blocked = { rank = 1, label = _("needs you") },
    waiting = { rank = 1, label = _("needs you") },
    working = { rank = 2, label = _("working") },
    done = { rank = 3, label = _("done") },
}

local Orca = WidgetContainer:extend{
    name = "orca",
    is_doc_only = false,
}

local function str(v)
    return type(v) == "string" and v or ""
end

local function basename(path)
    return str(path):gsub("[/\\]+$", ""):match("([^/\\]+)$") or str(path)
end

local function stateInfo(state)
    return STATE_LABELS[str(state)] or { rank = 4, label = "" }
end

local function now()
    return time.to_s(time.now())
end

local function stripAnsi(s)
    return (s:gsub("\27%][^\7\27]*\7", "")      -- OSC ... BEL
             :gsub("\27%][^\27]*\27\\", "")     -- OSC ... ST
             :gsub("\27%[[%d;?<=>]*[ -/]*[@-~]", "") -- CSI
             :gsub("\27[()][%w]", "")           -- charset selection
             :gsub("\27.", "")
             :gsub("\r", ""))
end

-- Trims trailing blanks, collapses runs of empty lines.
local function formatLines(lines, ansi)
    local out, blank = {}, 0
    for _, line in ipairs(lines) do
        line = str(line)
        if ansi then line = stripAnsi(line) end
        line = line:gsub("%s+$", "")
        if line == "" then
            blank = blank + 1
            if blank <= 1 then out[#out + 1] = "" end
        else
            blank = 0
            out[#out + 1] = line
        end
    end
    while out[#out] == "" do out[#out] = nil end
    return table.concat(out, "\n")
end

function Orca:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/orca.lua")
    local ok, err = pcall(NaCl.load, self.path .. "/lib/libtweetnacl.so")
    if not ok then
        logger.err("Orca: cannot load libtweetnacl:", err)
        self.load_error = tostring(err)
    end
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("13_orca", function(this)
            return {
                text = _("Send to Claude"),
                enabled = self.settings:has("pairing_url"),
                callback = function()
                    local text = this.selected_text and util.cleanupSelectedText(this.selected_text.text)
                    this:onClose()
                    self:askAboutPassage(text)
                end,
            }
        end)
    end
    self:startWatch()
end

function Orca:onCloseWidget()
    self:stopTicker()
    self:stopWatch()
    if self.client then self.client:close() end
end

-- KOReader stops scheduling while suspended; the socket is stale afterwards.
function Orca:onSuspend()
    self:stopWatch()
end

function Orca:onResume()
    self:resetClient()
    self.watch_states = nil
    self:startWatch()
end

-- Settings ---------------------------------------------------------------------

function Orca:getPairing()
    local url = self.settings:readSetting("pairing_url")
    if not url then return nil end
    return Client.parsePairingUrl(url)
end

function Orca:resetClient()
    if self.client then self.client:close() end
    self.client = nil
end

function Orca:savePairing(url)
    local offer, err = Client.parsePairingUrl(url)
    if not offer then
        UIManager:show(InfoMessage:new{ text = T(_("Invalid pairing code:\n%1"), err) })
        return false
    end
    self.settings:saveSetting("pairing_url", url:gsub("%s", ""))
    self.settings:flush()
    self:resetClient()
    UIManager:show(InfoMessage:new{
        text = T(_("Paired with %1"), offer.endpoint),
        timeout = 3,
    })
    return true
end

function Orca:importPairingFile()
    local f = io.open(PAIRING_FILE, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_("Copy the pairing link from Orca (Settings → Mobile) into\n%1\nthen try again."), PAIRING_FILE),
        })
        return
    end
    local url = f:read("*a")
    f:close()
    if self:savePairing(url) then
        -- The file holds a device credential; don't leave it lying around.
        os.remove(PAIRING_FILE)
    end
end

function Orca:showInput(title, description, input, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = description,
        input = input or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                on_save(value)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Orca:fontSize()
    return self.settings:readSetting("font_size") or 14
end

function Orca:refreshInterval()
    return self.settings:readSetting("refresh_interval") or 10
end

function Orca:watchInterval()
    return self.settings:readSetting("watch_interval") or 30
end

function Orca:watchEnabled()
    return self.settings:nilOrTrue("watch_enabled") and self.settings:has("pairing_url")
end

-- Main menu --------------------------------------------------------------------

function Orca:addToMainMenu(menu_items)
    local function choice(key, values, default, fmt)
        local items = {}
        for _, v in ipairs(values) do
            table.insert(items, {
                text = T(fmt, v),
                checked_func = function() return (self.settings:readSetting(key) or default) == v end,
                callback = function()
                    self.settings:saveSetting(key, v)
                    self.settings:flush()
                end,
            })
        end
        return items
    end

    menu_items.orca = {
        text = _("Orca"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sessions"),
                enabled_func = function() return self.settings:has("pairing_url") end,
                callback = function() self:openWorkspaces() end,
            },
            {
                text = _("Notify me while I read"),
                help_text = _("Checks your workspaces in the background and pops up when a Claude Code session needs a decision or finishes."),
                checked_func = function() return self.settings:nilOrTrue("watch_enabled") end,
                callback = function()
                    self.settings:flipNilOrTrue("watch_enabled")
                    self.settings:flush()
                    self:startWatch()
                end,
            },
            {
                text_func = function() return T(_("Check every %1 s"), self:watchInterval()) end,
                sub_item_table = choice("watch_interval", { 15, 30, 60, 120 }, 30, _("%1 seconds")),
            },
            {
                text = _("Display"),
                sub_item_table = {
                    {
                        text = _("Fit terminal to Kindle screen"),
                        help_text = _("While you view a session, the desktop resizes that terminal to the Kindle's width, and restores it when you leave."),
                        checked_func = function() return self.settings:nilOrTrue("fit_viewport") end,
                        callback = function() self.settings:flipNilOrTrue("fit_viewport"); self.settings:flush() end,
                    },
                    {
                        text = _("Live updates"),
                        help_text = _("Refresh the screen when the session prints something. Off: only refresh after you press a key or tap Refresh."),
                        checked_func = function() return self.settings:nilOrTrue("live_updates") end,
                        callback = function() self.settings:flipNilOrTrue("live_updates"); self.settings:flush() end,
                    },
                    {
                        text_func = function() return T(_("Font size: %1"), self:fontSize()) end,
                        sub_item_table = choice("font_size", { 11, 12, 13, 14, 16, 18 }, 14, _("%1 px")),
                    },
                },
            },
            {
                text = _("Pairing"),
                sub_item_table = {
                    {
                        text_func = function()
                            local offer = self:getPairing()
                            return offer and T(_("Paired: %1"), offer.endpoint) or _("Not paired")
                        end,
                        enabled_func = function() return false end,
                    },
                    {
                        text = T(_("Import from %1"), PAIRING_FILE),
                        callback = function() self:importPairingFile() end,
                    },
                    {
                        text = _("Enter pairing link…"),
                        callback = function()
                            self:showInput(_("Orca pairing link"),
                                _("Paste the link from Orca → Settings → Mobile (orca://pair?code=…)."),
                                "", function(url) self:savePairing(url) end)
                        end,
                    },
                    {
                        text = _("Forget pairing"),
                        enabled_func = function() return self.settings:has("pairing_url") end,
                        callback = function()
                            self.settings:delSetting("pairing_url")
                            self.settings:flush()
                            self:resetClient()
                        end,
                    },
                },
            },
            {
                text = _("Connection"),
                sub_item_table = {
                    {
                        text = _("Test connection"),
                        enabled_func = function() return self.settings:has("pairing_url") end,
                        callback = function() self:testConnection() end,
                    },
                    {
                        text = _("Connect through Tailscale proxy (localhost:1055)"),
                        checked_func = function() return self.settings:nilOrTrue("use_proxy") end,
                        callback = function()
                            self.settings:flipNilOrTrue("use_proxy")
                            self.settings:flush()
                            self:resetClient()
                        end,
                    },
                    {
                        text_func = function()
                            local host = self.settings:readSetting("host_override")
                            return host and T(_("Desktop address: %1"), host) or _("Desktop address: from pairing")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:showInput(_("Desktop address override"),
                                _("Leave empty to use the address from the pairing link. Example: 100.87.48.73"),
                                self.settings:readSetting("host_override"), function(host)
                                    host = host:gsub("%s", "")
                                    self.settings:saveSetting("host_override", host ~= "" and host or nil)
                                    self.settings:flush()
                                    self:resetClient()
                                end)
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Refresh every %1 s when live updates are off"), self:refreshInterval())
                        end,
                        sub_item_table = choice("refresh_interval", { 5, 10, 20, 30, 60 }, 10, _("%1 seconds")),
                    },
                },
            },
        },
    }
end

-- Connection and background jobs ---------------------------------------------------

function Orca:showError(err)
    UIManager:show(InfoMessage:new{ text = T(_("Orca: %1"), tostring(err)) })
end

function Orca:getClient()
    if self.load_error then
        return nil, T(_("crypto library failed to load: %1"), self.load_error)
    end
    if not self.client then
        local offer, err = self:getPairing()
        if not offer then return nil, err or _("not paired") end
        self.client = Client.new({
            offer = offer,
            proxy = self.settings:nilOrTrue("use_proxy") and PROXY or nil,
            host_override = self.settings:readSetting("host_override"),
        })
    end
    return self.client
end

--[[
    Network work runs in coroutines (the socket layer yields whenever it would
    block), stepped from the UI loop so KOReader never freezes. Jobs share one
    socket, so they run one at a time.

    job = { run = function(client) -> result, err, done = function(result, err),
            busy = optional text for a dismissable "please wait" message }
--]]
function Orca:queue(job)
    self.jobs = self.jobs or {}
    table.insert(self.jobs, job)
    if not self.current_job then
        self:nextJob()
    end
end

function Orca:isBusy()
    return self.current_job ~= nil
end

function Orca:nextJob()
    local job = self.jobs and table.remove(self.jobs, 1)
    self.current_job = job
    if not job then return end

    local busy_msg
    if job.busy then
        busy_msg = InfoMessage:new{
            text = job.busy,
            -- Tapping the message abandons the wait; the request finishes quietly.
            dismiss_callback = function()
                busy_msg = nil
                job.cancelled = true
            end,
        }
        UIManager:show(busy_msg)
    end

    local co = coroutine.create(function() return self:runWithClient(job.run) end)
    local function step()
        local ok, result, err = coroutine.resume(co)
        if ok and coroutine.status(co) ~= "dead" then
            UIManager:scheduleIn(0.1, step)
            return
        end
        if not ok then
            logger.err("Orca: job failed:", result)
            result, err = nil, tostring(result)
        end
        if busy_msg then
            -- InfoMessage fires dismiss_callback on every close, ours included;
            -- detach it so finishing the job doesn't count as a user cancel.
            busy_msg.dismiss_callback = nil
            UIManager:close(busy_msg)
        end
        if not job.cancelled and job.done then
            job.done(result, err)
        end
        self:nextJob()
    end
    step()
end

-- Runs fn(client), connecting first; on a dropped connection reconnects once.
function Orca:runWithClient(fn)
    local client, err = self:getClient()
    if not client then return nil, err end
    if not client:isConnected() then
        local ok, cerr = client:connect()
        if not ok then return nil, cerr end
        self:onReconnected(client)
    end
    local result, rerr = fn(client)
    if result == nil and not client:isConnected() then
        local ok, cerr = client:connect()
        if not ok then return nil, cerr end
        self:onReconnected(client)
        result, rerr = fn(client)
    end
    return result, rerr
end

-- A new socket has no subscription; re-establish the open session's.
function Orca:onReconnected(client)
    local session = self.session
    if session and session.subscribed then
        session.subscribed = false
        self:subscribe(client, session)
    end
end

-- Connects from scratch and reports which stage fails (proxy, network path,
-- WebSocket, authentication) or what the desktop returned.
function Orca:testConnection()
    NetworkMgr:runWhenOnline(function()
        self:resetClient()
        local started = now()
        self:queue{
            busy = _("Testing connection to Orca…"),
            run = function(c) return c:listWorktrees() end,
            done = function(worktrees, err)
                local client = self.client
                local target = client and (client.host .. ":" .. client.port) or "?"
                local via = self.settings:nilOrTrue("use_proxy") and _("via Tailscale proxy") or _("direct")
                if worktrees then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Connected to Orca at %1 (%2) in %3 s.\n%4 workspaces."),
                            target, via, string.format("%.1f", now() - started), #worktrees),
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = T(_("Cannot reach Orca at %1 (%2):\n\n%3\n\nIf the proxy is not reachable, start Tailscale (Network → Tailscale)."),
                            target, via, tostring(err)),
                    })
                end
            end,
        }
    end)
end

-- Workspace / terminal browser -----------------------------------------------------

-- on_pick(term, wt) runs when a terminal is chosen; default opens the session.
-- With `jump_to`, the browser opens straight on that workspace's terminals.
function Orca:openWorkspaces(on_pick, jump_to)
    on_pick = on_pick or function(term) self:openSession(term) end
    local title = self.pick_title or _("Orca workspaces")
    self.pick_title = nil
    NetworkMgr:runWhenOnline(function()
        self:loadWorkspaces(on_pick, function(items)
            self.menu = Menu:new{
                title = title,
                item_table = items,
                covers_fullscreen = true,
                is_borderless = true,
                is_popout = false,
            }
            UIManager:show(self.menu)
            if jump_to then self:openTerminals(jump_to, on_pick) end
        end)
    end)
end

function Orca:loadWorkspaces(on_pick, on_items)
    self:queue{
        busy = _("Connecting to Orca…"),
        run = function(c) return c:listWorktrees() end,
        done = function(worktrees, err)
            if not worktrees then return self:showError(err) end
            on_items(self:workspaceItems(worktrees, on_pick))
        end,
    }
end

function Orca:workspaceItems(worktrees, on_pick)
    table.sort(worktrees, function(a, b)
        local ra, rb = stateInfo(a.status).rank, stateInfo(b.status).rank
        if ra ~= rb then return ra < rb end
        return (tonumber(a.liveTerminalCount) or 0) > (tonumber(b.liveTerminalCount) or 0)
    end)
    local items = {
        { text = _("↻ Refresh"), callback = function()
            self:loadWorkspaces(on_pick, function(fresh) self.menu:switchItemTable(nil, fresh) end)
        end },
    }
    for _, wt in ipairs(worktrees) do
        local count = tonumber(wt.liveTerminalCount) or 0
        local branch = str(wt.branch):gsub("^refs/heads/", "")
        local label = stateInfo(wt.status).label
        table.insert(items, {
            text = basename(wt.path) .. (branch ~= "" and ("  [" .. branch .. "]") or ""),
            mandatory = label ~= "" and label or (count > 0 and tostring(count) or nil),
            bold = stateInfo(wt.status).rank == 1,
            callback = function() self:openTerminals(wt, on_pick) end,
        })
    end
    return items
end

function Orca:loadTerminals(wt, on_pick, on_items)
    self:queue{
        busy = _("Loading terminals…"),
        run = function(c)
            local terminals, err = c:listTerminals(wt.worktreeId)
            if not terminals then return nil, err end
            -- Agent states are a nicety; a failure here shouldn't hide the list.
            return { terminals = terminals, states = c:agentStates() or {} }
        end,
        done = function(result, err)
            if not result then return self:showError(err) end
            on_items(self:terminalItems(wt, result.terminals, result.states, on_pick))
        end,
    }
end

function Orca:terminalItems(wt, terminals, states, on_pick)
    local items = {
        { text = _("↻ Refresh"), callback = function()
            self:loadTerminals(wt, on_pick, function(fresh) self.menu:switchItemTable(nil, fresh) end)
        end },
    }
    for _, term in ipairs(terminals) do
        local title = str(term.title) ~= "" and str(term.title) or str(term.handle)
        local agent = states[term.handle]
        local info = stateInfo(agent and agent.state)
        table.insert(items, {
            text = title,
            mandatory = info.label ~= "" and info.label or nil,
            bold = info.rank == 1,
            callback = function() on_pick(term, wt) end,
        })
    end
    if #terminals == 0 then
        table.insert(items, { text = _("(no live terminals)"), select_enabled = false })
    end
    return items
end

function Orca:openTerminals(wt, on_pick)
    self:loadTerminals(wt, on_pick, function(items)
        local menu = self.menu
        if not menu then return end
        -- Push like a sub-menu so the back arrow returns to the workspace list.
        menu.item_table.title = menu.title
        table.insert(menu.item_table_stack, menu.item_table)
        menu:switchItemTable(basename(wt.path), items)
    end)
end

-- Watch mode -----------------------------------------------------------------------
--[[
    Polls worktree.ps in the background and pops up a notice when a workspace
    changes to "needs you" (permission prompt) or "done". The first poll only
    takes a snapshot, so re-opening KOReader doesn't replay old states.
--]]

function Orca:startWatch()
    self:stopWatch()
    if not self:watchEnabled() then return end
    self.watch_failures = 0
    self.watcher = function()
        if not self:watchEnabled() then self.watcher = nil; return end
        local delay = self:watchInterval()
        if (self.watch_failures or 0) > 0 then
            delay = math.min(WATCH_BACKOFF_MAX, delay * 2 ^ self.watch_failures)
        end
        UIManager:scheduleIn(delay, self.watcher)
        -- A session view has its own ticker; menus are already showing states.
        if self.menu and not UIManager:isWidgetShown(self.menu) then self.menu = nil end
        if self.notice and not UIManager:isWidgetShown(self.notice) then self.notice = nil end
        if self.session or self.menu or self:isBusy() or not NetworkMgr:isConnected() then
            return
        end
        self:queue{
            run = function(c) return c:agentStates() end,
            done = function(states, err)
                if not states then
                    self.watch_failures = (self.watch_failures or 0) + 1
                    logger.dbg("Orca: watch failed:", err)
                    return
                end
                self.watch_failures = 0
                self:checkAgentChanges(states)
            end,
        }
    end
    UIManager:scheduleIn(self:watchInterval(), self.watcher)
end

function Orca:stopWatch()
    if self.watcher then
        UIManager:unschedule(self.watcher)
        self.watcher = nil
    end
end

-- Workspace name from a worktree id ("<uuid>::<path>"), falling back to the tab title.
local function workspaceName(status)
    local path = str(status.worktree):match("::(.+)$")
    if path then return basename(path) end
    return str(status.title) ~= "" and status.title or _("a session")
end

function Orca:checkAgentChanges(states)
    local previous = self.watch_states
    local alerts = {}
    for handle, status in pairs(states) do
        local state = str(status.state)
        local before = previous and previous[handle]
        local rank = stateInfo(state).rank
        -- A new permission prompt, or work that just finished (idle→done
        -- flips happen on reconnects and are not news).
        if previous and before ~= state
                and (rank == 1 or (state == "done" and before == "working")) then
            table.insert(alerts, { handle = handle, status = status, rank = rank })
        end
    end
    local current = {}
    for handle, status in pairs(states) do current[handle] = str(status.state) end
    self.watch_states = current
    if #alerts == 0 or self.notice then return end

    table.sort(alerts, function(a, b) return a.rank < b.rank end)
    local alert = alerts[1]
    local name = workspaceName(alert.status)
    local text = alert.rank == 1
        and T(_("Claude Code in %1 is waiting for you."), name)
        or T(_("Claude Code in %1 has finished."), name)
    if #alerts > 1 then
        text = text .. "\n" .. T(_("(+%1 more sessions changed)"), #alerts - 1)
    end
    self.notice = ConfirmBox:new{
        text = text,
        ok_text = _("Open"),
        cancel_text = _("Later"),
        ok_callback = function()
            self.notice = nil
            self:openSession({ handle = alert.handle, title = alert.status.title })
        end,
        cancel_callback = function() self.notice = nil end,
        dismissable = true,
    }
    UIManager:show(self.notice)
end

-- Highlight → Claude ---------------------------------------------------------------

local function collapse(s)
    return (str(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function Orca:passageContext()
    local props = self.ui and self.ui.doc_props or {}
    local source = str(props.title)
    if source == "" and self.ui and self.ui.document then
        source = basename(self.ui.document.file)
    end
    if str(props.authors) ~= "" then
        source = source .. " by " .. collapse(props.authors:gsub("\n", ", "))
    end
    local ok, chapter = pcall(function()
        return self.ui.toc:getTocTitleByPage(self.ui:getCurrentPage())
    end)
    if ok and str(chapter) ~= "" then
        source = source .. ", chapter \"" .. collapse(chapter) .. "\""
    end
    return source
end

-- Asks what to do with a highlighted passage and sends it to a session.
function Orca:askAboutPassage(passage)
    passage = collapse(passage)
    if passage == "" then return end
    local source = self:passageContext()
    local preview = #passage > 300 and (passage:sub(1, 300) .. "…") or passage

    local dialog
    local function send(question)
        UIManager:close(dialog)
        local message = T(_("From %1:\n\n\"%2\"\n\n%3"), source, passage, question)
        self:pickSession(function(term)
            self:sendToTerminal(term, message)
        end)
    end
    local function preset(label, question)
        return { text = label, callback = function() send(question) end }
    end
    dialog = InputDialog:new{
        title = _("Send passage to Claude"),
        description = preview,
        input = "",
        input_hint = _("Your question (optional)"),
        allow_newline = true,
        buttons = {
            {
                preset(_("Explain"), _("Explain this passage in a few short paragraphs.")),
                preset(_("Context"), _("Give the historical and cultural context for this passage, and who or what it refers to.")),
                preset(_("Save note"), _("Append this passage, with its source and a one-line summary, to my reading notes (notes/reading-notes.md in this project; create it if missing). Reply with just the file path.")),
            },
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Send"), is_enter_default = true, callback = function()
                    local q = collapse(dialog:getInputText())
                    send(q ~= "" and q or _("What do you make of this passage?"))
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Offers the last-used session first, otherwise browses for one.
function Orca:pickSession(on_pick)
    local last = self.settings:readSetting("last_terminal")
    local function browse()
        self.pick_title = _("Send to which session?")
        self:openWorkspaces(function(term, wt)
            if self.menu then UIManager:close(self.menu); self.menu = nil end
            self.settings:saveSetting("last_terminal", {
                handle = term.handle, title = str(term.title), workspace = basename(wt.path),
            })
            self.settings:flush()
            on_pick(term)
        end)
    end
    if not last then return browse() end
    local box
    box = ConfirmBox:new{
        text = T(_("Send to %1 (%2)?"), last.title ~= "" and last.title or last.handle, last.workspace),
        ok_text = _("Send"),
        cancel_text = _("Choose another…"),
        ok_callback = function() on_pick(last) end,
        cancel_callback = function() browse() end,
        other_buttons = {{ { text = _("Cancel") } }},
    }
    UIManager:show(box)
end

-- Pastes a message into a terminal, submits it and opens the session view.
function Orca:sendToTerminal(term, message)
    NetworkMgr:runWhenOnline(function()
        self:queue{
            busy = _("Sending to Claude…"),
            run = function(c)
                local text = PASTE_START .. message .. PASTE_END
                local ok, err = c:sendText(term.handle, text, false)
                if not ok then return nil, err end
                -- A separate Enter: pasted text with a trailing newline is
                -- kept as a line break by the agent's input box.
                return c:sendText(term.handle, "", true)
            end,
            done = function(ok, err)
                if not ok then
                    if tostring(err):match("not found") then
                        self.settings:delSetting("last_terminal")
                        self.settings:flush()
                    end
                    return self:showError(err)
                end
                self:openSession(term)
            end,
        }
    end)
end

-- Session view -------------------------------------------------------------------

function Orca:openSession(term)
    local session = {
        handle = term.handle,
        title = str(term.title) ~= "" and str(term.title) or str(term.handle),
        live = self.settings:nilOrTrue("live_updates"),
        fit = self.settings:nilOrTrue("fit_viewport"),
        dirty = false,
        last_refresh = 0,
    }
    self.session = session

    local function key(label, text)
        return { text = label, callback = function() self:sendInput({ text = text }) end }
    end
    local buttons = {
        { key("1", "1"), key("2", "2"), key("3", "3"), key("Esc", KEY_ESC),
          { text = "Ctrl-C", callback = function() self:sendInput({ interrupt = true }) end } },
        { key("↑", KEY_UP), key("↓", KEY_DOWN), key("Tab", KEY_TAB), key("⇧Tab", KEY_SHIFT_TAB),
          { text = "⏎", callback = function() self:sendInput({ text = "", enter = true }) end } },
        { { text = _("Type…"), callback = function() self:promptInput() end },
          { text = _("Refresh"), callback = function() self:refreshSession() end } },
    }

    self.viewer = TextViewer:new{
        title = session.title,
        text = _("Connecting…"),
        text_type = "code",
        buttons_table = buttons,
        add_default_buttons = false,
        close_callback = function() self:closeSession(session) end,
    }
    -- Our own font size, so the number of columns that fit is predictable.
    self.viewer.monospace_font = true
    self.viewer.text_font_size = self:fontSize()
    self.viewer:init(true)
    UIManager:show(self.viewer)

    session.viewport = self:measureViewport()
    self:queue{
        run = function(c)
            if session.live or session.fit then
                local ok, err = self:subscribe(c, session)
                if not ok then return nil, err end
            end
            return c:readTerminal(session.handle, true)
        end,
        done = function(screen, err) self:showScreen(session, screen, err) end,
    }
    self:startTicker()
end

-- Columns and rows of monospace text that fit in the viewer.
function Orca:measureViewport()
    local text_widget = self.viewer.scroll_widget.text_widget
    local face = text_widget.face or Font:getFace("smallinfont", self:fontSize())
    local sample = string.rep("M", 20)
    local char_w = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, sample).x / #sample
    local cols = math.floor(text_widget.width / char_w) - 1
    local rows = math.floor(text_widget.height / text_widget.line_height_px)
    return {
        cols = math.max(20, math.min(cols, 1024)),
        rows = math.max(8, math.min(rows, 500)),
    }
end

-- Subscribes the session's terminal (runs inside a job).
function Orca:subscribe(c, session)
    local id, result = c:subscribeTerminal(session.handle, session.fit and session.viewport or nil)
    if not id then return nil, result end
    session.request_id = id
    session.subscribed = true
    session.fit_lost = false
    logger.dbg("Orca: subscribed", session.handle, result and result.cols, result and result.rows)
    return true
end

function Orca:closeSession(session)
    self:stopTicker()
    self.viewer = nil
    self.session = nil
    if session.subscribed then
        -- Ends the stream; the desktop then restores the terminal's own size.
        self:queue{
            run = function(c)
                if not c:isConnected() then return true end
                return c:unsubscribeTerminal(session.handle, session.request_id)
            end,
        }
    end
end

function Orca:showScreen(session, screen, err)
    if session ~= self.session then return end
    session.last_refresh = now()
    session.dirty = false
    local text
    if screen and screen.source == "screen-unavailable" then
        text = formatLines(screen.tail or {}, true)
    elseif screen then
        text = formatLines(screen.tail or {}, false)
    else
        text = T(_("Could not read the terminal:\n%1"), tostring(err))
    end
    self:setViewerText(text ~= "" and text or _("(empty screen)"))
end

function Orca:refreshSession()
    local session = self.session
    if not session or session.refresh_queued then return end
    session.refresh_queued = true
    self:queue{
        run = function(c)
            local screen, err = c:readTerminal(session.handle, true)
            if screen and screen.source == "screen-unavailable" then
                screen, err = c:readTerminal(session.handle, false, 200)
            end
            return screen, err
        end,
        done = function(screen, err)
            session.refresh_queued = false
            self:showScreen(session, screen, err)
        end,
    }
end

function Orca:setViewerText(text)
    local viewer = self.viewer
    if not viewer then return end
    viewer.text = text
    viewer:init(true)
    viewer.scroll_widget:scrollToBottom()
    UIManager:setDirty("all", "partial", viewer.frame.dimen)
end

function Orca:sendInput(params)
    local session = self.session
    if not session then return end
    params.terminal = session.handle
    self:queue{
        run = function(c)
            -- The desktop took the size back (someone typed or resized there):
            -- reclaim it before acting from the Kindle.
            if session.fit and session.fit_lost and session.subscribed then
                c:claimViewport(session.handle, session.viewport)
                session.fit_lost = false
            end
            return c:call("terminal.send", params)
        end,
        done = function(result, err)
            if not result then return self:showError(err) end
            if not session.live then
                -- Give the program a moment to redraw before reading the screen.
                UIManager:scheduleIn(1, function() self:refreshSession() end)
            end
        end,
    }
end

function Orca:promptInput()
    local dialog
    local function send(enter)
        local text = dialog:getInputText()
        UIManager:close(dialog)
        self:sendInput({ text = text, enter = enter })
    end
    dialog = InputDialog:new{
        title = T(_("Send to %1"), self.session and self.session.title or ""),
        input = "",
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Type only"), callback = function() send(false) end },
            { text = _("Send ⏎"), is_enter_default = true, callback = function() send(true) end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Applies stream events: output marks the screen dirty, a desktop resize
-- marks our fit as lost.
function Orca:handleEvents(session, events)
    for _, msg in ipairs(events) do
        local result = type(msg.result) == "table" and msg.result or nil
        if msg.id == session.request_id and result then
            if result.type == "data" or result.type == "scrollback" then
                if not session.dirty then session.dirty_since = now() end
                session.dirty = true
                session.last_output = now()
            elseif result.type == "fit-override-changed" and session.viewport then
                if tonumber(result.cols) ~= session.viewport.cols then
                    session.fit_lost = true
                end
            end
        end
    end
end

-- Once a second while a session is open: service the socket (keepalive
-- pings, stream events) and refresh the screen when it changed.
function Orca:startTicker()
    self:stopTicker()
    self.ticker = function()
        local session = self.session
        if not session then return end
        UIManager:scheduleIn(TICK, self.ticker)
        if self:isBusy() then return end

        local client = self.client
        local t = now()
        if client and not client:isConnected() then
            -- Dropped (Wi-Fi off after sleep, desktop restarted…): refreshing
            -- reconnects and resubscribes. Back off while it keeps failing;
            -- errors show in the viewer rather than as popups.
            if t >= (session.retry_at or 0) then
                session.retry_at = t + 10
                self:refreshSession()
            end
            return
        end
        if client then
            self:queue{
                run = function(c)
                    c:pump(0)
                    return c:takeEvents()
                end,
                done = function(events)
                    if events and session == self.session then
                        self:handleEvents(session, events)
                    end
                end,
            }
        end

        if session.live then
            if session.dirty and (t - (session.last_output or 0) >= LIVE_QUIET
                    or t - (session.dirty_since or t) >= LIVE_MAX_DELAY) then
                self:refreshSession()
            end
        elseif t - session.last_refresh >= self:refreshInterval() then
            self:refreshSession()
        end
    end
    UIManager:scheduleIn(TICK, self.ticker)
end

function Orca:stopTicker()
    if self.ticker then
        UIManager:unschedule(self.ticker)
        self.ticker = nil
    end
end

return Orca
