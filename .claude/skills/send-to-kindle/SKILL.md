---
name: send-to-kindle
description: Send a document, plan, diff or report to the user's Kindle as an EPUB over Tailscale/USB, or pull KOReader highlights back
---

# Send to Kindle

Use when the user asks to read something on the Kindle / e-ink (a plan, PR diff,
review, report, article, notes), or to get their Kindle highlights/notes back.
Both scripts are stdlib Python; run them from any directory.

## Send a document

```
python tools/send_to_kindle.py <file.md> [--title "..."]
```

- Accepts `.md` / `.txt` (converted to EPUB 3, split into chapters at `# ` headings),
  `.epub` / `.pdf` (sent as-is), or `-` for markdown on stdin.
- Write long content to a `.md` file in the scratchpad first, then send it. Use
  `# ` headings for chapters; fenced code blocks and diffs wrap on e-ink.
- Delivery is automatic: SSH over Tailscale (`root@$KINDLE_HOST`, default `kindle`; lands in
  `/mnt/us/documents/Claude/`), falling back to the USB drive
  (`<drive>:\documents\Claude\`) when the Kindle is plugged in. Force one with
  `--via ssh|usb`; `--via none --out DIR` only builds the file.
- Tell the user where it landed (the script prints it) and, for SSH, to open
  `documents/Claude` in KOReader's file browser.

## Pull highlights and notes

```
python tools/pull_notes.py [--since YYYY-MM-DD] [--out notes.md]
```

- Reads every `*.sdr/metadata.*.lua` under `/mnt/us/documents` (SSH, or the USB
  drive as fallback) and prints markdown grouped book → chapter, highlights as
  quotes with their notes beneath.
- `--via local --local-dir DIR` or explicit `.lua` files work offline.

## Failure modes

- "Connection timed out" on SSH: the Kindle is asleep or in USB-storage mode.
  Ask the user to wake it (Tailscale comes up with KOReader) or plug it in and
  rerun; the USB path needs the drive mounted (it has been `D:`).
- Never print the contents of `/mnt/us/koreader/settings/orca.lua` or
  `orca-pairing.txt`; they hold credentials.
