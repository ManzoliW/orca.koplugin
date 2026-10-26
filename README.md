# Kindle × Orca

Use a jailbroken Kindle as an e-ink remote for your
[Orca](https://github.com/stablyai/orca) sessions, such as Claude Code, over
Tailscale. Read a book, get a ping when Claude needs a decision, approve it
with one tap, and go back to reading.

<p align="center">
  <img src="docs/screenshots/session.png" width="300" alt="A Claude Code session on the Kindle">
</p>

All screenshots on this page come from a real Kindle Basic (10th gen, 600×800),
captured over SSH with [`tools/kindlectl.py`](tools/README.md).

## What you can do

### Browse workspaces and sessions

Workspaces are sorted by what needs attention first (**needs you** → working →
done), and each terminal shows its agent's state.

<p>
  <img src="docs/screenshots/workspaces.png" width="260" alt="Workspace list">
  &nbsp;
  <img src="docs/screenshots/terminals.png" width="260" alt="Terminals in a workspace">
</p>

### Drive a session

The session view shows the terminal's current screen. The desktop resizes that
terminal to the Kindle's width while you're looking at it, so nothing is cut
off, and restores the size when you leave. Buttons cover what Claude Code asks
for most: `1 2 3` for choices, `Esc`, `Ctrl-C`, arrows, `Tab`/`⇧Tab`
(mode switching), `⏎`, and **Type…** for free text. With live updates on, the
screen refreshes when the session prints something.

### Get notified while you read

With **Notify me while I read** on, the plugin checks your sessions in the
background (every 30 s by default). When one hits a permission prompt or
finishes its work, a popup appears over your book. Tap **Open** to go straight
to that session.

<p>
  <img src="docs/screenshots/menu.png" width="260" alt="Orca settings menu in KOReader">
</p>

### Send a passage to Claude

Select text in any book and the highlight menu gets a **Send to Claude**
button. Pick a preset (**Explain**, **Context**, **Save note**) or type your
own question. The passage is sent to your last-used session along with the
book title, author and chapter, and the session view opens so you can read the
answer.

<p>
  <img src="docs/screenshots/highlight-menu.png" width="260" alt="Highlight menu with Send to Claude">
  &nbsp;
  <img src="docs/screenshots/ask-dialog.png" width="260" alt="Passage dialog with presets">
</p>
<p>
  <img src="docs/screenshots/send-confirm.png" width="260" alt="Confirm which session to send to">
  &nbsp;
  <img src="docs/screenshots/pick-session.png" width="260" alt="Choose another session">
</p>

What arrives in Claude Code:

```
From Kindle x Orca by Claude, chapter "Kindle × Orca":

"Orca exposes its mobile RPC on"

Explain this passage in a few short paragraphs.
```

### Send documents from Claude to the Kindle

`tools/send_to_kindle.py` turns Markdown (plans, reviews, reports, diffs) into
an EPUB that reads well on e-ink and copies it to `documents/Claude/` over
Tailscale, or over USB when the Kindle is plugged in. In Claude Code, the
`/send-to-kindle` skill does this for you. `tools/pull_notes.py` brings your
KOReader highlights and notes back as Markdown.

<p>
  <img src="docs/screenshots/reader.png" width="260" alt="This README, sent to the Kindle as an EPUB">
</p>

```sh
python tools/send_to_kindle.py plan.md --title "Refactor plan"
git diff main | python tools/send_to_kindle.py - --title "Review: my-branch"
python tools/pull_notes.py --since 2026-10-01 --out notes.md
```

## Setup

You need a jailbroken Kindle with [KOReader](https://github.com/koreader/koreader),
Tailscale on both the Kindle and the PC, and Orca running on the PC.

1. **Install KOReader** via KPM: `;kpm install koreader`.
2. **Copy both plugins** into `koreader/plugins/` on the Kindle:
   `tailscale.koplugin/` and `orca.koplugin/`.
3. **Start Tailscale on the Kindle**: KOReader → Network → Tailscale → Setup
   (auth key, binaries), then **Start Service and Connect**. It starts by
   itself with KOReader after that.
4. **Pair with Orca**: on the PC, Orca → Settings → Mobile. Save the pairing
   link to `/mnt/us/orca-pairing.txt` on the Kindle, then KOReader → Tools →
   Orca → Pairing → **Import**. The file is deleted after import.
5. **Test it**: Tools → Orca → Connection → **Test connection**. It reports
   either the number of workspaces found or the step that failed.

> The pairing link is a device credential. Keep it out of chats, screenshots
> and repositories. Revoke it in Orca → Settings → Mobile if it leaks.

## How it works

```
Kindle (KOReader)                                   PC
┌──────────────────────┐                        ┌──────────────────┐
│ orca.koplugin        │  WebSocket, NaCl box   │ Orca             │
│  └ orcaclient/       │ ─────────────────────▶ │  mobile RPC      │
│ tailscaled           │   SOCKS5 :1055 →       │  :6768           │
│  (userspace mode)    │   tailnet              │                  │
└──────────────────────┘                        └──────────────────┘
```

- **Protocol**: the plugin speaks Orca's mobile protocol directly: a WebSocket
  on port 6768 with an end-to-end encrypted handshake (X25519 +
  XSalsa20-Poly1305, via a TweetNaCl build for the Kindle in
  `native/tweetnacl/`).
- **Networking**: 10th-gen Kindles have no TUN device, so `tailscaled` runs in
  userspace mode and apps reach the tailnet through its SOCKS5 proxy on
  `localhost:1055`. The patched Tailscale plugin sets that up, and can also
  forward local ports so KOReader's own OPDS/Calibre browser can reach the PC
  (Tailscale → Advanced → Local port forwards).
- **No freezes**: network work runs in coroutines stepped by KOReader's UI
  loop, so the reader stays responsive while waiting on the network.

## Repository layout

| Path | What |
| --- | --- |
| `orca.koplugin/` | KOReader plugin: sessions, notifications, Send to Claude |
| `tailscale.koplugin/` | Tailscale plugin, patched for kernels without TUN; autostart; port forwards |
| `native/tweetnacl/` | NaCl cross-build for armv7 (`build.sh`, needs Zig) |
| `tools/` | PC side: `kindlectl.py` (screenshot/tap over SSH), `send_to_kindle.py`, `pull_notes.py` |
| `tests/` | Protocol tests, run on the Kindle with KOReader's `luajit` |
| `.claude/skills/` | `send-to-kindle` skill for Claude Code |

## Tested on

Kindle Basic (KT4, 10th gen), firmware 5.18.1.1.1, KOReader 2026.07.1, Orca
desktop on Windows 11. Other Kindles that run KOReader should work. The
touch-injection tool (`kindlectl`) may need its profile adjusted on other
models (see `tools/README.md`).
