--[[
    Recent agent conversations, from Orca's session vault (aiVault.listSessions):
    title, project, age and size, and the last few messages. A conversation
    can be read as a book or continued in a desktop terminal.

    Terminal reads can't give this: Claude Code draws on the alternate
    screen, so its scrollback holds nothing but the current frame.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local shell = require("orca.core.shell")
local util = require("orca.core.util")

local Conversations = {}
Conversations.__index = Conversations

local LIST_LIMIT = 30
local LIST_TIMEOUT = 60 -- s; the vault scans transcripts on disk

function Conversations.new(app)
    return setmetatable({ app = app }, Conversations)
end

local function project(s)
    return util.basename(s.cwd)
end

local function title(s)
    local t = util.str(s.title)
    if t == "" then t = util.collapse(s.lastUserPrompt) end
    return t ~= "" and t or _("(untitled)")
end

-- "2026-10-31T14:37:10.560Z" -> local "31/10 11:37"
local function when(iso)
    local t = util.isoTime(iso)
    return t and os.date("%d/%m %H:%M", t) or ""
end

-- The agent's own session id; only plain ids, since it ends up in a command line.
local function sessionId(s)
    local id = util.str(s.sessionId)
    if id == "" then id = util.str(s.id):match(":(%x+%-%x+%-%x+%-%x+%-%x+)") or "" end
    return id:match("^[%w%-]+$")
end

function Conversations:transcript(s)
    local lines = {
        title(s),
        T(_("%1 · %2 · %3 messages · %4 tokens"), project(s), self.app:agentName(util.str(s.agent)),
            util.num(s.messageCount), util.shortCount(s.totalTokens)),
    }
    local branch = util.str(s.branch)
    if branch ~= "" then
        table.insert(lines, T(_("Branch %1 · updated %2"), branch, when(s.updatedAt)))
    else
        table.insert(lines, T(_("Updated %1"), when(s.updatedAt)))
    end
    table.insert(lines, "")
    if s.previewMessagesTruncated == true then
        table.insert(lines, _("(only the latest messages are available on the Kindle)"))
        table.insert(lines, "")
    end
    local agent = self.app:agentName(util.str(s.agent))
    for _i, m in ipairs(util.tbl(s.previewMessages)) do
        local who = util.str(m.role) == "user" and _("You") or agent
        table.insert(lines, who .. " · " .. when(m.timestamp))
        table.insert(lines, util.str(m.text))
        table.insert(lines, "")
    end
    return table.concat(lines, "\n")
end

local function newestFirst(sessions)
    local list = {}
    for _i, s in ipairs(util.tbl(sessions)) do
        if type(s) == "table" then table.insert(list, s) end
    end
    table.sort(list, function(a, b) return util.str(a.updatedAt) > util.str(b.updatedAt) end)
    return list
end

-- Inside a job: the conversation that ran last (sleep screen), or nil.
function Conversations:latest(c)
    local vault = c:call("aiVault.listSessions", { limit = 5 }, LIST_TIMEOUT)
    return newestFirst(type(vault) == "table" and vault.sessions)[1]
end

function Conversations:screen(sessions)
    local rows = {}
    local now = os.time()
    for _i, s in ipairs(sessions) do
        local parts = { project(s) }
        local ago = util.ago(s.updatedAt, now)
        if ago ~= "" then table.insert(parts, ago) end
        table.insert(rows, {
            title = title(s),
            subtitle = table.concat(parts, " · "),
            detail = util.shortCount(s.totalTokens),
            chevron = true,
            callback = function() self:showConversation(s) end,
        })
    end
    return {
        title = _("Conversations"),
        rows = rows,
        empty = T(_("No conversations yet. Start a %1 session in a workspace and it shows up here."),
            self.app:agentName()),
        refresh = function() self:load() end,
    }
end

function Conversations:load()
    local page = self.page
    if not page or not page:isShown() then
        page = self.app.nav:push{ title = _("Conversations"), loading = _("Loading conversations…") }
        self.page = page
    end
    self.app:request{
        run = function(c) return c:call("aiVault.listSessions", { limit = LIST_LIMIT }, LIST_TIMEOUT) end,
        done = function(result) page:set(self:screen(newestFirst(result.sessions))) end,
        on_error = function(err)
            page:set{ title = _("Conversations"), empty = self.app:explain(err),
                      refresh = function() self:load() end }
        end,
    }
end

function Conversations:open()
    self.app.online(function()
        self.page = nil
        self:load()
    end)
end

function Conversations:showConversation(s)
    local name = title(s)
    local actions = {
        { text = _("Read as book"), callback = function()
            self.app:openAsBook("conversation-" .. project(s) .. "-" .. name:sub(1, 40), self:transcript(s))
        end },
    }
    local id = sessionId(s)
    if id and util.str(s.agent) == "claude" then
        table.insert(actions, { text = _("Continue on desktop"), callback = function()
            self.app.create:runOnDesktop(util.ellipsize(name, 40), { shell.cmd(shell.flavor(s.cwd), "claude", "--resume", id) },
                util.str(s.cwd))
        end })
    end
    self.app.text.read{ title = name, text = self:transcript(s), actions = actions }
end

return Conversations
