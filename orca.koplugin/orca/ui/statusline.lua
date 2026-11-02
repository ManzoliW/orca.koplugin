--[[
    The thin line above every Orca screen: the clock on the left, Tailscale,
    the PC link and the battery on the right. Orca covers the whole screen
    (and koreader-patches/ hides the Kindle's own bar), so this is the only
    place they show while you're in it.

        info = { clock = "14:32", battery = 78, charging = false,
                 tailscale = true | false | nil (plugin not installed),
                 pc = true | false }

    StatusLine.ticker redraws only the line, once a minute, while its owner
    is on screen. With on_tap, the whole line is a button (the connection
    card: features/network).
--]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local _ = require("orca.core.i18n")

local kit = require("orca.ui.kit")
local style = require("orca.ui.style")

local StatusLine = {}

local LOW_BATTERY = 20  -- % drawn bold

-- widget with pad on both sides
local function inset(widget, pad)
    return HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, widget, HorizontalSpan:new{ width = pad } }
end

local function dot(on) return on and style.glyph.needs or style.glyph.done end

-- "Tailscale ● · PC ○ · 78%"
function StatusLine.text(info)
    local parts = {}
    if info.tailscale ~= nil then table.insert(parts, "Tailscale " .. dot(info.tailscale)) end
    if info.pc ~= nil then table.insert(parts, _("PC") .. " " .. dot(info.pc)) end
    if info.battery then
        table.insert(parts, info.battery .. "%" .. (info.charging and " +" or ""))
    end
    return table.concat(parts, " · ")
end

function StatusLine.build(info, width, on_tap)
    local pad = style.space.s
    local h = style.status_height
    local inner = Geom:new{ w = width - 2 * pad, h = h }
    local low = info.battery and info.battery <= LOW_BATTERY and not info.charging
    local line = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = width, h = h },
            inset(kit.text(info.clock or "", "detail", { bold = true }), pad) },
        RightContainer:new{ dimen = Geom:new{ w = width, h = h },
            inset(kit.text(StatusLine.text(info), "detail", { bold = low, dim = not low,
                                                                 max_width = inner.w * 0.75 }), pad) },
    }
    return on_tap and kit.Tappable:new{ callback = on_tap, line } or line
end

--[[
    source() returns info; place(widget) swaps the new line into the owner's
    layout. start() after the owner is shown; stop() when it closes.
--]]
function StatusLine.ticker(owner, source, width, place, on_tap)
    local t = {}
    local function untilNextMinute() return 60 - tonumber(os.date("%S")) + 1 end
    function t.tick()
        if not UIManager:isWidgetShown(owner) then return end
        local line = StatusLine.build(source(), width, on_tap)
        place(line)
        UIManager:setDirty(owner, function()
            return "ui", Geom:new{ x = 0, y = 0, w = width, h = line:getSize().h }
        end)
        UIManager:scheduleIn(untilNextMinute(), t.tick)
    end
    function t.start()
        UIManager:unschedule(t.tick)
        UIManager:scheduleIn(untilNextMinute(), t.tick)
    end
    function t.stop() UIManager:unschedule(t.tick) end
    return t
end

return StatusLine
