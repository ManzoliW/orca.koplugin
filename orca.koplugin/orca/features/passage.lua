--[[
    Highlight → agent: sends a passage from the book, with where it comes
    from and a question, to a terminal session, then opens that session.

    The last session used is offered first ("Send to Claude (kindle)?"), so
    asking about several passages while reading is two taps each.
--]]

local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local util = require("orca.core.util")

local Passage = {}
Passage.__index = Passage

-- Bracketed paste, so a multi-line message reaches the agent as one input.
local PASTE_START, PASTE_END = "\27[200~", "\27[201~"
local PREVIEW = 300

function Passage.new(app)
    return setmetatable({ app = app }, Passage)
end

-- "Title by Author, chapter "X"" for the open book; "" outside the reader.
function Passage:context()
    local plugin = self.app.plugin
    local ui = plugin and plugin.ui
    if not ui then return "" end
    local props = util.tbl(ui.doc_props)
    local source = util.str(props.title)
    if source == "" and ui.document then source = util.basename(ui.document.file) end
    local authors = util.str(props.authors)
    if authors ~= "" then
        source = source .. " by " .. util.collapse(authors:gsub("\n", ", "))
    end
    local ok, chapter = pcall(function() return ui.toc:getTocTitleByPage(ui:getCurrentPage()) end)
    if ok and util.str(chapter) ~= "" then
        source = source .. ", chapter \"" .. util.collapse(chapter) .. "\""
    end
    return source
end

function Passage:message(passage, question)
    local source = self:context()
    if source == "" then
        return T(_("\"%1\"\n\n%2"), passage, question)
    end
    return T(_("From %1:\n\n\"%2\"\n\n%3"), source, passage, question)
end

-- Asks what to do with a highlighted passage, then where to send it.
function Passage:ask(text)
    local passage = util.collapse(text)
    if passage == "" then return end
    local function send(question)
        local message = self:message(passage, question)
        self:pickSession(function(term, wt) self:sendToTerminal(term, message, wt) end)
    end
    local function preset(label, question)
        return { text = label, callback = function() send(question) end }
    end
    self.app.text.ask{
        title = T(_("Send to %1"), self.app:agentName()),
        description = util.ellipsize(passage, PREVIEW),
        hint = _("Your question (optional)"),
        multiline = true,
        ok_text = _("Send"),
        rows = { {
            preset(_("Explain"), _("Explain this passage in a few short paragraphs.")),
            preset(_("Context"), _("Give the historical and cultural context for this passage, and who or what it refers to.")),
            preset(_("Save note"), _("Append this passage, with its source and a one-line summary, to my reading notes (notes/reading-notes.md in this project; create it if missing). Reply with just the file path.")),
        } },
        on_ok = function(value)
            local q = util.collapse(value)
            send(q ~= "" and q or _("What do you make of this passage?"))
        end,
    }
end

-- Offers the last-used session first, otherwise browses for one.
-- on_pick(term, wt); wt may be nil for the remembered session.
function Passage:pickSession(on_pick)
    local app = self.app
    local function browse()
        app.home:open{
            title = _("Send to which session?"),
            on_pick = function(term, wt)
                app.nav:close()
                app.settings:set("last_terminal", {
                    handle = util.str(term.handle),
                    title = util.str(term.title),
                    workspace = util.basename(wt.path),
                    worktreeId = util.str(wt.worktreeId),
                    path = util.str(wt.path),
                })
                on_pick(term, wt)
            end,
        }
    end
    local last = app.settings:get("last_terminal")
    if type(last) ~= "table" or util.str(last.handle) == "" then return browse() end
    local wt = util.str(last.worktreeId) ~= "" and { worktreeId = last.worktreeId, path = last.path } or nil
    local name = util.str(last.title) ~= "" and last.title or last.handle
    app.dialog.card{
        text = T(_("Send to %1 (%2)?"), name, util.str(last.workspace)),
        buttons = {
            { { text = _("Choose another…"), callback = browse } },
            { { text = _("Cancel") },
              { text = _("Send"), primary = true, callback = function() on_pick(last, wt) end } },
        },
    }
end

-- Pastes a message into a terminal, submits it and opens the session view.
function Passage:sendToTerminal(term, message, wt)
    local app = self.app
    local handle = util.str(term.handle)
    local name = util.str(term.title) ~= "" and util.str(term.title) or handle
    app.online(function()
        app:request{
            busy = T(_("Sending to %1…"), name),
            once = true,
            run = function(c)
                local ok, err = c:sendText(handle, PASTE_START .. message .. PASTE_END, false)
                if not ok then return nil, err end
                -- A separate Enter: pasted text with a trailing newline is
                -- kept as a line break by the agent's input box.
                return c:sendText(handle, "", true)
            end,
            done = function() app.session:open(term, wt) end,
            on_error = function(err)
                if tostring(err):match("not found") then app.settings:set("last_terminal", nil) end
                app:fail(err)
            end,
        }
    end)
end

return Passage
