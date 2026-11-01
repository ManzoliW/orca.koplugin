--[[
    Draws a screen spec (title, subtitle, sections of rows and cards; see
    ui/window.lua) into a PNG the size of the screen, for the sleep screen.
    Sections that don't fit are left out; nothing is tappable.

        poster.write(spec, path) -> true or nil, err
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = require("device").screen

local cards = require("orca.ui.cards")
local kit = require("orca.ui.kit")
local style = require("orca.ui.style")

local poster = {}

local function build(spec, width, height)
    local title = kit.titleBar({ title = spec.title, subtitle = spec.subtitle }, width)
    -- Measure parts, not the column: getSize() would cache its layout before
    -- the sections are added.
    local column = VerticalGroup:new{ align = "left", title }
    local used = title:getSize().h
    for _, section in ipairs(spec.sections or {}) do
        local parts = {}
        if section.title and (section.card or #(section.rows or {}) > 0) then
            table.insert(parts, kit.section(section.title, width))
        end
        if section.card then table.insert(parts, cards.build(section.card, width)) end
        for _, row in ipairs(section.rows or {}) do table.insert(parts, kit.row(row, width)) end
        local h = 0
        for _, w in ipairs(parts) do h = h + w:getSize().h end
        if #parts > 0 and used + h <= height then
            for _, w in ipairs(parts) do table.insert(column, w) end
            used = used + h
        end
    end
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = style.color.page,
        width = width, height = height,
        column,
    }
end

function poster.write(spec, path)
    local w, h = Screen:getWidth(), Screen:getHeight()
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local ok, err = pcall(function()
        bb:fill(Blitbuffer.COLOR_WHITE)
        local widget = build(spec, w, h)
        widget:paintTo(bb, 0, 0)
        widget:free()
        bb:writePNG(path)
    end)
    bb:free()
    if not ok then return nil, tostring(err) end
    return true
end

return poster
