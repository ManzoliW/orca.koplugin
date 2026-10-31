--[[
    Modal cards in the plugin's style.

    dialog.card{ title, text, mono, buttons = { { {text, callback, primary}, ... }, ... },
                 dismissable, on_dismiss } -> widget (close with dialog.close(w))
        Every button closes the card before its callback runs.
    dialog.confirm{ title, text, ok_text, on_ok, cancel_text, destructive }
        A verb button and Cancel; never OK/Yes/No.
    dialog.sheet{ title, text, actions = { {text, callback}, ... } }
        A stacked list of choices with Cancel at the bottom.
    dialog.alert{ title, text, retry }
        Information or an error; Close (and Retry when given).
    dialog.toast(text, timeout)
        A small card that goes away by itself or on any tap.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local Screen = Device.screen
local _ = require("gettext")

local kit = require("orca.ui.kit")
local style = require("orca.ui.style")

local dialog = {}

local Card = InputContainer:extend{
    modal = true,
    dismissable = true,
    timeout = nil,
    on_dismiss = nil,
}

function Card:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then self.key_events = { Dismiss = { { "Back" } } } end
    self[1] = CenterContainer:new{ dimen = self.dimen, self.frame }
end

function Card:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    if self.timeout then
        self.timer = function() self:dismiss() end
        UIManager:scheduleIn(self.timeout, self.timer)
    end
    return true
end

function Card:onCloseWidget()
    if self.timer then UIManager:unschedule(self.timer) end
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

function Card:dismiss()
    UIManager:close(self)
    if self.on_dismiss then self.on_dismiss() end
end

function Card:onTapOutside(_, ges)
    if not self.dismissable then return true end
    if self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) or self.timeout then
        self:dismiss()
    end
    return true
end

function Card:onDismiss()
    if self.dismissable then self:dismiss() end
    return true
end

local function cardWidth()
    return math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
end

function dialog.card(opts)
    local width = opts.width or cardWidth()
    local inner = width - 2 * style.space.l
    local content = VerticalGroup:new{ align = "left" }
    local card

    if opts.title and opts.title ~= "" then
        table.insert(content, TextBoxWidget:new{
            text = opts.title, face = style.face("row", true), bold = true, width = inner,
        })
        table.insert(content, VerticalSpan:new{ width = style.space.s })
    end
    if opts.text and opts.text ~= "" then
        table.insert(content, TextBoxWidget:new{ text = opts.text, face = style.face("body"), width = inner })
        table.insert(content, VerticalSpan:new{ width = style.space.s })
    end
    if opts.mono and opts.mono ~= "" then
        -- A quoted terminal excerpt: monospace, in a thin frame.
        local max_h = math.floor(Screen:getHeight() * 0.35)
        local box = TextBoxWidget:new{ text = opts.mono, face = style.mono(15), width = inner - 2 * style.space.s }
        if box:getSize().h > max_h then
            box:free()
            box = ScrollTextWidget:new{
                text = opts.mono, face = style.mono(15), width = inner - 2 * style.space.s, height = max_h,
            }
        end
        table.insert(content, FrameContainer:new{
            bordersize = style.line, color = style.color.line, radius = style.radius / 2,
            padding = style.space.s, box,
        })
        table.insert(content, VerticalSpan:new{ width = style.space.s })
    end
    for _, row in ipairs(opts.buttons or {}) do
        local wrapped = {}
        for i, b in ipairs(row) do
            wrapped[i] = {
                text = b.text, primary = b.primary, mono = b.mono, enabled = b.enabled,
                callback = function()
                    UIManager:close(card)
                    if b.callback then b.callback() end
                end,
            }
        end
        table.insert(content, VerticalSpan:new{ width = style.space.s })
        table.insert(content, kit.buttonRow(wrapped, inner))
    end

    local frame = FrameContainer:new{
        background = style.color.page,
        bordersize = style.border,
        radius = style.radius,
        padding = style.space.l,
        content,
    }
    card = Card:new{
        frame = frame,
        dismissable = opts.dismissable ~= false,
        timeout = opts.timeout,
        on_dismiss = opts.on_dismiss,
    }
    UIManager:show(card)
    return card
end

function dialog.close(card)
    if card then UIManager:close(card) end
end

function dialog.isShown(card)
    return card ~= nil and UIManager:isWidgetShown(card)
end

function dialog.confirm(opts)
    return dialog.card{
        title = opts.title,
        text = opts.text,
        buttons = {{
            { text = opts.cancel_text or _("Cancel"), callback = opts.on_cancel },
            { text = opts.ok_text, callback = opts.on_ok, primary = not opts.destructive },
        }},
        on_dismiss = opts.on_cancel,
    }
end

function dialog.sheet(opts)
    local rows = {}
    for _, a in ipairs(opts.actions or {}) do
        table.insert(rows, { { text = a.text, callback = a.callback, enabled = a.enabled } })
    end
    table.insert(rows, { { text = _("Cancel") } })
    return dialog.card{ title = opts.title, text = opts.text, buttons = rows }
end

function dialog.alert(opts)
    local buttons = { { text = _("Close") } }
    if opts.retry then
        buttons = { { text = _("Close") }, { text = _("Retry"), callback = opts.retry, primary = true } }
    end
    return dialog.card{ title = opts.title, text = opts.text, mono = opts.mono, buttons = { buttons } }
end

function dialog.toast(text, timeout)
    return dialog.card{ text = text, timeout = timeout or 3 }
end

return dialog
