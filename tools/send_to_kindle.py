#!/usr/bin/env python3
"""Send a document to the Kindle as an EPUB.

    send_to_kindle.py <file.md|file.txt|file.epub|file.pdf|-> [--title T] [--author A]
                      [--dest /mnt/us/documents/Claude] [--host 100.93.172.106]
                      [--user root] [--via auto|ssh|usb|none] [--out FILE]

Markdown/plain text is converted to EPUB 3 with a small built-in converter
(stdlib only). EPUB and PDF inputs are sent as they are.

Delivery: "ssh" copies over Tailscale with scp, "usb" copies onto the mounted
Kindle drive, "auto" tries ssh then usb, "none" only builds the file.
"""

import argparse
import datetime as _dt
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import zipfile

DEFAULT_HOST = "100.93.172.106"
DEFAULT_USER = "root"
DEFAULT_DEST = "/mnt/us/documents/Claude"
USB_SUBDIR = os.path.join("documents", "Claude")

CSS = """\
html, body { margin: 0; padding: 0; }
body { font-family: serif; line-height: 1.4; }
h1, h2, h3, h4, h5, h6 { font-family: sans-serif; line-height: 1.2; margin: 1em 0 0.4em; page-break-after: avoid; }
h1 { font-size: 1.6em; } h2 { font-size: 1.35em; } h3 { font-size: 1.15em; }
p { margin: 0 0 0.7em; text-align: left; }
pre { font-family: monospace; font-size: 0.72em; line-height: 1.25; white-space: pre-wrap;
      word-wrap: break-word; word-break: break-all; overflow-wrap: anywhere;
      border: 1px solid #888; padding: 0.4em; margin: 0.6em 0; }
code { font-family: monospace; font-size: 0.85em; }
blockquote { margin: 0.6em 0 0.6em 1em; padding-left: 0.6em; border-left: 3px solid #888; }
ul, ol { margin: 0 0 0.7em 1.4em; padding: 0; }
li { margin: 0.15em 0; }
hr { border: 0; border-top: 1px solid #888; margin: 1em 0; }
table { border-collapse: collapse; margin: 0.6em 0; font-size: 0.85em; }
th, td { border: 1px solid #888; padding: 0.2em 0.4em; text-align: left; vertical-align: top; }
th { font-weight: bold; }
a { color: inherit; text-decoration: underline; }
"""


# ----------------------------------------------------------------------------
# Markdown -> XHTML
# ----------------------------------------------------------------------------

def esc(text):
    return html.escape(text, quote=True)


_INLINE_CODE = re.compile(r"`([^`]+)`")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_IMAGE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)\)")
_STRONG = re.compile(r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1")
_EM = re.compile(r"(?<![*\w])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![*\w])")
_STRIKE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")


def inline(text):
    """Converts inline markdown to escaped XHTML."""
    # Protect code spans first; they must not be touched by other rules.
    codes = []

    def stash(m):
        codes.append("<code>%s</code>" % esc(m.group(1)))
        return "\x00%d\x00" % (len(codes) - 1)

    text = _INLINE_CODE.sub(stash, text)

    # Images are dropped to their alt text (no asset handling); links are
    # stashed too so their URLs/titles don't get mangled by escaping.
    def stash_image(m):
        codes.append("<em>%s</em>" % esc(m.group(1)))
        return "\x00%d\x00" % (len(codes) - 1)

    def stash_link(m):
        codes.append('<a href="%s">%s</a>' % (esc(m.group(2)), esc(m.group(1))))
        return "\x00%d\x00" % (len(codes) - 1)

    text = _IMAGE.sub(stash_image, text)
    text = _LINK.sub(stash_link, text)
    text = esc(text)
    text = _STRONG.sub(lambda m: "<strong>%s</strong>" % m.group(2), text)
    text = _EM.sub(lambda m: "<em>%s</em>" % m.group(2), text)
    text = _STRIKE.sub(lambda m: "<del>%s</del>" % m.group(1), text)
    text = text.replace("  \n", "<br/>\n")

    def unstash(m):
        return codes[int(m.group(1))]

    return re.sub("\x00(\\d+)\x00", unstash, text)


_FENCE = re.compile(r"^(```+|~~~+)\s*(\S*)\s*$")
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_HR = re.compile(r"^ {0,3}([-*_])(\s*\1){2,}\s*$")
_UL = re.compile(r"^(\s*)[-*+]\s+(.*)$")
_OL = re.compile(r"^(\s*)\d+[.)]\s+(.*)$")
_TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
_QUOTE = re.compile(r"^\s{0,3}>\s?(.*)$")


def _split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def md_to_html(md):
    """Converts a markdown string to an XHTML fragment."""
    lines = md.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []
    i = 0
    n = len(lines)
    para = []

    def flush_para():
        if para:
            out.append("<p>%s</p>" % inline("\n".join(para).strip()))
            para.clear()

    def parse_list(start, indent, ordered):
        """Parses a list starting at lines[start]; returns (html, next_index)."""
        tag = "ol" if ordered else "ul"
        items = []
        j = start
        pat = _OL if ordered else _UL
        while j < n:
            m = pat.match(lines[j])
            if m and len(m.group(1)) == indent:
                body = [m.group(2)]
                j += 1
                # Continuation lines / nested lists.
                nested = []
                while j < n:
                    ln = lines[j]
                    if not ln.strip():
                        # Blank line: list continues only if next non-blank is indented or another item.
                        k = j
                        while k < n and not lines[k].strip():
                            k += 1
                        if k < n and (pat.match(lines[k]) and len(pat.match(lines[k]).group(1)) == indent):
                            j = k
                            break
                        if k < n and lines[k].startswith(" " * (indent + 2)):
                            j = k
                            continue
                        j = k
                        break
                    sub_ul, sub_ol = _UL.match(ln), _OL.match(ln)
                    sub = sub_ul or sub_ol
                    if sub and len(sub.group(1)) > indent:
                        sub_html, j = parse_list(j, len(sub.group(1)), bool(sub_ol))
                        nested.append(sub_html)
                        continue
                    if sub and len(sub.group(1)) == indent:
                        break
                    if ln.startswith(" " * (indent + 1)) or (sub is None and not _HEADING.match(ln)
                                                               and not _FENCE.match(ln) and ln.startswith(" ")):
                        body.append(ln.strip())
                        j += 1
                        continue
                    break
                items.append("<li>%s%s</li>" % (inline(" ".join(body)), "".join(nested)))
            else:
                break
        return "<%s>%s</%s>" % (tag, "".join(items), tag), j

    while i < n:
        line = lines[i]
        stripped = line.strip()

        m = _FENCE.match(stripped)
        if m:
            flush_para()
            fence = m.group(1)[0]
            lang = m.group(2)
            code = []
            i += 1
            while i < n and not (lines[i].strip().startswith(fence * 3) and set(lines[i].strip()) == {fence}):
                code.append(lines[i])
                i += 1
            i += 1  # closing fence
            cls = ' class="language-%s"' % esc(lang) if lang else ""
            out.append("<pre><code%s>%s</code></pre>" % (cls, esc("\n".join(code))))
            continue

        if not stripped:
            flush_para()
            i += 1
            continue

        m = _HEADING.match(line)
        if m:
            flush_para()
            level = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (level, inline(m.group(2)), level))
            i += 1
            continue

        if _HR.match(line):
            flush_para()
            out.append("<hr/>")
            i += 1
            continue

        # Setext headings
        if i + 1 < n and para == [] and re.match(r"^=+\s*$", lines[i + 1]):
            out.append("<h1>%s</h1>" % inline(stripped))
            i += 2
            continue
        if i + 1 < n and para == [] and re.match(r"^-{2,}\s*$", lines[i + 1]) and not _TABLE_SEP.match(lines[i + 1]):
            out.append("<h2>%s</h2>" % inline(stripped))
            i += 2
            continue

        m = _QUOTE.match(line)
        if m:
            flush_para()
            quote = []
            while i < n and _QUOTE.match(lines[i]):
                quote.append(_QUOTE.match(lines[i]).group(1))
                i += 1
            out.append("<blockquote>%s</blockquote>" % md_to_html("\n".join(quote)))
            continue

        if "|" in line and i + 1 < n and _TABLE_SEP.match(lines[i + 1]) and "|" in lines[i + 1]:
            flush_para()
            header = _split_row(line)
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(_split_row(lines[i]))
                i += 1
            t = ["<table><thead><tr>"]
            t.extend("<th>%s</th>" % inline(c) for c in header)
            t.append("</tr></thead><tbody>")
            for r in rows:
                t.append("<tr>")
                t.extend("<td>%s</td>" % inline(c) for c in r)
                t.append("</tr>")
            t.append("</tbody></table>")
            out.append("".join(t))
            continue

        m = _UL.match(line) or _OL.match(line)
        if m:
            flush_para()
            html_list, i = parse_list(i, len(m.group(1)), bool(_OL.match(line)))
            out.append(html_list)
            continue

        # Indented code block (4 spaces / tab) outside a paragraph.
        if not para and (line.startswith("    ") or line.startswith("\t")):
            code = []
            while i < n and (lines[i].startswith("    ") or lines[i].startswith("\t") or not lines[i].strip()):
                code.append(lines[i][4:] if lines[i].startswith("    ") else lines[i][1:] if lines[i].startswith("\t") else "")
                i += 1
            while code and not code[-1].strip():
                code.pop()
            out.append("<pre><code>%s</code></pre>" % esc("\n".join(code)))
            continue

        para.append(line)
        i += 1

    flush_para()
    return "\n".join(out)


# ----------------------------------------------------------------------------
# EPUB
# ----------------------------------------------------------------------------

XHTML_TMPL = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
<meta charset="utf-8"/>
<title>%(title)s</title>
<link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
%(body)s
</body>
</html>
"""

CONTAINER_XML = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def split_chapters(md):
    """Splits markdown at '# ' headings. Returns [(title, markdown)]."""
    lines = md.replace("\r\n", "\n").split("\n")
    chapters = []
    cur_title, cur = None, []
    in_fence = None
    for ln in lines:
        fm = _FENCE.match(ln.strip())
        if fm:
            if in_fence is None:
                in_fence = fm.group(1)[0]
            elif set(ln.strip()) == {in_fence}:
                in_fence = None
        hm = _HEADING.match(ln) if in_fence is None else None
        if hm and len(hm.group(1)) == 1:
            if cur_title is not None or any(s.strip() for s in cur):
                chapters.append((cur_title, "\n".join(cur)))
            cur_title, cur = hm.group(2).strip(), [ln]
        else:
            cur.append(ln)
    if cur_title is not None or any(s.strip() for s in cur):
        chapters.append((cur_title, "\n".join(cur)))
    return chapters or [(None, md)]


def guess_title(md, fallback):
    for ln in md.splitlines():
        m = _HEADING.match(ln)
        if m:
            return re.sub(r"[*_`]", "", m.group(2)).strip()
        if ln.strip():
            return ln.strip()[:80]
    return fallback


def safe_filename(title):
    name = re.sub(r"[^\w\s.-]", "", title, flags=re.UNICODE).strip()
    name = re.sub(r"\s+", " ", name)
    return (name or "document")[:80]


def build_epub(md, out_path, title, author):
    chapters = split_chapters(md)
    book_id = "urn:uuid:" + str(uuid.uuid4())
    now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    manifest, spine, nav_items, files = [], [], [], []
    for idx, (ch_title, ch_md) in enumerate(chapters, 1):
        ch_title = ch_title or (title if idx == 1 else "Section %d" % idx)
        fname = "chapter%03d.xhtml" % idx
        body = md_to_html(ch_md)
        files.append((fname, XHTML_TMPL % {"title": esc(ch_title), "body": body}))
        manifest.append('<item id="c%d" href="%s" media-type="application/xhtml+xml"/>' % (idx, fname))
        spine.append('<itemref idref="c%d"/>' % idx)
        nav_items.append('<li><a href="%s">%s</a></li>' % (fname, esc(ch_title)))

    nav = XHTML_TMPL % {
        "title": esc("Contents"),
        "body": '<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>%s</ol></nav>' % "".join(nav_items),
    }
    opf = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="en">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">%(id)s</dc:identifier>
    <dc:title>%(title)s</dc:title>
    <dc:creator>%(author)s</dc:creator>
    <dc:language>en</dc:language>
    <dc:date>%(date)s</dc:date>
    <meta property="dcterms:modified">%(date)s</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style.css" media-type="text/css"/>
    %(manifest)s
  </manifest>
  <spine>
    %(spine)s
  </spine>
</package>
""" % {"id": book_id, "title": esc(title), "author": esc(author), "date": now,
       "manifest": "\n    ".join(manifest), "spine": "\n    ".join(spine)}

    with zipfile.ZipFile(out_path, "w") as z:
        # The mimetype entry must be first and uncompressed.
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER_XML, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/style.css", CSS, compress_type=zipfile.ZIP_DEFLATED)
        for fname, content in files:
            z.writestr("OEBPS/" + fname, content, compress_type=zipfile.ZIP_DEFLATED)
    return out_path


# ----------------------------------------------------------------------------
# Delivery
# ----------------------------------------------------------------------------

def find_usb_drive():
    """Returns the root of a mounted Kindle (has documents/ and system/), or None."""
    candidates = []
    if os.name == "nt":
        candidates = ["%s:\\" % chr(c) for c in range(ord("D"), ord("Z") + 1)]
    else:
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


def send_ssh(path, host, user, dest, timeout=10):
    target = "%s@%s" % (user, host)
    common = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % timeout, "-o", "StrictHostKeyChecking=accept-new"]
    r = subprocess.run(["ssh"] + common + [target, "mkdir -p '%s'" % dest],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr.strip() or "ssh failed (%d)" % r.returncode)
    remote = "%s/%s" % (dest.rstrip("/"), os.path.basename(path))
    r = subprocess.run(["scp"] + common + [path, "%s:'%s'" % (target, remote)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr.strip() or "scp failed (%d)" % r.returncode)
    return remote, None


def send_usb(path):
    drive = find_usb_drive()
    if not drive:
        return None, "no mounted Kindle drive found (needs documents/ and system/ at its root)"
    dest_dir = os.path.join(drive, USB_SUBDIR)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(path))
    shutil.copy2(path, dest)
    return dest, None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="markdown/text/epub/pdf file, or - for stdin (markdown)")
    ap.add_argument("--title")
    ap.add_argument("--author", default="Claude Code")
    ap.add_argument("--dest", default=DEFAULT_DEST, help="remote directory for ssh delivery")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--user", default=DEFAULT_USER)
    ap.add_argument("--via", choices=["auto", "ssh", "usb", "none"], default="auto")
    ap.add_argument("--out", help="where to write the built EPUB (default: temp dir, or next to --via none output)")
    args = ap.parse_args(argv)

    src = args.source
    if src == "-":
        md = sys.stdin.read()
        base_title = "Note"
    elif src.lower().endswith((".epub", ".pdf")):
        md = None
        base_title = os.path.splitext(os.path.basename(src))[0]
    else:
        with open(src, "r", encoding="utf-8", errors="replace") as f:
            md = f.read()
        base_title = os.path.splitext(os.path.basename(src))[0]

    if md is None:
        path = src
    else:
        title = args.title or guess_title(md, base_title)
        stamp = _dt.datetime.now().strftime("%Y-%m-%d %H%M")
        fname = "%s (%s).epub" % (safe_filename(title), stamp)
        if args.out:
            path = args.out
            if os.path.isdir(path):
                path = os.path.join(path, fname)
        else:
            path = os.path.join(tempfile.mkdtemp(prefix="kindle-"), fname)
        build_epub(md, path, title, args.author)
        print("built: %s" % path)

    if args.via == "none":
        return 0

    errors = []
    if args.via in ("auto", "ssh"):
        remote, err = send_ssh(path, args.host, args.user, args.dest)
        if remote:
            print("sent over ssh: %s:%s" % (args.host, remote))
            print("On the Kindle: KOReader file browser -> open %s (pull down or tap the folder again to refresh)." % args.dest)
            return 0
        errors.append("ssh: " + err)
        if args.via == "ssh":
            print("\n".join(errors), file=sys.stderr)
            return 1
    if args.via in ("auto", "usb"):
        dest, err = send_usb(path)
        if dest:
            print("copied to Kindle drive: %s" % dest)
            print("Eject the Kindle; the book appears under documents/Claude.")
            return 0
        errors.append("usb: " + err)
    print("could not deliver:\n  " + "\n  ".join(errors), file=sys.stderr)
    print("file kept at: %s" % path, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
