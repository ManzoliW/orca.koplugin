--[[
    touch.lua: inject touch gestures on the Kindle by writing evdev events.

    Run on the device with KOReader's LuaJIT:
        cd /mnt/us/koreader && ./luajit /mnt/us/orca-dev/tools/touch.lua [flags] <command>

    Commands (coordinates are screen pixels unless --raw):
        probe                          print touch device, axis ranges, framebuffer size
        tap X Y
        longpress X Y [ms]             default 800 ms
        swipe X1 Y1 X2 Y2 [ms]         default 300 ms

    Flags:
        --dev /dev/input/eventN        skip the capability scan
        --fbw W --fbh H                framebuffer (screen) size, else read from /sys
        --swap                         panel X axis runs along screen Y
        --invert-x / --invert-y        flip panel axes (applied after --swap)
        --raw                          coordinates are already panel units

    Needs no extra binaries: the kernel accepts input_event structs written to
    /dev/input/eventN by root and injects them like real touches.
--]]

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
int open(const char *pathname, int flags, ...);
int close(int fd);
int ioctl(int fd, unsigned long request, ...);
ssize_t write(int fd, const void *buf, size_t count);
int usleep(unsigned int usec);
struct input_event { int32_t sec; int32_t usec; uint16_t type; uint16_t code; int32_t value; };
struct input_absinfo { int32_t value, minimum, maximum, fuzz, flat, resolution; };
]]

local C = ffi.C
local O_RDWR = 2

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT, SYN_MT_REPORT = 0, 2
local BTN_TOUCH = 0x14a
local ABS_X, ABS_Y = 0, 1
local ABS_MT_SLOT = 0x2f
local ABS_MT_TOUCH_MAJOR = 0x30
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39
local ABS_MAX = 0x3f

-- _IOC(dir, type, nr, size); dir 2 = read. Normalised to a positive number
-- because bit ops return signed int32 and the ioctl request is unsigned.
local function IOC(dir, typ, nr, size)
    local v = bit.bor(bit.lshift(dir, 30), bit.lshift(size, 16), bit.lshift(typ, 8), nr)
    if v < 0 then v = v + 2 ^ 32 end
    return v
end
local E = string.byte("E")
local EVIOCGNAME = IOC(2, E, 0x06, 256)
local EVIOCGBIT_ABS = IOC(2, E, 0x20 + EV_ABS, math.floor(ABS_MAX / 8) + 1)
local function EVIOCGABS(code) return IOC(2, E, 0x40 + code, ffi.sizeof("struct input_absinfo")) end

local function hasBit(bits, n)
    return bit.band(bits[math.floor(n / 8)], bit.lshift(1, n % 8)) ~= 0
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Visible framebuffer size: `modes` has the visible mode, virtual_size may be padded.
local function fbSize()
    local modes = readFile("/sys/class/graphics/fb0/modes") or ""
    local w, h = modes:match("(%d+)x(%d+)")
    if not w then
        w, h = (readFile("/sys/class/graphics/fb0/virtual_size") or ""):match("(%d+),(%d+)")
    end
    return tonumber(w), tonumber(h)
end

local function openDevice(path)
    local fd = C.open(path, O_RDWR)
    if fd < 0 then return nil end
    local name = ffi.new("char[256]")
    C.ioctl(fd, EVIOCGNAME, name)
    local absbits = ffi.new("uint8_t[?]", math.floor(ABS_MAX / 8) + 1)
    C.ioctl(fd, EVIOCGBIT_ABS, absbits)
    local dev = {
        fd = fd,
        path = path,
        name = ffi.string(name),
        mt = hasBit(absbits, ABS_MT_POSITION_X),
        slots = hasBit(absbits, ABS_MT_SLOT),
        major = hasBit(absbits, ABS_MT_TOUCH_MAJOR),
        st = hasBit(absbits, ABS_X),
    }
    local function range(code)
        local info = ffi.new("struct input_absinfo")
        if C.ioctl(fd, EVIOCGABS(code), info) < 0 then return nil end
        return { min = info.minimum, max = info.maximum }
    end
    if dev.mt then
        dev.x, dev.y = range(ABS_MT_POSITION_X), range(ABS_MT_POSITION_Y)
    elseif dev.st then
        dev.x, dev.y = range(ABS_X), range(ABS_Y)
    end
    return dev
end

local function findDevice(forced)
    if forced then
        local dev = openDevice(forced)
        if not dev then error("cannot open " .. forced) end
        return dev
    end
    local fallback
    for i = 0, 15 do
        local dev = openDevice("/dev/input/event" .. i)
        if dev then
            if dev.mt then return dev end
            if dev.st and not fallback then
                fallback = dev
            else
                C.close(dev.fd)
            end
        end
    end
    if fallback then return fallback end
    error("no touch device found under /dev/input (needs ABS_MT_POSITION_X or ABS_X)")
end

-- Argument parsing -----------------------------------------------------------

local opts, args = { ms = nil }, {}
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--dev" then opts.dev = arg[i + 1]; i = i + 1
    elseif a == "--fbw" then opts.fbw = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--fbh" then opts.fbh = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--swap" then opts.swap = true
    elseif a == "--invert-x" then opts.invert_x = true
    elseif a == "--invert-y" then opts.invert_y = true
    elseif a == "--raw" then opts.raw = true
    else args[#args + 1] = a end
    i = i + 1
end
local cmd = args[1]
if not cmd then
    io.stderr:write("usage: touch.lua [flags] probe | tap X Y | longpress X Y [ms] | swipe X1 Y1 X2 Y2 [ms]\n")
    os.exit(2)
end

local fbw, fbh = fbSize()
fbw, fbh = opts.fbw or fbw, opts.fbh or fbh
local dev = findDevice(opts.dev)

if cmd == "probe" then
    print(string.format("device %s (%s)", dev.path, dev.name))
    print(string.format("protocol %s", dev.mt and (dev.slots and "MT type B" or "MT type A") or "single-touch"))
    if dev.x then
        print(string.format("abs x %d..%d  y %d..%d", dev.x.min, dev.x.max, dev.y.min, dev.y.max))
    end
    print(string.format("fb %sx%s  bpp %s  stride %s",
        tostring(fbw), tostring(fbh),
        (readFile("/sys/class/graphics/fb0/bits_per_pixel") or "?"):gsub("%s", ""),
        (readFile("/sys/class/graphics/fb0/stride") or "?"):gsub("%s", "")))
    local other = {}
    for n = 0, 15 do
        local name = readFile("/sys/class/input/event" .. n .. "/device/name")
        if name then other[#other + 1] = "event" .. n .. "=" .. name:gsub("%s+$", "") end
    end
    print("inputs " .. table.concat(other, "  "))
    os.exit(0)
end

if not dev.x then error("device reports no axis ranges; use --raw") end

-- Screen pixels -> panel units. --swap first (panel X along screen Y), then
-- inversions in panel axes, then scale into the reported ABS ranges.
local function map(sx, sy)
    if opts.raw then return math.floor(sx), math.floor(sy) end
    if not fbw or not fbh then error("framebuffer size unknown; pass --fbw/--fbh or --raw") end
    local nx, ny = sx / (fbw - 1), sy / (fbh - 1)
    if opts.swap then nx, ny = ny, nx end
    if opts.invert_x then nx = 1 - nx end
    if opts.invert_y then ny = 1 - ny end
    nx, ny = math.min(1, math.max(0, nx)), math.min(1, math.max(0, ny))
    return math.floor(dev.x.min + nx * (dev.x.max - dev.x.min) + 0.5),
           math.floor(dev.y.min + ny * (dev.y.max - dev.y.min) + 0.5)
end

-- Event emission -----------------------------------------------------------

local ev = ffi.new("struct input_event")
local EV_SIZE = ffi.sizeof("struct input_event") -- 16 on 32-bit ARM
local function emit(type_, code, value)
    ev.type, ev.code, ev.value = type_, code, value
    if C.write(dev.fd, ev, EV_SIZE) ~= EV_SIZE then error("write to " .. dev.path .. " failed") end
end
local function syn() emit(EV_SYN, SYN_REPORT, 0) end

local function position(tx, ty)
    if dev.mt then
        emit(EV_ABS, ABS_MT_POSITION_X, tx)
        emit(EV_ABS, ABS_MT_POSITION_Y, ty)
    end
    if dev.st or not dev.mt then
        emit(EV_ABS, ABS_X, tx)
        emit(EV_ABS, ABS_Y, ty)
    end
end

local function down(tx, ty)
    if dev.slots then
        emit(EV_ABS, ABS_MT_SLOT, 0)
        emit(EV_ABS, ABS_MT_TRACKING_ID, 1)
        if dev.major then emit(EV_ABS, ABS_MT_TOUCH_MAJOR, 1) end
    elseif dev.mt then
        -- Type A panels on Kindles (cyttsp5, KOReader's "snow protocol") report
        -- a slot-like tracking id per frame and lift via BTN_TOUCH:0 only.
        emit(EV_ABS, ABS_MT_TRACKING_ID, 0)
    end
    position(tx, ty)
    if dev.mt and not dev.slots then emit(EV_SYN, SYN_MT_REPORT, 0) end
    emit(EV_KEY, BTN_TOUCH, 1)
    syn()
end

local function move(tx, ty)
    if dev.slots then emit(EV_ABS, ABS_MT_SLOT, 0) end
    position(tx, ty)
    if dev.mt and not dev.slots then emit(EV_SYN, SYN_MT_REPORT, 0) end
    syn()
end

local function up()
    if dev.slots then
        emit(EV_ABS, ABS_MT_SLOT, 0)
        emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
    elseif dev.mt then
        emit(EV_SYN, SYN_MT_REPORT, 0)
    end
    emit(EV_KEY, BTN_TOUCH, 0)
    syn()
end

local function sleepMs(ms) C.usleep(math.floor(ms * 1000)) end

local function num(k, what)
    local v = tonumber(args[k])
    if not v then error("missing or bad " .. what) end
    return v
end

if cmd == "tap" or cmd == "longpress" then
    local sx, sy = num(2, "X"), num(3, "Y")
    local hold = tonumber(args[4]) or (cmd == "tap" and 60 or 800)
    local tx, ty = map(sx, sy)
    down(tx, ty)
    sleepMs(hold)
    up()
    print(string.format("ok %s %d,%d -> %s %d,%d (%d ms)", cmd, sx, sy, dev.path, tx, ty, hold))
elseif cmd == "swipe" then
    local x1, y1, x2, y2 = num(2, "X1"), num(3, "Y1"), num(4, "X2"), num(5, "Y2")
    local ms = tonumber(args[6]) or 300
    local steps = math.max(2, math.floor(ms / 16))
    down(map(x1, y1))
    for s = 1, steps do
        sleepMs(ms / steps)
        local t = s / steps
        move(map(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t))
    end
    sleepMs(20)
    up()
    print(string.format("ok swipe %d,%d -> %d,%d on %s (%d ms, %d steps)", x1, y1, x2, y2, dev.path, ms, steps))
else
    error("unknown command " .. cmd)
end

C.close(dev.fd)
