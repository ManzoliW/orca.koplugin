--[[
    Starting things: new workspaces (blank or from a GitHub issue or PR),
    cloning and new projects, new sessions and shells in a workspace, and
    sleeping or removing one.

    Mobile clients can't call repo.clone / repo.add, so cloning and new
    projects run `git` and the `orca` CLI in a desktop terminal instead
    (runOnDesktop, also used to continue a conversation on the desktop).
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local api = require("orca.api.workspaces")
local shell = require("orca.core.shell")
local util = require("orca.core.util")

local Create = {}
Create.__index = Create

function Create.new(app)
    return setmetatable({ app = app }, Create)
end

-- "Start something new" ---------------------------------------------------------------

function Create:open()
    local agent = self.app:agentName()
    self.app.nav:push{
        title = _("Start something new"),
        sections = { { rows = {
            { title = T(_("New workspace with %1…"), agent), subtitle = _("In one of your projects"), chevron = true,
              callback = function()
                  self:pickRepo(_("New workspace in…"), function(repo) self:newWorkspace(repo) end)
              end },
            { title = _("From a GitHub issue or PR"), subtitle = _("Open issues and pull requests"), chevron = true,
              callback = function()
                  self:pickRepo(_("Issues and PRs of…"), function(repo) self:openWorkItems(repo) end)
              end },
            { title = _("Clone from GitHub…"), callback = function() self:cloneProject() end },
            { title = _("New empty project…"), callback = function() self:newProject() end },
        } } },
    }
end

-- Projects ------------------------------------------------------------------------------

function Create:pickRepo(title, on_pick)
    local page = self.app.nav:push{ title = title, loading = _("Loading projects…") }
    local function load()
        self.app:request{
            run = function(c) return api.repos(c) end,
            done = function(repos)
                local rows = {}
                for _i, repo in ipairs(repos) do
                    table.insert(rows, {
                        title = api.repoName(repo),
                        subtitle = util.unixPath(repo.path),
                        truncate_left = true,
                        detail = api.isRemote(repo) and util.str(repo.executionHostId) or nil,
                        chevron = true,
                        callback = function() on_pick(repo) end,
                    })
                end
                page:set{
                    title = title,
                    sections = { { rows = rows } },
                    empty = _("No projects in Orca yet. Go back and clone one, or start a new empty project."),
                    refresh = load,
                }
            end,
            on_error = function(err)
                page:set{ title = title, empty = self.app:explain(err), refresh = load }
            end,
        }
    end
    load()
end

-- Where new clones and projects go: the setting, else the folder most local
-- projects live in.
function Create:projectsDir(repos)
    local dir = self.app.settings:get("projects_dir")
    if dir then return dir end
    local counts, best, best_n = {}, nil, 0
    for _i, repo in ipairs(repos or {}) do
        if not api.isRemote(repo) then
            local parent = util.dirname(repo.path)
            counts[parent] = (counts[parent] or 0) + 1
            if counts[parent] > best_n then best, best_n = parent, counts[parent] end
        end
    end
    return best
end

-- New workspace -------------------------------------------------------------------------

-- Asks what the agent should do, then creates a workspace with it running.
-- opts: name, prompt, description, params (extra worktree.create params).
function Create:newWorkspace(repo, opts)
    opts = opts or {}
    local agent = self.app:agentName()
    self.app.text.ask{
        title = T(_("New workspace in %1"), api.repoName(repo)),
        description = opts.description or T(_("What should %1 work on? Leave empty to start a blank session."), agent),
        input = opts.prompt or "",
        multiline = true,
        ok_text = _("Start"),
        on_ok = function(prompt)
            prompt = util.trim(prompt)
            local params = {
                repo = "id:" .. util.str(repo.id),
                name = opts.name or util.slug(prompt),
                startupAgent = self.app:agent(),
                createdWithAgent = self.app:agent(),
                setupDecision = "inherit",
                clientMutationId = util.mutationId("wt"),
            }
            if prompt ~= "" then params.startupPrompt = prompt end
            for k, v in pairs(opts.params or {}) do params[k] = v end
            self:createWorkspace(params)
        end,
    }
end

function Create:createWorkspace(params)
    self.app:request{
        once = true,
        busy = T(_("Creating workspace %1…\n(cloning and setup can take a while)"), params.name),
        run = function(c) return api.create(c, params) end,
        done = function(result)
            local wt = util.tbl(result.worktree)
            local name = util.str(wt.displayName) ~= "" and util.str(wt.displayName) or params.name
            local warnings = {}
            for _i, w in ipairs(util.tbl(result.warnings)) do
                warnings[#warnings + 1] = type(w) == "table" and util.str(w.message) or util.str(w)
            end
            if #warnings > 0 then self.app:toast(table.concat(warnings, "\n"), 4) end
            local handle = util.str(result.agentTerminalHandle)
            if handle == "" then handle = util.str(util.tbl(result.startupTerminal).handle) end
            self.app.nav:close()
            if handle ~= "" then
                self.app.session:open({ handle = handle, title = name }, wt)
            else
                self.app:toast(T(_("Workspace %1 created."), name))
            end
        end,
    }
end

-- GitHub issues and PRs -----------------------------------------------------------------

function Create:workItemsScreen(repo, items, query, page)
    local rows = {}
    for _i, item in ipairs(items) do
        if item.state ~= "closed" and item.state ~= "merged" then
            table.insert(rows, {
                title = T("#%1 %2", util.num(item.number), util.str(item.title)),
                detail = item.type == "pr" and _("PR") or _("Issue"),
                callback = function() self:startOnWorkItem(repo, item) end,
            })
        end
    end
    if #rows == 0 then
        table.insert(rows, { title = query ~= "" and _("Nothing open matches. Try other words.")
            or _("Nothing open. Search to find something else."), dim = true })
    end
    return {
        title = _("Issues and PRs"),
        subtitle = query ~= "" and T(_("“%1”"), query) or api.repoName(repo),
        sections = {
            { rows = { { title = _("Search…"), callback = function()
                self.app.text.ask{
                    title = _("Search issues and PRs"),
                    description = _("Words to look for (GitHub search)."),
                    input = query,
                    ok_text = _("Search"),
                    on_ok = function(q) self:loadWorkItems(repo, util.trim(q), page) end,
                }
            end } } },
            { title = _("Open"), rows = rows },
        },
        refresh = function() self:loadWorkItems(repo, query, page) end,
    }
end

function Create:loadWorkItems(repo, query, page)
    self.app:request{
        run = function(c) return api.workItems(c, repo, query) end,
        done = function(items) page:set(self:workItemsScreen(repo, items, query, page)) end,
        on_error = function(err)
            page:set{ title = _("Issues and PRs"), empty = self.app:explain(err),
                      refresh = function() self:loadWorkItems(repo, query, page) end }
        end,
    }
end

function Create:openWorkItems(repo)
    local page = self.app.nav:push{ title = _("Issues and PRs"), loading = _("Loading issues and pull requests…") }
    self:loadWorkItems(repo, "", page)
end

function Create:startOnWorkItem(repo, item)
    local is_pr = item.type == "pr"
    local number = util.num(item.number)
    local prompt = is_pr
        and T(_("Review pull request #%1 (%2): %3"), number, util.str(item.url), util.str(item.title))
        or T(_("Work on GitHub issue #%1 (%2): %3"), number, util.str(item.url), util.str(item.title))
    local params = {
        displayName = T("#%1 %2", number, util.str(item.title)):sub(1, 60),
        displayNameKind = "generated",
        startupDraft = item.url,
    }
    if is_pr then params.linkedPR = item.number else params.linkedIssue = item.number end
    local function go(extra)
        for k, v in pairs(extra or {}) do params[k] = v end
        self:newWorkspace(repo, {
            name = (is_pr and "pr" or "issue") .. "-" .. number,
            prompt = prompt,
            description = T(_("%1 starts with this prompt; edit it if you like."), self.app:agentName()),
            params = params,
        })
    end
    if not is_pr then return go() end
    self.app:request{
        busy = _("Looking up the pull request…"),
        run = function(c) return api.resolvePrBase(c, repo, item) end,
        done = function(base)
            go({ baseBranch = base.baseBranch, compareBaseRef = base.compareBaseRef,
                 branchNameOverride = base.branchNameOverride, pushTarget = base.pushTarget })
        end,
    }
end

-- Desktop terminal: clone, new project, resume --------------------------------------------

--[[
    Runs commands (joined with ";") in a new background terminal and opens it.
    With cwd, it runs in the workspace checked out there, or cd's into cwd from
    the first workspace.
--]]
function Create:runOnDesktop(title, commands, cwd)
    self.app:request{
        once = true,
        busy = _("Starting a desktop terminal…"),
        run = function(c)
            local worktrees, err = c:listWorktrees()
            if not worktrees then return nil, err end
            if not worktrees[1] then return nil, _("Orca has no workspace to open a terminal in. Create one on the PC first.") end
            local target, list = worktrees[1], commands
            if cwd then
                target = nil
                for _i, w in ipairs(worktrees) do
                    if util.unixPath(w.path):lower() == util.unixPath(cwd):lower() then target = w end
                end
                if not target then
                    target = worktrees[1]
                    local cd, qerr = shell.cmd(shell.flavor(cwd), "cd", util.unixPath(cwd))
                    if not cd then return nil, T(_("Can't go to %1: it %2."), cwd, qerr) end
                    list = { cd }
                    for _i, cmd in ipairs(commands) do list[#list + 1] = cmd end
                end
            end
            local term, terr = api.runCommand(c, target, shell.join(list), title)
            if not term then return nil, terr end
            return { term = { handle = term.handle, title = title }, wt = target }
        end,
        done = function(r)
            self.app.nav:close()
            self.app.session:open(r.term, r.wt)
        end,
    }
end

-- Asks for a name or URL with the projects folder shown (and changeable).
-- on_ok(value, dir, flavor).
function Create:askProjectPlace(opts)
    self.app:request{
        busy = _("Loading projects…"),
        run = function(c) return api.repos(c) end,
        done = function(repos)
            local dir = self:projectsDir(repos)
            local function askFolder(then_ask)
                self.app.text.ask{
                    title = _("Projects folder on the PC"),
                    description = _("New projects go here. Example: C:/Users/me/projects"),
                    input = dir,
                    ok_text = _("Save"),
                    on_ok = function(v)
                        v = util.unixPath(util.trim(v))
                        self.app.settings:set("projects_dir", v ~= "" and v or nil)
                        dir = self:projectsDir(repos)
                        then_ask()
                    end,
                }
            end
            local ask
            ask = function(input)
                self.app.text.ask{
                    title = opts.title,
                    description = T(_("%1\n\nFolder: %2"), opts.description, dir or _("not set yet; tap Folder…")),
                    input = input or "",
                    hint = opts.hint,
                    ok_text = opts.ok_text,
                    extra = { { text = _("Folder…"), callback = function(v) askFolder(function() ask(v) end) end } },
                    on_ok = function(value)
                        value = util.trim(value)
                        if value == "" then return ask("") end
                        if not dir then return askFolder(function() ask(value) end) end
                        opts.on_ok(value, dir, shell.flavor(dir))
                    end,
                }
            end
            ask("")
        end,
    }
end

-- "owner/repo", "github.com/owner/repo" or a full URL -> clone URL, folder name.
function Create.cloneUrl(input)
    input = util.str(input):gsub("%.git$", "")
    local owner, name = input:match("^([%w%._%-]+)/([%w%._%-]+)$")
    if owner then return "https://github.com/" .. owner .. "/" .. name .. ".git", name end
    if input:match("^github%.com/") then input = "https://" .. input end
    name = input:match("([%w%._%-]+)/?$")
    if not name or not (input:match("^https?://") or input:match("^git@")) then return nil end
    return input .. ".git", name
end

-- Builds each command with shell.cmd; nil, err if any word can't be quoted.
local function commandList(flavor, specs)
    local list = {}
    for _i, words in ipairs(specs) do
        local cmd, err = shell.cmd(flavor, unpack(words))
        if not cmd then return nil, err end
        list[#list + 1] = cmd
    end
    return list
end

function Create:cloneProject()
    self:askProjectPlace{
        title = _("Clone from GitHub"),
        description = _("Repository URL, or owner/name. It's cloned on the PC and added to Orca."),
        hint = "owner/repo",
        ok_text = _("Clone"),
        on_ok = function(value, dir, flavor)
            local url, name = Create.cloneUrl(value)
            if not url then
                return self.app.dialog.alert{ title = _("Not a repository"),
                    text = T(_("“%1” isn't a GitHub repository. Type owner/name or a URL like https://github.com/owner/name."), value) }
            end
            local dest = dir .. "/" .. name
            local list, err = commandList(flavor, {
                { "git", "clone", url, dest },
                { "orca", "repo", "add", "--path", dest },
            })
            if not list then return self.app:fail(T(_("Can't clone there: the path %1."), err)) end
            self:runOnDesktop(T(_("Clone %1"), name), list)
        end,
    }
end

function Create:newProject()
    self:askProjectPlace{
        title = _("New empty project"),
        description = _("Name for the new project. It gets a git repository and is added to Orca."),
        hint = "my-project",
        ok_text = _("Create"),
        on_ok = function(value, dir, flavor)
            local name = util.slug(value)
            local dest = dir .. "/" .. name
            local list, err = commandList(flavor, {
                { "git", "init", dest },
                { "git", "-C", dest, "commit", "--allow-empty", "-m", "Initial commit" },
                { "orca", "repo", "add", "--path", dest },
            })
            if not list then return self.app:fail(T(_("Can't create it there: the path %1."), err)) end
            self:runOnDesktop(T(_("New project %1"), name), list)
        end,
    }
end

-- Inside a workspace --------------------------------------------------------------------

-- Opens a new tab in wt and shows it. params: agent, agentPrompt (or none for a shell).
function Create:createTab(wt, params, busy)
    self.app:request{
        once = true,
        busy = busy,
        run = function(c) return api.createTab(c, wt, params, self.app.now) end,
        done = function(term) self.app.session:open(term, wt) end,
    }
end

-- Starts an agent session in wt with an optional first prompt (prompt prefills it).
function Create:newSession(wt, prompt)
    local agent = self.app:agentName()
    self.app.text.ask{
        title = T(_("New session in %1"), util.basename(wt.path)),
        description = T(_("What should %1 do? Leave empty for a blank session."), agent),
        input = prompt or "",
        multiline = true,
        ok_text = _("Start"),
        on_ok = function(text)
            text = util.trim(text)
            self:createTab(wt, { agent = self.app:agent(), agentPrompt = text ~= "" and text or nil },
                T(_("Starting %1…"), agent))
        end,
    }
end

function Create:newShell(wt)
    self:createTab(wt, {}, _("Opening a shell…"))
end

-- Reloads whatever screen is on top (after it changed underneath).
function Create:refreshTop()
    local top = self.app.nav:top()
    if top and top.refresh then top.refresh() end
end

function Create:sleep(wt)
    local name = util.basename(wt.path)
    self.app:request{
        once = true,
        busy = T(_("Putting %1 to sleep…"), name),
        run = function(c) return api.sleep(c, wt) end,
        done = function()
            self.app:toast(T(_("%1 is asleep. Its checkout is kept."), name))
            self:refreshTop()
        end,
    }
end

function Create:remove(wt)
    local name = util.basename(wt.path)
    self.app.dialog.confirm{
        title = T(_("Remove %1?"), name),
        text = _("Its checkout is deleted from the PC. The branch is kept."),
        ok_text = _("Remove"),
        destructive = true,
        on_ok = function()
            self.app:request{
                once = true,
                busy = T(_("Removing %1…"), name),
                run = function(c) return api.remove(c, wt) end,
                done = function()
                    self.app.nav:pop()
                    self.app:toast(T(_("Removed %1."), name))
                    self:refreshTop()
                end,
            }
        end,
    }
end

function Create:manage(wt)
    self.app.dialog.sheet{
        title = util.basename(wt.path),
        text = _("Sleeping stops its sessions and keeps the checkout."),
        actions = {
            { text = _("Sleep workspace"), callback = function() self:sleep(wt) end },
            { text = _("Remove workspace…"), callback = function() self:remove(wt) end },
        },
    }
end

return Create
