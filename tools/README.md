# tools/ — drive the Kindle from the PC

`kindlectl.py` talks to the Kindle over SSH (Tailscale, `root@$KINDLE_HOST`, default `kindle`,
key login) so a Claude Code session can look at the screen and tap it while
testing the Orca plugin. Nothing is installed on the device beyond one Lua
script under `/mnt/us/orca-dev/tools/`, uploaded on first use.

```
python tools/kindlectl.py shot [--scale 0.5] [out.png]   screenshot (PNG) -> ./shots/ (or $KINDLE_SHOTS_DIR)
python tools/kindlectl.py probe                           touch device, axis ranges, fb size; writes device/profile.json
python tools/kindlectl.py tap X Y                         screen-pixel coordinates
python tools/kindlectl.py swipe X1 Y1 X2 Y2 [--ms 300]
python tools/kindlectl.py longpress X Y [--ms 800]
python tools/kindlectl.py key menu|back                   taps a spot from profile.json
python tools/kindlectl.py restart                         SIGTERM KOReader, wait, relaunch koreader.sh
python tools/kindlectl.py log [-n 60]                     tail /mnt/us/koreader/crash.log
python tools/kindlectl.py deploy                          orca.koplugin/ -> /mnt/us/koreader/plugins/orca.koplugin
python tools/kindlectl.py sh CMD...                       any shell command
python tools/kindlectl.py profile [KEY VALUE]             show / set calibration
```

## How it works

- **Screenshots** read `/dev/fb0` plus `/sys/class/graphics/fb0/{virtual_size,bits_per_pixel,stride,modes}`
  in one SSH call and decode 8-bit grayscale, RGB565 or 32-bit BGRA into a PNG
  (pure Python). `--scale 0.5` keeps images small enough to view quickly.
- **Touches** run `device/touch.lua` with KOReader's own LuaJIT. It scans
  `/dev/input/event*` for a device advertising `ABS_MT_POSITION_X` (falls back
  to `ABS_X`), reads the axis ranges, maps screen pixels into them and writes
  Linux MT type-B events (type A / single-touch fallbacks included).

## Calibration (once, on the real device)

1. `kindlectl probe` — records the touch device and framebuffer size.
2. `kindlectl shot`, then `kindlectl tap X Y` on something visible (a menu entry),
   then `shot` again. If the wrong thing reacted, set one or more of
   `profile swap_xy true`, `profile invert_x true`, `profile invert_y true`.
3. If screenshots look like negatives: `profile invert_gray true`.
   If they are sideways: `profile rotate 90` (or 180/270).

## Caveats

- Needs the Kindle awake and reachable; it is not in USB-storage mode.
- `restart` sends SIGTERM to `luajit reader.lua` and relaunches `koreader.sh`
  from SSH; launching from SSH has not yet been verified on this device.

# Send documents to the Kindle, pull notes back

`send_to_kindle.py` turns markdown/text into an EPUB 3 (pure Python, no
dependencies) and delivers it; `pull_notes.py` reads KOReader's highlights and
notes back as markdown. The `send-to-kindle` skill in `.claude/skills/` tells
any Claude Code session how to use them.

```
python tools/send_to_kindle.py plan.md [--title T] [--author A]      md/txt -> EPUB, deliver
python tools/send_to_kindle.py report.pdf                             epub/pdf sent as-is
cat notes.md | python tools/send_to_kindle.py - --title "Notes"       markdown on stdin
python tools/send_to_kindle.py plan.md --via none --out DIR           build only
python tools/pull_notes.py [--since YYYY-MM-DD] [--out notes.md]      highlights -> markdown
python tools/pull_notes.py --via local --local-dir DIR                parse local .sdr copies
```

- **Delivery** (`--via auto`, the default): `scp` over Tailscale into
  `/mnt/us/documents/Claude/` (after `mkdir -p`), else copy onto the mounted USB
  drive (the one with `documents/` and `system/` at its root) under
  `documents\Claude\`. `--via ssh|usb` forces one path. Options: `--host`,
  `--user`, `--dest`.
- **EPUB**: chapters split at `# ` headings (fences are respected), navigation
  document, e-ink CSS — serif body, `pre` blocks in small monospace with
  `pre-wrap` + `break-all` so diffs and code never run off the screen. The
  converter handles headings (ATX and setext), paragraphs, fenced and indented
  code, inline code, bold/italic/strike, links, nested ordered/unordered lists,
  blockquotes, pipe tables and rules; images collapse to their alt text.
- **Notes**: finds every `*.sdr/metadata.*.lua` under `/mnt/us/documents` in one
  SSH round trip (or on the USB drive) and parses the Lua literal with a small
  tolerant parser (comments, long strings, `\ddd`/`\xhh` byte escapes, `[k]=`
  and `k=` keys, `-math.huge`). Reads both the current `annotations` list and
  the legacy `highlight[page][n]` + `bookmarks` layout. Output is grouped book →
  chapter, highlights as quotes with their note underneath, with page and date.
