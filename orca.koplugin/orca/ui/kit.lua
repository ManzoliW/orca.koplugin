--[[
    Building blocks drawn from KOReader widgets in the plugin's style:
    list rows, section headers, title bar, notes and button rows.

    Row anatomy: [glyph] title / subtitle ............ detail ›
--]]

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local style = require("orca.ui.style")

local kit = {}

-- Wraps a widget so tapping it inverts it briefly (e-ink feedback) and then
-- runs callback; holding runs hold_callback.
local Tappable = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
}

function Tappable:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self[1]:getSize().w, h = self[1]:getSize().h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Tappable:onTap()
    if not self.callback then return true end
    if G_reader_settings:nilOrTrue("flash_ui") and self.dimen.x then
        local d = self.dimen
        self.invert = true
        UIManager:widgetInvert(self, d.x, d.y)
        UIManager:setDirty(nil, "fast", d)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
        self.invert = false
        UIManager:widgetInvert(self, d.x, d.y)
        UIManager:setDirty(nil, "fast", d)
    end
    self.callback()
    return true
end

function Tappable:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

kit.Tappable = Tappable

local function text(t, role, opts)
    opts = opts or {}
    return TextWidget:new{
        text = t,
        face = opts.face or style.face(role, opts.bold),
        bold = opts.bold,
        fgcolor = opts.dim and style.color.dim or style.color.text,
        max_width = opts.max_width,
        truncate_left = opts.truncate_left,
    }
end
kit.text = text

function kit.separator(width, color)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = style.line },
        background = color or style.color.line,
    }
end

--[[
    row = { glyph, title, subtitle, detail, bold, chevron, dim, mono,
            callback, hold_callback }
--]]
function kit.row(row, width)
    local pad = style.space.l
    local glyph_widget = row.glyph and text(row.glyph, "row", { bold = row.bold, dim = row.dim })
    -- Status glyphs fit the column; wider ones (git's "M", "??") get room to breathe.
    local glyph_w = glyph_widget and math.max(style.space.xl, glyph_widget:getSize().w + style.space.m) or 0
    local accessory = row.chevron and style.glyph.chevron or nil
    local accessory_w = accessory and style.space.l or 0

    local detail_widget
    if row.detail and row.detail ~= "" then
        detail_widget = text(row.detail, "detail", { dim = true, max_width = math.floor(width * 0.4) })
    end
    local detail_w = detail_widget and (detail_widget:getSize().w + style.space.s) or 0
    local text_w = width - 2 * pad - glyph_w - detail_w - accessory_w

    local column = VerticalGroup:new{ align = "left" }
    table.insert(column, text(row.title or "", "row", {
        bold = row.bold, dim = row.dim, max_width = text_w,
        face = row.mono and style.mono(style.size.row - 2) or nil,
    }))
    if row.subtitle and row.subtitle ~= "" then
        table.insert(column, VerticalSpan:new{ width = math.floor(style.space.xs / 2) })
        table.insert(column, text(row.subtitle, "detail", {
            dim = true, max_width = text_w, truncate_left = row.truncate_left,
            face = row.mono and style.mono(style.size.detail - 2) or nil,
        }))
    end
    local min_h = row.subtitle and row.subtitle ~= "" and style.row_height or style.row_height_single
    local h = math.max(min_h, column:getSize().h + 2 * style.space.s)

    local line = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    if glyph_widget then
        table.insert(line, LeftContainer:new{
            dimen = Geom:new{ w = glyph_w, h = h },
            glyph_widget,
        })
    end
    table.insert(line, LeftContainer:new{ dimen = Geom:new{ w = text_w, h = h }, column })
    if detail_widget then
        table.insert(line, RightContainer:new{ dimen = Geom:new{ w = detail_w, h = h }, detail_widget })
    end
    if accessory then
        table.insert(line, RightContainer:new{
            dimen = Geom:new{ w = accessory_w, h = h },
            text(accessory, "row", { dim = true }),
        })
    end
    table.insert(line, HorizontalSpan:new{ width = pad })

    local body = VerticalGroup:new{
        align = "left",
        FrameContainer:new{ bordersize = 0, padding = 0, background = style.color.page, line },
        LeftContainer:new{
            dimen = Geom:new{ w = width, h = style.line },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad + glyph_w },
                kit.separator(width - 2 * pad - glyph_w, style.color.faint),
            },
        },
    }
    if not row.callback and not row.hold_callback then return body end
    return Tappable:new{ callback = row.callback, hold_callback = row.hold_callback, body }
end

-- "NEEDS YOU · 2" style header above a group of rows.
function kit.section(title, width)
    local label = text(title:upper(), "detail", { bold = true, dim = true, max_width = width - 2 * style.space.l })
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = style.space.m },
        HorizontalGroup:new{ HorizontalSpan:new{ width = style.space.l }, label },
        VerticalSpan:new{ width = style.space.xs },
    }
end

-- Centered explanatory text (empty states, loading, errors).
function kit.note(t, width)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = style.row_height * 2 },
        TextBoxWidget:new{
            text = t,
            face = style.face("body"),
            fgcolor = style.color.dim,
            width = width - 2 * style.space.xl,
            alignment = "center",
        },
    }
end

-- A borderless glyph button for title bars. enabled = false draws it grayed out.
function kit.iconButton(glyph, callback, size, enabled)
    return Button:new{
        text = glyph,
        callback = callback,
        enabled = enabled ~= false,
        bordersize = 0,
        width = size or style.min_target,
        height = size or style.min_target,
        text_font_face = "smallinfofont",
        text_font_size = style.size.title + 4,
        text_font_bold = false,
        padding = 0,
    }
end

--[[
    Title bar: back (‹) or close (✕) on the left, centered title and optional
    subtitle, up to two action glyphs on the right.
    opts = { title, subtitle, on_back, on_close, actions = { {glyph, callback} } }
--]]
function kit.titleBar(opts, width)
    local side = style.min_target * 2 + style.space.s
    local center = VerticalGroup:new{ align = "center" }
    table.insert(center, text(opts.title or "", "title", { bold = true, max_width = width - 2 * side }))
    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(center, text(opts.subtitle, "detail", { dim = true, max_width = width - 2 * side }))
    end
    local h = math.max(style.title_height, center:getSize().h + style.space.s)

    local left = HorizontalGroup:new{ HorizontalSpan:new{ width = style.space.xs } }
    if opts.on_back then
        table.insert(left, kit.iconButton(style.glyph.back, opts.on_back))
    elseif opts.on_close then
        table.insert(left, kit.iconButton(style.glyph.close, opts.on_close))
    end
    local right = HorizontalGroup:new{}
    for _, a in ipairs(opts.actions or {}) do
        table.insert(right, kit.iconButton(a.glyph, a.callback))
    end
    table.insert(right, HorizontalSpan:new{ width = style.space.xs })

    return VerticalGroup:new{
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = h },
            LeftContainer:new{ dimen = Geom:new{ w = width, h = h }, left },
            CenterContainer:new{ dimen = Geom:new{ w = width, h = h }, center },
            RightContainer:new{ dimen = Geom:new{ w = width, h = h }, right },
        },
        LineWidget:new{ dimen = Geom:new{ w = width, h = style.border }, background = style.color.text },
    }
end

--[[
    A row of equal-width buttons. button = { text, callback, primary, enabled }
    Primary buttons are drawn filled (white on black): one per row at most.
--]]
function kit.buttonRow(buttons, width, height)
    local gap = style.space.s
    local n = #buttons
    local w = math.floor((width - gap * (n - 1)) / n)
    local group = HorizontalGroup:new{}
    for i, b in ipairs(buttons) do
        if i > 1 then table.insert(group, HorizontalSpan:new{ width = gap }) end
        -- Button's height is its label's: padding and border come on top.
        local button = Button:new{
            text = b.text,
            callback = b.callback,
            enabled = b.enabled ~= false,
            width = w,
            height = (height or style.button_height) - 2 * (style.space.xs + style.border),
            radius = style.radius,
            bordersize = style.border,
            background = b.primary and style.color.text or nil,
            text_font_face = b.mono and "smallinfont" or "smallinfofont",
            text_font_size = style.size.button,
            text_font_bold = b.primary or false,
            padding = style.space.xs,
        }
        -- Button always draws black text; a filled button needs it white.
        if b.primary and button.label_widget then
            button.label_widget.fgcolor = style.color.inverse
            -- A long label becomes a TextBoxWidget, pre-rendered black on black.
            if button.label_widget.update then button.label_widget:update() end
        end
        table.insert(group, button)
    end
    return group
end

return kit
