#!/usr/bin/env python3
"""
kindlectl: see and drive the Kindle from the PC over SSH (Tailscale).

    python tools/kindlectl.py shot                 screenshot -> scratchpad/shots/<ts>.png
    python tools/kindlectl.py shot --scale 0.5 out.png
    python tools/kindlectl.py tap 500 700
    python tools/kindlectl.py swipe 800 700 200 700 --ms 300
    python tools/kindlectl.py longpress 500 700 --ms 800
    python tools/kindlectl.py probe                touch device, axis ranges, framebuffer
    python tools/kindlectl.py profile [KEY VALUE]  show / set calibration (device/profile.json)
    python tools/kindlectl.py key menu|back        tap a profile-defined spot
    python tools/kindlectl.py restart              stop KOReader cleanly and relaunch it
    python tools/kindlectl.py log [-n 60]          tail crash.log
    python tools/kindlectl.py deploy               copy orca.koplugin/ to the device
    python tools/kindlectl.py sh CMD...            run a shell command

Stdlib only; shells out to the ssh executable (key-based login, no password).
"""

import argparse
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import sys
import tarfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
TOUCH_LUA = os.path.join(HERE, "device", "touch.lua")
PROFILE = os.path.join(HERE, "device", "profile.json")
REMOTE_TOUCH = "/mnt/us/orca-dev/tools/touch.lua"
LUAJIT_DIR = "/mnt/us/koreader"
PLUGIN_DEST = "/mnt/us/koreader/plugins/orca.koplugin"
CRASH_LOG = "/mnt/us/koreader/crash.log"
SHOTS_DIR = os.environ.get("KINDLE_SHOTS_DIR", os.path.join(os.getcwd(), "shots"))
DEFAULT_HOST = os.environ.get("KINDLE_HOST", "kindle")  # Tailscale MagicDNS name or IP

DEFAULT_PROFILE = {
    "device": None,          # /dev/input/eventN, or null to auto-detect
    "swap_xy": False,
    "invert_x": False,
    "invert_y": False,
    "fb_width": None,        # null = read from /sys on the device
    "fb_height": None,
    "invert_gray": False,    # set true if screenshots come out as negatives
    "rotate": 0,             # 0/90/180/270, if the framebuffer is stored rotated
    # Key spots as [x, y]; values <= 1 are fractions of the screen size.
    "keys": {"menu": [0.5, 0.03], "back": [0.05, 0.03]},
}


# SSH plumbing ----------------------------------------------------------------

class Device:
    def __init__(self, host, user, port):
        self.target = "%s@%s" % (user, host)
        self.port = str(port)

    def _base(self):
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new", "-p", self.port, self.target]

    def run(self, cmd, stdin=None, check=True, timeout=120):
        """Run a remote shell command; returns stdout bytes."""
        p = subprocess.run(self._base() + [cmd], input=stdin, capture_output=True, timeout=timeout)
        if check and p.returncode != 0:
            err = p.stderr.decode("utf-8", "replace").strip()
            if "Connection timed out" in err or "No route to host" in err:
                raise SystemExit("Kindle unreachable over SSH (asleep, in USB mode, or Tailscale down).")
            raise SystemExit("remote command failed (%d): %s\n%s" % (p.returncode, cmd, err))
        return p.stdout

    def text(self, cmd, **kw):
        return self.run(cmd, **kw).decode("utf-8", "replace")

    def stream(self, cmd):
        """Run a remote command with output going straight to the terminal."""
        return subprocess.call(self._base() + [cmd])


# Profile -------------------------------------------------------------------

def load_profile():
    prof = json.loads(json.dumps(DEFAULT_PROFILE))
    if os.path.exists(PROFILE):
        with open(PROFILE, "r", encoding="utf-8") as f:
            prof.update(json.load(f))
    return prof


def save_profile(prof):
    os.makedirs(os.path.dirname(PROFILE), exist_ok=True)
    with open(PROFILE, "w", encoding="utf-8") as f:
        json.dump(prof, f, indent=2)
        f.write("\n")


def touch_flags(prof, args):
    flags = []
    if prof.get("device"):
        flags += ["--dev", prof["device"]]
    if prof.get("swap_xy"):
        flags.append("--swap")
    if prof.get("invert_x"):
        flags.append("--invert-x")
    if prof.get("invert_y"):
        flags.append("--invert-y")
    if prof.get("fb_width") and prof.get("fb_height"):
        flags += ["--fbw", str(prof["fb_width"]), "--fbh", str(prof["fb_height"])]
    if getattr(args, "raw", False):
        flags.append("--raw")
    return flags


# Touch injection ---------------------------------------------------------------

def ensure_touch_script(dev):
    """Upload touch.lua once; re-upload only when the local copy changed."""
    with open(TOUCH_LUA, "rb") as f:
        local = f.read()
    local_md5 = hashlib.md5(local).hexdigest()
    remote = dev.text("md5sum %s 2>/dev/null | cut -d' ' -f1" % REMOTE_TOUCH, check=False).strip()
    if remote != local_md5:
        dev.run("mkdir -p %s && cat > %s" % (os.path.dirname(REMOTE_TOUCH), REMOTE_TOUCH), stdin=local)


def run_touch(dev, prof, args, words):
    ensure_touch_script(dev)
    cmd = "cd %s && ./luajit %s %s" % (LUAJIT_DIR, REMOTE_TOUCH,
                                        " ".join(touch_flags(prof, args) + [str(w) for w in words]))
    return dev.text(cmd)


# Framebuffer -> PNG ----------------------------------------------------------

def png_write(path, width, height, rows, gray):
    """rows: list of bytes (one per scanline), gray -> 8-bit grayscale else RGB."""
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0 if gray else 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def fetch_fb(dev):
    """Returns (info dict, raw framebuffer bytes). One ssh round trip."""
    header_cmd = (
        "cd /sys/class/graphics/fb0 && "
        "echo virtual_size=$(cat virtual_size); echo bpp=$(cat bits_per_pixel); "
        "echo stride=$(cat stride 2>/dev/null); echo modes=$(head -1 modes 2>/dev/null); "
        "echo fbset=$(fbset 2>/dev/null | tr '\\n' ' '); echo __FB__; gzip -1 -c /dev/fb0")
    out = dev.run(header_cmd, timeout=180)
    head, _, data = out.partition(b"__FB__\n")
    # Compressed on the device: mostly white e-ink pages shrink a lot.
    data = zlib.decompress(data, 16 + zlib.MAX_WBITS)
    info = {}
    for line in head.decode("utf-8", "replace").splitlines():
        k, _, v = line.partition("=")
        info[k.strip()] = v.strip()
    return info, data


def decode_fb(info, data, args):
    vw, vh = [int(x) for x in re.findall(r"\d+", info.get("virtual_size", ""))[:2]] or (0, 0)
    bpp = int(info.get("bpp") or 8)
    stride = int(info.get("stride") or 0)
    # Visible size: modes ("U:1072x1448p-0") or fbset geometry, else the virtual size.
    width, height = vw, vh
    m = re.search(r"(\d+)x(\d+)", info.get("modes", ""))
    if m:
        width, height = int(m.group(1)), int(m.group(2))
    else:
        g = re.search(r"geometry (\d+) (\d+)", info.get("fbset", ""))
        if g:
            width, height = int(g.group(1)), int(g.group(2))
    width = args.width or width
    height = args.height or height
    bpp = args.bpp or bpp
    bytespp = bpp // 8
    if not stride:
        stride = max(vw, width) * bytespp
    if len(data) < stride * height:
        # Short read: trust what we got rather than fail.
        height = len(data) // stride
    return width, height, bpp, stride


def convert_rows(data, width, height, bpp, stride, step, invert):
    rows = []
    bytespp = bpp // 8
    for y in range(0, height, step):
        off = y * stride
        row = data[off:off + width * bytespp]
        if bpp == 8:
            px = row[::step]
            if invert:
                px = bytes(255 - b for b in px)
            rows.append(px)
        elif bpp == 16:
            vals = struct.unpack("<%dH" % (len(row) // 2), row)[::step]
            out = bytearray()
            for v in vals:
                out += bytes(((v >> 11) << 3, ((v >> 5) & 0x3F) << 2, (v & 0x1F) << 3))
            rows.append(bytes(out))
        elif bpp == 32:
            out = bytearray()
            for x in range(0, len(row), 4 * step):
                b, g, r = row[x], row[x + 1], row[x + 2]  # BGRA, the usual fb layout
                out += bytes((r, g, b))
            rows.append(bytes(out))
        else:
            raise SystemExit("unsupported bits_per_pixel %d (pass --bpp)" % bpp)
    return rows


def rotate_rows(rows, width, height, gray, deg):
    """Rotate scanlines (nearest, lossless) so the PNG is upright."""
    if deg % 360 == 0:
        return rows, width, height
    n = 1 if gray else 3
    pix = [[r[x * n:(x + 1) * n] for x in range(width)] for r in rows]
    if deg == 90:
        new = [[pix[height - 1 - y][x] for y in range(height)] for x in range(width)]
    elif deg == 180:
        new = [[pix[height - 1 - y][width - 1 - x] for x in range(width)] for y in range(height)]
    elif deg == 270:
        new = [[pix[y][width - 1 - x] for y in range(height)] for x in range(width)]
    else:
        raise SystemExit("rotate must be 0, 90, 180 or 270")
    return [b"".join(r) for r in new], len(new[0]), len(new)


def cmd_shot(dev, prof, args):
    info, data = fetch_fb(dev)
    width, height, bpp, stride = decode_fb(info, data, args)
    step = max(1, int(round(1 / args.scale))) if args.scale else 1
    invert = args.invert if args.invert is not None else prof.get("invert_gray", False)
    rows = convert_rows(data, width, height, bpp, stride, step, invert)
    out_w, out_h = len(rows[0]) // (1 if bpp == 8 else 3), len(rows)
    deg = args.rotate if args.rotate is not None else prof.get("rotate", 0)
    rows, out_w, out_h = rotate_rows(rows, out_w, out_h, bpp == 8, deg)
    out = args.out
    if not out:
        os.makedirs(SHOTS_DIR, exist_ok=True)
        out = os.path.join(SHOTS_DIR, time.strftime("%Y%m%d-%H%M%S") + ".png")
    png_write(out, out_w, out_h, rows, bpp == 8)
    print("%s  (%dx%d fb, %d bpp, stride %d, scale 1/%d -> %dx%d)" %
          (os.path.abspath(out), width, height, bpp, stride, step, out_w, out_h))


# Other commands ----------------------------------------------------------------

def cmd_probe(dev, prof, args):
    out = run_touch(dev, prof, args, ["probe"])
    print(out, end="")
    m = re.search(r"^device (\S+)", out, re.M)
    fb = re.search(r"^fb (\d+)x(\d+)", out, re.M)
    if m and not prof.get("device"):
        prof["device"] = m.group(1)
    if fb and not prof.get("fb_width"):
        prof["fb_width"], prof["fb_height"] = int(fb.group(1)), int(fb.group(2))
    save_profile(prof)
    print("profile saved to %s (edit swap_xy / invert_x / invert_y after a test tap)" % PROFILE)


def cmd_profile(dev, prof, args):
    if args.key:
        if args.value is None:
            raise SystemExit("profile KEY VALUE")
        v = args.value
        try:
            v = json.loads(v)
        except ValueError:
            pass
        prof[args.key] = v
        save_profile(prof)
    print(json.dumps(prof, indent=2))


def cmd_tap(dev, prof, args):
    print(run_touch(dev, prof, args, ["tap", args.x, args.y]), end="")


def cmd_longpress(dev, prof, args):
    print(run_touch(dev, prof, args, ["longpress", args.x, args.y, args.ms]), end="")


def cmd_swipe(dev, prof, args):
    print(run_touch(dev, prof, args, ["swipe", args.x1, args.y1, args.x2, args.y2, args.ms]), end="")


def cmd_drag(dev, prof, args):
    # Hold, then pan: how you select text in KOReader.
    print(run_touch(dev, prof, args, ["drag", args.x1, args.y1, args.x2, args.y2, args.hold, args.ms]), end="")


def cmd_key(dev, prof, args):
    spot = (prof.get("keys") or {}).get(args.name)
    if not spot:
        raise SystemExit("no key '%s' in profile; add it under keys" % args.name)
    x, y = spot
    if x <= 1 or y <= 1:
        if not (prof.get("fb_width") and prof.get("fb_height")):
            raise SystemExit("run `probe` first so the screen size is known")
        x, y = int(x * prof["fb_width"]), int(y * prof["fb_height"])
    print(run_touch(dev, prof, args, ["tap", x, y]), end="")


def cmd_restart(dev, prof, args):
    # KOReader runs as `./luajit reader.lua` under koreader.sh. SIGTERM makes
    # LuaJIT exit (KOReader installs no handler, so this is "clean" only in the
    # sense that koreader.sh then runs its normal teardown and restores the
    # Kindle framework); SIGKILL is the fallback after 10 s.
    pids = dev.text("pgrep -f 'reader.lua' 2>/dev/null || ps | grep '[r]eader.lua' | awk '{print $1}'").split()
    if pids:
        dev.run("kill -TERM %s" % " ".join(pids), check=False)
        for _ in range(20):
            time.sleep(0.5)
            if not dev.text("pgrep -f 'reader.lua' 2>/dev/null || ps | grep '[r]eader.lua' | awk '{print $1}'").split():
                break
        else:
            dev.run("kill -KILL %s" % " ".join(pids), check=False)
        # Let the parent koreader.sh finish its teardown before relaunching.
        for _ in range(20):
            if not dev.text("ps | grep '[k]oreader.sh' | awk '{print $1}'").split():
                break
            time.sleep(0.5)
        print("stopped KOReader (pids %s)" % " ".join(pids))
    else:
        print("KOReader was not running")
    # Launch detached. koreader.sh is the same entry point KUAL/KPM use; it
    # stops the Kindle UI itself. Untested from SSH on this device: if the
    # Kindle UI stays on top, launch KOReader from the Kindle instead.
    launch = ("cd %s && nohup sh -c 'command -v setsid >/dev/null && exec setsid ./koreader.sh || exec ./koreader.sh' "
              ">/dev/null 2>&1 </dev/null &" % LUAJIT_DIR)
    dev.run(launch, check=False, timeout=20)
    time.sleep(3)
    running = dev.text("pgrep -f 'reader.lua' 2>/dev/null || ps | grep '[r]eader.lua' | awk '{print $1}'").split()
    print("KOReader %s" % ("started (pid %s)" % running[0] if running else "did not start; check `log`"))


def cmd_log(dev, prof, args):
    print(dev.text("tail -n %d %s" % (args.n, CRASH_LOG), check=False), end="")


def cmd_deploy(dev, prof, args):
    src = os.path.join(PROJECT, "orca.koplugin")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d not in ("tests", "__pycache__", ".git")]
            for name in files:
                if name.endswith((".pyc", ".swp")):
                    continue
                full = os.path.join(root, name)
                tar.add(full, arcname=os.path.relpath(full, src).replace("\\", "/"))
    dest = args.dest
    staging = dest.rstrip("/") + ".new"
    dev.run("rm -rf %s && mkdir -p %s && tar xf - -C %s && rm -rf %s && mv %s %s"
            % (staging, staging, staging, dest, staging, dest), stdin=buf.getvalue())
    n = dev.text("find %s -type f | wc -l" % dest).strip()
    print("deployed orca.koplugin -> %s (%s files). Restart KOReader to load it: kindlectl restart" % (dest, n))


def cmd_sh(dev, prof, args):
    sys.exit(dev.stream(" ".join(args.cmd)))


# CLI -----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Drive the Kindle over SSH.")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--user", default="root")
    ap.add_argument("--port", type=int, default=22)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("shot", help="screenshot of /dev/fb0 as PNG")
    p.add_argument("out", nargs="?")
    p.add_argument("--scale", type=float, help="e.g. 0.5 (nearest-neighbour downsample)")
    p.add_argument("--width", type=int)
    p.add_argument("--height", type=int)
    p.add_argument("--bpp", type=int)
    p.add_argument("--invert", action="store_true", default=None, help="invert grayscale")
    p.add_argument("--rotate", type=int, choices=(0, 90, 180, 270))
    p.set_defaults(fn=cmd_shot)

    p = sub.add_parser("probe", help="touch device, axis ranges, framebuffer; saves profile.json")
    p.add_argument("--raw", action="store_true")
    p.set_defaults(fn=cmd_probe)

    p = sub.add_parser("profile", help="show or set a profile value (JSON values accepted)")
    p.add_argument("key", nargs="?")
    p.add_argument("value", nargs="?")
    p.set_defaults(fn=cmd_profile)

    for name, fn, coords in (("tap", cmd_tap, ("x", "y")),
                             ("longpress", cmd_longpress, ("x", "y")),
                             ("swipe", cmd_swipe, ("x1", "y1", "x2", "y2")),
                             ("drag", cmd_drag, ("x1", "y1", "x2", "y2"))):
        p = sub.add_parser(name)
        for c in coords:
            p.add_argument(c, type=int)
        if name != "tap":
            p.add_argument("--ms", type=int, default={"longpress": 800, "drag": 400}.get(name, 300))
        if name == "drag":
            p.add_argument("--hold", type=int, default=900, help="hold before panning (ms)")
        p.add_argument("--raw", action="store_true", help="coordinates are panel units")
        p.set_defaults(fn=fn)

    p = sub.add_parser("key", help="tap a profile-defined spot (menu, back, ...)")
    p.add_argument("name")
    p.set_defaults(fn=cmd_key)

    p = sub.add_parser("restart", help="stop KOReader and relaunch it")
    p.set_defaults(fn=cmd_restart)

    p = sub.add_parser("log", help="tail crash.log")
    p.add_argument("-n", type=int, default=60)
    p.set_defaults(fn=cmd_log)

    p = sub.add_parser("deploy", help="copy orca.koplugin to the device")
    p.add_argument("--dest", default=PLUGIN_DEST)
    p.set_defaults(fn=cmd_deploy)

    p = sub.add_parser("sh", help="run a shell command on the Kindle")
    p.add_argument("cmd", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_sh)

    args = ap.parse_args()
    dev = Device(args.host, args.user, args.port)
    args.fn(dev, load_profile(), args)


if __name__ == "__main__":
    main()
