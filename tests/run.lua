-- Runs every PC test:  luajit tests/run.lua   (from the repo root)
local H = require("tests.harness")
local dir = "tests/features"
local p = io.popen('ls "' .. dir .. '"')
for file in p:lines() do
    if file:match("_test%.lua$") then
        print(file)
        dofile(dir .. "/" .. file)
    end
end
p:close()
print(string.format("\n%d passed, %d failed", H.passed, H.failures))
os.exit(H.failures == 0 and 0 or 1)
