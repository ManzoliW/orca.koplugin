--[[
    The plugin's full-screen window: a stack of screens with a title bar,
    sections of rows split into pages, and a page footer. One window serves
    every list (workspaces, terminals, git, files, conversations…): pushing
    a screen drills in, ‹ goes back, ✕ closes the window. Above the title
    bar, the status line (clock, battery, links: ui/statusline); ⚙ next to
    ‹ / ✕ opens the settings; tapping the status line, the connection card.

    screen spec = {
        title, subtitle,
        refresh = function() end,       -- shows ↻ in the title bar
        add = function() end,           -- shows + in the title bar
        sections = { { title = "Needs you", rows = { row, ... } }, ... },
                                        -- or { title, card = card }: see ui/cards
        rows = { row, ... },            -- shorthand for one untitled section
        empty = "Nothing here yet.",    -- shown when there are no rows
        loading = "Loading…",           -- shown instead of rows while set
        on_close = function() end,      -- this screen left the stack
        tabs = { {text, callback, selected}, ... },  -- tab bar at the bottom
    }
    row = see kit.row.

    push/replace return a page handle: page:set(spec) updates that screen
    only while it is still on the stack (a load that finishes after the user
    went back is dropped); page:isShown().
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local StatusLine = require("orca.ui.statusline")
local cards = require("orca.ui.cards")
local kit = require("orca.ui.kit")
local style = require("orca.ui.style")

local Window = InputContainer:extend{
    covers_fullscreen = true,
    stack = nil,
    on_closed = nil,
    status = nil,       -- function() -> status line info; no line without it
    on_settings = nil,  -- shows ⚙ in the title bar
    on_status = nil,    -- tapping the status line
}

function Window:init()
    self.stack = self.stack or {}
    self:fitScreen()
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self[1] = FrameContainer:new{ bordersize = 0, padding = 0, background = style.color.page }
    self:makeTicker()
end

-- Redraws the status line every minute (built for the current width).
function Window:makeTicker()
    if self.ticker then self.ticker.stop() end
    if not self.status then return end
    self.ticker = StatusLine.ticker(self, self.status, self.dimen.w, function(line)
        local group = self[1][1]
        if group and group[1] then
            group[1] = line
            group:resetLayout()
        end
    end, self.on_status)
end

function Window:fitScreen()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

-- Rotation is broadcast top-down, so the screen hasn't turned yet when we
-- get it: lay out again once whoever turns it has.
function Window:onSetRotationMode()
    UIManager:nextTick(function()
        if not UIManager:isWidgetShown(self) then return end
        self:fitScreen()
        self:makeTicker()
        self:render()
    end)
end

function Window:top()
    return self.stack[#self.stack]
end

-- Flattens sections into drawable items (headers and rows) and splits them
-- into pages that fit the body height.
function Window:paginate(spec, width, body_h)
    local items = {}
    local sections = spec.sections or { { rows = spec.rows or {} } }
    local count = 0
    for _, section in ipairs(sections) do
        local rows = section.rows or {}
        if section.card then
            if section.title then
                table.insert(items, { widget = kit.section(section.title, width), header = true })
            end
            table.insert(items, { widget = cards.build(section.card, width) })
            count = count + 1
        elseif #rows > 0 then
            if section.title then
                table.insert(items, { widget = kit.section(section.title, width), header = true })
            end
            for _, row in ipairs(rows) do
                table.insert(items, { widget = kit.row(row, width) })
                count = count + 1
            end
        end
    end
    local pages, page, used = {}, {}, 0
    for i, item in ipairs(items) do
        local h = item.widget:getSize().h
        -- Don't leave a header alone at the bottom of a page.
        local need = h
        if item.header and items[i + 1] then need = h + items[i + 1].widget:getSize().h end
        if used + need > body_h and #page > 0 then
            table.insert(pages, page)
            page, used = {}, 0
        end
        table.insert(page, item.widget)
        used = used + h
    end
    if #page > 0 then table.insert(pages, page) end
    return pages, count
end

function Window:render()
    local spec = self:top()
    if not spec then return end
    local width, height = self.dimen.w, self.dimen.h

    local line = self.status and StatusLine.build(self.status(), width, self.on_status) or VerticalSpan:new{ width = 0 }
    local title = kit.titleBar({
        title = spec.title,
        subtitle = spec.subtitle,
        on_back = #self.stack > 1 and function() self:pop() end or nil,
        on_close = function() self:close() end,
        left_action = self.on_settings and { glyph = style.glyph.settings, callback = self.on_settings } or nil,
        actions = (function()
            local actions = {}
            if spec.add then table.insert(actions, { glyph = style.glyph.add, callback = spec.add }) end
            if spec.refresh then table.insert(actions, { glyph = style.glyph.refresh, callback = spec.refresh }) end
            return actions
        end)(),
    }, width)
    local tabs = spec.tabs and kit.tabBar(spec.tabs, width)
    local tabs_h = tabs and tabs:getSize().h or 0
    -- The page footer only takes room when there is more than one page.
    local footer_h = 0
    local body_h = height - line:getSize().h - title:getSize().h - tabs_h

    local body = VerticalGroup:new{ align = "left" }
    local pages, count = {}, 0
    if spec.loading then
        table.insert(body, kit.note(spec.loading, width))
    else
        pages, count = self:paginate(spec, width, body_h)
        if #pages > 1 then
            footer_h = style.min_target
            body_h = body_h - footer_h
            pages, count = self:paginate(spec, width, body_h)
        end
        if count == 0 then
            table.insert(body, kit.note(spec.empty or _("Nothing here."), width))
        end
    end
    spec.page = math.max(1, math.min(spec.page or 1, #pages))
    for _, w in ipairs(pages[spec.page] or {}) do
        table.insert(body, w)
    end
    self.page_count = #pages

    local footer = HorizontalGroup:new{}
    if #pages > 1 then
        local nav_w = style.min_target * 2
        footer = HorizontalGroup:new{
            align = "center",
            -- As tall as the footer: a taller button would paint over the page above it.
            kit.iconButton(style.glyph.back, function() self:onPrevPage() end, nav_w, spec.page > 1, footer_h),
            HorizontalSpan:new{ width = style.space.xl },
            kit.text(T(_("%1 of %2"), spec.page, #pages), "detail", { dim = true }),
            HorizontalSpan:new{ width = style.space.xl },
            kit.iconButton(style.glyph.chevron, function() self:onNextPage() end, nav_w, spec.page < #pages, footer_h),
        }
    end

    -- FrameContainer's width/height don't count in getSize(): pad the body
    -- ourselves so the footer sits at the bottom.
    local filler = body_h - body:getSize().h
    if filler > 0 then
        table.insert(body, VerticalSpan:new{ width = filler })
        -- getSize() cached the offsets without the filler.
        body:resetLayout()
    end

    self[1][1] = VerticalGroup:new{
        align = "left",
        line,
        title,
        body,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = footer_h }, footer },
        tabs,
    }
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    if self.ticker then self.ticker.start() end
end

function Window:onNextPage()
    local spec = self:top()
    if spec and (spec.page or 1) < (self.page_count or 1) then
        spec.page = spec.page + 1
        self:render()
    end
    return true
end

function Window:onPrevPage()
    local spec = self:top()
    if spec and (spec.page or 1) > 1 then
        spec.page = spec.page - 1
        self:render()
    end
    return true
end

function Window:onSwipe(_, ges)
    local dir = ges and ges.direction
    if dir == "west" or dir == "north" then return self:onNextPage() end
    if dir == "east" or dir == "south" then return self:onPrevPage() end
end

function Window:pop()
    local spec = table.remove(self.stack)
    if spec and spec.on_close then spec.on_close() end
    if #self.stack == 0 then return self:close() end
    self:render()
end

function Window:onClose()
    if #self.stack > 1 then self:pop() else self:close() end
    return true
end

function Window:close()
    for i = #self.stack, 1, -1 do
        local spec = self.stack[i]
        self.stack[i] = nil
        if spec.on_close then spec.on_close() end
    end
    if self.ticker then self.ticker.stop() end
    UIManager:close(self, "full")
    if self.on_closed then self.on_closed() end
end

-- Navigation API ------------------------------------------------------------------

local Nav = {}
Nav.__index = Nav

-- opts: status, on_settings, on_status (see Window)
function Nav.new(opts)
    opts = opts or {}
    return setmetatable({ status = opts.status, on_settings = opts.on_settings, on_status = opts.on_status }, Nav)
end

function Nav:isOpen()
    return self.window ~= nil
end

function Nav:top()
    return self.window and self.window:top()
end

local Page = {}
Page.__index = Page

function Page:isShown()
    local w = self.nav.window
    if not w then return false end
    for _, spec in ipairs(w.stack) do
        if spec == self.spec then return true end
    end
    return false
end

-- Replaces this screen's content (keeping its page when the title is the same).
function Page:set(spec)
    local w = self.nav.window
    if not w then return end
    for i, s in ipairs(w.stack) do
        if s == self.spec then
            if spec.title == s.title then spec.page = s.page end
            spec.on_close = spec.on_close or s.on_close
            w.stack[i] = spec
            self.spec = spec
            if i == #w.stack then w:render() end
            return
        end
    end
end

function Nav:handle(spec)
    return setmetatable({ nav = self, spec = spec }, Page)
end

function Nav:push(spec)
    if not self.window then
        self.window = Window:new{
            stack = { spec },
            status = self.status,
            on_settings = self.on_settings,
            on_status = self.on_status,
            on_closed = function() self.window = nil end,
        }
        self.window:render()
        UIManager:show(self.window, "full")
    else
        table.insert(self.window.stack, spec)
        self.window:render()
    end
    return self:handle(spec)
end

-- Replaces the top screen (or opens the window with it).
function Nav:replace(spec)
    if not self.window then return self:push(spec) end
    local page = self:handle(self.window:top())
    page:set(spec)
    return page
end

function Nav:pop()
    if self.window then self.window:pop() end
end

function Nav:close()
    if self.window then self.window:close() end
end

return Nav
