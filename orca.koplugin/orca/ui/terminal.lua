--[[
    The full-screen session view: title bar (‹ back, ↻ refresh, workspace and
    status underneath), the terminal's screen in monospace, and a key bar.

        local view = Terminal.new{ title, subtitle, font_size,
                                   on_key = function(id) end,  -- see Terminal.KEYS
                                   on_close = function() end,  -- once, however it closed
                                   on_refresh = function() end }
        view:setText(text)      -- keeps the scroll position unless at the bottom
        view:setSubtitle(s)
        view:viewport()         -- { cols, rows } of text that fit
        view:close()

    E-ink: only the text area is refreshed on updates ("ui"), with a
    "flashui" every few updates to clear ghosting; "full" when opening.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local RenderText = require("ui/rendertext")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")

local kit = require("orca.ui.kit")
local style = require("orca.ui.style")

local FLASH_EVERY = 6

-- Key bar rows: id is what on_key receives. Esc and Ctrl-C sit on another
-- row than Enter so a slip doesn't cancel what you meant to confirm.
-- Labels stay ASCII/basic arrows: ⇧ and ⏎ aren't sure to be in the UI fonts.
local KEYS = {
    { { id = "1", text = "1" }, { id = "2", text = "2" }, { id = "3", text = "3" },
      { id = "esc", text = "Esc" }, { id = "ctrl-c", text = "Ctrl-C" } },
    { { id = "up", text = "↑" }, { id = "down", text = "↓" }, { id = "tab", text = "Tab" },
      { id = "shift-tab", text = "S-Tab" }, { id = "enter", text = "Enter" } },
    { { id = "type", text = _("Type…"), primary = true } },
}

local View = InputContainer:extend{
    covers_fullscreen = true,
    title = nil,
    subtitle = nil,
    font_size = 14,
    on_key = nil,
    on_close = nil,
    on_refresh = nil,
}

function View:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end
    self.updates = 0
    self.text = self.text or _("Connecting…")

    self.title_bar = self:titleBar(w)
    local keys = self:keyBar(w)
    local pad = style.space.s
    local text_h = h - self.title_bar:getSize().h - keys:getSize().h - 2 * pad
    self.scroll = ScrollTextWidget:new{
        text = self.text,
        face = style.mono(self.font_size),
        width = w - 2 * pad,
        height = text_h,
        dialog = self,
    }
    self.scroll:scrollToBottom()
    self.body = VerticalGroup:new{
        align = "left",
        self.title_bar,
        FrameContainer:new{ bordersize = 0, padding = pad, self.scroll },
        keys,
    }
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, background = style.color.page,
        width = w, height = h,
        self.body,
    }
end

function View:titleBar(w)
    return kit.titleBar({
        title = self.title,
        -- Always a second line, so the title bar (and the text area under
        -- it) keeps its height when the status appears or goes.
        subtitle = (self.subtitle and self.subtitle ~= "") and self.subtitle or " ",
        on_back = function() self:close() end,
        actions = { { glyph = style.glyph.refresh, callback = function()
            if self.on_refresh then self.on_refresh() end
        end } },
    }, w)
end

function View:keyBar(w)
    local inner = w - 2 * style.space.s
    local group = VerticalGroup:new{
        align = "center",
        LineWidget:new{ dimen = Geom:new{ w = w, h = style.line }, background = style.color.line },
    }
    for _i, row in ipairs(KEYS) do
        local buttons = {}
        for i, key in ipairs(row) do
            buttons[i] = {
                text = key.text,
                primary = key.primary,
                callback = function() if self.on_key then self.on_key(key.id) end end,
            }
        end
        table.insert(group, VerticalSpan:new{ width = style.space.xs })
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = w, h = style.min_target },
            kit.buttonRow(buttons, inner, style.min_target),
        })
    end
    table.insert(group, VerticalSpan:new{ width = style.space.s })
    return group
end

function View:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
    return true
end

local function atBottom(tw)
    return tw.virtual_line_num + tw.lines_per_page > #tw.vertical_string_list
end

function View:refreshText()
    self.updates = self.updates + 1
    local mode = self.updates % FLASH_EVERY == 0 and "flashui" or "ui"
    UIManager:setDirty(self, function() return mode, self.scroll.dimen end)
end

function View:setText(text)
    if self.closed or text == self.text then return end
    self.text = text
    local tw = self.scroll.text_widget
    local follow = atBottom(tw)
    local top = tw.virtual_line_num
    tw:setText(text)
    if follow then
        tw:scrollToBottom()
    else
        -- The user scrolled up to read: stay on the same lines.
        local last_top = math.max(1, #tw.vertical_string_list - tw.lines_per_page + 1)
        top = math.min(top, last_top)
        if tw.virtual_line_num ~= top then
            tw.virtual_line_num = top
            tw:free(false)
            tw:_updateLayout()
        end
    end
    self.scroll:resetScroll()
    self:refreshText()
end

function View:setSubtitle(subtitle)
    if self.closed or subtitle == self.subtitle then return end
    self.subtitle = subtitle
    local w = self.dimen.w
    local old = self.title_bar
    self.title_bar = self:titleBar(w)
    self.body[1] = self.title_bar
    self.body:resetLayout()
    old:free()
    local h = self.title_bar:getSize().h
    UIManager:setDirty(self, function() return "ui", Geom:new{ x = 0, y = 0, w = w, h = h } end)
end

-- Columns and rows of monospace text that fit in the text area.
function View:viewport()
    local tw = self.scroll.text_widget
    local sample = string.rep("M", 20)
    local char_w = RenderText:sizeUtf8Text(0, Screen:getWidth(), tw.face, sample).x / #sample
    local cols = math.floor(tw.width / char_w) - 1
    local rows = math.floor(tw.height / tw.line_height_px)
    return {
        cols = math.max(20, math.min(cols, 1024)),
        rows = math.max(8, math.min(rows, 500)),
    }
end

function View:onClose()
    self:close()
    return true
end

function View:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "full")
    if self.on_close then self.on_close() end
end

local Terminal = { KEYS = KEYS, View = View }

-- Builds the view and shows it.
function Terminal.new(opts)
    local view = View:new(opts)
    UIManager:show(view, "full")
    return view
end

return Terminal
