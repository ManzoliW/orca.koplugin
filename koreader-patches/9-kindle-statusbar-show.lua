-- Resumes the Kindle status bar paused by 2-kindle-statusbar-hide.lua.

local Device = require("device")
if not Device:isKindle() then return end

os.execute("killall -CONT JunoStatusBarDriver 2>/dev/null")
