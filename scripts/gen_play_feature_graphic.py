#!/usr/bin/env python3
"""Generate the Google Play feature graphic (1024x500 PNG, no alpha).

Composition: brand portrait (circle-cropped, right-aligned) over a deep
teal-charcoal field sampled from the icon's own palette; app name + tagline
left. Output: appstore/play/feature-graphic-1024x500.png

Built for the 2026-07 first Play release. Run from repo root:
    python3 scripts/gen_play_feature_graphic.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "brand" / "icon-square-1024.png"
OUT = ROOT / "appstore" / "play" / "feature-graphic-1024x500.png"

W, H = 1024, 500
BG = (16, 26, 30)          # deep teal-charcoal, from the icon's shadow tones
ACCENT = (72, 168, 170)    # braid teal
TEXT = (236, 240, 239)
SUBTEXT = (158, 175, 176)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Avenir Next.ttc",
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        try:
            # Avenir Next.ttc faces: 0=Bold, 5=Medium, 7=Regular (probed via getname()).
            if path.endswith(".ttc"):
                return ImageFont.truetype(path, size, index=0 if bold else 5)
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


img = Image.new("RGB", (W, H), BG)
draw = ImageDraw.Draw(img)

# Right: circle-cropped portrait, bleeding slightly off-canvas.
portrait = Image.open(SRC).convert("RGB")
D = 520  # circle diameter
portrait = portrait.resize((D, D), Image.LANCZOS)
mask = Image.new("L", (D, D), 0)
ImageDraw.Draw(mask).ellipse((0, 0, D, D), fill=255)
mask = mask.filter(ImageFilter.GaussianBlur(1))
cx, cy = W - 250, H // 2  # circle center
img.paste(portrait, (cx - D // 2, cy - D // 2), mask)

# Thin accent ring around the portrait.
ring = ImageDraw.Draw(img)
r = D // 2 + 6
ring.ellipse((cx - r, cy - r, cx + r, cy + r), outline=ACCENT, width=3)

# Left: name + tagline. Hierarchy via size/weight only.
LX = 64
draw.text((LX, 148), "Quenderin", font=font(84, bold=True), fill=TEXT)
draw.text((LX, 258), "Private on-device AI chat", font=font(36), fill=ACCENT)
draw.text((LX, 318), "Works fully offline", font=font(27), fill=SUBTEXT)
draw.text((LX, 356), "No account · No cloud", font=font(27), fill=SUBTEXT)

OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT, "PNG")
print(f"wrote {OUT} ({img.size[0]}x{img.size[1]}, mode={img.mode})")
