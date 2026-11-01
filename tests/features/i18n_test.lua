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

H.test("pt_BR translates every string in the plugin, with the same placeholders", function()
    local catalog = require("orca.l10n.pt_BR")
    local ids, count, problems = msgids(), 0, {}
    for id, path in pairs(ids) do
        count = count + 1
        if not catalog[id] then
            table.insert(problems, "missing " .. string.format("%q", id) .. " (" .. path .. ")")
        elseif placeholders(catalog[id]) ~= placeholders(id) then
            table.insert(problems, "placeholders differ in " .. string.format("%q", id))
        end
    end
    for id in pairs(catalog) do
        if not ids[id] then table.insert(problems, "no longer used: " .. string.format("%q", id)) end
    end
    H.eq(table.concat(problems, "\n"), "")
    H.eq(count > 400, true, "strings found")
end)

H.test("the language KOReader runs in picks the catalog; others keep KOReader's", function()
    GetText.current_lang = "pt_BR"
    H.eq(_("Continue reading"), "Continuar lendo")
    H.eq(_.date("%a %d %b", os.time{ year = 2026, month = 11, day = 1, hour = 12 }), "Dom 01 nov")
    H.eq(_.ago(os.time() - 300), "há 5 min")
    H.eq(_.ago(os.time() - 30 * 3600), "ontem")
    H.eq(_.number(1234567), "1.234.567")
    GetText.current_lang = "de"
    H.eq(_("Continue reading"), "Continue reading")
    GetText.current_lang = "C"
    H.eq(_.number(1234567), "1,234,567")
    H.eq(_.ago(os.time() - 300), "5 min ago")
    H.eq(_.date("%a %d %b", os.time{ year = 2026, month = 11, day = 1, hour = 12 }), "Sun 01 Nov")
end)
