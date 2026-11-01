--[[
    The plugin's own translations. KOReader's catalog only knows KOReader's
    strings, so most of ours stayed English in a translated KOReader. Each
    language with a catalog in orca/l10n/<lang>.lua (msgid -> text) uses it,
    regional variants included (es_MX uses es.lua); any other language falls
    back to KOReader's gettext, as before.

        local _ = require("orca.core.i18n")
        _("Home")                        -- "Início" in pt_BR
        _.date("%a %d %b", t)            -- os.date with translated day and month names
        _.ago(t)                         -- "5 min ago", "yesterday", "31/10"
        _.number(1234)                   -- "1,234"; "1.234" in pt_BR
--]]

local GetText = require("gettext")
local T = require("ffi/util").template

local util = require("orca.core.util")

local catalogs = {}   -- lang -> table, or false when there is none

local function catalog()
    local lang = GetText.current_lang or "C"
    if catalogs[lang] == nil then
        local ok, t = pcall(require, "orca.l10n." .. lang)
        if not (ok and type(t) == "table") and lang:find("_") then
            ok, t = pcall(require, "orca.l10n." .. lang:match("^[^_]+"))
        end
        catalogs[lang] = ok and type(t) == "table" and t or false
    end
    return catalogs[lang]
end

local function _(msgid)
    local c = catalog()
    return c and c[msgid] or GetText(msgid)
end

local i18n = {}

-- os.date, but %a and %b in the translated language (os.date uses the C locale).
function i18n.date(fmt, t)
    t = t or os.time()
    local d = os.date("*t", t)
    local days = { _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat") }
    local months = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
                     _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }
    fmt = fmt:gsub("%%a", (days[d.wday]:gsub("%%", "%%%%")))
             :gsub("%%b", (months[d.month]:gsub("%%", "%%%%")))
    return os.date(fmt, t)
end

-- Epoch seconds or milliseconds or ISO string -> "5 min ago", "yesterday", "31/10".
function i18n.ago(when, now)
    local t = type(when) == "string" and util.isoTime(when) or tonumber(when)
    if not t then return "" end
    if t > 1e11 then t = t / 1000 end
    local s = (now or os.time()) - t
    if s < 60 then return _("now") end
    if s < 3600 then return T(_("%1 min ago"), math.floor(s / 60)) end
    if s < 86400 then return T(_("%1 h ago"), math.floor(s / 3600)) end
    if s < 2 * 86400 then return _("yesterday") end
    return os.date("%d/%m", math.floor(t))
end

function i18n.number(n)
    -- The thousands separator, as each language writes it.
    local sep = _(",")
    return (util.thousands(n):gsub(",", (sep:gsub("%%", "%%%%"))))
end

return setmetatable(i18n, { __call = function(_self, msgid) return _(msgid) end })
