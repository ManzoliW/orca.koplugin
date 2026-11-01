-- orca/render/ansi.lua: escape stripping, screen tidying, prompt excerpt, choices.
local H = require("tests.harness")
local ansi = require("orca.render.ansi")

H.test("strip removes CSI, OSC, charset and carriage returns", function()
    H.eq(ansi.strip("\27[1;32mgreen\27[0m"), "green")
    H.eq(ansi.strip("\27]0;title\7text"), "text")
    H.eq(ansi.strip("\27]8;;http://x\27\\link"), "link")
    H.eq(ansi.strip("\27(Bplain\r"), "plain")
    H.eq(ansi.strip("\27[?25lhidden cursor\27[?25h"), "hidden cursor")
    H.eq(ansi.strip(nil), "")
end)

H.test("formatLines trims trailing blanks and collapses empty runs", function()
    H.eq(ansi.formatLines({ "a   ", "", "", "", "b", "", "" }), "a\n\nb")
    H.eq(ansi.formatLines({ "\27[31mred\27[0m" }, true), "red")
    H.eq(ansi.formatLines({ "\27[31mred" }, false), "\27[31mred")
    -- JSON null in a line list decodes to userdata.
    H.eq(ansi.formatLines({ "x", newproxy and newproxy() or {}, "y" }), "x\n\ny")
    H.eq(ansi.formatLines(nil), "")
end)

H.test("promptExcerpt keeps the question, skips art, borders and footer hints", function()
    local lines = { " ▐▛███▛█   Claude Code", " Bash command", "   rm -rf build", "",
                    "│ Do you want to proceed? │", " ❯ 1. Yes",
                    "   2. No, and tell Claude what to do differently (esc)", "",
                    "Enter to select · ↑/↓ to navigate · Esc to cancel", "" }
    local text = ansi.promptExcerpt(lines)
    H.has(text, "Do you want to proceed?")
    H.has(text, "2. No, and tell Claude")
    H.eq(text:find("▐", 1, true), nil)
    H.eq(text:find("│", 1, true), nil)
    H.eq(text:find("Enter to select", 1, true), nil)
    H.eq(ansi.promptExcerpt(lines, 2), " ❯ 1. Yes\n   2. No, and tell Claude what to do differently (esc)")
end)

H.test("choices finds numbered options once each, in order", function()
    local found = ansi.choices("Do you want to proceed?\n❯ 1. Yes\n  2) Yes, and don't ask again\n3. No\n1. Yes again")
    H.eq(#found, 3)
    H.eq(found[1].key, "1"); H.eq(found[1].label, "Yes")
    H.eq(found[2].key, "2"); H.eq(found[2].label, "Yes, and don't ask again")
    H.eq(found[3].label, "No")
    H.eq(#ansi.choices("no options here\n10 items"), 0)
    H.eq(#ansi.choices(nil), 0)
end)

H.test("symbols the terminal font lacks become ones it has, one column each", function()
    local ansi = require("orca.render.ansi")
    H.eq(ansi.formatLines({ "⏺ Done", "  ⎿  Read 3 files", "⏵⏵ auto mode" }),
         "● Done\n  └  Read 3 files\n▶▶ auto mode")
    H.eq(ansi.formatLines({ "─│╭╮" }), "─│╭╮", "box drawing stays")
end)
