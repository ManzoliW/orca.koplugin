--[[
    Which cards Home and the sleep picture show, and in what order. One order
    for both; each card can be hidden on either. Cards the sleep picture
    can't draw (they need a tap or data it doesn't fetch) are Home-only.

    Kept in settings home_layout = { order = { id, ... }, hidden = { home = { id = true }, sleep = { ... } } }.
    Cards added in later versions join at their default place.
--]]

local _ = require("orca.core.i18n")

local util = require("orca.core.util")

local Layout = {}
Layout.__index = Layout

-- Default order. sleep = false: not on the sleep picture.
Layout.CARDS = {
    { id = "question", label = _("Question waiting for you") },
    { id = "sessions", label = _("Sessions") },
    { id = "prs", label = _("Your pull requests"), sleep = false },
    { id = "usage", label = _("Claude usage") },
    { id = "activity", label = _("Activity"), sleep = false },
    { id = "week", label = _("This week"), note = _("on the sleep screen on Mondays") },
    { id = "book", label = _("Continue reading") },
    { id = "reading", label = _("Reading") },
    { id = "github", label = _("GitHub contributions") },
    { id = "files", label = _("From Claude"), sleep = false },
}

local BY_ID = {}
for i, card in ipairs(Layout.CARDS) do
    card.rank = i
    BY_ID[card.id] = card
end

function Layout.new(app)
    return setmetatable({ app = app }, Layout)
end

function Layout:saved()
    local saved = util.tbl(self.app.settings:get("home_layout"))
    return util.tbl(saved.order), util.tbl(util.tbl(saved.hidden).home), util.tbl(util.tbl(saved.hidden).sleep)
end

function Layout:save(order, home, sleep)
    self.app.settings:set("home_layout", { order = order, hidden = { home = home, sleep = sleep } })
end

-- Every card id in order: the saved order, with new cards at their default place.
function Layout:order()
    local saved = self:saved()
    local order, seen = {}, {}
    for _i, id in ipairs(saved) do
        if BY_ID[id] and not seen[id] then
            seen[id] = true
            table.insert(order, id)
        end
    end
    for _i, card in ipairs(Layout.CARDS) do
        if not seen[card.id] then
            -- After the last card that comes before it by default.
            local at = 1
            for i, id in ipairs(order) do
                if BY_ID[id].rank < card.rank then at = i + 1 end
            end
            table.insert(order, at, card.id)
        end
    end
    return order
end

function Layout:canShow(id, where)
    return where == "home" or BY_ID[id].sleep ~= false
end

function Layout:isShown(id, where)
    if not self:canShow(id, where) then return false end
    local _order, home, sleep = self:saved()
    return not (where == "home" and home or sleep)[id]
end

-- The ids shown on "home" or "sleep", in order.
function Layout:shown(where)
    local ids = {}
    for _i, id in ipairs(self:order()) do
        if self:isShown(id, where) then table.insert(ids, id) end
    end
    return ids
end

function Layout:toggle(id, where)
    local _order, home, sleep = self:saved()
    local hidden = where == "home" and home or sleep
    hidden[id] = not hidden[id] or nil
    self:save(self:order(), home, sleep)
end

function Layout:move(id, delta)
    local order = self:order()
    for i, other in ipairs(order) do
        if other == id then
            local j = i + delta
            if j >= 1 and j <= #order then order[i], order[j] = order[j], order[i] end
            break
        end
    end
    local _order, home, sleep = self:saved()
    self:save(order, home, sleep)
end

function Layout:reset()
    self.app.settings:set("home_layout", nil)
end

-- Screen ---------------------------------------------------------------------------------

function Layout:where(id)
    local home, sleep = self:isShown(id, "home"), self:isShown(id, "sleep")
    if home and sleep then return _("Home and sleep screen") end
    if home then return _("Home") end
    if sleep then return _("Sleep screen") end
    return _("Hidden")
end

function Layout:screen()
    local rows = {}
    for i, id in ipairs(self:order()) do
        local card = BY_ID[id]
        local hidden = not self:isShown(id, "home") and not self:isShown(id, "sleep")
        table.insert(rows, {
            glyph = tostring(i),
            title = card.label,
            subtitle = self:where(id),
            dim = hidden,
            callback = function() self:choose(id) end,
        })
    end
    return {
        title = _("Home cards"),
        subtitle = _("Order and where each shows"),
        sections = {
            { rows = rows },
            { rows = { { title = _("Back to the default"), callback = function()
                self:reset()
                self:redraw()
            end } } },
        },
    }
end

function Layout:redraw()
    if self.page and self.page:isShown() then self.page:set(self:screen()) end
end

function Layout:choose(id)
    local card = BY_ID[id]
    local actions = {}
    local function add(text, fn)
        table.insert(actions, { text = text, callback = function() fn(); self:redraw() end })
    end
    add(self:isShown(id, "home") and _("Hide on Home") or _("Show on Home"), function() self:toggle(id, "home") end)
    if self:canShow(id, "sleep") then
        add(self:isShown(id, "sleep") and _("Hide on the sleep screen") or _("Show on the sleep screen"),
            function() self:toggle(id, "sleep") end)
    end
    add(_("Move up"), function() self:move(id, -1) end)
    add(_("Move down"), function() self:move(id, 1) end)
    local text = self:canShow(id, "sleep") and card.note
        or not self:canShow(id, "sleep") and _("Only on Home: the sleep screen can't show it.") or nil
    self.app.dialog.sheet{ title = card.label, text = text, actions = actions }
end

function Layout:open()
    self.page = self.app.nav:push(self:screen())
end

return Layout
