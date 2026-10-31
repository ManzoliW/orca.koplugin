--[[
    Small pure helpers shared by every module. No KOReader dependencies, so
    they run (and are unit-tested) on a PC.
--]]

local util = {}

-- JSON null decodes to userdata (truthy), so every field read goes through these.
function util.str(v)
    return type(v) == "string" and v or ""
end

function util.num(v, default)
    return tonumber(v) or default or 0
end

function util.tbl(v)
    return type(v) == "table" and v or {}
end

function util.trim(s)
    return (util.str(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Collapses all whitespace runs to single spaces.
function util.collapse(s)
    return util.trim(util.str(s):gsub("%s+", " "))
end

function util.unixPath(p)
    return (util.str(p):gsub("\\", "/"):gsub("/+$", ""))
end

function util.basename(p)
    local s = util.unixPath(p)
    return s:match("([^/]+)$") or s
end

function util.dirname(p)
    local s = util.unixPath(p)
    return s:match("^(.*)/[^/]*$") or s
end

-- "Fix the login bug" -> "fix-the-login-bug"
function util.slug(text, fallback)
    local words = {}
    for w in util.str(text):lower():gmatch("[%w]+") do
        words[#words + 1] = w
        if #words == 5 then break end
    end
    local s = table.concat(words, "-"):sub(1, 32):gsub("%-+$", "")
    return s ~= "" and s or fallback or ("kindle-" .. os.date("%m%d-%H%M"))
end

-- Cuts to at most n characters without splitting a UTF-8 sequence.
function util.ellipsize(s, n)
    s = util.str(s)
    local count, cut = 0, nil
    for pos in s:gmatch("()[^\128-\191]") do
        count = count + 1
        if count == n then cut = pos end
        if count > n then
            return s:sub(1, cut - 1) .. "…"
        end
    end
    return s
end

-- 324000000 -> "324M", 1100000 -> "1.1M", 495000 -> "495k"
function util.shortCount(n)
    n = tonumber(n) or 0
    local function fmt(v, suffix)
        return (v < 10 and string.format("%.1f", v):gsub("%.0$", "") or string.format("%d", math.floor(v + 0.5))) .. suffix
    end
    if n >= 1e9 then return fmt(n / 1e9, "B") end
    if n >= 1e6 then return fmt(n / 1e6, "M") end
    if n >= 1e3 then return fmt(n / 1e3, "k") end
    return tostring(math.floor(n))
end

-- Seconds since the epoch for an ISO-8601 UTC timestamp ("2026-10-31T13:33:00.000Z").
function util.isoTime(iso)
    local y, mo, d, h, mi, s = util.str(iso):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    local t = os.time{ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }
    -- os.time read the fields as local time; shift back to UTC.
    local now = os.time()
    local utc_offset = os.difftime(now, os.time(os.date("!*t", now)))
    return t + utc_offset
end

-- Epoch seconds or milliseconds or ISO string -> "5 min ago", "yesterday", "31/10".
function util.ago(when, now)
    local t = type(when) == "string" and util.isoTime(when) or tonumber(when)
    if not t then return "" end
    if t > 1e11 then t = t / 1000 end
    local s = (now or os.time()) - t
    if s < 60 then return "now" end
    if s < 3600 then return string.format("%d min ago", math.floor(s / 60)) end
    if s < 86400 then return string.format("%d h ago", math.floor(s / 3600)) end
    if s < 2 * 86400 then return "yesterday" end
    return os.date("%d/%m", math.floor(t))
end

function util.mutationId(kind)
    return string.format("kindle-%s:%x:%06x", kind, os.time(), math.random(0, 0xffffff))
end

return util
