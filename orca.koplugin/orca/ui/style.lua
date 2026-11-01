--[[
    Design tokens: one place for type, spacing, lines and glyphs.

    E-ink rules this follows (Apple HIG, translated): hierarchy from size and
    weight, not color; nothing under 16 px outside the terminal; touch
    targets of at least 48 px; status always as glyph + word; separators
    instead of boxes; gray only for secondary text.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Screen = require("device").screen

local S = Screen.scaleBySize and function(v) return Screen:scaleBySize(v) end or function(v) return v end

local style = {}

-- Type scale (px before scaling).
style.size = {
    title = 22,     -- screen title, bold
    row = 20,       -- row title
    body = 18,      -- dialog text
    detail = 16,    -- subtitles, right-hand values, section headers
    button = 18,
}

function style.face(role, bold)
    local size = style.size[role] or style.size.body
    return Font:getFace(bold and "smallinfofontbold" or "smallinfofont", size)
end

-- The terminal font is DejaVu Sans Mono, bundled: the Kindle's monospace
-- font (Droid Sans Mono) has no box drawing or the symbols agents draw their
-- screens with, so KOReader takes those from proportional fallback fonts and
-- the columns stop lining up. Font:getFace only opens files below its fonts
-- folder, so the path climbs out of it to the plugin.
local MONO_FILE = (function()
    local root = debug.getinfo(1, "S").source:match("^@(.*)/orca/ui/[^/]*$")
    if not root then return nil end
    if root:sub(1, 1) ~= "/" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and type(lfs) == "table" and lfs.currentdir and lfs.currentdir()
        if not cwd then return nil end
        root = cwd .. "/" .. root:gsub("^%./", "")
    end
    return string.rep("../", 16) .. root:sub(2) .. "/fonts/DejaVuSansMono.ttf"
end)()

function style.mono(size)
    size = size or 16
    return MONO_FILE and Font:getFace(MONO_FILE, size) or Font:getFace("smallinfont", size)
end

style.color = {
    text = Blitbuffer.COLOR_BLACK,
    dim = Blitbuffer.gray(0.55),
    line = Blitbuffer.gray(0.75),
    faint = Blitbuffer.gray(0.88),
    page = Blitbuffer.COLOR_WHITE,
    inverse = Blitbuffer.COLOR_WHITE,
}

-- Spacing rhythm: 4-px base.
style.space = {
    xs = S(4),
    s = S(8),
    m = S(12),
    l = S(16),
    xl = S(24),
}

style.line = S(1)
style.radius = S(10)
style.border = S(1.5)

style.min_target = S(48)
style.row_height = S(64)      -- row with a subtitle
style.row_height_single = S(52)
style.title_height = S(60)
style.button_height = S(56)

-- Status and drill-in glyphs (present in KOReader's Noto fonts).
style.glyph = {
    needs = "●",
    working = "◐",
    done = "○",
    idle = " ",
    error = "✕",
    chevron = "›",
    back = "‹",
    close = "✕",
    refresh = "↻",
    add = "+",
    check = "✓",
    cross = "✕",
    pending = "…",
    skipped = "–",
}

-- Status = glyph + word, never one without the other.
local _ = require("gettext")
style.status = {
    needs = { glyph = "●", label = _("Needs you"), bold = true },
    working = { glyph = "◐", label = _("Working") },
    done = { glyph = "○", label = _("Done") },
    idle = { glyph = nil, label = "" },
}

return style
