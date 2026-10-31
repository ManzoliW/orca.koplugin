--[[
    Quoting for commands typed into a desktop terminal (clone, new project,
    `claude --resume`, `cd`). The desktop shell is PowerShell on Windows and
    a POSIX shell elsewhere; both take single-quoted words literally, but they
    escape an embedded single quote differently ('' vs '\''), so the flavor
    matters only for words that contain one. With no flavor such words are
    refused rather than guessed at.

        shell.cmd("powershell", "git", "clone", url, dest)  -> "git clone https://… 'C:/My Projects/x'"
        shell.join{ a, b }                                  -> "a; b" (both shells accept ";")
--]]

local util = require("orca.core.util")

local shell = {}

-- Words made only of these pass through bare in both shells. No "," (an
-- array in PowerShell), "@" / "$" / "~" / quotes / spaces.
local SAFE = "^[%w%._/:%+=%-]+$"

-- PowerShell also treats the typographic single quotes as quote characters.
local PS_QUOTES = { "'", "\226\128\152", "\226\128\153", "\226\128\154", "\226\128\155" }

-- "powershell" for a Windows path (C:/…, C:\…, \\server\…), "posix" otherwise.
function shell.flavor(path)
    local p = util.str(path)
    if p:match("^%a:[/\\]") or p:match("^%a:$") or p:match("^\\\\") then return "powershell" end
    if p:match("^/") or p:match("^~") then return "posix" end
    return nil
end

local function hasControl(s)
    return s:find("[%z\1-\31\127]") ~= nil
end

local function hasQuote(s)
    for _i, q in ipairs(PS_QUOTES) do
        if s:find(q, 1, true) then return true end
    end
    return false
end

-- One word, quoted when needed. Returns nil, err for control characters
-- (a newline would run the rest as another command), and for quotes when the
-- flavor is unknown.
function shell.quote(s, flavor)
    if type(s) ~= "string" then s = tostring(s or "") end
    if hasControl(s) then return nil, "contains a control character" end
    if s:match(SAFE) then return s end
    if not hasQuote(s) then return "'" .. s .. "'" end
    if flavor == "posix" then
        return "'" .. s:gsub("'", "'\\''") .. "'"
    elseif flavor == "powershell" then
        local out = s
        for _i, q in ipairs(PS_QUOTES) do out = out:gsub(q, q .. q) end
        return "'" .. out .. "'"
    end
    return nil, "contains a quote"
end

-- shell.cmd(flavor, "git", "init", dest): the program name stays bare (it
-- comes from us), every argument is quoted. Returns nil, err like quote.
function shell.cmd(flavor, program, ...)
    local words = { program }
    for i = 1, select("#", ...) do
        local q, err = shell.quote(select(i, ...), flavor)
        if not q then return nil, err end
        words[#words + 1] = q
    end
    return table.concat(words, " ")
end

function shell.join(commands)
    return table.concat(commands, "; ")
end

return shell
