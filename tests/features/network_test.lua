-- The connection card the status line opens.
local H = require("tests.harness")

local function fakeTailscale(up)
    local ts = { up = up }
    function ts.isUp() return ts.up end
    function ts.startTailscale() ts.up = true end
    function ts.stopTailscale() ts.up = false end
    return ts
end

H.test("the card says what's on and turns Tailscale on or off", function()
    local app, t = H.app()
    local ts = fakeTailscale(false)
    app.tailscale = function() return ts end
    app.status = function() return { battery = 42, charging = true } end
    app.network:open()
    local card = t.lastCard()
    H.eq(card.title, "Connection")
    H.has(card.text, "Tailscale: off")
    H.has(card.text, "PC: ")
    H.has(card.text, "Battery: 42% (charging)")
    t.press("Turn Tailscale on")
    H.eq(ts.up, true)
    app.network:open()
    H.eq(t.lastCard().actions[1].text, "Turn Tailscale off")
end)

H.test("without the Tailscale plugin or a pairing, the card only reports", function()
    local app, t = H.app({ settings = {} })
    app.network:open()
    local card = t.lastCard()
    H.eq(card.text:find("Tailscale", 1, true), nil)
    H.has(card.text, "PC: not paired")
    H.eq(#card.actions, 0)
end)

H.test("the connection test reports the workspaces it found, or the error with Retry", function()
    local app, t = H.app()
    t.client.host, t.client.port = "100.64.0.2", 6768
    app.network:open()
    t.press("Test connection")
    H.eq(t.lastCard().title, "Connected")
    H.has(t.lastCard().text, "2 workspaces")

    H.results["worktree.ps"] = function() return nil, "proxy: connection refused" end
    app.network:test(); t.settle()
    H.eq(t.lastCard().title, "Can't reach Orca")
    H.has(t.lastCard().text, "tap the status line")
    H.eq(type(t.lastCard().retry), "function")
end)
