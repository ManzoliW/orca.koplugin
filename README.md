# Kindle × Orca

Tools for using a jailbroken Kindle (KOReader) as a remote for
[Orca](https://github.com/stablyai/orca) desktop sessions such as Claude Code,
over Tailscale.

```
orca.koplugin/        KOReader plugin: browse workspaces, view and drive terminals,
                      get notified while reading, send highlighted passages to Claude
tailscale.koplugin/   Tailscale plugin patched for kernels without TUN (userspace
                      networking + SOCKS5 proxy), autostart, local port forwards
native/tweetnacl/     NaCl build for the Kindle (E2EE handshake with Orca)
tools/                PC side: screenshot/tap the Kindle over SSH, send documents
                      as EPUB, pull highlights back
tests/                Protocol tests, run on the device with KOReader's luajit
```

## How it works

Orca exposes its mobile RPC on port 6768 as a WebSocket with an end-to-end
encrypted handshake (NaCl box). The plugin speaks that protocol directly
(`orca.koplugin/orcaclient/`), through the SOCKS5 proxy that `tailscaled
--tun=userspace-networking` provides on `localhost:1055`, because 10th-gen
Kindles have no TUN device.

Network work runs in coroutines stepped by KOReader's UI loop, so the reader
never freezes while waiting on the socket.

## Setup

1. Jailbreak the Kindle and install KOReader (KPM: `;kpm install koreader`).
2. Copy `tailscale.koplugin/` and `orca.koplugin/` into `koreader/plugins/`.
3. Tailscale: KOReader → Network → Tailscale → Setup (auth key, binaries), then
   Start Service and Connect.
4. Orca → Settings → Mobile: copy the pairing link into `/mnt/us/orca-pairing.txt`
   on the Kindle, then KOReader → Tools → Orca → Pairing → Import. The file is
   deleted after import; the link is a device credential, keep it out of chat
   and repositories.
5. Tools → Orca → Connection → Test connection.

## Features

- **Sessions**: workspaces sorted by state (needs you / working / done),
  terminals with agent state, a session view with `1 2 3 Esc Ctrl-C ↑ ↓ Tab ⇧Tab ⏎`,
  free text, live updates, and the terminal resized to fit the Kindle.
- **Notify me while I read**: background polling; a popup when a session needs a
  decision or finishes, with an Open button.
- **Send to Claude**: in the highlight menu; Explain / Context / Save note presets
  or your own question, sent to the last-used session.
- **Local port forwards** (Tailscale → Advanced): reach a Calibre/OPDS server on
  the PC from KOReader's own catalog browser.
- **PC tools**: see `tools/README.md` (`kindlectl.py`, `send_to_kindle.py`,
  `pull_notes.py`) and the `send-to-kindle` Claude Code skill.

## Device notes

Tested on a Kindle KT4 (Basic, 10th gen): firmware 5.18.1.1.1, 600×800 8-bit
framebuffer, `cyttsp5_mt` touch panel (KOReader "snow protocol"), armv7l
hard-float, glibc 2.20. TweetNaCl is cross-compiled with Zig
(`native/tweetnacl/build.sh`).
