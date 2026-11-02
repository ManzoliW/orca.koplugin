"""Draws docs/cover.png: the title beside three Kindles showing screenshots.

    python tools/screenshots/cover.py [left.png middle.png right.png]

Defaults to a session, Home and the heatmaps from docs/screenshots/.
1280x460: the title block and the three Kindles share one vertical center
and the same margin on every side.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "docs" / "screenshots"
W, H = 1280, 460
MARGIN = 64        # px around everything; the Kindles keep it top and bottom
PAPER = (244, 241, 234)
INK = (28, 28, 28)
DIM = (96, 92, 86)
BEZEL = (36, 36, 38)


def font(names, size):
    for name in names:
        for folder in (Path("C:/Windows/Fonts"), Path("/usr/share/fonts/truetype/dejavu"), Path("/Library/Fonts")):
            path = folder / name
            if path.exists():
                return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def kindle(shot, screen_w):
    """A Kindle Basic: a dark bezel, thicker at the bottom, around the screenshot."""
    img = Image.open(shot).convert("L").convert("RGB")
    screen_h = round(screen_w * img.height / img.width)
    img = img.resize((screen_w, screen_h), Image.LANCZOS)
    side, top, bottom = round(screen_w * 0.07), round(screen_w * 0.09), round(screen_w * 0.16)
    w, h = screen_w + 2 * side, screen_h + top + bottom
    device = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(device)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius=round(screen_w * 0.07), fill=BEZEL)
    device.paste(img, (side, top))
    # The logo strip under the screen.
    d.rounded_rectangle((w // 2 - screen_w // 12, h - bottom // 2 - 2, w // 2 + screen_w // 12, h - bottom // 2 + 2),
                        radius=2, fill=(70, 70, 72))
    return device


def shadow(canvas, device, x, y):
    blur = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    mask = Image.new("L", device.size, 0)
    mask.paste(device.split()[3])
    blur.paste((0, 0, 0, 90), (x + 10, y + 16), mask)
    canvas.alpha_composite(blur.filter(ImageFilter.GaussianBlur(18)))
    canvas.alpha_composite(device, (x, y))


def main():
    shots = [Path(p) for p in sys.argv[1:4]] or [SHOTS / "session.png", SHOTS / "home.png", SHOTS / "home-reading.png"]
    canvas = Image.new("RGBA", (W, H), PAPER + (255,))

    # Three Kindles, the middle one in front and as tall as the margins allow;
    # the side ones centered on it.
    front = round((H - 2 * MARGIN * 0.6) / (4 / 3 + 0.25))
    back = round(front * 0.84)
    left, middle, right = (kindle(s, w) for s, w in zip(shots, (back, front, back)))
    overlap = round(front * 0.28)
    total = left.width + middle.width + right.width - 2 * overlap
    x = W - MARGIN - total
    mid = H // 2
    shadow(canvas, left, x, mid - left.height // 2)
    shadow(canvas, right, x + left.width + middle.width - 2 * overlap, mid - right.height // 2)
    shadow(canvas, middle, x + left.width - overlap, mid - middle.height // 2)

    # The title block, centered on the same line.
    d = ImageDraw.Draw(canvas)
    title = font(["georgiab.ttf", "DejaVuSerif-Bold.ttf"], 60)
    body = font(["georgia.ttf", "DejaVuSerif.ttf"], 25)
    small = font(["segoeui.ttf", "DejaVuSans.ttf"], 19)
    blocks = [
        ("Kindle × Orca", title, INK, 26),
        ("Claude Code and your other agents,", body, DIM, 8),
        ("on e-ink. Answer them from your book.", body, DIM, 24),
        ("A KOReader plugin  ·  Tailscale  ·  GPLv3", small, DIM, 0),
    ]
    heights = [d.textbbox((0, 0), t, font=f)[3] for t, f, _c, _g in blocks]
    y = mid - (sum(heights) + sum(g for *_x, g in blocks)) // 2
    for (t, f, color, gap), h in zip(blocks, heights):
        d.text((MARGIN, y), t, font=f, fill=color)
        y += h + gap

    out = ROOT / "docs" / "cover.png"
    canvas.convert("RGB").save(out, optimize=True)
    print(out)


if __name__ == "__main__":
    main()
