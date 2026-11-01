--[[
    Orca for KOReader: browse Orca desktop workspaces and drive their terminal
    sessions (e.g. Claude Code) from an e-ink screen.

    This file only wires things together and follows KOReader's lifecycle.
    orca/core     settings, job queue, connection (no UI)
    orca/api      Orca RPC calls returning plain data
    orca/ui       style tokens, window (screen stack), dialogs, text input
    orca/features one module per area (home, session, git, notify, …)
    orcaclient    WebSocket + NaCl transport for Orca's mobile protocol
--]]

-- Our modules load lazily, after KOReader has taken the plugin directory off
-- package.path, so keep it there ourselves.
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
if not package.path:find(PLUGIN_DIR .. "/?.lua", 1, true) then
    package.path = PLUGIN_DIR .. "/?.lua;" .. package.path
end

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local Client = require("orcaclient.client")
local NaCl = require("orcaclient.nacl")

local App = require("orca.app")
local Connection = require("orca.core.connection")
local Jobs = require("orca.core.jobs")
local Settings = require("orca.core.settings")
local Nav = require("orca.ui.window")
local dialog = require("orca.ui.dialog")
local text = require("orca.ui.text")
local Menu = require("orca.features.menu")

local PROXY = { host = "127.0.0.1", port = 1055 }

local FEATURES = {
    home = "orca.features.home",
    workspace = "orca.features.workspace",
    session = "orca.features.session",
    create = "orca.features.create",
    git = "orca.features.git",
    files = "orca.features.files",
    conversations = "orca.features.conversations",
    notify = "orca.features.notify",
    accounts = "orca.features.accounts",
    automations = "orca.features.automations",
    sleep = "orca.features.sleepscreen",
    passage = "orca.features.passage",
    github = "orca.features.github",
}

local Orca = WidgetContainer:extend{
    name = "orca",
    is_doc_only = false,
}

-- Connection, stream and wake events, for debugging from crash.log. Never
-- pass request params or the pairing: they hold the device token.
local function log(...) logger.info("Orca:", ...) end

-- Builds the app context; separate from init so tests can build one with fakes.
function Orca.buildApp(opts)
    local settings = opts.settings
    local schedule = function(delay, fn) UIManager:scheduleIn(delay, fn) end
    local connection = Connection.new{
        settings = settings,
        Client = Client,
        proxy = PROXY,
        schedule = schedule,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        log = log,
        load_error = opts.load_error,
    }
    local jobs = Jobs.new{
        connection = connection,
        schedule = schedule,
        log = log,
        busy = function(message, on_cancel)
            local msg
            msg = InfoMessage:new{ text = message, dismiss_callback = function()
                msg = nil
                on_cancel()
            end }
            UIManager:show(msg)
            return function()
                -- InfoMessage fires dismiss_callback on every close, ours included.
                if msg then msg.dismiss_callback = nil; UIManager:close(msg) end
            end
        end,
    }
    local app = App.new{
        settings = settings,
        connection = connection,
        jobs = jobs,
        nav = Nav.new(),
        dialog = dialog,
        text = text,
        online = function(fn) NetworkMgr:runWhenOnline(fn) end,
        isOnline = function() return NetworkMgr:isConnected() end,
        now = function() return time.to_s(time.now()) end,
        log = log,
        plugin = opts.plugin,
        library = require("orca.core.library"),
        web = require("orca.core.web"),
        poster = require("orca.ui.poster").write,
        sleep_dir = DataStorage:getDataDir() .. "/cache/orca-sleep",
    }
    for name, module in pairs(FEATURES) do
        app[name] = require(module).new(app)
    end
    return app
end

function Orca:init()
    local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/orca.lua")
    local ok, err = pcall(NaCl.load, self.path .. "/lib/libtweetnacl.so")
    if not ok then logger.err("Orca: cannot load libtweetnacl:", err) end
    self.app = Orca.buildApp{
        settings = Settings.new(store),
        load_error = not ok and tostring(err) or nil,
        plugin = self,
    }
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("13_orca", function(this)
            return {
                text = T(_("Send to %1"), self.app:agentName()),
                enabled = self.app.settings:isPaired(),
                callback = function()
                    local selected = this.selected_text and util.cleanupSelectedText(this.selected_text.text)
                    this:onClose()
                    self.app.passage:ask(selected)
                end,
            }
        end)
    end
    self.app.notify:start()
    self.app.sleep:start()
end

function Orca:addToMainMenu(menu_items)
    menu_items.orca = Menu.items(self.app, self)
end

function Orca:onCloseWidget()
    self.app.session:close()
    self.app.notify:stop()
    self.app.sleep:stop()
    self.app.connection:stop()
end

-- KOReader stops scheduling while suspended and Wi-Fi goes off: the socket
-- is stale afterwards.
function Orca:onSuspend()
    log("suspend")
    self.app.notify:suspend()
end

function Orca:onResume()
    self.app.connection:reset("woke up")
    self.app.notify:resume()
    self.app.sleep:wake()
    self.app.sleep:start()
end

-- Pairing ---------------------------------------------------------------------------

function Orca:savePairing(url)
    local offer, err = Client.parsePairingUrl(url)
    if not offer then
        self.app.dialog.alert{ title = _("That pairing link doesn't work"), text = tostring(err) }
        return false
    end
    self.app.settings:set("pairing_url", (url:gsub("%s", "")))
    self.app.connection:reset("new pairing")
    self.app:toast(T(_("Paired with %1"), offer.endpoint))
    self.app.notify:start()
    return true
end

function Orca:importPairingFile()
    local f = io.open(Menu.PAIRING_FILE, "r")
    if not f then
        self.app.dialog.alert{
            title = _("No pairing file"),
            text = T(_("Copy the pairing link from Orca (Settings → Mobile) into\n%1\nthen try again."), Menu.PAIRING_FILE),
        }
        return
    end
    local url = f:read("*a")
    f:close()
    if self:savePairing(url) then
        -- The file holds a device credential; don't leave it lying around.
        os.remove(Menu.PAIRING_FILE)
    end
end

-- Connects from scratch and reports which stage fails or how long it took.
function Orca:testConnection()
    local app = self.app
    app.online(function()
        app.connection:reset()
        local started = app.now()
        app:run{
            busy = _("Testing the connection…"),
            run = function(c) return c:listWorktrees() end,
            done = function(worktrees, err)
                local client = app.connection.instance
                local target = client and (client.host .. ":" .. client.port) or "?"
                local via = app.settings:get("use_proxy") and _("through the Tailscale proxy") or _("directly")
                if worktrees then
                    app.dialog.alert{
                        title = _("Connected"),
                        text = T(_("Reached Orca at %1 %2 in %3 s. %4 workspaces."),
                            target, via, string.format("%.1f", app.now() - started), #worktrees),
                    }
                else
                    app.dialog.alert{
                        title = _("Can't reach Orca"),
                        text = T(_("Tried %1 %2:\n\n%3\n\nIf the proxy isn't reachable, start Tailscale (Network → Tailscale)."),
                            target, via, tostring(err)),
                        retry = function() self:testConnection() end,
                    }
                end
            end,
        }
    end)
end

return Orca
