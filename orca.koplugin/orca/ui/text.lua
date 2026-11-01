--[[
    Text input and long-text reading, on KOReader's own widgets (they own the
    keyboard and scrolling).

    text.ask{ title, description, input, hint, multiline, ok_text, on_ok(value),
              extra = { {text, callback(value)} } }
        The keyboard opens right away; Cancel is always first.
    text.read{ title, text, mono, actions = { {text, callback} } }
        Full-screen scrollable text; each action closes the viewer first.
    text.book(dir, name, text) -> ok, err
        Saves the text as name.txt in dir and opens it in the reader.
--]]

local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("orca.core.i18n")

local text = {}

function text.ask(opts)
    local dialog
    local row = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
    }
    for _, b in ipairs(opts.extra or {}) do
        table.insert(row, { text = b.text, callback = function()
            local value = dialog:getInputText()
            UIManager:close(dialog)
            b.callback(value)
        end })
    end
    table.insert(row, { text = opts.ok_text or _("Save"), is_enter_default = true, callback = function()
        local value = dialog:getInputText()
        UIManager:close(dialog)
        opts.on_ok(value)
    end })
    local buttons = {}
    for _, extra_row in ipairs(opts.rows or {}) do
        local wrapped = {}
        for i, b in ipairs(extra_row) do
            wrapped[i] = { text = b.text, callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                b.callback(value)
            end }
        end
        table.insert(buttons, wrapped)
    end
    table.insert(buttons, row)
    dialog = InputDialog:new{
        title = opts.title,
        description = opts.description,
        input = opts.input or "",
        input_hint = opts.hint,
        allow_newline = opts.multiline or false,
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

function text.read(opts)
    local viewer
    local buttons
    if opts.actions and #opts.actions > 0 then
        local row = {}
        for i, a in ipairs(opts.actions) do
            row[i] = { text = a.text, callback = function()
                UIManager:close(viewer)
                a.callback()
            end }
        end
        buttons = { row }
    end
    viewer = TextViewer:new{
        title = opts.title,
        text = (opts.text and opts.text ~= "") and opts.text or _("(empty)"),
        text_type = opts.mono and "code" or nil,
        monospace_font = opts.mono or nil,
        buttons_table = buttons,
        add_default_buttons = true,
    }
    UIManager:show(viewer)
    return viewer
end

function text.book(dir, name, body)
    lfs.mkdir(dir)
    local path = dir .. "/" .. name:gsub("[^%w%._%-]+", "_") .. ".txt"
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(body)
    f:close()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
    return true
end

return text
