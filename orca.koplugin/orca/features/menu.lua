--[[
    Tools → Orca opens Orca; its settings open from ⚙ in Orca's title bar, in
    KOReader's own menu widget. Connection things (Tailscale, test) aren't
    here: tapping the status line opens them (features/network). Settings rows read "Label: value" (TouchMenu
    has no right-hand value column).
--]]

local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local Menu = {}

local PAIRING_FILE = "/mnt/us/orca-pairing.txt"
Menu.PAIRING_FILE = PAIRING_FILE

local function choice(app, key, values, fmt, on_change)
    local items = {}
    for _, v in ipairs(values) do
        table.insert(items, {
            text = fmt and T(fmt, v) or tostring(v),
            checked_func = function() return app.settings:get(key) == v end,
            radio = true,
            callback = function()
                app.settings:set(key, v)
                if on_change then on_change(v) end
            end,
        })
    end
    return items
end

-- Tools → Orca.
function Menu.items(app)
    return {
        text = _("Orca"),
        sorting_hint = "tools",
        help_text = _("Opens Orca. Settings are under ⚙ in its title bar; tap the line with the clock and battery for Tailscale and the connection. To open Orca with one tap, pick Open Orca in Settings → Taps and gestures."),
        callback = function() app.home:open() end,
    }
end

function Menu.settings(app, plugin)
    local settings = app.settings
    local paired = function() return settings:isPaired() end

    -- Rarely changed; Tailscale and the connection test are on the card the
    -- status line opens (features/network).
    local advanced = {
        text = _("Advanced"),
        sub_item_table = {
            {
                text = _("Use Tailscale proxy"),
                help_text = _("Reach the PC through Tailscale's SOCKS5 proxy on localhost:1055 (needed on Kindles without a TUN device)."),
                checked_func = function() return settings:get("use_proxy") end,
                callback = function()
                    settings:flip("use_proxy")
                    app.connection:reset()
                end,
            },
            {
                text_func = function() return T("%1: %2", _("Desktop address"), settings:get("host_override") or _("from pairing")) end,
                keep_menu_open = true,
                callback = function()
                    app.text.ask{
                        title = _("Desktop address"),
                        description = _("Leave empty to use the address from the pairing link. Example: 100.64.0.2"),
                        input = settings:get("host_override"),
                        on_ok = function(host)
                            host = host:gsub("%s", "")
                            settings:set("host_override", host ~= "" and host or nil)
                            app.connection:reset()
                        end,
                    }
                end,
            },
            {
                text_func = function() return T("%1: %2", _("Check for news every"), T(_("%1 s"), settings:get("watch_interval"))) end,
                help_text = _("Used only when the desktop can't push notifications to the Kindle."),
                sub_item_table = choice(app, "watch_interval", { 15, 30, 60, 120 }, _("%1 seconds")),
            },
            {
                text_func = function() return T("%1: %2", _("Refresh interval"), T(_("%1 s"), settings:get("refresh_interval"))) end,
                help_text = _("How often an open session redraws when Live updates is off."),
                enabled_func = function() return not settings:get("live_updates") end,
                sub_item_table = choice(app, "refresh_interval", { 5, 10, 20, 30, 60 }, _("%1 seconds")),
            },
        },
    }

    return {
        {
            text = _("Notify me while I read"),
            help_text = _("Pops up over your book when a session needs a decision or finishes, with buttons to answer it right there."),
            checked_func = function() return settings:get("watch_enabled") end,
            callback = function()
                settings:flip("watch_enabled")
                app.notify:start()
            end,
        },
        {
            text = _("Claude status on the sleep screen"),
            help_text = _("While the Kindle is awake, redraws a sleep-screen picture every few minutes: the question a session is waiting on, Claude's usage limits, which sessions are at work, the book you're reading and your reading heatmap. Turning it off restores your previous sleep screen."),
            checked_func = function() return settings:get("sleep_status") end,
            callback = function() app.sleep:setEnabled(not settings:get("sleep_status")) end,
        },
        {
            text = _("Home cards…"),
            help_text = _("Choose which cards Home and the sleep screen show, and in what order."),
            callback = function() app.layout:open() end,
        },
        {
            text = _("Open the question when I wake the Kindle"),
            help_text = _("When the sleep screen shows a session waiting for you, waking the Kindle opens Orca on that question, with its answer buttons."),
            enabled_func = function() return settings:get("sleep_status") end,
            checked_func = function() return settings:get("wake_to_question") end,
            callback = function() settings:flip("wake_to_question") end,
        },
        {
            text_func = function() return T("%1: %2", _("Agent for new sessions"), app:agentName()) end,
            sub_item_table = (function()
                local items = {}
                for _, id in ipairs({ "claude", "codex", "gemini", "opencode" }) do
                    table.insert(items, {
                        text = app:agentName(id),
                        radio = true,
                        checked_func = function() return app:agent() == id end,
                        callback = function() settings:set("agent", id) end,
                    })
                end
                return items
            end)(),
        },
        {
            text_func = function()
                return T("%1: %2", _("GitHub user"), app.github:login() or _("from your pull requests"))
            end,
            help_text = _("Home shows this user's public contribution calendar from github.com, fetched by the Kindle twice a day."),
            keep_menu_open = true,
            callback = function() app.github:askLogin() end,
            separator = true,
        },
        {
            text = _("Session view"),
            sub_item_table = {
                {
                    text = _("Fit terminal to Kindle screen"),
                    help_text = _("While you view a session, the desktop resizes that terminal to the Kindle's width, and restores it when you leave."),
                    checked_func = function() return settings:get("fit_viewport") end,
                    callback = function() settings:flip("fit_viewport") end,
                },
                {
                    text = _("Keep earlier output"),
                    help_text = _("Makes the terminal a few screens taller than the Kindle while you view it, so you can swipe up to read what scrolled off. Takes effect the next time you open a session."),
                    enabled_func = function() return settings:get("fit_viewport") end,
                    checked_func = function() return settings:get("session_history") end,
                    callback = function() settings:flip("session_history") end,
                },
                {
                    text = _("Live updates"),
                    help_text = _("Refresh the screen when the session prints something. Off: refresh after you press a key, and every few seconds."),
                    checked_func = function() return settings:get("live_updates") end,
                    callback = function() settings:flip("live_updates") end,
                },
                {
                    text_func = function() return T("%1: %2", _("Font size"), T(_("%1 px"), settings:get("font_size"))) end,
                    sub_item_table = choice(app, "font_size", { 11, 12, 13, 14, 16, 18 }, _("%1 px")),
                },
            },
        },
        {
            text_func = function() return T("%1: %2", _("Pairing"), settings:isPaired() and _("Paired") or _("Not paired")) end,
            sub_item_table = {
                {
                    text = T(_("Import from %1"), PAIRING_FILE),
                    callback = function() plugin:importPairingFile() end,
                },
                {
                    text = _("Enter pairing link…"),
                    callback = function()
                        app.text.ask{
                            title = _("Orca pairing link"),
                            description = _("Paste the link from Orca → Settings → Mobile (orca://pair?code=…)."),
                            ok_text = _("Pair"),
                            on_ok = function(url) plugin:savePairing(url) end,
                        }
                    end,
                },
                {
                    text = _("Forget pairing"),
                    enabled_func = paired,
                    callback = function()
                        app.dialog.confirm{
                            title = _("Forget pairing?"),
                            text = _("This Kindle will stop reaching Orca until you pair it again."),
                            ok_text = _("Forget"),
                            destructive = true,
                            on_ok = function()
                                settings:set("pairing_url", nil)
                                app.connection:reset()
                            end,
                        }
                    end,
                },
            },
        },
        advanced,
    }
end

-- Shows the settings over Orca, the way KOReader shows its own menu.
function Menu.showSettings(app, plugin)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Screen = require("device").screen
    local TouchMenu = require("ui/widget/touchmenu")
    local UIManager = require("ui/uimanager")
    local container = CenterContainer:new{ covers_header = true, ignore = "height", dimen = Screen:getSize() }
    local items = Menu.settings(app, plugin)
    items.icon = "appbar.settings"
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        last_index = 1,
        tab_item_table = { items },
        show_parent = container,
    }
    menu.close_callback = function() UIManager:close(container) end
    container[1] = menu
    UIManager:show(container)
end

return Menu
