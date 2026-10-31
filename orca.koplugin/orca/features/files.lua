--[[
    Browsing a workspace's files: folders first, a file opens as text (or as
    a book), and "Ask <agent>…" sends a question about it to a session in
    that workspace.
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local api = require("orca.api.workspaces")
local util = require("orca.core.util")

local Files = {}
Files.__index = Files

function Files.new(app)
    return setmetatable({ app = app }, Files)
end

-- 1234 -> "1.2 KB"
function Files.size(bytes)
    bytes = tonumber(bytes)
    if not bytes then return nil end
    if bytes < 1024 then return T(_("%1 B"), bytes) end
    local units = { "KB", "MB", "GB" }
    local v, i = bytes / 1024, 1
    while v >= 1024 and i < #units do v, i = v / 1024, i + 1 end
    return (v < 10 and string.format("%.1f", v) or string.format("%d", math.floor(v + 0.5))) .. " " .. units[i]
end

local function join(rel, name)
    return rel == "" and name or (rel .. "/" .. name)
end

function Files:screen(wt, rel, r, page)
    local rows = {}
    for _i, e in ipairs(r.entries) do
        local name = util.str(e.name)
        local path = join(rel, name)
        if e.isDirectory == true then
            table.insert(rows, { title = name, chevron = true, callback = function() self:open(wt, path) end })
        else
            table.insert(rows, { title = name, detail = Files.size(e.size),
                                 callback = function() self:showFile(wt, path) end })
        end
    end
    if r.hasMore then
        table.insert(rows, { title = T(_("%1 more not shown"), math.max(0, r.total - #r.entries)), dim = true })
    end
    return {
        title = rel == "" and util.basename(wt.path) or util.basename(rel),
        subtitle = rel ~= "" and rel or util.unixPath(wt.path),
        sections = { { rows = rows } },
        empty = _("This folder is empty."),
        refresh = function() self:load(wt, rel, page) end,
    }
end

function Files:load(wt, rel, page)
    self.app:request{
        run = function(c) return api.readDir(c, wt, rel) end,
        done = function(r) page:set(self:screen(wt, rel, r, page)) end,
        on_error = function(err)
            page:set{ title = rel == "" and util.basename(wt.path) or util.basename(rel),
                      empty = self.app:explain(err), refresh = function() self:load(wt, rel, page) end }
        end,
    }
end

-- rel: folder inside the workspace ("" or nil for its root).
function Files:open(wt, rel)
    rel = rel or ""
    local page = self.app.nav:push{
        title = rel == "" and util.basename(wt.path) or util.basename(rel),
        loading = _("Listing files…"),
    }
    self:load(wt, rel, page)
end

function Files:showFile(wt, rel)
    self.app:request{
        busy = T(_("Opening %1…"), util.basename(rel)),
        run = function(c) return api.readFile(c, wt, rel) end,
        done = function(f)
            local text = f.content
            if f.truncated then text = text .. "\n\n" .. _("(truncated at 512 KB)") end
            self.app.text.read{
                title = rel,
                text = text,
                mono = true,
                actions = {
                    { text = _("Open as book"), callback = function()
                        self.app:openAsBook(util.basename(wt.path) .. "-" .. rel, text)
                    end },
                    { text = T(_("Ask %1…"), self.app:agentName()), callback = function()
                        self:askAbout(wt, rel)
                    end },
                },
            }
        end,
    }
end

-- Asks a question about subject (a file, "my changes to x") and sends
-- "In workspace <name> (<path>), about <subject>: <question>" to a new or
-- running session in that workspace.
function Files:askAbout(wt, subject)
    local agent = self.app:agentName()
    self.app.text.ask{
        title = T(_("Ask %1 about %2"), agent, subject),
        hint = _("Your question"),
        multiline = true,
        ok_text = _("Send…"),
        on_ok = function(q)
            q = util.trim(q)
            if q == "" then return end
            local message = T(_("In workspace %1 (%2), about %3:\n\n%4"),
                util.basename(wt.path), util.unixPath(wt.path), subject, q)
            self:chooseSession(wt, message)
        end,
    }
end

function Files:chooseSession(wt, message)
    local agent = self.app:agentName()
    self.app.dialog.sheet{
        title = _("Send to which session?"),
        actions = {
            { text = T(_("New %1 session"), agent), callback = function()
                self.app.create:createTab(wt, { agent = self.app:agent(), agentPrompt = message },
                    T(_("Starting %1…"), agent))
            end },
            { text = _("A running session…"), callback = function()
                local passage = self.app.passage
                passage:pickSession(function(term, picked)
                    passage:sendToTerminal(term, message, picked or wt)
                end)
            end },
        },
    }
end

return Files
