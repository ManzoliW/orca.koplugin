--[[
    The app context every feature receives: settings, the job queue, the
    connection, navigation and dialogs, plus the features themselves
    (app.home, app.git, …) so they can open each other's screens.

    Features never touch KOReader widgets directly; they describe screens for
    app.nav and use app.dialog / app.text. Tests swap those for fakes.
--]]

local _ = require("orca.core.i18n")
local T = require("ffi/util").template

local util = require("orca.core.util")

local App = {}
App.__index = App

App.DOCS_DIR = "/mnt/us/documents/Claude"

App.AGENTS = {
    claude = "Claude",
    codex = "Codex",
    gemini = "Gemini",
    opencode = "OpenCode",
}

-- opts: settings, connection, jobs, nav, dialog, text, online(fn), log, docs_dir
function App.new(opts)
    local app = setmetatable({}, App)
    for k, v in pairs(opts) do app[k] = v end
    app.docs_dir = opts.docs_dir or App.DOCS_DIR
    return app
end

function App:run(job)
    return self.jobs:run(job)
end

-- Agent for new sessions, and its display name.
function App:agent()
    return self.settings:get("agent")
end

function App:agentName(id)
    id = id or self:agent()
    return App.AGENTS[id] or id
end

-- Turns transport errors into something the user can act on.
function App:explain(err)
    local e = tostring(err or "")
    if e == "not paired" then
        return _("This Kindle isn't paired with Orca yet. Open Tools → Orca → Pairing.")
    end
    if e:match("timed out") or e:match("timeout") or e:match("refused") or e:match("SOCKS")
            or e:match("not connected") or e:match("closed") or e:match("unreachable") then
        return T(_("Can't reach your PC. Check that Orca is running and Tailscale is on.\n\n(%1)"), e)
    end
    -- The desktop keeps some methods (automations, for one) from mobile clients.
    if e:match("^forbidden") or e:match("not available to mobile") then
        return _("Orca doesn't let phones or the Kindle do this. Use Orca on your PC.")
    end
    if e:match("authentication") then
        return _("Orca rejected this Kindle. The pairing may have been revoked: pair again in Tools → Orca → Pairing.")
    end
    return e
end

function App:fail(err, retry)
    self.dialog.alert{ title = _("Something went wrong"), text = self:explain(err), retry = retry }
end

function App:toast(text, timeout)
    self.dialog.toast(text, timeout)
end

-- Runs a job and shows its error (with Retry when it is safe to repeat).
-- opts = job fields; done(result) only runs on success.
function App:request(opts)
    local done = opts.done
    local job
    job = {
        busy = opts.busy,
        once = opts.once,
        background = opts.background,
        run = opts.run,
        done = function(result, err)
            if result == nil then
                if opts.background then return end
                if opts.on_error then return opts.on_error(err) end
                return self:fail(err, not opts.once and function() self:request(opts) end or nil)
            end
            if done then done(result) end
        end,
    }
    return self:run(job)
end

-- Saves text under documents/Claude and opens it as a book.
function App:openAsBook(name, body)
    self.nav:close()
    local ok, err = self.text.book(self.docs_dir, name, body)
    if not ok then self:fail(err) end
end

App.util = util

return App
