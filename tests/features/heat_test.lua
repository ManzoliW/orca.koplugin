-- Heatmap levels, streaks and the grid.
local H = require("tests.harness")
local heat = require("orca.render.heat")

local NOW = os.time{ year = 2026, month = 11, day = 1, hour = 15 }   -- a Sunday
local function day(offset) return heat.day(NOW + offset * 86400) end

H.test("levels split active days at their quartiles", function()
    local values = { a = 10, b = 20, c = 30, d = 40, e = 0 }
    local th = heat.thresholds(values)
    H.eq(#th, 3)
    H.eq(heat.level(0, th), 0)
    H.eq(heat.level(nil, th), 0)
    H.eq(heat.level(10, th), 1)
    H.eq(heat.level(40, th), 4)
    H.eq(heat.level(1000, th), 4)
end)

H.test("streak counts back from today, or from yesterday before reading today", function()
    H.eq(heat.streak({ [day(0)] = 5, [day(-1)] = 5, [day(-2)] = 5, [day(-4)] = 5 }, NOW), 3)
    H.eq(heat.streak({ [day(-1)] = 5, [day(-2)] = 5 }, NOW), 2)
    H.eq(heat.streak({ [day(-2)] = 5 }, NOW), 0)
end)

H.test("grid ends with today's week, Sunday on top, later days marked", function()
    local cols = heat.grid({ [day(0)] = 60, [day(-7)] = 30 }, 3, NOW)
    H.eq(#cols, 3)
    H.eq(cols[3][1].day, day(0))         -- today is Sunday: top of the last column
    H.eq(cols[3][1].level > 0, true)
    H.eq(cols[3][2].future, true)
    H.eq(cols[2][1].day, day(-7))
    H.eq(cols[1][1].day, day(-14))
    H.eq(cols[2][2].future, false)
end)

H.test("last active day and month starts", function()
    H.eq(heat.day(heat.last({ [day(-3)] = 5, [day(-9)] = 7, [day(-1)] = 0 })), day(-3))
    H.eq(heat.last({}), nil)
    local cols = heat.grid({}, 8, NOW)       -- 8 weeks back from 1 Nov crosses into October
    local months = heat.months(cols)
    H.eq(#months, 2)
    H.eq(months[1].label, os.date("%b", os.time{ year = 2026, month = 10, day = 1, hour = 12 }))
    H.eq(months[2].column, 8)
end)
