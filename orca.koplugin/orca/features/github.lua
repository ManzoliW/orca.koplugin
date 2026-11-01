--[[
    GitHub on Home: your open pull requests across Orca's projects with
    their checks, how many you merged this week, and your contribution
    calendar as a heatmap next to the reading one.

    Pull requests come through Orca (the desktop's GitHub login), one
    background job per project so a tap never waits behind all of them,
    and are reused for 15 minutes. The calendar is GitHub's public page,
    fetched by the Kindle at most twice a day and kept in the settings, so
    it shows straight away (and offline) after a restart. Your login is
    taken from your own pull requests unless set in the menu.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local api = require("orca.api.github")
local heat = require("orca.render.heat")
local style = require("orca.ui.style")
local util = require("orca.core.util")
local workspaces = require("orca.api.workspaces")

local GitHub = {}
GitHub.__index = GitHub

local PRS_FRESH = 900               -- s to reuse pull requests
local CALENDAR_FRESH = 12 * 3600    -- s to reuse the contribution calendar
local STUCK = 300                   -- s after which a refresh that never finished is retried

local CHECKS = {
    success = { glyph = style.glyph.check, word = _("Checks pass") },
    failure = { glyph = style.glyph.cross, word = _("Checks fail") },
    pending = { glyph = style.glyph.pending, word = _("Checks running") },
    neutral = { glyph = style.glyph.skipped, word = _("Checks neutral") },
}

function GitHub.new(app)
    return setmetatable({ app = app }, GitHub)
end

function GitHub:login()
    local user = self.app.settings:get("github_user")
    return util.str(user) ~= "" and user or nil
end

function GitHub:calendar()
    local cal = self.app.settings:get("github_calendar")
    if type(cal) ~= "table" or cal.user ~= self:login() then return nil end
    return cal
end

-- Pull requests and merged counts, a project at a time. on_change() runs
-- once when all are in.
function GitHub:refreshPRs(force, on_change)
    local now = os.time()
    -- A cancelled job never reports back: don't wait on one forever.
    if self.loading and now - self.loading < STUCK then return end
    if not force and self.prs_at and now - self.prs_at < PRS_FRESH then return end
    self.loading = now
    local since = os.date("%Y-%m-%d", now - 7 * 86400)
    local app = self.app
    app:run{
        background = true,
        run = function(c)
            local repos, err = workspaces.repos(c)
            if not repos then return nil, err end
            local login = not self:login() and api.login(c, repos) or nil
            return { repos = repos, login = login }
        end,
        done = function(r)
            if not r then self.loading = nil; return end
            if r.login then app.settings:set("github_user", r.login) end
            local prs, merged, left = {}, 0, #r.repos
            local function finish()
                table.sort(prs, function(a, b) return util.str(a.updatedAt) > util.str(b.updatedAt) end)
                self.prs, self.merged, self.prs_at, self.loading = prs, merged, now, nil
                if on_change then on_change() end
                -- The login may be new: the calendar can follow.
                self:refreshCalendar(false, on_change)
            end
            if left == 0 then return finish() end
            for _i, repo in ipairs(r.repos) do
                app:run{
                    background = true,
                    run = function(c)
                        return { prs = api.openPRs(c, repo) or {}, merged = api.mergedSince(c, repo, since) or 0 }
                    end,
                    done = function(one)
                        if one then
                            for _j, pr in ipairs(one.prs) do table.insert(prs, pr) end
                            merged = merged + one.merged
                        end
                        left = left - 1
                        if left == 0 then finish() end
                    end,
                }
            end
        end,
    }
end

function GitHub:refreshCalendar(force, on_change)
    local login, web = self:login(), self.app.web
    if not login or not web or self.fetching or not self.app.isOnline() then return end
    local cal = self:calendar()
    if not force and cal and os.time() - (cal.at or 0) < CALENDAR_FRESH then return end
    self.fetching = true
    web.fetch(api.contributionsUrl(login), {
        transform = function(html) return api.packContributions(api.parseContributions(html)) end,
    }, function(text)
        self.fetching = false
        local got = text and api.unpackContributions(text)
        if not got then return end
        got.user, got.at = login, os.time()
        self.app.settings:set("github_calendar", got)
        if on_change then on_change() end
    end)
end

function GitHub:refresh(force, on_change)
    self:refreshPRs(force, on_change)
    self:refreshCalendar(force, on_change)
end

function GitHub:prRow(pr)
    local checks = CHECKS[util.str(pr.checksStatus)]
    local parts = { T("%1 #%2", pr.repoName, pr.number) }
    if checks then table.insert(parts, checks.word) end
    local ago = util.ago(pr.updatedAt, os.time())
    if ago ~= "" then table.insert(parts, ago) end
    return {
        glyph = checks and checks.glyph or " ",
        title = pr.title,
        subtitle = table.concat(parts, " · "),
        bold = pr.checksStatus == "failure",
        chevron = true,
        -- The PR screen only needs the project's id from the workspace.
        callback = function()
            self.app.git:openPR({ worktreeId = pr.repoId .. "::" }, pr)
        end,
    }
end

-- Sets the login by hand (empty: learn it again from your pull requests).
function GitHub:askLogin()
    self.app.text.ask{
        title = _("GitHub user"),
        description = _("Whose contributions Home shows. Leave empty to use the author of your pull requests."),
        input = self:login() or "",
        on_ok = function(value)
            value = util.trim(value)
            self.app.settings:set("github_user", value ~= "" and value or nil)
            self.app.settings:set("github_calendar", nil)
            self.prs_at = nil
        end,
    }
end

-- Home sections: { prs = section or nil, calendar = section or nil }
function GitHub:sections()
    local out = {}
    if self.prs and #self.prs > 0 then
        local rows = {}
        for _i, pr in ipairs(self.prs) do table.insert(rows, self:prRow(pr)) end
        out.prs = { title = _("Your pull requests"), rows = rows }
    end
    local cal = self:calendar()
    if cal then
        local parts = { T(_("%1 contributions in the last year"), util.thousands(cal.total)) }
        local streak = heat.streak(cal.days, os.time())
        if streak > 1 then table.insert(parts, T(_("%1-day streak"), streak)) end
        out.calendar = {
            title = T(_("GitHub · %1"), cal.user),
            card = { type = "heatmap", values = cal.days, now = os.time(), caption = table.concat(parts, " · ") },
        }
    end
    return out
end

return GitHub
