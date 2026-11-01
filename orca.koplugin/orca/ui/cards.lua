--[[
    Dashboard cards: blocks that sit in a screen's sections next to rows.
    A section holds one with { title, card = {...} }.

    card = { type = "hero", title, text, mono, buttons = { { {text, callback, primary}, ... }, ... } }
        White on black: the one thing that needs you. text is wrapped body
        text; mono is a terminal excerpt.
    card = { type = "gauges", items = { {label, percent, detail}, ... }, callback }
        One line per limit: label, a bar, the percentage and a dim detail.
    card = { type = "tiles", items = { {value, label, callback}, ... } }
        Big numbers side by side.

    E-ink: black, white and two light grays only, so bars and tiles stay
    crisp under "ui" refreshes; the hero is the only filled area.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local kit = require("orca.ui.kit")
local style = require("orca.ui.style")

local cards = {}

local HERO_MONO_LINES = 5

local function padded(widget, width, pad)
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = pad },
        widget,
        HorizontalSpan:new{ width = width - pad - widget:getSize().w },
    }
end

local function tappable(widget, callback)
    if not callback then return widget end
    return kit.Tappable:new{ callback = callback, widget }
end

function cards.hero(card, width)
    local pad = style.space.l
    local inner = width - 2 * pad - 2 * style.space.m
    local column = VerticalGroup:new{ align = "left" }
    table.insert(column, TextWidget:new{
        text = card.title or "",
        face = style.face("row", true),
        bold = true,
        fgcolor = style.color.inverse,
        max_width = inner,
    })
    local function body(t, face)
        table.insert(column, VerticalSpan:new{ width = style.space.s })
        table.insert(column, TextBoxWidget:new{
            text = t,
            face = face,
            width = inner,
            fgcolor = style.color.inverse,
            bgcolor = style.color.text,
        })
    end
    if card.text and card.text ~= "" then body(card.text, style.face("body")) end
    if card.mono and card.mono ~= "" then
        -- The question sits at the end of the excerpt: keep its last lines.
        local lines = {}
        for line in (card.mono .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
        local from = math.max(1, #lines - HERO_MONO_LINES + 1)
        body(table.concat(lines, "\n", from), style.mono(style.size.detail - 2))
    end
    for _, row in ipairs(card.buttons or {}) do
        table.insert(column, VerticalSpan:new{ width = style.space.s })
        table.insert(column, kit.buttonRow(row, inner, style.min_target))
    end
    local frame = FrameContainer:new{
        background = style.color.text,
        bordersize = 0,
        radius = style.radius,
        padding = style.space.m,
        column,
    }
    return VerticalGroup:new{
        VerticalSpan:new{ width = style.space.s },
        padded(frame, width, pad),
        VerticalSpan:new{ width = style.space.s },
    }
end

-- A flat bar: black for the used part, light gray for the rest.
function cards.bar(percent, w, h)
    percent = math.max(0, math.min(100, tonumber(percent) or 0))
    local used = math.floor(w * percent / 100 + 0.5)
    local group = HorizontalGroup:new{}
    if used > 0 then
        table.insert(group, LineWidget:new{ dimen = Geom:new{ w = used, h = h }, background = style.color.text })
    end
    if used < w then
        table.insert(group, LineWidget:new{ dimen = Geom:new{ w = w - used, h = h }, background = style.color.faint })
    end
    return group
end

function cards.gauges(card, width)
    local pad = style.space.l
    local inner = width - 2 * pad
    local label_w = math.floor(inner * 0.18)
    local pct_w = math.floor(inner * 0.12)
    local detail_w = math.floor(inner * 0.3)
    local bar_w = inner - label_w - pct_w - detail_w - 2 * style.space.s
    -- Not a tap target of its own (the whole card is), so rows can be tighter.
    local h = style.min_target - style.space.s
    local column = VerticalGroup:new{ align = "left" }
    for _, item in ipairs(card.items or {}) do
        local pct = math.floor((tonumber(item.percent) or 0) + 0.5)
        table.insert(column, HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            LeftContainer:new{ dimen = Geom:new{ w = label_w, h = h },
                kit.text(item.label or "", "row", { max_width = label_w }) },
            cards.bar(pct, bar_w, style.space.m),
            HorizontalSpan:new{ width = style.space.s },
            RightContainer:new{ dimen = Geom:new{ w = pct_w, h = h },
                kit.text(pct .. "%", "row", { bold = pct >= 90 }) },
            HorizontalSpan:new{ width = style.space.s },
            RightContainer:new{ dimen = Geom:new{ w = detail_w, h = h },
                kit.text(item.detail or "", "detail", { dim = true, max_width = detail_w }) },
        })
    end
    return tappable(column, card.callback)
end

function cards.tiles(card, width)
    local pad = style.space.l
    local items = card.items or {}
    local n = math.max(1, #items)
    local tile_w = math.floor((width - 2 * pad) / n)
    local h = style.row_height + style.space.l
    local group = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(group, LineWidget:new{
                dimen = Geom:new{ w = style.line, h = h - 2 * style.space.m },
                background = style.color.line,
            })
        end
        local tile = CenterContainer:new{
            dimen = Geom:new{ w = tile_w - (i > 1 and style.line or 0), h = h },
            VerticalGroup:new{
                align = "center",
                kit.text(item.value or "–", "stat", { bold = true, max_width = tile_w - style.space.s }),
                kit.text(item.label or "", "detail", { dim = true, max_width = tile_w - style.space.s }),
            },
        }
        table.insert(group, tappable(tile, item.callback))
    end
    return group
end

function cards.build(card, width)
    local build = cards[card.type]
    if type(build) ~= "function" or card.type == "build" or card.type == "bar" then
        return kit.note("?" .. tostring(card.type), width)
    end
    return build(card, width)
end

return cards
