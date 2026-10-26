-- Run on the Kindle: luajit tests/nacl_test.lua <plugin_dir> <vectors.json>
local plugin_dir, vec_path = arg[1], arg[2]
package.path = plugin_dir .. "/?.lua;" .. package.path

local NaCl = require("orcaclient.nacl")
local Base64 = require("orcaclient.base64")
NaCl.load(plugin_dir .. "/lib/libtweetnacl.so")

local raw = assert(io.open(vec_path)):read("*a")
local function field(name) return raw:match('"' .. name .. '":"(.-)"[,}]') end
local function b64(name) return Base64.decode(field(name)) end

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print((ok and "PASS " or "FAIL ") .. label)
end

local msg = raw:match('"msg":"(.-)","ct"'):gsub('\\"', '"')
check("base64 roundtrip", Base64.encode(b64("ct")), field("ct"))
local shared = NaCl.before(b64("pk2"), b64("sk1"))
check("box.before matches tweetnacl-js", Base64.encode(shared), field("shared"))
local ct = NaCl.after(msg, b64("nonce"), shared)
check("box.after matches tweetnacl-js", Base64.encode(ct), field("ct"))
check("box.open.after decrypts tweetnacl-js ciphertext", NaCl.openAfter(b64("ct"), b64("nonce"), shared), msg)
local tampered = ct:sub(1, 5) .. string.char((ct:byte(6) + 1) % 256) .. ct:sub(7)
check("box.open.after rejects tampering", NaCl.openAfter(tampered, b64("nonce"), shared), nil)
local pk, sk = NaCl.keyPair()
local pk2 = b64("pk2")
check("keypair interop", NaCl.before(pk2, sk), NaCl.before(pk, b64("sk2")))

local t0 = os.clock()
for _ = 1, 5 do NaCl.before(pk2, sk) end
print(string.format("box.before: %.0f ms each", (os.clock() - t0) / 5 * 1000))
local big = string.rep("x", 200000)
t0 = os.clock()
NaCl.openAfter(NaCl.after(big, b64("nonce"), shared), b64("nonce"), shared)
print(string.format("200 KB encrypt+decrypt: %.0f ms", (os.clock() - t0) * 1000))
os.exit(failures == 0 and 0 or 1)
