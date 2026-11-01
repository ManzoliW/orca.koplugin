-- The plugin's own translations: every string in the code has one, with the same %n.
local H = require("tests.harness")
local GetText = require("gettext")
local _ = require("orca.core.i18n")

-- Every _("...") literal in the plugin's Lua files, decoded.
local function msgids()
    local found, files, dir = {}, {}, nil
    local p = io.popen('ls -R orca.koplugin')
    for line in p:lines() do
        local d = line:match("^(.*):$")
        if d then dir = d
        elseif line:match("%.lua$") and line ~= "_meta.lua" then table.insert(files, dir .. "/" .. line) end
    end
    p:close()
    for _i, path in ipairs(files) do
        local f = assert(io.open(path, "rb"))
        local src = f:read("*a")
        f:close()
        local at = 1
        while true do
            local s, e = src:find('_%(%s*"', at)
            if not s then break end
            local before = s > 1 and src:sub(s - 1, s - 1) or ""
            local i, raw = e + 1, {}
            while i <= #src do
                local c = src:sub(i, i)
                if c == "\\" then table.insert(raw, src:sub(i, i + 1)); i = i + 2
                elseif c == '"' or c == "\n" then break
                else table.insert(raw, c); i = i + 1 end
            end
            if not before:match("[%w_]") and src:sub(i + 1):match('^%s*%)') then
                found[loadstring('return "' .. table.concat(raw) .. '"')()] = path
            end
            at = i + 1
        end
    end
    return found
end

local function placeholders(s)
    local list = {}
    for n in s:gmatch("%%(%d)") do table.insert(list, n) end
    table.sort(list)
    return table.concat(list, ",")
end

local function languages()
    local list = {}
    local p = io.popen('ls orca.koplugin/orca/l10n')
    for file in p:lines() do
        local lang = file:match("^(.+)%.lua$")
        if lang then table.insert(list, lang) end
    end
    p:close()
    return list
end

H.test("every catalog translates every string in the plugin, with the same placeholders", function()
    local ids, count = msgids(), 0
    for _id in pairs(ids) do count = count + 1 end
    H.eq(count > 400, true, "strings found")
    local langs = languages()
    H.eq(table.concat(langs, ","), "es,pt_BR")
    for _i, lang in ipairs(langs) do
        local catalog, problems = require("orca.l10n." .. lang), {}
        for id, path in pairs(ids) do
            if not catalog[id] then
                table.insert(problems, "missing " .. string.format("%q", id) .. " (" .. path .. ")")
            elseif placeholders(catalog[id]) ~= placeholders(id) then
                table.insert(problems, "placeholders differ in " .. string.format("%q", id))
            end
        end
        for id in pairs(catalog) do
            if not ids[id] then table.insert(problems, "no longer used: " .. string.format("%q", id)) end
        end
        H.eq(table.concat(problems, "\n"), "", lang)
    end
end)

H.test("the language KOReader runs in picks the catalog; others keep KOReader's", function()
    GetText.current_lang = "pt_BR"
    H.eq(_("Continue reading"), "Continuar lendo")
    H.eq(_.date("%a %d %b", os.time{ year = 2026, month = 11, day = 1, hour = 12 }), "Dom 01 nov")
    H.eq(_.ago(os.time() - 300), "há 5 min")
    H.eq(_.ago(os.time() - 30 * 3600), "ontem")
    H.eq(_.number(1234567), "1.234.567")
    GetText.current_lang = "es_MX"
    H.eq(_("Continue reading"), "Seguir leyendo")
    H.eq(_.date("%a %d %b", os.time{ year = 2026, month = 11, day = 1, hour = 12 }), "Dom 01 nov")
    GetText.current_lang = "de"
    H.eq(_("Continue reading"), "Continue reading")
    GetText.current_lang = "C"
    H.eq(_.number(1234567), "1,234,567")
    H.eq(_.ago(os.time() - 300), "5 min ago")
    H.eq(_.date("%a %d %b", os.time{ year = 2026, month = 11, day = 1, hour = 12 }), "Sun 01 Nov")
end)
