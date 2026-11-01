--[[
    The plugin's own translations. KOReader's catalog only knows KOReader's
    strings, so most of ours stayed English in a translated KOReader. Each
    language with a catalog in orca/l10n/<lang>.lua (msgid -> text) uses it;
    any other language falls back to KOReader's gettext, as before.

        local _ = require("orca.core.i18n")
        _("Home")                        -- "Início" in pt_BR
        _.date("%a %d %b", t)            -- os.date with translated day and month names
--]]

local GetText = require("gettext")

local catalogs = {}   -- lang -> table, or false when there is none

local function catalog()
    local lang = GetText.current_lang or "C"
    if catalogs[lang] == nil then
        local ok, t = pcall(require, "orca.l10n." .. lang)
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

return setmetatable(i18n, { __call = function(_self, msgid) return _(msgid) end })
