--[[
    Terminal text: strips escape sequences, tidies screens for e-ink, and
    finds the question an agent is asking. Pure functions, unit-tested.
--]]

local util = require("orca.core.util")

local ansi = {}

function ansi.strip(s)
    return (util.str(s):gsub("\27%][^\7\27]*\7", "")   -- OSC ... BEL
                       :gsub("\27%][^\27]*\27\\", "")  -- OSC ... ST
                       :gsub("\27%[[%d;?<=>]*[ -/]*[@-~]", "") -- CSI
                       :gsub("\27[()][%w]", "")        -- charset selection
                       :gsub("\27.", "")
                       :gsub("\r", ""))
end

-- Symbols agents use that the terminal font (DejaVu Sans Mono) lacks, as the
-- closest ones it has: a fallback font would draw them at another width.
ansi.SUBSTITUTES = {
    ["⎿"] = "└", ["⏵"] = "▶", ["⏺"] = "●", ["⎯"] = "─", ["※"] = "*",
}

function ansi.monoSafe(s)
    for from, to in pairs(ansi.SUBSTITUTES) do s = s:gsub(from, to) end
    return s
end

-- Joins screen lines, trimming trailing blanks and collapsing runs of empty
-- lines.
function ansi.formatLines(lines, strip)
    local out, blank = {}, 0
    for _, line in ipairs(lines or {}) do
        line = util.str(line)
        if strip then line = ansi.strip(line) end
        line = ansi.monoSafe(line)
        line = line:gsub("%s+$", "")
        if line == "" then
            blank = blank + 1
            if blank <= 1 then out[#out + 1] = "" end
        else
            blank = 0
            out[#out + 1] = line
        end
    end
    while out[#out] == "" do out[#out] = nil end
    return table.concat(out, "\n")
end

-- The last few meaningful lines of a screen: where an agent's question is.
-- Skips box borders, logo art (block elements, U+2580–259F) and footer hints.
ansi.PROMPT_LINES = 9
function ansi.promptExcerpt(lines, max)
    max = max or ansi.PROMPT_LINES
    local out = {}
    for i = #(lines or {}), 1, -1 do
        local line = util.str(lines[i]):gsub("^%s*│%s?", ""):gsub("%s*│%s*$", ""):gsub("%s+$", "")
        if line:match("[%w%?]") and not line:find("\226\150[\128-\159]")
                and not line:match("^%s*Enter to select") and not line:match("^%s*Esc to cancel") then
            table.insert(out, 1, line)
            if #out == max then break end
        end
    end
    return table.concat(out, "\n")
end

-- Numbered choices in a prompt ("❯ 1. Yes", "2. Yes, and don't ask again")
-- -> { {key = "1", label = "Yes"}, ... } in screen order.
function ansi.choices(text)
    local found, seen = {}, {}
    for line in (util.str(text) .. "\n"):gmatch("([^\n]*)\n") do
        local key, label = line:match("^[%s❯>›]*(%d)[%.%)]%s+(.+)$")
        if key and not seen[key] then
            seen[key] = true
            table.insert(found, { key = key, label = util.trim(label) })
        end
    end
    return found
end

return ansi
