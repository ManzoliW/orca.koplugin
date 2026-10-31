--[[
    Git for one workspace: changes with their diffs, commit (with a message
    drafted on the desktop), push and pull, and the branch's pull request:
    create it, follow its checks, re-run failures, ask the agent to fix
    them, merge.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local api = require("orca.api.git")
local style = require("orca.ui.style")
local util = require("orca.core.util")

local Git = {}
Git.__index = Git

function Git.new(app)
    return setmetatable({ app = app }, Git)
end

local STATUS_LETTER = {
    modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", copied = "C",
}

-- Overall PR checks (prForBranch's checksStatus) -> glyph + word.
local CHECKS = {
    success = { glyph = style.glyph.check, word = _("Checks pass") },
    failure = { glyph = style.glyph.cross, word = _("Checks fail") },
    pending = { glyph = style.glyph.pending, word = _("Checks running") },
    neutral = { glyph = style.glyph.skipped, word = _("Checks neutral") },
}

-- One check run's conclusion -> glyph + word.
local CONCLUSION = {
    success = { glyph = style.glyph.check, word = _("Passed") },
    failure = { glyph = style.glyph.cross, word = _("Failed") },
    timed_out = { glyph = style.glyph.cross, word = _("Timed out") },
    cancelled = { glyph = style.glyph.cross, word = _("Cancelled") },
    action_required = { glyph = style.glyph.cross, word = _("Needs action") },
    startup_failure = { glyph = style.glyph.cross, word = _("Didn't start") },
    skipped = { glyph = style.glyph.skipped, word = _("Skipped") },
    neutral = { glyph = style.glyph.skipped, word = _("Neutral") },
    stale = { glyph = style.glyph.skipped, word = _("Stale") },
}
local RUNNING = {
    queued = _("Queued"), in_progress = _("Running"), waiting = _("Waiting"), pending = _("Waiting"),
    requested = _("Queued"),
}

local PR_STATE = { open = _("Open"), closed = _("Closed"), merged = _("Merged"), draft = _("Draft") }
local MERGEABLE = { MERGEABLE = _("mergeable"), CONFLICTING = _("has conflicts"), UNKNOWN = "" }
local REVIEW = { APPROVED = _("approved"), CHANGES_REQUESTED = _("changes requested"), REVIEW_REQUIRED = _("review required") }

local MERGE_METHODS = {
    { method = "squash", label = _("Squash and merge") },
    { method = "merge", label = _("Create a merge commit") },
    { method = "rebase", label = _("Rebase and merge") },
}

-- Why hostedReview says a PR can't be created yet.
local BLOCKED = {
    dirty = _("Commit your changes first."),
    detached_head = _("The workspace isn't on a branch."),
    default_branch = _("You're on the default branch. Start a workspace on its own branch first."),
    no_upstream = _("Push the branch first."),
    needs_push = _("Push your latest commits first."),
    needs_sync = _("The branch needs syncing with its base. Pull first."),
    auth_required = _("The PC isn't signed in to GitHub. Run gh auth login there."),
    existing_review = _("A pull request already exists."),
    base_not_on_remote = _("The base branch isn't on the remote."),
}

function Git.checkStatus(check)
    if util.str(check.status) ~= "completed" then
        return { glyph = style.glyph.pending, word = RUNNING[util.str(check.status)] or util.str(check.status) }
    end
    local conclusion = util.str(check.conclusion)
    return CONCLUSION[conclusion] or { glyph = style.glyph.skipped, word = conclusion }
end

local function isFailed(check)
    return Git.checkStatus(check).glyph == style.glyph.cross
end

local function stateWord(state)
    state = util.str(state)
    return PR_STATE[state] or state
end

-- Git screen ------------------------------------------------------------------------------

function Git:branchLine(status)
    local branch = api.branch(status.branch)
    if branch == "" then return _("Detached, not on a branch") end
    local up = status.upstream
    if up and up.hasUpstream then
        return T(_("%1 · ↑%2 ↓%3"), branch, util.num(up.ahead), util.num(up.behind))
    end
    return T(_("%1 · not pushed yet"), branch)
end

function Git:entryRow(wt, e)
    local path = util.str(e.path)
    local added, removed = tonumber(e.added), tonumber(e.removed)
    local detail
    if added or removed then
        detail = string.format("+%d −%d", added or 0, removed or 0)
    elseif e.area == "staged" then
        detail = _("staged")
    end
    return {
        glyph = STATUS_LETTER[util.str(e.status)] or "·",
        title = util.basename(path),
        subtitle = path:find("/", 1, true) and util.dirname(path) or nil,
        truncate_left = true,
        detail = detail,
        chevron = true,
        callback = function() self:showDiff(wt, e) end,
    }
end

function Git:screen(wt, status, page)
    local entries = status.entries
    local branch = api.branch(status.branch)

    local pr_rows = {}
    if status.pr then
        local pr = status.pr
        local checks = CHECKS[util.str(pr.checksStatus)]
        table.insert(pr_rows, {
            glyph = checks and checks.glyph or " ",
            title = T("#%1 %2", util.num(pr.number), util.str(pr.title)),
            subtitle = stateWord(pr.state),
            detail = checks and checks.word or nil,
            chevron = true,
            callback = function() self:openPR(wt, pr) end,
        })
    elseif branch ~= "" then
        table.insert(pr_rows, { title = _("Create pull request…"),
            callback = function() self:createPR(wt, branch, page) end })
    end

    local changes = {}
    for _i, e in ipairs(entries) do table.insert(changes, self:entryRow(wt, e)) end
    if #changes == 0 then
        table.insert(changes, { title = _("Nothing to commit. The working tree is clean."), dim = true })
    end

    local actions = {}
    if #entries > 0 then
        table.insert(actions, { title = _("Commit…"), callback = function() self:commit(wt, entries, false, page) end })
        table.insert(actions, { title = _("Commit and push…"), callback = function() self:commit(wt, entries, true, page) end })
    end
    table.insert(actions, { title = _("Push"), callback = function() self:push(wt, branch, page) end })
    table.insert(actions, { title = _("Pull"), callback = function() self:pull(wt, branch, page) end })
    if #entries > 0 then
        table.insert(actions, { title = _("Read all changes as a book"),
            callback = function() self:changesBook(wt, entries) end })
    end

    return {
        title = _("Git"),
        subtitle = self:branchLine(status),
        sections = {
            { title = _("Pull request"), rows = pr_rows },
            { title = #entries > 0 and T(_("Changes (%1)"), #entries) or _("Changes"), rows = changes },
            { title = _("Actions"), rows = actions },
        },
        refresh = function() self:load(wt, page) end,
    }
end

function Git:load(wt, page)
    self.app:request{
        run = function(c) return api.status(c, wt) end,
        done = function(status) page:set(self:screen(wt, status, page)) end,
        on_error = function(err)
            page:set{ title = _("Git"), empty = self.app:explain(err), refresh = function() self:load(wt, page) end }
        end,
    }
end

function Git:open(wt)
    local page = self.app.nav:push{ title = _("Git"), loading = _("Reading git status…") }
    self:load(wt, page)
end

-- Changes ---------------------------------------------------------------------------------

function Git:showDiff(wt, e)
    local path = util.str(e.path)
    self.app:request{
        busy = _("Loading diff…"),
        run = function(c) return api.diffText(c, wt, e) end,
        done = function(text)
            self.app.text.read{
                title = util.basename(path),
                text = text,
                mono = true,
                actions = {
                    { text = _("Read as book"), callback = function()
                        self.app:openAsBook(util.basename(wt.path) .. "-" .. util.basename(path) .. ".diff", text)
                    end },
                    { text = T(_("Ask %1…"), self.app:agentName()), callback = function()
                        self.app.files:askAbout(wt, T(_("my uncommitted changes to %1"), path))
                    end },
                },
            }
        end,
    }
end

function Git:changesBook(wt, entries)
    self.app:request{
        busy = #entries == 1 and _("Collecting the diff…") or T(_("Collecting %1 diffs…"), #entries),
        run = function(c) return api.changesText(c, wt, entries) end,
        done = function(text)
            self.app:openAsBook(util.basename(wt.path) .. "-changes-" .. os.date("%m%d-%H%M"), text)
        end,
    }
end

-- Commit, push, pull ----------------------------------------------------------------------

-- Stages everything, has the desktop draft a message, lets you edit it, commits.
function Git:commit(wt, entries, push, page)
    self.app:request{
        once = true,
        busy = _("Staging and drafting a commit message…"),
        run = function(c) return api.stageAndDraft(c, wt, entries) end,
        done = function(draft) self:askMessage(wt, entries, draft.message, push, page) end,
    }
end

function Git:askMessage(wt, entries, message, push, page)
    local function go(with_push)
        return function(value)
            value = util.trim(value)
            if value == "" then return self:askMessage(wt, entries, value, push, page) end
            self:runCommit(wt, value, with_push, page)
        end
    end
    local commit_text, push_text = _("Commit"), _("Commit and push")
    self.app.text.ask{
        title = #entries == 1 and _("Commit 1 file") or T(_("Commit %1 files"), #entries),
        input = message,
        hint = _("Commit message"),
        multiline = true,
        ok_text = push and push_text or commit_text,
        on_ok = go(push),
        extra = { { text = push and commit_text or push_text, callback = go(not push) } },
    }
end

function Git:runCommit(wt, message, push, page)
    self.app:request{
        once = true,
        busy = push and _("Committing and pushing…") or _("Committing…"),
        run = function(c)
            local res, err = api.commit(c, wt, message)
            if not res then return nil, err end
            if push then return api.push(c, wt) end
            return res
        end,
        done = function()
            self.app:toast(push and _("Committed and pushed.") or _("Committed."), 2)
            self:load(wt, page)
        end,
    }
end

function Git:push(wt, branch, page)
    self.app:request{
        once = true,
        busy = branch ~= "" and T(_("Pushing %1…"), branch) or _("Pushing…"),
        run = function(c) return api.push(c, wt) end,
        done = function()
            self.app:toast(_("Pushed."), 2)
            self:load(wt, page)
        end,
    }
end

function Git:pull(wt, branch, page)
    self.app:request{
        once = true,
        busy = branch ~= "" and T(_("Pulling into %1…"), branch) or _("Pulling…"),
        run = function(c) return api.pull(c, wt) end,
        done = function()
            self.app:toast(_("Pulled."), 2)
            self:load(wt, page)
        end,
    }
end

-- Creating a pull request -----------------------------------------------------------------

function Git:createPR(wt, branch, page)
    self.app:request{
        busy = _("Checking the branch…"),
        run = function(c) return api.prEligibility(c, wt, branch) end,
        done = function(el)
            local review = util.tbl(el.review)
            if util.str(review.url) ~= "" then
                return self.app.dialog.alert{ title = _("Already open"),
                    text = T(_("This branch already has a pull request:\n%1"), util.str(review.url)) }
            end
            if not el.canCreate then
                local reason = util.str(el.blockedReason)
                return self.app.dialog.alert{ title = _("Can't create a pull request yet"),
                    text = BLOCKED[reason] or reason }
            end
            local function create(draft)
                return function(title) self:submitPR(wt, el, util.trim(title), draft, page) end
            end
            self.app.text.ask{
                title = T(_("Pull request into %1"), util.str(el.defaultBaseRef)),
                input = util.str(el.title) ~= "" and util.str(el.title) or branch,
                hint = _("Title"),
                ok_text = _("Create"),
                on_ok = create(false),
                extra = { { text = _("Create draft"), callback = create(true) } },
            }
        end,
    }
end

function Git:submitPR(wt, el, title, draft, page)
    self.app:request{
        once = true,
        busy = draft and _("Creating the draft pull request…") or _("Creating the pull request…"),
        run = function(c) return api.createPR(c, wt, el, title, draft) end,
        done = function(r)
            self.app:toast(T(_("Pull request #%1 created."), util.num(r.number)), 3)
            if page then self:load(wt, page) end
        end,
    }
end

-- Pull request screen ---------------------------------------------------------------------

function Git:prScreen(wt, pr, checks, page)
    local agent = self.app:agentName()
    local failed = {}
    local check_rows = {}
    for _i, check in ipairs(checks) do
        if isFailed(check) then failed[#failed + 1] = util.str(check.name) end
        local s = Git.checkStatus(check)
        table.insert(check_rows, {
            glyph = s.glyph, title = util.str(check.name), detail = s.word, chevron = true,
            callback = function() self:showCheck(wt, check) end,
        })
    end
    if #check_rows == 0 then
        table.insert(check_rows, { title = _("No checks on this pull request."), dim = true })
    end

    local facts = {}
    for _i, fact in ipairs({ MERGEABLE[util.str(pr.mergeable)] or util.str(pr.mergeable),
                            REVIEW[util.str(pr.reviewDecision)] or "" }) do
        if fact ~= "" then facts[#facts + 1] = fact end
    end

    local actions = {}
    if pr.state == "open" then
        table.insert(actions, { title = _("Merge…"), callback = function() self:merge(wt, pr, page) end })
    end
    if #failed > 0 then
        table.insert(actions, {
            title = #failed == 1 and _("Re-run the failed check") or T(_("Re-run %1 failed checks"), #failed),
            callback = function() self:rerun(wt, pr) end,
        })
        table.insert(actions, {
            title = T(_("Ask %1 to fix…"), agent),
            callback = function() self:askToFix(wt, pr, failed) end,
        })
    end

    local sections = {
        { rows = { { title = util.str(pr.title), subtitle = #facts > 0 and table.concat(facts, " · ") or nil } } },
    }
    if #actions > 0 then table.insert(sections, { title = _("Actions"), rows = actions }) end
    table.insert(sections, { title = _("Checks"), rows = check_rows })
    return {
        title = T("#%1", util.num(pr.number)),
        subtitle = stateWord(pr.state),
        sections = sections,
        refresh = function() self:loadPR(wt, pr, page, true) end,
    }
end

function Git:loadPR(wt, pr, page, no_cache)
    self.app:request{
        run = function(c) return api.prChecks(c, wt, pr, no_cache) end,
        done = function(checks) page:set(self:prScreen(wt, pr, checks, page)) end,
        on_error = function(err)
            page:set{ title = T("#%1", util.num(pr.number)), empty = self.app:explain(err),
                      refresh = function() self:loadPR(wt, pr, page, true) end }
        end,
    }
end

function Git:openPR(wt, pr)
    local page = self.app.nav:push{ title = T("#%1", util.num(pr.number)), loading = _("Loading checks…") }
    self:loadPR(wt, pr, page)
end

function Git.checkText(check, d)
    local s = Git.checkStatus(check)
    local conclusion = util.str(d.conclusion) ~= "" and util.str(d.conclusion) or s.word
    local lines = { T("%1 %2 · %3", s.glyph, util.str(check.name), conclusion) }
    for _i, key in ipairs({ "title", "summary", "text" }) do
        if util.str(d[key]) ~= "" then lines[#lines + 1] = "\n" .. util.str(d[key]) end
    end
    for _i, job in ipairs(util.tbl(d.jobs)) do
        local state = util.str(job.conclusion) ~= "" and util.str(job.conclusion) or util.str(job.status)
        lines[#lines + 1] = T("\n%1 · %2", util.str(job.name), state)
        for _i, step in ipairs(util.tbl(job.steps)) do
            local conc = util.str(step.conclusion)
            if conc ~= "success" and conc ~= "skipped" then
                local mark = CONCLUSION[conc] and CONCLUSION[conc].glyph or style.glyph.pending
                lines[#lines + 1] = T("  %1 %2", mark, util.str(step.name))
            end
        end
    end
    local annotations = util.tbl(d.annotations)
    if #annotations > 0 then lines[#lines + 1] = "\n" .. _("Annotations:") end
    for _i, a in ipairs(annotations) do
        local where = util.str(a.path)
        local line = tonumber(a.startLine) or tonumber(a.start_line)
        if line then where = where .. ":" .. line end
        lines[#lines + 1] = T("%1  %2", where, util.str(a.message))
    end
    if #lines == 1 then
        lines[#lines + 1] = "\n" .. _("GitHub has no details for this check (it comes from an outside service). Its page:")
    end
    local url = util.str(d.detailsUrl) ~= "" and util.str(d.detailsUrl)
        or util.str(d.url) ~= "" and util.str(d.url) or util.str(check.url)
    lines[#lines + 1] = "\n" .. url
    return table.concat(lines, "\n")
end

function Git:showCheck(wt, check)
    self.app:request{
        busy = T(_("Loading %1…"), util.str(check.name)),
        run = function(c) return api.prCheckDetails(c, wt, check) end,
        done = function(d)
            self.app.text.read{ title = util.str(check.name), text = Git.checkText(check, d) }
        end,
    }
end

function Git:rerun(wt, pr)
    self.app:request{
        once = true,
        busy = _("Re-running failed checks…"),
        run = function(c) return api.rerunFailedChecks(c, wt, pr) end,
        done = function()
            self.app:toast(_("Failed checks restarted. Refresh in a few minutes."), 3)
        end,
    }
end

-- Starts an agent session in the workspace with a prompt about the failures (editable).
function Git:askToFix(wt, pr, failed)
    local number = util.num(pr.number)
    local prompt = T(_("These checks fail on pull request #%1 (%2): %3. Look at their logs (gh pr checks %1), fix the cause, and push."),
        number, util.str(pr.url), table.concat(failed, ", "))
    self.app.create:newSession(wt, prompt)
end

function Git:merge(wt, pr, page)
    local number = util.num(pr.number)
    local base = util.str(pr.baseRefName)
    local actions = {}
    for _i, m in ipairs(MERGE_METHODS) do
        table.insert(actions, { text = m.label, callback = function()
            self.app.dialog.confirm{
                title = T(_("Merge #%1 into %2?"), number, base ~= "" and base or _("its base branch")),
                text = T(_("%1: %2"), m.label, util.str(pr.title)),
                ok_text = _("Merge"),
                on_ok = function() self:runMerge(wt, pr, m.method, page) end,
            }
        end })
    end
    self.app.dialog.sheet{ title = T(_("Merge #%1"), number), actions = actions }
end

function Git:runMerge(wt, pr, method, page)
    local number = util.num(pr.number)
    self.app:request{
        once = true,
        busy = T(_("Merging #%1…"), number),
        run = function(c) return api.mergePR(c, wt, pr, method) end,
        done = function()
            pr.state = "merged"
            self.app:toast(T(_("Pull request #%1 merged."), number), 3)
            if page and page:isShown() then self:loadPR(wt, pr, page, true) end
        end,
    }
end

return Git
