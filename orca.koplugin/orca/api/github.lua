--[[
    GitHub for the dashboard: your open pull requests (with their checks)
    and how many you merged lately, through Orca's github.* methods (the
    desktop's GitHub login), and the public contribution calendar, which the
    Kindle fetches itself (github.com/users/<login>/contributions, no token).
--]]

local common = require("orca.api.common")
local util = require("orca.core.util")

local github = {}

local MINE = "is:pr author:@me"

function github.contributionsUrl(login)
    return "https://github.com/users/" .. login .. "/contributions"
end

--[[
    The contributions page -> { days = { ["YYYY-MM-DD"] = count }, total } or nil.
    Each day is a <td data-date=… id=…>; its count is in the <tool-tip for=id>
    ("3 contributions on …", "No contributions on …").
--]]
function github.parseContributions(html)
    html = util.str(html)
    local dates = {}
    for td in html:gmatch("<td[^>]-ContributionCalendar%-day[^>]*>") do
        local date, id = td:match('data%-date="([%d%-]+)"'), td:match('id="([^"]+)"')
        if date and id then dates[id] = date end
    end
    if not next(dates) then return nil end
    local days = {}
    for id, date in pairs(dates) do days[date] = 0 end
    for id, text in html:gmatch('<tool%-tip[^>]-for="([^"]+)"[^>]*>([^<]*)') do
        local count = text:match("^%s*([%d,]+) contribution")
        if dates[id] and count then days[dates[id]] = tonumber((count:gsub(",", ""))) or 0 end
    end
    local total = html:match("([%d,]+)%s+contributions?%s+in the last year")
    total = total and tonumber((total:gsub(",", ""))) or nil
    if not total then
        total = 0
        for _, n in pairs(days) do total = total + n end
    end
    return { days = days, total = total }
end

-- A parsed calendar as a short string ("total|date=n;date=n…") to pass
-- between processes, and back.
function github.packContributions(cal)
    if not cal then return "" end
    local parts = {}
    for date, n in pairs(cal.days) do table.insert(parts, date .. "=" .. n) end
    table.sort(parts)
    return tostring(cal.total or 0) .. "|" .. table.concat(parts, ";")
end

function github.unpackContributions(text)
    local total, rest = util.str(text):match("^(%d+)|(.*)$")
    if not total then return nil end
    local days = {}
    for date, n in rest:gmatch("([%d%-]+)=(%d+)") do days[date] = tonumber(n) end
    return { days = days, total = tonumber(total) }
end

-- Inside a job: your open pull requests in one repo, each with its overall
-- checks status ("success", "failure", "pending", "neutral" or nil).
function github.openPRs(c, repo)
    local selector = "id:" .. util.str(repo.id)
    local r, err = c:call("github.listWorkItems", { repo = selector, limit = 10, query = MINE .. " is:open" },
        common.TIMEOUT.slow)
    if not r then return nil, err end
    local prs = {}
    for _i, item in ipairs(util.tbl(r.items)) do
        if type(item) == "table" and util.str(item.type) == "pr" then
            local found = c:call("github.prForBranch", { repo = selector, branch = util.str(item.branchName) },
                common.TIMEOUT.slow)
            local pr = type(found) == "table" and type(found.pr) == "table" and found.pr or {}
            table.insert(prs, {
                number = util.num(item.number),
                title = util.str(item.title),
                state = util.str(item.state),
                updatedAt = item.updatedAt,
                branch = util.str(item.branchName),
                headSha = util.str(item.headSha),
                author = util.str(item.author),
                url = util.str(item.url),
                checksStatus = pr.checksStatus,
                repoId = util.str(repo.id),
                repoName = util.basename(repo.path),
            })
        end
    end
    return prs
end

-- Inside a job: pull requests of yours merged in this repo since a date.
function github.mergedSince(c, repo, since_day)
    local n = c:call("github.countWorkItems",
        { repo = "id:" .. util.str(repo.id), query = MINE .. " is:merged merged:>=" .. since_day }, common.TIMEOUT.slow)
    return tonumber(n)
end

-- Inside a job: your GitHub login, from the author of any pull request of yours.
function github.login(c, repos)
    for _i, repo in ipairs(repos) do
        local r = c:call("github.listWorkItems", { repo = "id:" .. util.str(repo.id), limit = 1, query = MINE },
            common.TIMEOUT.slow)
        local item = type(r) == "table" and util.tbl(r.items)[1]
        if type(item) == "table" and util.str(item.author) ~= "" then return item.author end
    end
    return nil
end

return github
