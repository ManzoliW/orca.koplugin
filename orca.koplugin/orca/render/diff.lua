--[[
    Line diff for showing a file's changes on e-ink. git.diff returns the old
    and new contents rather than a patch, so we build a unified-style view
    here: common prefix/suffix trimmed, LCS on what's left (bounded), context
    lines around each change.
--]]

local Diff = {}

local LCS_LIMIT = 4e6 -- cells; beyond this, show the changed region as -/+ blocks
local CONTEXT = 3

local function splitLines(s)
    local lines = {}
    if not s or s == "" then return lines end
    s = s:gsub("\r\n", "\n")
    for line in (s:sub(-1) == "\n" and s or s .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end
Diff.splitLines = splitLines

-- Returns a list of { op = " " | "-" | "+", text } for a and b (line lists).
function Diff.ops(a, b)
    local n, m = #a, #b
    local pre = 0
    while pre < n and pre < m and a[pre + 1] == b[pre + 1] do pre = pre + 1 end
    local suf = 0
    while suf < n - pre and suf < m - pre and a[n - suf] == b[m - suf] do suf = suf + 1 end

    local ops = {}
    for i = 1, pre do ops[#ops + 1] = { op = " ", text = a[i] } end

    local an, bm = n - pre - suf, m - pre - suf
    if an * bm <= LCS_LIMIT and an > 0 and bm > 0 then
        -- lengths[i][j] = LCS of a[pre+i..] and b[pre+j..], rows built bottom-up.
        local lengths = {}
        for i = an + 1, 1, -1 do
            local row, below = {}, lengths[i + 1]
            for j = bm + 1, 1, -1 do
                if i > an or j > bm then
                    row[j] = 0
                elseif a[pre + i] == b[pre + j] then
                    row[j] = below[j + 1] + 1
                else
                    local d, r = below[j], row[j + 1]
                    row[j] = d > r and d or r
                end
            end
            lengths[i] = row
        end
        local i, j = 1, 1
        while i <= an and j <= bm do
            if a[pre + i] == b[pre + j] then
                ops[#ops + 1] = { op = " ", text = a[pre + i] }; i = i + 1; j = j + 1
            elseif lengths[i + 1][j] >= lengths[i][j + 1] then
                ops[#ops + 1] = { op = "-", text = a[pre + i] }; i = i + 1
            else
                ops[#ops + 1] = { op = "+", text = b[pre + j] }; j = j + 1
            end
        end
        for k = i, an do ops[#ops + 1] = { op = "-", text = a[pre + k] } end
        for k = j, bm do ops[#ops + 1] = { op = "+", text = b[pre + k] } end
    else
        for k = 1, an do ops[#ops + 1] = { op = "-", text = a[pre + k] } end
        for k = 1, bm do ops[#ops + 1] = { op = "+", text = b[pre + k] } end
    end

    for i = n - suf + 1, n do ops[#ops + 1] = { op = " ", text = a[i] } end
    return ops
end

-- Unified-style text with @@ line markers; returns text, added, removed.
function Diff.unified(old, new, context)
    context = context or CONTEXT
    local ops = Diff.ops(splitLines(old), splitLines(new))
    local keep, added, removed = {}, 0, 0
    for idx, o in ipairs(ops) do
        if o.op ~= " " then
            if o.op == "+" then added = added + 1 else removed = removed + 1 end
            for k = math.max(1, idx - context), math.min(#ops, idx + context) do keep[k] = true end
        end
    end
    local out, old_no, new_no, gap = {}, 0, 0, true
    for idx, o in ipairs(ops) do
        if o.op ~= "+" then old_no = old_no + 1 end
        if o.op ~= "-" then new_no = new_no + 1 end
        if keep[idx] then
            if gap then
                out[#out + 1] = string.format("@@ line %d @@", o.op == "-" and old_no or new_no)
                gap = false
            end
            out[#out + 1] = o.op .. " " .. o.text
        else
            gap = true
        end
    end
    return table.concat(out, "\n"), added, removed
end

return Diff
