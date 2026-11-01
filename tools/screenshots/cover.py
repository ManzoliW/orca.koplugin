"""Draws docs/cover.png: the title beside three Kindles showing screenshots.

    python tools/screenshots/cover.py [left.png middle.png right.png]

Defaults to a session, Home and the heatmaps from docs/screenshots/.
1280x640, GitHub's size for a repository's social preview.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "docs" / "screenshots"
W, H = 1280, 640
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

    d = ImageDraw.Draw(canvas)
    title = font(["georgiab.ttf", "DejaVuSerif-Bold.ttf"], 64)
    body = font(["georgia.ttf", "DejaVuSerif.ttf"], 26)
    d.text((72, 190), "Kindle × Orca", font=title, fill=INK)
    lines = ["Claude Code and your other agents,", "on e-ink. Answer them from your book."]
    for i, line in enumerate(lines):
        d.text((74, 290 + i * 40), line, font=body, fill=DIM)
    small = font(["segoeui.ttf", "DejaVuSans.ttf"], 20)
    d.text((74, 400), "A KOReader plugin  ·  Tailscale  ·  GPLv3", font=small, fill=DIM)

    # Three Kindles, the middle one in front.
    back, front = 210, 250
    left, middle, right = (kindle(s, w) for s, w in zip(shots, (back, front, back)))
    overlap = 70
    total = left.width + middle.width + right.width - 2 * overlap
    x = W - 40 - total
    shadow(canvas, left, x, H - left.height - 60)
    shadow(canvas, right, x + left.width + middle.width - 2 * overlap, H - right.height - 60)
    shadow(canvas, middle, x + left.width - overlap, H - middle.height - 30)

    out = ROOT / "docs" / "cover.png"
    canvas.convert("RGB").save(out, optimize=True)
    print(out)


if __name__ == "__main__":
    main()
