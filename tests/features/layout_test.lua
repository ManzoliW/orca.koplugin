-- Home cards: which ones Home and the sleep picture show, and in what order.
local H = require("tests.harness")

local function titles(spec)
    local out = {}
    for _, s in ipairs(spec.sections) do
        if s.title then table.insert(out, (s.title:gsub(" ·.*", ""))) end
    end
    return table.concat(out, ", ")
end

H.test("by default every card shows, in the default order; Home-only cards stay off the sleep screen", function()
    local app = H.app({ quiet = true })
    H.eq(table.concat(app.layout:shown("home"), ","),
        "question,sessions,prs,usage,activity,week,book,reading,github,files")
    H.eq(table.concat(app.layout:shown("sleep"), ","), "question,sessions,usage,week,book,reading,github")
end)

H.test("hiding and moving a card changes Home and the sleep picture", function()
    G_reader_settings = H.store{}
    local library = {
        recent = function() return { { file = "/b.epub", title = "B", percent = 10 } } end,
        readingDays = function() return { [os.date("%Y-%m-%d")] = 600 } end,
        files = function() return {} end,
        cover = function() return nil end,
    }
    local app, t = H.app({ library = library })
    app.layout:toggle("book", "sleep")
    app.layout:move("reading", -1)
    app.layout:move("reading", -1)
    app.layout:toggle("activity", "home")
    H.eq(app.layout:isShown("book", "home"), true)
    H.eq(app.layout:isShown("book", "sleep"), false)

    local spec = app.sleep:posterSpec({ states = {}, usage = nil })
    H.eq(titles(spec), "Sessions, Reading")
    app.home:open()
    t.settle()
    H.has(titles(t.top()), "Reading, This week, Continue reading")
    H.eq(titles(t.top()):find("Activity"), nil)
end)

H.test("cards added in a later version join at their default place", function()
    local app = H.app({ quiet = true, settings = { pairing_url = "x",
        home_layout = { order = { "files", "question", "usage" } } } })
    local order = table.concat(app.layout:order(), ",")
    H.eq(order, "files,question,sessions,prs,usage,activity,week,book,reading,github")
end)

H.test("the Home cards screen: tap a card to hide it or move it; back to the default", function()
    local app, t = H.app({ quiet = true })
    app.layout:open()
    local rows = t.top().sections[1].rows
    H.eq(rows[1].title, "Question waiting for you")
    H.eq(rows[1].subtitle, "Home and sleep screen")
    H.eq(rows[3].title, "Your pull requests"); H.eq(rows[3].subtitle, "Home")

    rows[3].callback()
    H.eq(#t.lastCard().actions, 3, "no sleep screen choice for a Home-only card")
    t.press("Move up")
    H.eq(t.top().sections[1].rows[2].title, "Your pull requests")

    t.top().sections[1].rows[2].callback()
    t.press("Hide on Home")
    H.eq(t.top().sections[1].rows[2].subtitle, "Hidden")
    H.eq(t.top().sections[1].rows[2].dim, true)

    t.top().sections[2].rows[1].callback()
    H.eq(t.top().sections[1].rows[3].title, "Your pull requests")
    H.eq(app.settings:get("home_layout"), nil)
end)
