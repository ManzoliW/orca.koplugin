--[[
    The Kindle's own books, from KOReader: the reading history and each
    book's progress, covers (CoverBrowser's cache when it has one, else the
    document itself), time read per day from the statistics plugin's
    database, and the files Orca saved under documents/Claude.

    Everything here is local and synchronous; features reach it as
    app.library, which tests replace with a fake.

        library.recent(n)            -> { book, ... } newest first
        library.cover(file, w, h)    -> BlitBuffer or nil (cached)
        library.readingDays(since)   -> { ["YYYY-MM-DD"] = seconds }
        library.files(dir, n)        -> { book, ... } newest first
        library.open(file)
    book = { file, title, authors, percent (0-100 or nil), status, time }
--]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local library = {}

local BOOK_EXTENSIONS = { epub = true, pdf = true, azw3 = true, mobi = true, fb2 = true, txt = true,
                          md = true, html = true, djvu = true, cbz = true, docx = true }

local function titleFromFile(file)
    return (file:match("([^/]+)$") or file):gsub("%.[^.]+$", "")
end

-- Title, authors and progress from the book's sidecar (no document opened).
local function describe(file, time)
    local book = { file = file, title = titleFromFile(file), time = time }
    if not DocSettings:hasSidecarFile(file) then return book end
    local ok, settings = pcall(DocSettings.open, DocSettings, file)
    if not ok or not settings then return book end
    local props = settings:readSetting("doc_props") or {}
    if type(props.title) == "string" and props.title ~= "" then book.title = props.title end
    if type(props.authors) == "string" and props.authors ~= "" then
        book.authors = props.authors:gsub("\n", ", ")
    end
    local percent = tonumber(settings:readSetting("percent_finished"))
    if percent then book.percent = math.floor(percent * 100 + 0.5) end
    local summary = settings:readSetting("summary")
    book.status = type(summary) == "table" and summary.status or nil
    return book
end

function library.recent(n)
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return {} end
    local books = {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        if #books >= n then break end
        if item.file and lfs.attributes(item.file, "mode") == "file" then
            table.insert(books, describe(item.file, item.time))
        end
    end
    return books
end

function library.files(dir, n)
    local found = {}
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then return {} end
    for name in iter, state do
        local ext = name:match("%.([^.]+)$")
        if ext and BOOK_EXTENSIONS[ext:lower()] then
            local file = dir .. "/" .. name
            local mtime = lfs.attributes(file, "modification")
            if mtime then table.insert(found, { file = file, time = mtime }) end
        end
    end
    table.sort(found, function(a, b) return a.time > b.time end)
    local books = {}
    for i = 1, math.min(n, #found) do
        table.insert(books, describe(found[i].file, found[i].time))
    end
    return books
end

local covers = {}

local function scaled(bb, w, h)
    local RenderImage = require("ui/renderimage")
    local ok, out = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, w, h, false)
    return ok and out or nil
end

-- A cover that fits w × h, keeping its proportions.
function library.cover(file, w, h)
    local key = table.concat({ file, w, h }, "|")
    if covers[key] ~= nil then return covers[key] or nil end
    local bb
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim and BookInfoManager then
        local ok, info = pcall(BookInfoManager.getBookInfo, BookInfoManager, file, true)
        if ok and info and info.cover_bb then bb = info.cover_bb end
    end
    if not bb then
        local ok, FileManagerBookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
        if ok then
            local got, image = pcall(FileManagerBookInfo.getCoverImage, FileManagerBookInfo, nil, file)
            if got then bb = image end
        end
    end
    local result
    if bb then
        local bw, bh = bb:getWidth(), bb:getHeight()
        local scale = math.min(w / bw, h / bh)
        result = scaled(bb, math.max(1, math.floor(bw * scale)), math.max(1, math.floor(bh * scale)))
    end
    covers[key] = result or false
    return result
end

function library.readingDays(since)
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return {} end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return {} end
    local days = {}
    local done, err = pcall(function()
        local conn = SQ3.open(path)
        -- The base table, not the page_stat view: it has the start_time index.
        local rows = conn:exec(string.format([[
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day, sum(duration)
            FROM page_stat_data WHERE start_time >= %d GROUP BY day]], math.floor(since)))
        conn:close()
        if rows then
            for i = 1, #rows[1] do days[tostring(rows[1][i])] = tonumber(rows[2][i]) or 0 end
        end
    end)
    if not done then logger.warn("Orca: reading statistics:", err) end
    return days
end

function library.open(file)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(file)
end

return library
