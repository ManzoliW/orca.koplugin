#!/usr/bin/env python3
"""Pull KOReader highlights and notes from the Kindle as markdown.

    pull_notes.py [--via auto|ssh|usb|local] [--host 100.93.172.106] [--user root]
                  [--root /mnt/us/documents] [--since YYYY-MM-DD] [--out notes.md]
                  [--local-dir DIR] [FILE.lua ...]

KOReader keeps each book's metadata in <book>.sdr/metadata.<ext>.lua, a plain
Lua table literal. Recent versions store highlights in an `annotations` list;
older ones in `highlight[page][n]` plus `bookmarks`. Both shapes are read.

Delivery: "ssh" runs find+cat over Tailscale, "usb" reads the mounted Kindle
drive, "local" reads --local-dir or the FILE arguments, "auto" tries ssh then usb.
"""

import argparse
import datetime as _dt
import os
import re
import subprocess
import sys

DEFAULT_HOST = "100.93.172.106"
DEFAULT_USER = "root"
DEFAULT_ROOT = "/mnt/us/documents"


# ----------------------------------------------------------------------------
# Lua literal parser
# ----------------------------------------------------------------------------

class LuaParseError(ValueError):
    pass


class LuaParser:
    """Parses a Lua table literal (what KOReader's `dump` writes) into Python."""

    _ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f",
                "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}

    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    # -- lexing helpers ------------------------------------------------------
    def skip(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                m = re.match(r"--\[(=*)\[", s[self.i:])
                if m:
                    end = s.find("]%s]" % m.group(1), self.i + len(m.group(0)))
                    self.i = n if end < 0 else end + len(m.group(1)) + 2
                else:
                    nl = s.find("\n", self.i)
                    self.i = n if nl < 0 else nl + 1
            else:
                break

    def peek(self):
        self.skip()
        return self.s[self.i] if self.i < self.n else ""

    def expect(self, ch):
        if self.peek() != ch:
            raise LuaParseError("expected %r at %d, got %r" % (ch, self.i, self.s[self.i:self.i + 20]))
        self.i += 1

    # -- values ----------------------------------------------------------------
    def parse(self):
        self.skip()
        # Files may start with "return {", "local x = {" or just "{".
        m = re.match(r"(return|local\s+\w+\s*=)\s*", self.s[self.i:])
        if m:
            self.i += len(m.group(0))
        value = self.value()
        self.skip()
        return value

    def value(self):
        c = self.peek()
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        if c == "[":
            return self.long_string()
        m = re.match(r"-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?|inf|nan)",
                     self.s[self.i:])
        if m and m.group(0) not in ("-",):
            tok = m.group(0)
            self.i += len(tok)
            try:
                if tok.lower().lstrip("-").startswith("0x"):
                    return int(tok, 16)
                if re.fullmatch(r"-?\d+", tok):
                    return int(tok)
                return float(tok)
            except ValueError:
                return float("nan")
        m = re.match(r"-?[A-Za-z_]\w*", self.s[self.i:])
        if m:
            tok = m.group(0)
            self.i += len(tok)
            tok = tok.lstrip("-")
            if tok == "true":
                return True
            if tok == "false":
                return False
            if tok == "nil":
                return None
            # Unknown identifier (e.g. math.huge): keep as string.
            while self.i < self.n and (self.s[self.i].isalnum() or self.s[self.i] in "._"):
                self.i += 1
            return tok
        raise LuaParseError("unexpected %r at %d" % (self.s[self.i:self.i + 20], self.i))

    def string(self):
        quote = self.s[self.i]
        self.i += 1
        # Lua strings are byte strings: \ddd and \xhh escapes are raw bytes
        # (KOReader writes UTF-8 as e.g. \195\169), so assemble bytes and
        # decode once at the end.
        out = bytearray()
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            if c == quote:
                self.i += 1
                return out.decode("utf-8", errors="replace")
            if c == "\\":
                self.i += 1
                e = s[self.i] if self.i < self.n else ""
                if e in self._ESCAPES:
                    out += self._ESCAPES[e].encode("utf-8")
                    self.i += 1
                elif e.isdigit():
                    m = re.match(r"\d{1,3}", s[self.i:])
                    out.append(int(m.group(0)) & 0xFF)
                    self.i += len(m.group(0))
                elif e == "x":
                    out.append(int(s[self.i + 1:self.i + 3], 16))
                    self.i += 3
                elif e == "u":
                    m = re.match(r"u\{([0-9a-fA-F]+)\}", s[self.i:])
                    out += chr(int(m.group(1), 16)).encode("utf-8")
                    self.i += len(m.group(0))
                elif e == "z":
                    self.i += 1
                    while self.i < self.n and s[self.i] in " \t\r\n":
                        self.i += 1
                else:
                    out += e.encode("utf-8")
                    self.i += 1
            else:
                out += c.encode("utf-8")
                self.i += 1
        raise LuaParseError("unterminated string")

    def long_string(self):
        m = re.match(r"\[(=*)\[", self.s[self.i:])
        if not m:
            raise LuaParseError("bad long bracket at %d" % self.i)
        close = "]%s]" % m.group(1)
        start = self.i + len(m.group(0))
        end = self.s.find(close, start)
        if end < 0:
            raise LuaParseError("unterminated long string")
        self.i = end + len(close)
        body = self.s[start:end]
        if body.startswith("\n"):
            body = body[1:]
        return body

    def table(self):
        self.expect("{")
        result = {}
        auto_index = 1
        while True:
            c = self.peek()
            if c == "}":
                self.i += 1
                break
            if c == "":
                raise LuaParseError("unterminated table")
            if c == "[":
                # [key] = value   (but not a long string [[...]] used as a value)
                if re.match(r"\[=*\[", self.s[self.i:]):
                    key = auto_index
                    auto_index += 1
                    val = self.value()
                else:
                    self.i += 1
                    key = self.value()
                    self.expect("]")
                    self.expect("=")
                    val = self.value()
            else:
                m = re.match(r"([A-Za-z_]\w*)\s*=(?!=)", self.s[self.i:])
                if m:
                    key = m.group(1)
                    self.i += len(m.group(0))
                    val = self.value()
                else:
                    key = auto_index
                    auto_index += 1
                    val = self.value()
            if isinstance(key, float) and key.is_integer():
                key = int(key)
            if val is not None:
                result[key] = val
            c = self.peek()
            if c in ",;":
                self.i += 1
        return result


def parse_lua(text):
    return LuaParser(text).parse()


def as_list(tbl):
    """Returns the array part of a parsed table in index order."""
    if isinstance(tbl, list):
        return tbl
    if not isinstance(tbl, dict):
        return []
    keys = sorted(k for k in tbl if isinstance(k, int))
    return [tbl[k] for k in keys]


# ----------------------------------------------------------------------------
# Extraction
# ----------------------------------------------------------------------------

def _str(v):
    return v.strip() if isinstance(v, str) else ""


def _date_from(entry):
    d = _str(entry.get("datetime")) if isinstance(entry, dict) else ""
    if not d and isinstance(entry, dict):
        d = _str(entry.get("date"))
    return d


def book_title(meta, path):
    doc = meta.get("doc_props") if isinstance(meta.get("doc_props"), dict) else {}
    title = _str(doc.get("title"))
    authors = _str(doc.get("authors"))
    if not title:
        # path: .../Book Name.sdr/metadata.epub.lua
        sdr = os.path.basename(os.path.dirname(path.replace("\\", "/")))
        title = re.sub(r"\.sdr$", "", sdr) or os.path.basename(path)
    return title, authors


def extract(meta, path):
    """Returns (title, authors, [entry]) with entry = {text, note, chapter, datetime, page, kind}."""
    title, authors = book_title(meta, path)
    entries = []
    ann = meta.get("annotations")
    if ann:
        for a in as_list(ann):
            if not isinstance(a, dict):
                continue
            text = _str(a.get("text"))
            note = _str(a.get("note"))
            if not text and not note:
                continue
            page = a.get("pageno", a.get("page"))
            entries.append({
                "text": text, "note": note, "chapter": _str(a.get("chapter")),
                "datetime": _date_from(a), "page": page,
                "kind": "bookmark" if not text and note else "highlight",
            })
    else:
        hl = meta.get("highlight") or {}
        notes_by_key = {}
        for b in as_list(meta.get("bookmarks") or {}):
            if isinstance(b, dict):
                key = (_str(b.get("datetime")), _str(b.get("notes")) or _str(b.get("text")))
                notes_by_key[key[0]] = b
        if isinstance(hl, dict):
            pages = sorted((k for k in hl if isinstance(k, (int, float))), key=float)
            pages += [k for k in hl if not isinstance(k, (int, float))]
            for page in pages:
                for h in as_list(hl[page]):
                    if not isinstance(h, dict):
                        continue
                    text = _str(h.get("text"))
                    if not text:
                        continue
                    dt = _date_from(h)
                    bm = notes_by_key.get(dt)
                    note = ""
                    if bm:
                        note = _str(bm.get("text"))
                        # In old files bookmark.text holds the note or defaults to "Page N ... @ date".
                        if note.startswith("Page ") and "@" in note:
                            note = ""
                    entries.append({"text": text, "note": note, "chapter": _str(h.get("chapter")),
                                    "datetime": dt, "page": page, "kind": "highlight"})
        for b in as_list(meta.get("bookmarks") or {}):
            if isinstance(b, dict) and not b.get("highlighted"):
                note = _str(b.get("text"))
                if note and not (note.startswith("Page ") and "@" in note):
                    entries.append({"text": "", "note": note, "chapter": _str(b.get("chapter")),
                                    "datetime": _date_from(b), "page": b.get("page"), "kind": "bookmark"})

    def sort_key(e):
        p = e["page"]
        try:
            p = float(p)
        except (TypeError, ValueError):
            p = float("inf")
        return (p, e["datetime"])

    entries.sort(key=sort_key)
    return title, authors, entries


def parse_date(s):
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", s or "")
    if not m:
        return None
    try:
        return _dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def render(books, since=None):
    out = []
    total = 0
    book_count = 0
    for title, authors, entries in books:
        if since:
            entries = [e for e in entries if (parse_date(e["datetime"]) or _dt.date.min) >= since]
        if not entries:
            continue
        total += len(entries)
        book_count += 1
        out.append("# %s" % title + (" — %s" % authors if authors else ""))
        out.append("")
        cur_chapter = object()
        for e in entries:
            if e["chapter"] != cur_chapter:
                cur_chapter = e["chapter"]
                out.append("## %s" % (cur_chapter or "(no chapter)"))
                out.append("")
            meta = []
            if e["page"] not in (None, ""):
                meta.append("p. %s" % e["page"])
            if e["datetime"]:
                meta.append(e["datetime"])
            tag = " _(%s)_" % ", ".join(meta) if meta else ""
            if e["text"]:
                for ln in e["text"].splitlines():
                    out.append("> " + ln)
                out[-1] += tag
                if e["note"]:
                    out.append(">")
                    out.append("> **Note:** " + e["note"].replace("\n", "\n> "))
            else:
                out.append("- **Note:** %s%s" % (e["note"].replace("\n", " "), tag))
            out.append("")
    header = "_%d highlights/notes from %d books%s_\n" % (
        total, book_count, ", since %s" % since if since else "")
    return header + "\n" + "\n".join(out) if out else header + "\nNo highlights found.\n"


# ----------------------------------------------------------------------------
# Fetching
# ----------------------------------------------------------------------------

def fetch_ssh(host, user, root, timeout=10):
    """Returns {path: text} for every metadata.*.lua under root, via a single ssh call."""
    target = "%s@%s" % (user, host)
    common = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % timeout, "-o", "StrictHostKeyChecking=accept-new"]
    # Print each file framed by markers so one round trip is enough.
    script = ("find '%s' -name 'metadata.*.lua' -print0 | while IFS= read -r -d '' f; do "
              "printf '\\n==KOFILE==%%s\\n' \"$f\"; cat \"$f\"; done; printf '\\n==KOEND==\\n'" % root)
    r = subprocess.run(["ssh"] + common + [target, script], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0 and "==KOEND==" not in r.stdout:
        raise RuntimeError(r.stderr.strip() or "ssh failed (%d)" % r.returncode)
    files = {}
    parts = r.stdout.split("\n==KOFILE==")
    for part in parts[1:]:
        name, _, body = part.partition("\n")
        body = body.split("\n==KOEND==")[0]
        files[name.strip()] = body
    return files


def find_usb_drive():
    if os.name == "nt":
        candidates = ["%s:\\" % chr(c) for c in range(ord("D"), ord("Z") + 1)]
    else:
        candidates = []
        for base in ("/media", "/mnt", "/Volumes", "/run/media"):
            if os.path.isdir(base):
                for root, dirs, _ in os.walk(base):
                    candidates.extend(os.path.join(root, d) for d in dirs)
                    if root.count(os.sep) - base.count(os.sep) >= 1:
                        dirs[:] = []
    for c in candidates:
        try:
            if os.path.isdir(os.path.join(c, "documents")) and os.path.isdir(os.path.join(c, "system")):
                return c
        except OSError:
            continue
    return None


def fetch_dir(directory):
    files = {}
    for root, _, names in os.walk(directory):
        for name in names:
            if name.startswith("metadata.") and name.endswith(".lua"):
                p = os.path.join(root, name)
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    files[p] = f.read()
    return files


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="metadata.*.lua files to read directly")
    ap.add_argument("--via", choices=["auto", "ssh", "usb", "local"], default="auto")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--user", default=DEFAULT_USER)
    ap.add_argument("--root", default=DEFAULT_ROOT, help="remote documents directory")
    ap.add_argument("--local-dir", help="directory to scan instead of the device")
    ap.add_argument("--since", help="only entries from this date on (YYYY-MM-DD)")
    ap.add_argument("--out", help="write markdown here instead of stdout")
    args = ap.parse_args(argv)

    since = None
    if args.since:
        since = parse_date(args.since)
        if not since:
            ap.error("--since must be YYYY-MM-DD")

    files = {}
    errors = []
    if args.files or args.local_dir or args.via == "local":
        for p in args.files:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                files[p] = f.read()
        if args.local_dir:
            files.update(fetch_dir(args.local_dir))
    else:
        if args.via in ("auto", "ssh"):
            try:
                files = fetch_ssh(args.host, args.user, args.root)
            except RuntimeError as e:
                errors.append("ssh: %s" % e)
                if args.via == "ssh":
                    print("\n".join(errors), file=sys.stderr)
                    return 1
        if not files and args.via in ("auto", "usb"):
            drive = find_usb_drive()
            if drive:
                files = fetch_dir(os.path.join(drive, "documents"))
            else:
                errors.append("usb: no mounted Kindle drive found")
        if not files and errors:
            print("could not reach the Kindle:\n  " + "\n  ".join(errors), file=sys.stderr)
            return 1

    books = []
    for path in sorted(files):
        try:
            meta = parse_lua(files[path])
        except LuaParseError as e:
            print("skipping %s: %s" % (path, e), file=sys.stderr)
            continue
        if not isinstance(meta, dict):
            continue
        title, authors, entries = extract(meta, path)
        if entries:
            books.append((title, authors, entries))

    md = render(books, since)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(md)
        print("wrote %s" % args.out)
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
