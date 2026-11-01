--[[
    Plugin settings (settings/orca.lua) with one place for keys and defaults.
    Wraps a LuaSettings-like store: readSetting / saveSetting / delSetting / flush.
--]]

local Settings = {}
Settings.__index = Settings

Settings.DEFAULTS = {
    agent = "claude",              -- agent for new sessions
    watch_enabled = true,          -- notify while reading
    watch_interval = 30,           -- s between polls when the instant stream is unavailable
    sleep_status = false,          -- Claude status on the sleep screen
    fit_viewport = true,           -- resize the desktop terminal to the Kindle
    live_updates = true,           -- refresh the session view on output
    session_history = true,        -- fit a few screens tall, so swiping up shows earlier output
    font_size = 14,                -- terminal font, px
    refresh_interval = 10,         -- s between refreshes when live updates are off
    use_proxy = true,              -- reach the desktop through Tailscale's SOCKS5 proxy
    -- Without defaults: pairing_url (credential), host_override, client_id,
    -- projects_dir, last_terminal, notify_watermark {seq, epoch}, saved_screensaver.
}

function Settings.new(store)
    return setmetatable({ store = store }, Settings)
end

function Settings:get(key)
    local v = self.store:readSetting(key)
    if v == nil then return Settings.DEFAULTS[key] end
    return v
end

function Settings:set(key, value)
    if value == nil then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, value)
    end
    self.store:flush()
end

function Settings:flip(key)
    self:set(key, not self:get(key))
    return self:get(key)
end

function Settings:has(key)
    return self.store:readSetting(key) ~= nil
end

function Settings:isPaired()
    return self:has("pairing_url")
end

-- A random id that names this Kindle to the desktop in subscriptions, so the
-- device token (a credential) never ends up in desktop-side ids or logs.
function Settings:clientId()
    local id = self:get("client_id")
    if not id then
        id = string.format("kindle-%06x%06x", math.random(0, 0xffffff), math.random(0, 0xffffff))
        self:set("client_id", id)
    end
    return id
end

return Settings
