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

### Home

**Open Orca** starts on a dashboard that answers "does anything need me?"
first:

- **The session waiting for you**, drawn as a black card with the agent's
  question and its choices as buttons (**1 Yes**, **2 …**, **Esc**), so you
  can answer from Home, or **Open session**.
- **Workspaces with an agent at work**, as ● Needs you, ◐ Working and ○ Done.
- **Claude usage**: the 5-hour and weekly limits as bars, with when they reset.
- **Activity**: conversations touched today, agents started, pull requests
  and agent time. Tap a number for the screen behind it.
- **Continue reading**: the book you opened last, with its cover, progress
  and time read today. Tap it to go back to the book.
- **Reading**: the time you read each day, from KOReader's reading
  statistics, as a heatmap over the last months, with your streak (or the
  day you last read) and this month's total.
- **From Claude**: the newest files in `documents/Claude/` (diffs, files and
  conversations you opened as books), marked **New** until you open them.
- **Tabs** at the bottom: Home, Workspaces, Chats, Usage and Automations.

The last dashboard shows straight away while the new one loads ("Updating…").
Usage and totals are reused for 5 minutes and conversations for 15, since
listing conversations makes the desktop scan transcripts on disk; ↻ fetches
everything again. The reading part comes from the Kindle itself, so it is
there even when your PC can't be reached.

<p>
  <img src="docs/screenshots/home.png" width="260" alt="Home dashboard">
  &nbsp;
  <img src="docs/screenshots/reading.png" width="260" alt="Reading heatmap and files from Claude">
</p>

### Browse workspaces and sessions

The **Workspaces** tab lists every workspace, grouped by what needs attention
first (**● Needs you**, **◐ Working**, **○ Done**), and each session shows its
agent's state. Tap a row to go in, **‹** to go back, swipe or use the page
buttons to turn pages.

<p>
  <img src="docs/screenshots/workspaces.png" width="260" alt="Workspace list">
  &nbsp;
  <img src="docs/screenshots/terminals.png" width="260" alt="Terminals in a workspace">
</p>

### Drive a session

The session view shows the terminal's current screen. The desktop resizes that
terminal to the Kindle's width while you're looking at it, so nothing is cut
off, and restores the size when you leave. Buttons cover what Claude Code asks
for most: `1 2 3` for choices, `Esc`, `Ctrl-C`, arrows, `Tab`/`S-Tab`
(mode switching), `Enter`, and **Type…** for free text. With live updates on, the
screen refreshes when the session prints something. The terminal uses a
bundled DejaVu Sans Mono, since the Kindle's own monospace font has no box
drawing, so agents' boxes and rules line up.

Swipe down in the text to read what scrolled off: with **Keep earlier
output** on (Session view settings), the terminal is made three Kindle
screens tall while you view it. **Rotate** switches between portrait and
landscape; the terminal is resized to fit either way.

### Start something new

**+** in the title bar of the workspace list (also **Start something new…** in
Tools → Orca) gives four options:

- **New workspace with Claude:** pick a project, say what Claude should do,
  and the workspace opens with Claude already working on it.
- **From a GitHub issue or PR:** browse or search the project's open issues and
  pull requests, tap one, and Claude starts in a workspace linked to it. For a
  PR, the workspace checks out the PR's branch.
- **Clone from GitHub:** type `owner/repo` or a URL. It's cloned on the desktop
  and added to Orca, and you watch the progress in a terminal.
- **New empty project:** creates a folder with a git repository (and an empty
  first commit) and adds it to Orca.

Orca doesn't let phones clone or add projects directly. For those two, the
plugin runs `git` and the `orca` CLI in a desktop terminal. New projects go
next to your existing ones; change the folder with **Folder…**.

### Work inside a workspace

Opening a workspace shows its sessions, then:

- **+** in the title bar: a new Claude session (with an optional first prompt)
  or a shell.
- **Git:** branch and ahead/behind, the changed files (tap one for its diff),
  **Commit all** (with a message drafted by the desktop's agent, which you can
  edit) and **Commit & push**, **Push**, **Pull**, **Open a pull request**
  (normal or draft), and **Read all changes as a book**, which opens every diff
  as one document in KOReader.
- **Pull request:** when the branch already has one, the Git screen shows it
  with its checks (✓ ✗ …). Tap a check for its failing steps and annotations;
  **Re-run the failed checks**, **Ask Claude to fix the failures** (starts a
  session in the workspace with the failing check names), or **Merge…**
  (squash, merge commit or rebase).
- **Files:** browse the checkout and read any file. **Open as book** saves it
  to `documents/Claude/`; **Ask Claude…** sends a question about it to a session.
- **Sleep or remove…:** put the workspace to sleep, or remove it (the branch
  is kept).

<p>
  <img src="docs/screenshots/git.png" width="260" alt="Git screen of a workspace">
</p>

### Claude status on the sleep screen

With **Claude status on the sleep screen** on, the plugin keeps KOReader's
sleep message up to date while the Kindle is awake, so the sleeping Kindle
shows Claude's usage and your sessions:

<p>
  <img src="docs/screenshots/sleep.png" width="260" alt="Claude status on the sleep screen">
</p>

The limits are Claude's own 5-hour and weekly limits, as Orca's accounts
screen shows them, followed by the most recent conversation and its total
tokens. Turning the option off restores your previous sleep message.

### Account and usage

**Account and usage** (the **Usage** tab) shows the 5-hour and
weekly limits with when they reset, and Orca's totals: agents started, pull
requests and agent time. When you have more than one Claude account in Orca,
it lists them too: tap one to make new sessions use it (or go back to
**System default**, the login on your PC).

<p>
  <img src="docs/screenshots/account.png" width="260" alt="Account and usage screen">
</p>

**Automations** (its own tab) lists Orca's scheduled agent runs, with **Run now** and
on/off, for desktops that allow it. Current Orca builds keep automations from
mobile clients; the screen then says so.

### Recent conversations

**Conversations** (the **Chats** tab) lists your latest agent conversations across all projects, with their size in
tokens. Open one to see its latest messages, read them as a book, or
**Continue on desktop**, which runs `claude --resume` in that project's
workspace and opens it on the Kindle.

### Get notified while you read

With **Notify me while I read** on, the plugin subscribes to Orca's
notification stream, so a popup appears over your book the moment a session
hits a permission prompt or finishes its work (when the stream isn't
available it falls back to checking every 30 s). For a prompt, the popup
shows the question itself with **1 2 3 Esc** buttons, so you can answer
without leaving the book; **Open** goes straight to that session. When the
Kindle wakes up, it catches up on what finished or started waiting while it
was asleep.

Battery: keeping the stream open costs about 5 mA while the Kindle is awake
(52 mA with notifications on vs 48 mA off on a Kindle Basic (KT4), Wi-Fi on,
measured over 8 minutes each), roughly 10% less reading time. Asleep, Wi-Fi
is off and it costs nothing.

<p>
  <img src="docs/screenshots/notify-answer.png" width="260" alt="Popup with Claude's question and answer buttons">
</p>

<p>
  <img src="docs/screenshots/menu.png" width="260" alt="Orca settings menu in KOReader">
</p>

### Send a passage to Claude

Select text in any book and the highlight menu gets a **Send to Claude**
button (named after the agent you picked for new sessions). Pick a preset (**Explain**, **Context**, **Save note**) or type your
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
   `tailscale.koplugin/` and `orca.koplugin/`. Each
   [release](https://github.com/ManzoliW/orca.koplugin/releases) has a zip of
   each plugin (and `SHA256SUMS`); unzip them into `koreader/plugins/`.
3. **Start Tailscale on the Kindle**: KOReader → Network → Tailscale → Setup
   (auth key, binaries), then **Start Service and Connect**. It starts by
   itself with KOReader after that.
4. **Pair with Orca**: on the PC, Orca → Settings → Mobile. Save the pairing
   link to `/mnt/us/orca-pairing.txt` on the Kindle, then KOReader → Tools →
   Orca → Pairing → **Import**. The file is deleted after import.
5. **Test it**: Tools → Orca → Connection → **Test connection**. It reports
   either the number of workspaces found or the step that failed.
6. **Kindle firmware 5.16 or later**: copy the two files in
   [`koreader-patches/`](koreader-patches) (also `koreader-patches.zip` in
   each release) to `koreader/patches/`. Newer firmware draws its status bar
   (clock, Wi-Fi, battery) with a process KOReader doesn't know about, and it
   repaints over KOReader's top corners every minute, covering the back
   button. The patches pause it while KOReader runs and resume it on exit,
   even after a crash.

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

The plugin's modules (core, API wrappers, UI kit, one file per feature) and
the design rules for the e-ink UI are described in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

| Path | What |
| --- | --- |
| `orca.koplugin/` | KOReader plugin; `main.lua` only wires it together |
| `orca.koplugin/orca/` | `core/` (settings, jobs, connection), `api/` (Orca RPC wrappers), `ui/` (e-ink UI kit), `features/` (one file per screen or behavior), `render/` (terminal text, diffs) |
| `orca.koplugin/orcaclient/` | Orca mobile protocol: WebSocket, NaCl handshake, RPC and streams |
| `tailscale.koplugin/` | Tailscale plugin, patched for kernels without TUN; autostart; port forwards |
| `koreader-patches/` | KOReader user patches: keep the Kindle's status bar from drawing over KOReader (firmware 5.16+) |
| `native/tweetnacl/` | NaCl cross-build for armv7 (`build.sh`, needs Zig) |
| `tools/` | PC side: `kindlectl.py` (screenshot/tap/deploy over SSH; set `KINDLE_HOST`), `send_to_kindle.py`, `pull_notes.py` |
| `tests/` | `luajit tests/run.lua` runs every screen on a PC against a fake Orca and stubbed KOReader (also in CI); `tests/device/` scripts run on the Kindle, and `rpc_probe.lua` there calls the real desktop |
| `.claude/skills/` | `send-to-kindle` skill for Claude Code |

## Tested on

Kindle Basic (KT4, 10th gen), firmware 5.18.1.1.1, KOReader 2026.07.1, Orca
desktop on Windows 11. Other Kindles that run KOReader should work. The
touch-injection tool (`kindlectl`) may need its profile adjusted on other
models (see `tools/README.md`).

## License

[GPLv3](LICENSE), like KOReader.
