--[[
    NaCl box (Curve25519 + XSalsa20-Poly1305) via a TweetNaCl shared library.
    Matches tweetnacl-js `nacl.box.before` / `nacl.box.after` / `nacl.box.open.after`.
--]]

local ffi = require("ffi")

ffi.cdef[[
int crypto_box_curve25519xsalsa20poly1305_tweet_keypair(unsigned char *pk, unsigned char *sk);
int crypto_box_curve25519xsalsa20poly1305_tweet_beforenm(unsigned char *k, const unsigned char *pk, const unsigned char *sk);
int crypto_box_curve25519xsalsa20poly1305_tweet_afternm(unsigned char *c, const unsigned char *m, unsigned long long d, const unsigned char *n, const unsigned char *k);
int crypto_box_curve25519xsalsa20poly1305_tweet_open_afternm(unsigned char *m, const unsigned char *c, unsigned long long d, const unsigned char *n, const unsigned char *k);
void randombytes(unsigned char *buf, unsigned long long len);
]]

local KEY_BYTES = 32
local NONCE_BYTES = 24
-- NaCl's C API pads plaintext with 32 zero bytes and ciphertext with 16.
local ZERO_BYTES = 32
local BOX_ZERO_BYTES = 16

local NaCl = {
    KEY_BYTES = KEY_BYTES,
    NONCE_BYTES = NONCE_BYTES,
    OVERHEAD = ZERO_BYTES - BOX_ZERO_BYTES,
}

local lib

function NaCl.load(path)
    lib = ffi.load(path)
end

function NaCl.randomBytes(n)
    local buf = ffi.new("unsigned char[?]", n)
    lib.randombytes(buf, n)
    return ffi.string(buf, n)
end

-- Returns publicKey, secretKey as 32-byte strings.
function NaCl.keyPair()
    local pk = ffi.new("unsigned char[?]", KEY_BYTES)
    local sk = ffi.new("unsigned char[?]", KEY_BYTES)
    lib.crypto_box_curve25519xsalsa20poly1305_tweet_keypair(pk, sk)
    return ffi.string(pk, KEY_BYTES), ffi.string(sk, KEY_BYTES)
end

function NaCl.before(their_public, my_secret)
    assert(#their_public == KEY_BYTES and #my_secret == KEY_BYTES, "bad key length")
    local k = ffi.new("unsigned char[?]", KEY_BYTES)
    lib.crypto_box_curve25519xsalsa20poly1305_tweet_beforenm(k, their_public, my_secret)
    return ffi.string(k, KEY_BYTES)
end

-- Returns ciphertext (plaintext length + 16 bytes of MAC).
function NaCl.after(plaintext, nonce, shared)
    assert(#nonce == NONCE_BYTES, "bad nonce length")
    local len = #plaintext + ZERO_BYTES
    local m = ffi.new("unsigned char[?]", len)
    ffi.copy(m + ZERO_BYTES, plaintext, #plaintext)
    local c = ffi.new("unsigned char[?]", len)
    lib.crypto_box_curve25519xsalsa20poly1305_tweet_afternm(c, m, len, nonce, shared)
    return ffi.string(c + BOX_ZERO_BYTES, len - BOX_ZERO_BYTES)
end

-- Returns plaintext, or nil when authentication fails.
function NaCl.openAfter(ciphertext, nonce, shared)
    if #nonce ~= NONCE_BYTES or #ciphertext < NaCl.OVERHEAD then
        return nil
    end
    local len = #ciphertext + BOX_ZERO_BYTES
    local c = ffi.new("unsigned char[?]", len)
    ffi.copy(c + BOX_ZERO_BYTES, ciphertext, #ciphertext)
    local m = ffi.new("unsigned char[?]", len)
    if lib.crypto_box_curve25519xsalsa20poly1305_tweet_open_afternm(m, c, len, nonce, shared) ~= 0 then
        return nil
    end
    return ffi.string(m + ZERO_BYTES, len - ZERO_BYTES)
end

return NaCl
