-- GitHub on Home: contribution calendar, open pull requests, merged count.
local H = require("tests.harness")
local api = require("orca.api.github")

local today = os.date("%Y-%m-%d")
local yesterday = os.date("%Y-%m-%d", os.time() - 86400)

-- The shape of github.com/users/<login>/contributions, trimmed.
local PAGE = [[
<h2 class="f4 text-normal mb-2">
      1,234
      contributions
        in the last year
    </h2>
<td tabindex="0" data-ix="0" style="width: 11px" data-date="]] .. yesterday .. [[" id="contribution-day-component-0-0" data-level="2" role="gridcell" data-view-component="true" class="ContributionCalendar-day"></td>
<td tabindex="0" data-ix="1" style="width: 11px" data-date="]] .. today .. [[" id="contribution-day-component-0-1" data-level="0" role="gridcell" data-view-component="true" class="ContributionCalendar-day"></td>
<tool-tip id="tooltip-a" for="contribution-day-component-0-0" popover="manual" class="sr-only">56 contributions on March 22nd.</tool-tip>
<tool-tip id="tooltip-b" for="contribution-day-component-0-1" popover="manual" class="sr-only">No contributions on March 23rd.</tool-tip>
]]

H.test("contribution page parses into days and a total, and survives packing", function()
    local cal = api.parseContributions(PAGE)
    H.eq(cal.total, 1234)
    H.eq(cal.days[yesterday], 56)
    H.eq(cal.days[today], 0)
    local back = api.unpackContributions(api.packContributions(cal))
    H.eq(back.total, 1234)
    H.eq(back.days[yesterday], 56)
    H.eq(api.parseContributions("<html>not found</html>"), nil)
    H.eq(api.unpackContributions(""), nil)
end)

local REPOS = { repos = {
    { id = "r1", path = "C:\\p\\faxa" },
    { id = "r2", path = "C:\\p\\kindle" },
} }

local function results(extra)
    local r = {
        ["repo.list"] = REPOS,
        ["github.listWorkItems"] = function(p)
            if p.repo ~= "id:r1" then return { items = {} } end
            if p.query == "is:pr author:@me" then return { items = { { type = "pr", author = "ManzoliW" } } } end
            return { items = { { type = "pr", number = 116, title = "Fix the thing", state = "open",
                                 branchName = "fix", headSha = "abc", author = "ManzoliW",
                                 updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ") } } }
        end,
        ["github.prForBranch"] = { kind = "found", pr = { number = 116, checksStatus = "failure" } },
        ["github.countWorkItems"] = function(p) return p.repo == "id:r1" and 19 or 7 end,
        ["github.prChecks"] = { checks = {} },
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

local function fakeWeb(fetched)
    return { fetch = function(url, opts, done)
        table.insert(fetched, url)
        done(opts.transform(PAGE))
    end }
end

local function section(spec, prefix)
    for _, s in ipairs(spec.sections or {}) do
        if (s.title or ""):find(prefix, 1, true) == 1 then return s end
    end
    return nil
end

H.test("home lists your open pull requests with checks, and merged this week", function()
    local fetched = {}
    local app, t = H.app({ results = results({ ["stats.summary"] = { totalAgentsSpawned = 3 } }),
                           web = fakeWeb(fetched) })
    app.home:open()
    t.settle()
    local top = t.top()
    local prs = section(top, "Your pull requests")
    H.eq(#prs.rows, 1)
    H.eq(prs.rows[1].title, "Fix the thing")
    H.eq(prs.rows[1].glyph, "✕")
    H.has(prs.rows[1].subtitle, "faxa #116 · Checks fail")
    local merged
    for _, tile in ipairs(section(top, "Activity").card.items) do
        if tile.label == "PRs this week" then merged = tile.value end
    end
    H.eq(merged, "26")

    prs.rows[1].callback()
    t.settle()
    H.eq(t.top().title, "#116")
    H.eq(t.lastCall("github.prChecks").params.repo, "id:r1")
end)

H.test("the login comes from your pull requests, then the calendar is fetched and kept", function()
    local fetched = {}
    local app, t = H.app({ results = results(), web = fakeWeb(fetched) })
    app.home:open()
    t.settle()
    H.eq(app.settings:get("github_user"), "ManzoliW")
    H.eq(fetched[1], "https://github.com/users/ManzoliW/contributions")
    local cal = section(t.top(), "GitHub · ManzoliW")
    H.eq(cal.card.type, "heatmap")
    H.eq(cal.card.values[yesterday], 56)
    H.has(cal.card.caption, "1,234 contributions in the last year")

    -- Kept in the settings: opening again doesn't fetch again.
    app.nav:close()
    app.home:open()
    t.settle()
    H.eq(#fetched, 1)
end)

H.test("a login set by hand wins, and changing it drops the old calendar", function()
    local fetched = {}
    local app, t = H.app({ results = results(), web = fakeWeb(fetched),
                           settings = { pairing_url = "orca://pair?code=x", github_user = "someone" } })
    app.home:open()
    t.settle()
    H.eq(fetched[1], "https://github.com/users/someone/contributions")
    H.eq(#t.called("github.listWorkItems") > 0, true)
    app.github:askLogin()
    t.answer("other")
    H.eq(app.settings:get("github_user"), "other")
    H.eq(app.settings:get("github_calendar"), nil)
end)

H.test("a project whose GitHub calls fail doesn't hold up the rest", function()
    local r = results()
    local list = r["github.listWorkItems"]
    r["github.listWorkItems"] = function(p)
        if p.repo == "id:r2" then return nil, "gh: not a GitHub repo" end
        return list(p)
    end
    r["github.countWorkItems"] = function(p) if p.repo == "id:r2" then return nil, "nope" end return 4 end
    local app, t = H.app({ results = r, web = fakeWeb({}) })
    app.home:open()
    t.settle()
    H.eq(#section(t.top(), "Your pull requests").rows, 1)
    H.eq(app.github.merged, 4)
end)

H.test("no open pull requests: no section", function()
    local r = results()
    r["github.listWorkItems"] = { items = {} }
    local app, t = H.app({ results = r })
    app.home:open()
    t.settle()
    H.eq(section(t.top(), "Your pull requests"), nil)
end)
