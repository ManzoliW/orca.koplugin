--[[
    Network work runs in coroutines (the socket layer yields whenever it would
    block), stepped from the UI loop so KOReader never freezes. Jobs share one
    socket, so they run one at a time; what the user asked for runs before
    background work (polls, pumps) that is still waiting.

    job = {
        run = function(client) -> result, err   -- inside the coroutine
        done = function(result, err)            -- back on the UI loop
        busy = "Pushing to origin…"             -- optional, shows a dismissable message
        background = true                       -- optional, lower priority, never shows errors
        once = true                             -- optional, don't re-run after a reconnect
                                                -- (set it on anything that changes state)
    }
--]]

local Jobs = {}
Jobs.__index = Jobs

-- opts: connection (ensure(), isConnected()), schedule(delay, fn), busy(text, on_cancel) -> close, log(...)
function Jobs.new(opts)
    return setmetatable({
        connection = opts.connection,
        schedule = opts.schedule,
        busy = opts.busy,
        log = opts.log or function() end,
        queue = {},
        current = nil,
    }, Jobs)
end

function Jobs:run(job)
    if job.background then
        table.insert(self.queue, job)
    else
        -- Ahead of queued background work, behind other user jobs.
        local at = #self.queue + 1
        for i, queued in ipairs(self.queue) do
            if queued.background then at = i; break end
        end
        table.insert(self.queue, at, job)
    end
    if not self.current then self:next() end
    return job
end

function Jobs:isBusy()
    return self.current ~= nil
end

-- Drops queued jobs matching pred (all when nil); a running job finishes quietly.
function Jobs:cancel(pred)
    for i = #self.queue, 1, -1 do
        if not pred or pred(self.queue[i]) then table.remove(self.queue, i) end
    end
    if self.current and (not pred or pred(self.current)) then self.current.cancelled = true end
end

-- Runs fn(client), connecting first; after a dropped connection, reconnects
-- and runs it once more unless the job changes state.
function Jobs:execute(job)
    local client, err = self.connection:ensure()
    if not client then return nil, err end
    local result, rerr = job.run(client)
    if result == nil and not job.once and not self.connection:isConnected() then
        client, err = self.connection:ensure()
        if not client then return nil, err end
        result, rerr = job.run(client)
    end
    return result, rerr
end

function Jobs:next()
    local job = table.remove(self.queue, 1)
    self.current = job
    if not job then return end

    local close_busy
    if job.busy and self.busy then
        -- Dismissing the message abandons the wait; the request finishes quietly.
        close_busy = self.busy(job.busy, function()
            close_busy = nil
            job.cancelled = true
        end)
    end

    local co = coroutine.create(function() return self:execute(job) end)
    local function step()
        local ok, result, err = coroutine.resume(co)
        if ok and coroutine.status(co) ~= "dead" then
            self.schedule(0.1, step)
            return
        end
        if not ok then
            self.log("job failed:", result, debug.traceback(co))
            result, err = nil, tostring(result)
        end
        if close_busy then close_busy() end
        -- Still `current` while done runs, so jobs it queues wait their turn.
        if not job.cancelled and job.done then
            local cb_ok, cb_err = pcall(job.done, result, err)
            if not cb_ok then self.log("job callback failed:", cb_err) end
        end
        self.current = nil
        self:next()
    end
    step()
end

return Jobs
