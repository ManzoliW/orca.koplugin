--[[
    Recent agent conversations, from Orca's session vault (aiVault.listSessions):
    title, project, size in messages and tokens, and the last few messages.
    A conversation can be read as a book or continued in a desktop terminal.

    Terminal reads can't give this: Claude Code draws on the alternate
    screen, so its scrollback holds nothing but the current frame.
--]]

local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")
local T = require("ffi/util").template

local LIST_LIMIT = 30

return function(Orca, h)
    local str, basename = h.str, h.basename

    -- 324277013 -> "324M"
    local function shortCount(n)
        n = tonumber(n) or 0
        if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
        if n >= 1e7 then return string.format("%.0fM", n / 1e6) end
        if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
        if n >= 1e4 then return string.format("%.0fk", n / 1e3) end
        return tostring(math.floor(n))
    end
    Orca.shortCount = shortCount

    local function projectName(s) return basename(str(s.cwd):gsub("\\", "/")) end

    local function title(s)
        local t = str(s.title)
        if t == "" then t = str(s.lastUserPrompt):gsub("%s+", " ") end
        return t ~= "" and t or _("(untitled)")
    end

    -- "2026-10-31T14:37:10.560Z" -> local "31/10 11:37"
    local function when(iso)
        local y, mo, d, hh, mm, ss = str(iso):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
        if not y then return "" end
        local utc = os.time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = ss })
        local offset = os.time() - os.time(os.date("!*t"))
        return os.date("%d/%m %H:%M", utc + offset)
    end

    local function sessionId(s)
        return str(s.sessionId) ~= "" and s.sessionId or str(s.id):match(":(%x+%-%x+%-%x+%-%x+%-%x+)")
    end

    local function transcript(s)
        local lines = {
            title(s),
            T(_("%1 · %2 · %3 messages · %4 tokens"), projectName(s), str(s.agent),
                tonumber(s.messageCount) or 0, shortCount(s.totalTokens)),
            T(_("Branch %1 · updated %2"), str(s.branch), when(s.updatedAt)),
            "",
        }
        if s.previewMessagesTruncated then
            lines[#lines + 1] = _("(only the latest messages are available on the Kindle)")
            lines[#lines + 1] = ""
        end
        for _i, m in ipairs(type(s.previewMessages) == "table" and s.previewMessages or {}) do
            lines[#lines + 1] = (m.role == "user" and _("You") or _("Claude")) .. " · " .. when(m.timestamp)
            lines[#lines + 1] = str(m.text)
            lines[#lines + 1] = ""
        end
        return table.concat(lines, "\n")
    end

    function Orca:loadConversations(limit, on_loaded)
        self:queue{
            busy = on_loaded and nil or _("Loading conversations…"),
            run = function(c) return c:call("aiVault.listSessions", { limit = limit }, 60) end,
            done = function(r, err)
                if not r then return self:showError(err) end
                local sessions = type(r.sessions) == "table" and r.sessions or {}
                table.sort(sessions, function(a, b) return str(a.updatedAt) > str(b.updatedAt) end)
                on_loaded(sessions)
            end,
        }
    end

    function Orca:openConversations()
        NetworkMgr:runWhenOnline(function()
            self:loadConversations(LIST_LIMIT, function(sessions)
                local items = {}
                for _i, s in ipairs(sessions) do
                    items[#items + 1] = {
                        text = T("%1 · %2", projectName(s), title(s)),
                        mandatory = shortCount(s.totalTokens),
                        callback = function() self:showConversation(s) end,
                    }
                end
                if #items == 0 then
                    items[1] = { text = _("(no conversations found)"), select_enabled = false }
                end
                self:pushMenu(_("Recent conversations"), items)
            end)
        end)
    end

    function Orca:showConversation(s)
        local id = sessionId(s)
        self:viewText(title(s), transcript(s), function(close)
            local row = {
                { text = _("Read as book"), callback = function()
                    close(); self:openAsBook("conversation-" .. projectName(s) .. "-" .. title(s):sub(1, 40), transcript(s))
                end },
            }
            if id and str(s.agent) == "claude" then
                table.insert(row, { text = _("Continue on desktop"), callback = function()
                    close()
                    self:runOnDesktop(title(s):sub(1, 40), { "claude --resume " .. id }, str(s.cwd))
                end })
            end
            return row
        end)
    end
end
