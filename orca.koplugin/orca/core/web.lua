--[[
    Plain HTTPS GETs from the Kindle itself (not through Orca), run in a
    child process so a slow page never freezes KOReader. The child can
    shrink the page (transform) before handing it back over the pipe.

        web.fetch(url, { transform = fn(body) -> string, timeout = s },
                  done(text or nil, err))

    Features reach it as app.web; tests replace it with a fake.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local web = {}

local POLL = 0.5            -- s between checks on the child
local TIMEOUT = 60          -- s before giving up on it

function web.fetch(url, opts, done)
    opts = opts or {}
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local https = require("ssl.https")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local sink = {}
        local code = socket.skip(1, https.request{
            url = url,
            sink = ltn12.sink.table(sink),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
        })
        socketutil:reset_timeout()
        local out
        if code == 200 then
            local body = table.concat(sink)
            local ok, text = pcall(opts.transform or function(b) return b end, body)
            out = ok and ("1" .. tostring(text)) or ("0" .. tostring(text))
        else
            out = "0HTTP " .. tostring(code)
        end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then
        return done(nil, tostring(fd))
    end

    local started = os.time()
    local function check()
        local ready = ffiutil.getNonBlockingReadSize(fd)
        if ready and ready > 0 then
            local data = ffiutil.readAllFromFD(fd)
            ffiutil.isSubProcessDone(pid, true)
            if data:sub(1, 1) == "1" then return done(data:sub(2)) end
            logger.warn("Orca: fetch failed:", url, data:sub(2))
            return done(nil, data:sub(2))
        end
        if ffiutil.isSubProcessDone(pid) then
            -- It may have written and exited since the check above.
            local late = ffiutil.getNonBlockingReadSize(fd)
            if late and late > 0 then return check() end
            return done(nil, "no answer")
        end
        if os.time() - started > (opts.timeout or TIMEOUT) then
            ffiutil.terminateSubProcess(pid)
            return done(nil, "timed out")
        end
        UIManager:scheduleIn(POLL, check)
    end
    UIManager:scheduleIn(POLL, check)
end

return web
