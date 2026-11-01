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
    card = { type = "figures", items = { {value, label, note, callback}, ... } }
        Big numbers down the page, each with its label and a dim note.
    card = { type = "book", title, authors, percent, detail, cover = function(w, h), callback }
        A book with its cover and progress.
    card = { type = "heatmap", values = { ["YYYY-MM-DD"] = n }, caption, now, callback }
        Days as squares, darker for more.

    E-ink: black, white and two light grays only, so bars and tiles stay
    crisp under "ui" refreshes; the hero is the only filled area.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local heat = require("orca.render.heat")
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

function cards.figures(card, width)
    local pad = style.space.l
    local value_w = math.floor((width - 2 * pad) * 0.3)
    local text_w = width - 2 * pad - value_w - style.space.m
    local column = VerticalGroup:new{ align = "left" }
    for _, item in ipairs(card.items or {}) do
        local words = VerticalGroup:new{ align = "left", kit.text(item.label or "", "row", { max_width = text_w }) }
        if item.note and item.note ~= "" then
            table.insert(words, kit.text(item.note, "detail", { dim = true, max_width = text_w }))
        end
        local line = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            LeftContainer:new{
                dimen = Geom:new{ w = value_w, h = style.row_height },
                kit.text(item.value or "–", "stat", { bold = true, max_width = value_w }),
            },
            HorizontalSpan:new{ width = style.space.m },
            words,
        }
        table.insert(column, tappable(line, item.callback))
    end
    return column
end

--[[
    A book: its cover (or a framed initial) beside the title, author, a
    progress bar and a detail line. card.cover(w, h) returns a BlitBuffer
    that fits w × h, or nil.
--]]
function cards.book(card, width)
    local pad = style.space.l
    local cover_w, cover_h = style.row_height + style.space.l, style.row_height * 2
    local col_w = width - 2 * pad - cover_w - style.space.l
    local image = card.cover and card.cover(cover_w, cover_h)
    local cover
    if image then
        cover = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            ImageWidget:new{ image = image, image_disposable = false },
        }
    else
        local initial = (card.title or "?"):match("[%z\1-\127\194-\244][\128-\191]*") or "?"
        cover = FrameContainer:new{
            bordersize = style.border,
            padding = 0,
            radius = style.space.xs,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w - 2 * style.border, h = cover_h - 2 * style.border },
                kit.text(initial:upper(), "stat", { bold = true }),
            },
        }
    end
    local column = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = card.title or "",
            face = style.face("row", true),
            bold = true,
            width = col_w,
            height = math.floor(cover_h * 0.45),
            height_overflow_show_ellipsis = true,
        },
    }
    if card.authors and card.authors ~= "" then
        table.insert(column, kit.text(card.authors, "detail", { dim = true, max_width = col_w }))
    end
    table.insert(column, VerticalSpan:new{ width = style.space.m })
    if card.percent then
        table.insert(column, cards.bar(card.percent, col_w, style.space.s))
        table.insert(column, VerticalSpan:new{ width = style.space.s })
    end
    if card.detail and card.detail ~= "" then
        table.insert(column, kit.text(card.detail, "detail", { max_width = col_w }))
    end
    local line = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = pad },
        cover,
        HorizontalSpan:new{ width = style.space.l },
        LeftContainer:new{ dimen = Geom:new{ w = col_w, h = cover_h }, column },
    }
    return tappable(VerticalGroup:new{
        VerticalSpan:new{ width = style.space.s },
        line,
        VerticalSpan:new{ width = style.space.s },
    }, card.callback)
end

-- Heatmap shades (darkness) for levels 0–4; 0 still shows the grid.
local SHADES = { [0] = 0.08, 0.3, 0.55, 0.8, 1 }

--[[
    A GitHub-style heatmap: as many weeks as fit the width, today in the
    last column. card = { values = { ["YYYY-MM-DD"] = n }, caption, now }
--]]
function cards.heatmap(card, width)
    local pad = style.space.l
    local inner = width - 2 * pad
    local gap = math.max(2, math.floor(style.space.xs * 0.75))
    local target = style.space.l - gap
    local weeks = math.max(1, math.floor((inner + gap) / (target + gap)))
    local cell = math.floor((inner - gap * (weeks - 1)) / weeks)
    local columns = heat.grid(card.values or {}, weeks, card.now)
    local grid = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad } }
    for w, days in ipairs(columns) do
        if w > 1 then table.insert(grid, HorizontalSpan:new{ width = gap }) end
        local column = VerticalGroup:new{}
        for d, day in ipairs(days) do
            if d > 1 then table.insert(column, VerticalSpan:new{ width = gap }) end
            if day.future then
                table.insert(column, VerticalSpan:new{ width = cell })
            else
                table.insert(column, LineWidget:new{
                    dimen = Geom:new{ w = cell, h = cell },
                    background = Blitbuffer.gray(SHADES[day.level]),
                })
            end
        end
        table.insert(grid, column)
    end
    local group = VerticalGroup:new{ align = "left" }
    if card.caption and card.caption ~= "" then
        table.insert(group, HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            kit.text(card.caption, "detail", { max_width = inner }),
        })
        table.insert(group, VerticalSpan:new{ width = style.space.s })
    end
    table.insert(group, grid)
    -- Month names under the columns where months begin, skipping any that
    -- would run into the previous one.
    local labels = HorizontalGroup:new{}
    local cursor = 0
    for _, m in ipairs(heat.months(columns)) do
        local x = pad + (m.column - 1) * (cell + gap)
        local label = kit.text(m.label, "detail", { dim = true })
        if x >= cursor + style.space.s and x + label:getSize().w <= width then
            table.insert(labels, HorizontalSpan:new{ width = x - cursor })
            table.insert(labels, label)
            cursor = x + label:getSize().w
        end
    end
    table.insert(group, VerticalSpan:new{ width = style.space.xs })
    table.insert(group, labels)
    table.insert(group, VerticalSpan:new{ width = style.space.s })
    return tappable(group, card.callback)
end

function cards.build(card, width)
    local build = cards[card.type]
    if type(build) ~= "function" or card.type == "build" or card.type == "bar" then
        return kit.note("?" .. tostring(card.type), width)
    end
    return build(card, width)
end

return cards
