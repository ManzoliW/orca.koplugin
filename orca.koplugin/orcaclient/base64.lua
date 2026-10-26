--[[
    Standard and URL-safe base64 for LuaJIT.
--]]

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local enc, dec = {}, {}
for i = 1, 64 do
    local c = ALPHABET:byte(i)
    enc[i - 1] = string.char(c)
    dec[c] = i - 1
end
-- Accept the URL-safe alphabet when decoding.
dec[("-"):byte()] = 62
dec[("_"):byte()] = 63

local Base64 = {}

function Base64.encode(s)
    local out = {}
    local n = #s
    for i = 1, n, 3 do
        local a, b, c = s:byte(i, i + 2)
        local v = bor(lshift(a, 16), lshift(b or 0, 8), c or 0)
        out[#out + 1] = enc[rshift(v, 18)] .. enc[band(rshift(v, 12), 63)]
            .. (b and enc[band(rshift(v, 6), 63)] or "=")
            .. (c and enc[band(v, 63)] or "=")
    end
    return table.concat(out)
end

-- Ignores padding and whitespace; returns nil on an invalid character.
function Base64.decode(s)
    local out = {}
    local acc, bits = 0, 0
    for i = 1, #s do
        local ch = s:byte(i)
        local v = dec[ch]
        if v then
            acc = bor(lshift(band(acc, 0xFFFF), 6), v)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = string.char(band(rshift(acc, bits), 0xFF))
            end
        elseif ch ~= 61 and ch ~= 10 and ch ~= 13 and ch ~= 32 then -- '=', '\n', '\r', ' '
            return nil
        end
    end
    return table.concat(out)
end

return Base64
