--[[
    Git and pull requests: git.*, github.* and hostedReview.* calls. Params
    and timeouts are the ones verified against the desktop.
--]]

local _ = require("orca.core.i18n")

local Diff = require("orca.render.diff")
local common = require("orca.api.common")
local workspaces = require("orca.api.workspaces")
local util = require("orca.core.util")

local git = {}

function git.branch(name)
    return (util.str(name):gsub("^refs/heads/", ""))
end

-- git.status plus upstream (ahead/behind) and the branch's open PR, if any.
-- The extras are best effort: a failure there leaves them nil.
function git.status(c, wt)
    local status, err = c:call("git.status", { worktree = common.wt(wt), includeLineStats = true }, common.TIMEOUT.slow)
    if not status then return nil, err end
    local up = c:call("git.upstreamStatus", { worktree = common.wt(wt) }, 30)
    status.upstream = type(up) == "table" and up or nil
    local branch = git.branch(status.branch)
    local repo = common.repoId(wt)
    if branch ~= "" and repo then
        local found = c:call("github.prForBranch", { repo = "id:" .. repo, branch = branch }, common.TIMEOUT.slow)
        if type(found) == "table" and found.kind == "found" and type(found.pr) == "table" then
            status.pr = found.pr
        end
    end
    status.entries = util.tbl(status.entries)
    return status
end

-- Unified diff text for one status entry.
function git.diffText(c, wt, e)
    if e.status == "untracked" then
        local f, err = workspaces.readFile(c, wt, e.path, 30)
        if not f then return nil, err end
        return (Diff.unified("", f.content))
    end
    local params = { worktree = common.wt(wt), filePath = e.path, staged = e.area == "staged" }
    if util.str(e.oldPath) ~= "" then params.oldPath = e.oldPath end
    local d, err = c:call("git.diff", params, 30)
    if not d then return nil, err end
    if d.kind == "binary" then return _("(binary file)") end
    local text = Diff.unified(util.str(d.originalContent), util.str(d.modifiedContent))
    return text ~= "" and text or _("(no textual changes)")
end

-- Every entry's diff, one after another, for reading as a book.
function git.changesText(c, wt, entries)
    local rule = string.rep("=", 40)
    local parts = {}
    for _i, e in ipairs(entries) do
        local text = git.diffText(c, wt, e) or _("(could not read)")
        parts[#parts + 1] = rule .. "\n" .. util.str(e.path) .. "\n" .. rule .. "\n" .. text
    end
    return table.concat(parts, "\n\n")
end

-- Stages every entry, then lets the desktop's agent draft a message ("" if it can't).
function git.stageAndDraft(c, wt, entries)
    local paths = {}
    for _i, e in ipairs(entries) do
        paths[#paths + 1] = e.path
        if util.str(e.oldPath) ~= "" then paths[#paths + 1] = e.oldPath end
    end
    local ok, err = c:call("git.bulkStage", { worktree = common.wt(wt), filePaths = paths }, common.TIMEOUT.slow)
    if not ok then return nil, err end
    local m = c:call("git.generateCommitMessage", { worktree = common.wt(wt) }, 180)
    return { message = type(m) == "table" and m.success and util.str(m.message) or "" }
end

function git.commit(c, wt, message)
    local res, err = c:call("git.commit", { worktree = common.wt(wt), message = message }, common.TIMEOUT.slow)
    if not res then return nil, err end
    if res.success == false then
        return nil, util.str(res.error) ~= "" and res.error or _("commit failed")
    end
    return res
end

function git.push(c, wt)
    return c:call("git.push", { worktree = common.wt(wt) }, 120)
end

function git.pull(c, wt)
    return c:call("git.pull", { worktree = common.wt(wt) }, 120)
end

local function repo(wt)
    return "id:" .. util.str(common.repoId(wt))
end

function git.prEligibility(c, wt, branch)
    return c:call("hostedReview.getCreationEligibility",
        { repo = repo(wt), branch = branch, worktree = common.wt(wt) }, common.TIMEOUT.slow)
end

-- el: the eligibility result (provider, base, head, body come from it).
function git.createPR(c, wt, el, title, draft)
    local r, err = c:call("hostedReview.create", {
        repo = repo(wt), worktree = common.wt(wt),
        provider = el.provider, base = el.defaultBaseRef, head = el.head,
        title = title, body = el.body, draft = draft,
    }, 120)
    if not r then return nil, err end
    if not r.ok then return nil, util.str(r.error) ~= "" and r.error or util.str(r.code) end
    return r
end

function git.prChecks(c, wt, pr, no_cache)
    local r, err = c:call("github.prChecks",
        { repo = repo(wt), prNumber = pr.number, headSha = pr.headSha, noCache = no_cache }, common.TIMEOUT.slow)
    if not r then return nil, err end
    return type(r.checks) == "table" and r.checks or r
end

function git.prCheckDetails(c, wt, check)
    return c:call("github.prCheckDetails", {
        repo = repo(wt), checkRunId = check.checkRunId,
        workflowRunId = check.workflowRunId, checkName = check.name, url = check.url,
    }, common.TIMEOUT.slow)
end

local function failed(r)
    if r.ok == false or util.str(r.error) ~= "" then
        local msg = util.str(r.error) ~= "" and r.error or util.str(r.message)
        return msg ~= "" and msg or _("the desktop refused")
    end
end

function git.rerunFailedChecks(c, wt, pr)
    local r, err = c:call("github.rerunPRChecks", {
        repo = repo(wt), prNumber = pr.number, headSha = pr.headSha, failedOnly = true,
    }, 120)
    if not r then return nil, err end
    local msg = r.ok == false and failed(r)
    if msg then return nil, msg end
    return r
end

-- method: "squash" | "merge" | "rebase"
function git.mergePR(c, wt, pr, method)
    local r, err = c:call("github.mergePR", { repo = repo(wt), prNumber = pr.number, method = method }, 120)
    if not r then return nil, err end
    local msg = failed(r)
    if msg then return nil, msg end
    return r
end

return git
