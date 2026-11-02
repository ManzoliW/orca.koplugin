--[[
    The connection card: tapping the status line on any Orca screen opens it.
    One place for what's otherwise spread over menus: whether Tailscale is
    on (and turning it on or off, when the Tailscale plugin is installed),
    whether the PC is reached, and a connection test that says which step
    fails.
--]]

local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local Network = {}
Network.__index = Network

function Network.new(app)
    return setmetatable({ app = app }, Network)
end

function Network:tailscale()
    return self.app.tailscale and self.app.tailscale()
end

function Network:summary()
    local app, lines = self.app, {}
    local ts = self:tailscale()
    if ts then
        table.insert(lines, T("%1: %2", "Tailscale", ts:isUp() and _("on") or _("off")))
    end
    local pc
    if not app.settings:isPaired() then
        pc = _("not paired")
    elseif app.connection:isConnected() then
        pc = _("connected")
    else
        pc = _("not connected right now")
    end
    table.insert(lines, T("%1: %2", _("PC"), pc))
    local info = app.status and app.status()
    if info and info.battery then
        table.insert(lines, T("%1: %2", _("Battery"),
            info.charging and T(_("%1% (charging)"), info.battery) or info.battery .. "%"))
    end
    return table.concat(lines, "\n")
end

function Network:open()
    local actions = {}
    local ts = self:tailscale()
    if ts then
        local up = ts:isUp()
        table.insert(actions, {
            text = up and _("Turn Tailscale off") or _("Turn Tailscale on"),
            callback = function()
                if up then ts:stopTailscale() else ts:startTailscale() end
                self.app.connection:reset("tailscale toggled")
            end,
        })
    end
    if self.app.settings:isPaired() then
        table.insert(actions, { text = _("Test connection"), callback = function() self:test() end })
    end
    self.app.dialog.sheet{ title = _("Connection"), text = self:summary(), actions = actions }
end

-- Connects from scratch and reports which stage fails or how long it took.
function Network:test()
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
                        text = T(_("Tried %1 %2:\n\n%3\n\nIf the proxy isn't reachable, turn Tailscale on: tap the status line at the top of Orca."),
                            target, via, tostring(err)),
                        retry = function() self:test() end,
                    }
                end
            end,
        }
    end)
end

return Network
