--[[
    Kindle firmware 5.16+ draws its status bar (clock, Wi-Fi, battery) with
    /app/bin/JunoStatusBarDriver. KOReader's launcher hides the older "pillow"
    status bar and pauses the window manager, but not this one, so every
    minute the clock is redrawn over KOReader's top-left corner (and Wi-Fi and
    battery over the top right), covering title bar buttons.

    This pauses the status bar while KOReader runs. 9-kindle-statusbar-show.lua
    resumes it on a normal exit; a small watcher resumes it when KOReader
    is killed or crashes instead.
--]]

local Device = require("device")
if not Device:isKindle() then return end

local ffi = require("ffi")
pcall(ffi.cdef, "int getpid(void);")
local pid = ffi.C.getpid()

os.execute("killall -STOP JunoStatusBarDriver 2>/dev/null")
os.execute(string.format(
    "setsid sh -c 'while kill -0 %d 2>/dev/null; do sleep 2; done; killall -CONT JunoStatusBarDriver' " ..
    ">/dev/null 2>&1 </dev/null &", pid))
