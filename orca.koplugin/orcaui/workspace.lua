--[[
    Workspace actions for the Orca plugin: create workspaces (blank, from a
    GitHub issue/PR), clone or start projects, launch agents, git (changes,
    diff, commit, push, pull request) and a file browser.

    Installed onto the Orca plugin class by main.lua: require("orcaui.workspace")(Orca, helpers).
    Everything here goes through Orca:queue so the socket is used one job at a
    time and the UI never blocks.

    Mobile clients can't call repo.clone / repo.add, so cloning and new
    projects run `git` and the `orca` CLI in a desktop terminal instead.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Diff = require("orcaui.diff")

local DEFAULT_AGENT = "claude"
local DOCS_DIR = "/mnt/us/documents/Claude"
local CREATE_TIMEOUT = 600 -- worktree.create may clone or run setup hooks
local NEW_TERMINAL_WAIT = 15

local GIT_STATUS = {
    modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", copied = "C",
}

return function(Orca, h)
    local str, basename = h.str, h.basename

    local function wtSelector(wt) return "id:" .. wt.worktreeId end
    local function repoIdOf(wt) return str(wt.worktreeId):match("^(.-)::") end

    local function mutationId(kind)
        return string.format("kindle-%s:%x:%06x", kind, os.time(), math.random(0, 0xffffff))
    end

    -- Cooperative sleep inside a job: services the socket while waiting.
    local function wait(c, seconds)
        local deadline = h.now() + seconds
        while h.now() < deadline do
            c:pump(deadline - h.now())
        end
    end

    -- "Fix the login bug" -> "fix-the-login-bug"
    local function slug(text)
        local words = {}
        for w in str(text):lower():gmatch("[%w]+") do
            words[#words + 1] = w
            if #words == 5 then break end
        end
        local s = table.concat(words, "-"):sub(1, 32):gsub("%-+$", "")
        return s ~= "" and s or ("kindle-" .. os.date("%m%d-%H%M"))
    end

    local function unixPath(p) return (str(p):gsub("\\", "/"):gsub("/+$", "")) end
    local function dirname(p) return unixPath(p):match("^(.*)/[^/]*$") or unixPath(p) end

    -- Menu plumbing -------------------------------------------------------------------

    -- Pushes items like a sub-menu (the back arrow returns), or opens a new
    -- menu when none is showing.
    function Orca:pushMenu(title, items)
        local menu = self.menu
        if menu and UIManager:isWidgetShown(menu) then
            menu.item_table.title = menu.title
            table.insert(menu.item_table_stack, menu.item_table)
            menu:switchItemTable(title, items)
        else
            self:showMenu(title, items)
        end
    end

    function Orca:replaceMenu(items)
        if self.menu then self.menu:switchItemTable(nil, items) end
    end

    function Orca:closeMenu()
        if self.menu then UIManager:close(self.menu); self.menu = nil end
    end

    function Orca:viewText(title, text, extra_buttons)
        local viewer
        local buttons = {}
        if extra_buttons then buttons[1] = extra_buttons(function() UIManager:close(viewer) end) end
        viewer = TextViewer:new{
            title = title,
            text = text ~= "" and text or _("(empty)"),
            text_type = "code",
            buttons_table = #buttons > 0 and buttons or nil,
            add_default_buttons = true,
        }
        UIManager:show(viewer)
    end

    -- Saves text under documents/Claude and opens it as a book.
    function Orca:openAsBook(name, text)
        local dir = self.docs_dir or DOCS_DIR
        lfs.mkdir(dir)
        local path = dir .. "/" .. name:gsub("[^%w%._%-]+", "_") .. ".txt"
        local f, err = io.open(path, "w")
        if not f then return self:showError(err) end
        f:write(text)
        f:close()
        self:closeMenu()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end

    function Orca:agentId()
        return self.settings:readSetting("agent") or DEFAULT_AGENT
    end

    -- Repos ---------------------------------------------------------------------------

    function Orca:loadRepos(on_repos)
        self:queue{
            busy = _("Loading projects…"),
            run = function(c)
                local r, err = c:call("repo.list")
                if not r then return nil, err end
                return r.repos or {}
            end,
            done = function(repos, err)
                if not repos then return self:showError(err) end
                table.sort(repos, function(a, b)
                    return str(a.displayName):lower() < str(b.displayName):lower()
                end)
                on_repos(repos)
            end,
        }
    end

    function Orca:pickRepo(title, on_pick)
        self:loadRepos(function(repos)
            local items = {}
            for _i, repo in ipairs(repos) do
                local name = str(repo.displayName) ~= "" and repo.displayName or basename(repo.path)
                table.insert(items, {
                    text = name,
                    mandatory = str(repo.executionHostId) ~= "" and repo.executionHostId ~= "local"
                        and repo.executionHostId or nil,
                    callback = function() on_pick(repo) end,
                })
            end
            if #items == 0 then
                table.insert(items, { text = _("(no projects in Orca yet)"), select_enabled = false })
            end
            self:pushMenu(title, items)
        end)
    end

    -- Where new clones and projects go: a setting, else the folder most
    -- existing projects live in.
    function Orca:projectsDir(repos)
        local dir = self.settings:readSetting("projects_dir")
        if dir then return dir end
        local counts, best, best_n = {}, nil, 0
        for _i, repo in ipairs(repos or {}) do
            if str(repo.executionHostId) == "" or repo.executionHostId == "local" then
                local parent = dirname(repo.path)
                counts[parent] = (counts[parent] or 0) + 1
                if counts[parent] > best_n then best, best_n = parent, counts[parent] end
            end
        end
        return best
    end

    -- "+ New" menu ---------------------------------------------------------------------

    function Orca:newItems()
        return {
            { text = _("New workspace with Claude…"), callback = function()
                self:pickRepo(_("New workspace in…"), function(repo) self:newWorkspace(repo) end)
            end },
            { text = _("From a GitHub issue or PR…"), callback = function()
                self:pickRepo(_("Issues and PRs of…"), function(repo) self:openWorkItems(repo) end)
            end },
            { text = _("Clone from GitHub…"), callback = function() self:cloneProject() end },
            { text = _("New empty project…"), callback = function() self:newProject() end },
        }
    end

    -- Asks what Claude should do, then creates a workspace with it running.
    function Orca:newWorkspace(repo, opts)
        opts = opts or {}
        local dialog
        local function start(prompt)
            UIManager:close(dialog)
            prompt = prompt:gsub("^%s+", ""):gsub("%s+$", "")
            local params = {
                repo = "id:" .. repo.id,
                name = opts.name or slug(prompt),
                startupAgent = self:agentId(),
                createdWithAgent = self:agentId(),
                setupDecision = "inherit",
                clientMutationId = mutationId("wt"),
            }
            if prompt ~= "" then params.startupPrompt = prompt end
            for k, v in pairs(opts.params or {}) do params[k] = v end
            self:createWorkspace(params)
        end
        dialog = InputDialog:new{
            title = T(_("New workspace in %1"), str(repo.displayName) ~= "" and repo.displayName or basename(repo.path)),
            description = opts.description or _("What should Claude work on? Leave empty to start a blank session."),
            input = opts.prompt or "",
            allow_newline = true,
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Start"), is_enter_default = true, callback = function() start(dialog:getInputText()) end },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    -- worktree.create with startupAgent; on a name clash retries with -2, -3.
    function Orca:createWorkspace(params)
        NetworkMgr:runWhenOnline(function()
            self:queue{
                busy = T(_("Creating workspace %1…\n(cloning and setup can take a while)"), params.name),
                run = function(c)
                    local base, result, err = params.name, nil, nil
                    for attempt = 1, 3 do
                        result, err = c:call("worktree.create", params, CREATE_TIMEOUT)
                        if result or not tostring(err):lower():match("exist") then break end
                        params.name = base .. "-" .. (attempt + 1)
                        params.clientMutationId = mutationId("wt")
                    end
                    return result, err
                end,
                done = function(result, err)
                    if not result then return self:showError(err) end
                    local wt = result.worktree or {}
                    local handle = result.agentTerminalHandle
                        or (result.startupTerminal and result.startupTerminal.handle)
                    local warnings = {}
                    for _i, w in ipairs(type(result.warnings) == "table" and result.warnings or {}) do
                        warnings[#warnings + 1] = type(w) == "table" and str(w.message) or str(w)
                    end
                    if #warnings > 0 then
                        UIManager:show(InfoMessage:new{ text = table.concat(warnings, "\n"), timeout = 4 })
                    end
                    self:closeMenu()
                    if handle then
                        self:openSession({ handle = handle, title = str(wt.displayName) ~= "" and wt.displayName or params.name })
                    else
                        UIManager:show(InfoMessage:new{
                            text = T(_("Workspace %1 created."), str(wt.displayName) ~= "" and wt.displayName or params.name),
                        })
                    end
                end,
            }
        end)
    end

    -- GitHub issues and PRs ------------------------------------------------------------

    function Orca:openWorkItems(repo, query)
        self:queue{
            busy = _("Loading issues and pull requests…"),
            run = function(c)
                return c:call("github.listWorkItems", { repo = "id:" .. repo.id, limit = 40, query = query or "" }, 60)
            end,
            done = function(result, err)
                if not result then return self:showError(err) end
                local items = {
                    { text = _("Search…"), callback = function()
                        self:showInput(_("Search issues and PRs"), _("Words to look for (GitHub search)."), query,
                            function(q) self:openWorkItems(repo, q) end)
                    end },
                }
                for _i, item in ipairs(result.items or {}) do
                    if item.state ~= "closed" and item.state ~= "merged" then
                        table.insert(items, {
                            text = T("#%1 %2", item.number, str(item.title)),
                            mandatory = item.type == "pr" and _("PR") or _("issue"),
                            callback = function() self:startOnWorkItem(repo, item) end,
                        })
                    end
                end
                if #items == 1 then
                    table.insert(items, { text = _("(nothing open)"), select_enabled = false })
                end
                if query then self:replaceMenu(items) else self:pushMenu(_("Issues and PRs"), items) end
            end,
        }
    end

    function Orca:startOnWorkItem(repo, item)
        local is_pr = item.type == "pr"
        local kind = is_pr and "pr" or "issue"
        local prompt = is_pr
            and T(_("Review pull request #%1 (%2): %3"), item.number, str(item.url), str(item.title))
            or T(_("Work on GitHub issue #%1 (%2): %3"), item.number, str(item.url), str(item.title))
        local params = {
            displayName = T("#%1 %2", item.number, str(item.title)):sub(1, 60),
            displayNameKind = "generated",
            startupDraft = item.url,
        }
        if is_pr then params.linkedPR = item.number else params.linkedIssue = item.number end
        local function go(extra)
            for k, v in pairs(extra or {}) do params[k] = v end
            self:newWorkspace(repo, {
                name = kind .. "-" .. item.number,
                prompt = prompt,
                description = _("Claude starts with this prompt; edit it if you like."),
                params = params,
            })
        end
        if not is_pr then return go() end
        -- A PR workspace checks out the PR's branch: ask the host where it starts.
        self:queue{
            busy = _("Looking up the pull request…"),
            run = function(c)
                return c:call("worktree.resolvePrBase", {
                    repo = "id:" .. repo.id, prNumber = item.number,
                    headRefName = item.branchName, baseRefName = item.baseRefName,
                }, 60)
            end,
            done = function(base, err)
                if not base or base.error then return self:showError(err or base.error) end
                go({ baseBranch = base.baseBranch, compareBaseRef = base.compareBaseRef,
                     branchNameOverride = base.branchNameOverride, pushTarget = base.pushTarget })
            end,
        }
    end

    -- Clone / new project (via a desktop terminal) -------------------------------------

    -- Runs a shell command in a new background terminal of any workspace and
    -- opens it so you can watch. Commands are joined with ";", which both
    -- PowerShell and POSIX shells accept. With `cwd`, it runs in the workspace
    -- checked out there, or cd's into it from another one.
    function Orca:runOnDesktop(title, commands, cwd)
        NetworkMgr:runWhenOnline(function()
            self:queue{
                busy = _("Starting a desktop terminal…"),
                run = function(c)
                    local worktrees, err = c:listWorktrees()
                    if not worktrees then return nil, err end
                    if not worktrees[1] then return nil, _("Orca has no workspace to open a terminal in.") end
                    local target = worktrees[1]
                    if cwd then
                        target = nil
                        for _i, w in ipairs(worktrees) do
                            if unixPath(w.path):lower() == unixPath(cwd):lower() then target = w end
                        end
                        if not target then
                            target = worktrees[1]
                            commands = { "cd \"" .. unixPath(cwd) .. "\"", unpack(commands) }
                        end
                    end
                    local r, cerr = c:call("terminal.create", {
                        worktree = wtSelector(target),
                        command = table.concat(commands, "; "),
                        title = title,
                        presentation = "background",
                        startupCommandDelivery = "shell-ready",
                        clientMutationId = mutationId("term"),
                    }, 60)
                    if not r then return nil, cerr end
                    return r.terminal
                end,
                done = function(term, err)
                    if not term or not term.handle then return self:showError(err or _("no terminal returned")) end
                    self:closeMenu()
                    self:openSession({ handle = term.handle, title = title })
                end,
            }
        end)
    end

    function Orca:askProjectPlace(title, description, input, hint, on_ok)
        self:loadRepos(function(repos)
            local dir = self:projectsDir(repos)
            local dialog
            dialog = InputDialog:new{
                title = title,
                description = T(_("%1\n\nFolder: %2"), description, dir or _("(not set — tap Folder…)")),
                input = input or "",
                input_hint = hint,
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    { text = _("Folder…"), callback = function()
                        UIManager:close(dialog)
                        self:showInput(_("Projects folder on the desktop"),
                            _("New projects go here. Example: C:/Users/me/projects"), dir, function(v)
                                v = unixPath(v)
                                self.settings:saveSetting("projects_dir", v ~= "" and v or nil)
                                self.settings:flush()
                                self:askProjectPlace(title, description, input, hint, on_ok)
                            end)
                    end },
                    { text = _("OK"), is_enter_default = true, callback = function()
                        local value = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                        if value == "" or not dir then return end
                        UIManager:close(dialog)
                        on_ok(value, dir)
                    end },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end)
    end

    -- "owner/repo", "github.com/owner/repo" or a full URL -> clone URL, folder name.
    local function cloneUrl(input)
        input = input:gsub("%.git$", "")
        local owner, name = input:match("^([%w%._%-]+)/([%w%._%-]+)$")
        if owner then return "https://github.com/" .. owner .. "/" .. name .. ".git", name end
        if input:match("^github%.com/") then input = "https://" .. input end
        name = input:match("([%w%._%-]+)/?$")
        if not name or not (input:match("^https?://") or input:match("^git@")) then return nil end
        return input .. ".git", name
    end

    function Orca:cloneProject()
        self:askProjectPlace(_("Clone from GitHub"),
            _("Repository URL, or owner/name. It's cloned on the desktop and added to Orca."),
            "", "owner/repo", function(value, dir)
                local url, name = cloneUrl(value)
                if not url then return self:showError(_("not a repository URL")) end
                local dest = dir .. "/" .. name
                self:runOnDesktop(T(_("Clone %1"), name), {
                    "git clone " .. url .. " " .. dest,
                    "orca repo add --path " .. dest,
                })
            end)
    end

    function Orca:newProject()
        self:askProjectPlace(_("New empty project"),
            _("Name for the new project. It gets a git repository and is added to Orca."),
            "", "my-project", function(value, dir)
                local name = slug(value)
                local dest = dir .. "/" .. name
                self:runOnDesktop(T(_("New project %1"), name), {
                    "git init " .. dest,
                    "git -C " .. dest .. " commit --allow-empty -m \"Initial commit\"",
                    "orca repo add --path " .. dest,
                })
            end)
    end

    -- Inside a workspace ---------------------------------------------------------------

    -- Extra rows shown above a workspace's terminal list.
    function Orca:workspaceActionItems(wt)
        return {
            { text = _("+ New Claude session…"), callback = function() self:newAgentHere(wt) end },
            { text = _("+ New shell"), callback = function() self:newTerminalHere(wt) end },
            { text = _("Git: changes, commit, push…"), callback = function() self:openGit(wt) end },
            { text = _("Files…"), callback = function() self:openFiles(wt, "") end },
            { text = _("Workspace: sleep, remove…"), callback = function() self:openWorkspaceManage(wt) end },
        }
    end

    -- Waits for a terminal that wasn't in `before` to show up in the workspace.
    local function waitForNewTerminal(c, wt, before)
        local deadline = h.now() + NEW_TERMINAL_WAIT
        while h.now() < deadline do
            local terminals = c:listTerminals(wt.worktreeId) or {}
            for _i, term in ipairs(terminals) do
                if not before[term.handle] then return term end
            end
            wait(c, 1.5)
        end
    end

    function Orca:createTabHere(wt, params, busy)
        NetworkMgr:runWhenOnline(function()
            self:queue{
                busy = busy,
                run = function(c)
                    local before = {}
                    for _i, term in ipairs(c:listTerminals(wt.worktreeId) or {}) do before[term.handle] = true end
                    params.worktree = wtSelector(wt)
                    params.activate = false
                    params.select = true
                    params.navigation = "caller"
                    params.clientMutationId = mutationId("tab")
                    local r, err = c:call("session.tabs.createTerminal", params, 60)
                    if not r then return nil, err end
                    local tab = r.tab or {}
                    if type(tab.terminal) == "string" then return { handle = tab.terminal, title = tab.title } end
                    -- The tab is pending a terminal handle; pick it up from the list.
                    return waitForNewTerminal(c, wt, before) or nil, _("the new terminal didn't appear yet; refresh in a moment")
                end,
                done = function(term, err)
                    if not term then return self:showError(err) end
                    self:closeMenu()
                    self:openSession(term)
                end,
            }
        end)
    end

    function Orca:newAgentHere(wt)
        local dialog
        local function start(prompt)
            UIManager:close(dialog)
            prompt = prompt:gsub("^%s+", ""):gsub("%s+$", "")
            self:createTabHere(wt, { agent = self:agentId(), agentPrompt = prompt ~= "" and prompt or nil },
                _("Starting Claude…"))
        end
        dialog = InputDialog:new{
            title = T(_("New session in %1"), basename(wt.path)),
            description = _("What should Claude do? Leave empty for a blank session."),
            input = "",
            allow_newline = true,
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Start"), is_enter_default = true, callback = function() start(dialog:getInputText()) end },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    function Orca:newTerminalHere(wt)
        self:createTabHere(wt, {}, _("Opening a shell…"))
    end

    function Orca:openWorkspaceManage(wt)
        local name = basename(wt.path)
        self:pushMenu(T(_("Workspace %1"), name), {
            { text = _("Sleep (stop its terminals, keep the checkout)"), callback = function()
                self:queue{
                    busy = _("Putting the workspace to sleep…"),
                    run = function(c) return c:call("worktree.sleep", { worktree = wtSelector(wt) }, 60) end,
                    done = function(r, err)
                        if not r then return self:showError(err) end
                        UIManager:show(InfoMessage:new{ text = T(_("%1 is asleep."), name), timeout = 3 })
                    end,
                }
            end },
            { text = _("Remove workspace…"), callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove workspace %1?\n\nIts checkout is deleted; the branch is kept."), name),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        self:queue{
                            busy = _("Removing workspace…"),
                            run = function(c)
                                return c:call("worktree.rm", { worktree = wtSelector(wt), deleteBranch = false }, 120)
                            end,
                            done = function(r, err)
                                if not r then return self:showError(err) end
                                self:closeMenu()
                                UIManager:show(InfoMessage:new{ text = T(_("Removed %1."), name), timeout = 3 })
                            end,
                        }
                    end,
                })
            end },
        })
    end

    -- Git ------------------------------------------------------------------------------

    function Orca:loadGit(wt, on_loaded)
        self:queue{
            busy = _("Reading git status…"),
            run = function(c)
                local status, err = c:call("git.status", { worktree = wtSelector(wt), includeLineStats = true }, 60)
                if not status then return nil, err end
                status.upstream = c:call("git.upstreamStatus", { worktree = wtSelector(wt) }, 30)
                return status
            end,
            done = function(status, err)
                if not status then return self:showError(err) end
                on_loaded(status)
            end,
        }
    end

    function Orca:gitItems(wt, status)
        local entries = status.entries or {}
        local up = type(status.upstream) == "table" and status.upstream or {}
        local branch = str(status.branch):gsub("^refs/heads/", "")
        local summary = branch
        if up.hasUpstream then
            summary = T(_("%1  ↑%2 ↓%3"), branch, tonumber(up.ahead) or 0, tonumber(up.behind) or 0)
        elseif branch ~= "" then
            summary = T(_("%1  (not pushed yet)"), branch)
        end
        local items = {
            { text = _("↻ Refresh"), callback = function()
                self:loadGit(wt, function(s) self:replaceMenu(self:gitItems(wt, s)) end)
            end },
            { text = summary ~= "" and summary or _("(detached)"), select_enabled = false },
        }
        if #entries > 0 then
            table.insert(items, { text = T(_("Commit all %1 changes…"), #entries), callback = function()
                self:commitAll(wt, entries)
            end })
        end
        table.insert(items, { text = _("Push"), callback = function() self:gitSimple(wt, "git.push", _("Pushing…"), _("Pushed.")) end })
        table.insert(items, { text = _("Pull"), callback = function() self:gitSimple(wt, "git.pull", _("Pulling…"), _("Pulled.")) end })
        table.insert(items, { text = _("Open a pull request…"), callback = function() self:openPullRequest(wt, branch) end })
        table.insert(items, { text = _("Read all changes as a book"), callback = function() self:changesBook(wt, entries) end })
        for _i, e in ipairs(entries) do
            local stats = ""
            if e.added or e.removed then stats = string.format("+%d -%d", tonumber(e.added) or 0, tonumber(e.removed) or 0) end
            table.insert(items, {
                text = (GIT_STATUS[str(e.status)] or "·") .. " " .. str(e.path),
                mandatory = stats ~= "" and stats or (e.area == "staged" and _("staged") or nil),
                callback = function() self:showDiff(wt, e) end,
            })
        end
        if #entries == 0 then
            table.insert(items, { text = _("(working tree clean)"), select_enabled = false })
        end
        return items
    end

    function Orca:openGit(wt)
        self:loadGit(wt, function(status)
            self:pushMenu(T(_("Git: %1"), basename(wt.path)), self:gitItems(wt, status))
        end)
    end

    -- Diff text for one status entry (runs inside a job).
    local function entryDiff(c, wt, e)
        if e.status == "untracked" then
            local f, err = c:call("files.read", { worktree = wtSelector(wt), relativePath = e.path }, 30)
            if not f then return nil, err end
            return (Diff.unified("", f.content or ""))
        end
        local params = { worktree = wtSelector(wt), filePath = e.path, staged = e.area == "staged" }
        if e.oldPath then params.oldPath = e.oldPath end
        local d, err = c:call("git.diff", params, 30)
        if not d then return nil, err end
        if d.kind == "binary" then return _("(binary file)") end
        local text = Diff.unified(d.originalContent or "", d.modifiedContent or "")
        return text ~= "" and text or _("(no textual changes)")
    end

    function Orca:showDiff(wt, e)
        self:queue{
            busy = _("Loading diff…"),
            run = function(c) return entryDiff(c, wt, e) end,
            done = function(text, err)
                if not text then return self:showError(err) end
                self:viewText(str(e.path), text, function(close)
                    return {
                        { text = _("Open as book"), callback = function()
                            close(); self:openAsBook(basename(wt.path) .. "-" .. basename(e.path) .. ".diff", text)
                        end },
                        { text = _("Ask Claude…"), callback = function()
                            close(); self:askAbout(wt, T(_("my uncommitted changes to %1"), e.path))
                        end },
                    }
                end)
            end,
        }
    end

    function Orca:changesBook(wt, entries)
        if #entries == 0 then return self:showError(_("no changes")) end
        self:queue{
            busy = T(_("Collecting %1 diffs…"), #entries),
            run = function(c)
                local parts = {}
                for _i, e in ipairs(entries) do
                    local text = entryDiff(c, wt, e) or _("(could not read)")
                    parts[#parts + 1] = string.rep("=", 40) .. "\n" .. str(e.path) .. "\n" .. string.rep("=", 40) .. "\n" .. text
                end
                return table.concat(parts, "\n\n")
            end,
            done = function(text, err)
                if not text then return self:showError(err) end
                self:openAsBook(basename(wt.path) .. "-changes-" .. os.date("%m%d-%H%M"), text)
            end,
        }
    end

    function Orca:gitSimple(wt, method, busy, ok_text)
        self:queue{
            busy = busy,
            run = function(c) return c:call(method, { worktree = wtSelector(wt) }, 120) end,
            done = function(r, err)
                if not r then return self:showError(err) end
                UIManager:show(InfoMessage:new{ text = ok_text, timeout = 2 })
                self:loadGit(wt, function(s) self:replaceMenu(self:gitItems(wt, s)) end)
            end,
        }
    end

    -- Stages everything, lets the desktop's agent draft a message, then commits.
    function Orca:commitAll(wt, entries)
        local paths = {}
        for _i, e in ipairs(entries) do
            paths[#paths + 1] = e.path
            if e.oldPath then paths[#paths + 1] = e.oldPath end
        end
        self:queue{
            busy = _("Staging and drafting a commit message…"),
            run = function(c)
                local ok, err = c:call("git.bulkStage", { worktree = wtSelector(wt), filePaths = paths }, 60)
                if not ok then return nil, err end
                local m = c:call("git.generateCommitMessage", { worktree = wtSelector(wt) }, 180)
                return { message = m and m.success and m.message or "" }
            end,
            done = function(r, err)
                if not r then return self:showError(err) end
                local dialog
                local function commit(push)
                    local message = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if message == "" then return end
                    UIManager:close(dialog)
                    self:queue{
                        busy = push and _("Committing and pushing…") or _("Committing…"),
                        run = function(c)
                            local res, cerr = c:call("git.commit", { worktree = wtSelector(wt), message = message }, 60)
                            if not res then return nil, cerr end
                            if res.success == false then return nil, res.error or _("commit failed") end
                            if push then return c:call("git.push", { worktree = wtSelector(wt) }, 120) end
                            return res
                        end,
                        done = function(res, cerr)
                            if not res then return self:showError(cerr) end
                            UIManager:show(InfoMessage:new{ text = push and _("Committed and pushed.") or _("Committed."), timeout = 2 })
                            self:loadGit(wt, function(s) self:replaceMenu(self:gitItems(wt, s)) end)
                        end,
                    }
                end
                dialog = InputDialog:new{
                    title = T(_("Commit %1 files"), #entries),
                    input = r.message,
                    input_hint = _("Commit message"),
                    allow_newline = true,
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        { text = _("Commit"), callback = function() commit(false) end },
                        { text = _("Commit & push"), is_enter_default = true, callback = function() commit(true) end },
                    }},
                }
                UIManager:show(dialog)
            end,
        }
    end

    local BLOCKED = {
        dirty = _("commit your changes first"),
        detached_head = _("the workspace isn't on a branch"),
        default_branch = _("you're on the default branch"),
        no_upstream = _("push the branch first"),
        needs_push = _("push your latest commits first"),
        needs_sync = _("the branch needs syncing with its base"),
        auth_required = _("the desktop isn't signed in to GitHub (gh auth login)"),
        existing_review = _("a pull request already exists"),
        base_not_on_remote = _("the base branch isn't on the remote"),
    }

    function Orca:openPullRequest(wt, branch)
        local repo = "id:" .. repoIdOf(wt)
        self:queue{
            busy = _("Checking the branch…"),
            run = function(c)
                return c:call("hostedReview.getCreationEligibility",
                    { repo = repo, branch = branch, worktree = wtSelector(wt) }, 60)
            end,
            done = function(el, err)
                if not el then return self:showError(err) end
                if el.review and str(el.review.url) ~= "" then
                    return UIManager:show(InfoMessage:new{ text = T(_("Pull request already open:\n%1"), el.review.url) })
                end
                if not el.canCreate then
                    return self:showError(T(_("can't open a pull request: %1"),
                        BLOCKED[str(el.blockedReason)] or str(el.blockedReason)))
                end
                local dialog
                dialog = InputDialog:new{
                    title = T(_("Pull request into %1"), str(el.defaultBaseRef)),
                    input = str(el.title) ~= "" and el.title or branch,
                    input_hint = _("Title"),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        { text = _("Draft"), callback = function()
                            UIManager:close(dialog); self:createPullRequest(wt, el, dialog:getInputText(), true)
                        end },
                        { text = _("Open PR"), is_enter_default = true, callback = function()
                            UIManager:close(dialog); self:createPullRequest(wt, el, dialog:getInputText(), false)
                        end },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        }
    end

    function Orca:createPullRequest(wt, el, title, draft)
        self:queue{
            busy = _("Opening the pull request…"),
            run = function(c)
                return c:call("hostedReview.create", {
                    repo = "id:" .. repoIdOf(wt), worktree = wtSelector(wt),
                    provider = el.provider, base = el.defaultBaseRef, head = el.head,
                    title = title, body = el.body, draft = draft,
                }, 120)
            end,
            done = function(r, err)
                if not r then return self:showError(err) end
                if not r.ok then return self:showError(r.error or r.code) end
                UIManager:show(InfoMessage:new{ text = T(_("Pull request #%1 opened:\n%2"), r.number, str(r.url)) })
            end,
        }
    end

    -- Files ----------------------------------------------------------------------------

    function Orca:openFiles(wt, rel, replace)
        self:queue{
            busy = _("Listing files…"),
            run = function(c)
                return c:call("files.readDir", { worktree = wtSelector(wt), relativePath = rel, limit = 1000 }, 30)
            end,
            done = function(r, err)
                if not r then return self:showError(err) end
                local entries = r.entries or r
                table.sort(entries, function(a, b)
                    if a.isDirectory ~= b.isDirectory then return a.isDirectory end
                    return str(a.name):lower() < str(b.name):lower()
                end)
                local items = {}
                for _i, e in ipairs(entries) do
                    local path = rel == "" and e.name or (rel .. "/" .. e.name)
                    table.insert(items, {
                        text = e.isDirectory and (e.name .. "/") or e.name,
                        callback = function()
                            if e.isDirectory then self:openFiles(wt, path) else self:showFile(wt, path) end
                        end,
                    })
                end
                if r.hasMore then
                    table.insert(items, { text = T(_("(%1 more not shown)"), (r.total or 0) - #entries), select_enabled = false })
                end
                if #items == 0 then table.insert(items, { text = _("(empty folder)"), select_enabled = false }) end
                local title = rel == "" and basename(wt.path) or rel
                if replace then self:replaceMenu(items) else self:pushMenu(title, items) end
            end,
        }
    end

    function Orca:showFile(wt, rel)
        self:queue{
            busy = _("Opening file…"),
            run = function(c) return c:call("files.read", { worktree = wtSelector(wt), relativePath = rel }, 60) end,
            done = function(f, err)
                if not f then return self:showError(err) end
                local text = str(f.content)
                if f.truncated then text = text .. "\n\n" .. _("(truncated at 512 KB)") end
                self:viewText(rel, text, function(close)
                    return {
                        { text = _("Open as book"), callback = function()
                            close(); self:openAsBook(basename(wt.path) .. "-" .. rel, text)
                        end },
                        { text = _("Ask Claude…"), callback = function()
                            close(); self:askAbout(wt, rel)
                        end },
                    }
                end)
            end,
        }
    end

    -- Sends "In <workspace>, about <subject>: <question>" to a session.
    function Orca:askAbout(wt, subject)
        local dialog
        dialog = InputDialog:new{
            title = T(_("Ask Claude about %1"), subject),
            input = "",
            input_hint = _("Your question"),
            allow_newline = true,
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Send"), is_enter_default = true, callback = function()
                    local q = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if q == "" then return end
                    UIManager:close(dialog)
                    local message = T(_("In workspace %1 (%2), about %3:\n\n%4"), basename(wt.path), unixPath(wt.path), subject, q)
                    self:pickSession(function(term) self:sendToTerminal(term, message) end)
                end },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    -- Stats ----------------------------------------------------------------------------

    function Orca:showStats()
        NetworkMgr:runWhenOnline(function()
            self:queue{
                busy = _("Loading stats…"),
                run = function(c) return c:call("stats.summary", nil, 30) end,
                done = function(s, err)
                    if not s then return self:showError(err) end
                    local hours = (tonumber(s.totalAgentTimeMs) or 0) / 3600000
                    UIManager:show(InfoMessage:new{
                        text = T(_("Agents started: %1\nPull requests: %2\nAgent time: %3 h"),
                            tonumber(s.totalAgentsSpawned) or 0, tonumber(s.totalPRsCreated) or 0,
                            string.format("%.1f", hours)),
                    })
                end,
            }
        end)
    end

end
