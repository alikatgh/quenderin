#!/usr/bin/env python3
"""Generate every platform icon from the master Quenderin artwork.

Usage:  python3 scripts/generate_icons.py [path-to-source-art]
        (default source: brand/icon-source.png)

The source is the full Gemini artwork: a rounded-square icon plate on a blurred
backdrop. The script finds the plate by scanning for its bright rim, crops just
inside it (full-bleed square master), then writes:

  brand/                          master crops (source of truth for redraws)
  apple/QuenderinApp/Assets.xcassets/AppIcon.appiconset/
                                  iOS 1024 full-bleed + macOS Big-Sur squircle set
  android/app/src/main/res/      adaptive icon (foreground per density + bg color)
                                  and legacy rounded/round mipmaps
  brand/electron/                 electron-builder resources (icns/ico/png)
  website/                        favicon PNGs, SVG wrapper, apple-touch-icon,
                                  manifest 512

Pillow required (pip3 install --user Pillow). macOS `iconutil` builds the .icns.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent


def find_plate(img: Image.Image) -> tuple[int, int, int, int]:
    """Locate the icon plate by SHARPNESS, not brightness: the backdrop is heavily
    blurred while the plate is crisp, so per-column/row high-frequency energy spikes
    exactly across the plate. (A brightness scan latches onto bright skin instead.)"""
    small = img.convert("L").resize((512, 512), Image.BILINEAR)
    w, h = small.size
    px = small.load()
    col = [sum(abs(px[x, y] - px[x, y - 1]) for y in range(1, h, 2)) for x in range(w)]
    row = [sum(abs(px[x, y] - px[x - 1, y]) for x in range(1, w, 2)) for y in range(h)]

    def band(profile):
        threshold = max(profile) * 0.22
        above = [i for i, v in enumerate(profile) if v > threshold]
        if not above:
            raise SystemExit("could not find the icon plate — check the source image")
        return above[0], above[-1]

    lx, rx = band(col)
    ty, by = band(row)
    sx, sy = img.size[0] / w, img.size[1] / h
    return round(lx * sx), round(ty * sy), round(rx * sx), round(by * sy)


def square_master(img: Image.Image, size: int = 1024) -> Image.Image:
    """Full-bleed square master: crop just inside the plate rim (drops rim + backdrop)."""
    left, top, right, bottom = find_plate(img)
    # Inset enough that the SQUARE's corners sit inside the plate's ROUNDED corners
    # (radius ≈12% → r·(1−1/√2) ≈ 3.5%) plus the white rim itself.
    inset = int((right - left) * 0.058)
    box = (left + inset, top + inset, right - inset, bottom - inset)
    # Force square around the box center (the plate can read a few px non-square).
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    half = min(box[2] - box[0], box[3] - box[1]) / 2
    sq = img.crop((round(cx - half), round(cy - half), round(cx + half), round(cy + half)))
    return sq.resize((size, size), Image.LANCZOS).convert("RGB")


def rounded(img: Image.Image, radius_frac: float) -> Image.Image:
    """The art with rounded corners + transparency (legacy Android, Windows, Linux)."""
    s = img.size[0]
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=int(s * radius_frac), fill=255)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def circled(img: Image.Image) -> Image.Image:
    s = img.size[0]
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, s - 1, s - 1), fill=255)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def mac_squircle(master: Image.Image) -> Image.Image:
    """Big-Sur style: 824×824 rounded-rect plate centered on a transparent 1024 canvas
    (Apple's icon-grid margins), corner radius ≈185/824."""
    plate = master.resize((824, 824), Image.LANCZOS)
    mask = Image.new("L", (824, 824), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 823, 823), radius=186, fill=255)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    canvas.paste(plate, (100, 100), mask)
    return canvas


def adaptive_foreground(master: Image.Image, canvas_px: int) -> Image.Image:
    """Android adaptive-icon foreground: art at 70% of the 108dp canvas, centered —
    the launcher's mask (circle ≈72dp) then crops only the art's leather corners."""
    art_px = int(canvas_px * 0.70)
    art = master.resize((art_px, art_px), Image.LANCZOS)
    canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
    canvas.paste(art, ((canvas_px - art_px) // 2, (canvas_px - art_px) // 2))
    return canvas


def frame_color(master: Image.Image) -> str:
    """Median color of the art's border band — the adaptive-icon background color."""
    s = master.size[0]
    band = list(master.crop((0, 0, s, s // 20)).getdata()) + list(master.crop((0, s - s // 20, s, s)).getdata())
    med = tuple(sorted(c[i] for c in band)[len(band) // 2] for i in range(3))
    return "#{:02X}{:02X}{:02X}".format(*med)


def save(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print(f"  {path.relative_to(ROOT)}  {img.size[0]}x{img.size[1]}")


def main():
    src_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "brand/icon-source.png"
    src = Image.open(src_path)
    master = square_master(src)

    print("brand masters:")
    save(master, ROOT / "brand/icon-square-1024.png")
    save(master.resize((512, 512), Image.LANCZOS), ROOT / "brand/playstore-512.png")

    print("apple (iOS full-bleed + macOS squircle):")
    appicon = ROOT / "apple/QuenderinApp/Assets.xcassets/AppIcon.appiconset"
    save(master, appicon / "AppIcon-iOS-1024.png")
    squircle = mac_squircle(master)
    for pt in (16, 32, 64, 128, 256, 512, 1024):
        save(squircle.resize((pt, pt), Image.LANCZOS), appicon / f"AppIcon-mac-{pt}.png")

    print("android (adaptive + legacy):")
    res = ROOT / "android/app/src/main/res"
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, mult in densities.items():
        save(rounded(master, 0.15).resize((int(48 * mult),) * 2, Image.LANCZOS), res / f"mipmap-{name}/ic_launcher.png")
        save(circled(master).resize((int(48 * mult),) * 2, Image.LANCZOS), res / f"mipmap-{name}/ic_launcher_round.png")
        save(adaptive_foreground(master, int(108 * mult)), res / f"mipmap-{name}/ic_launcher_foreground.png")
    bg = frame_color(master)
    print(f"  adaptive background color: {bg}")

    print("electron-builder resources:")
    save(rounded(master, 0.10).resize((512, 512), Image.LANCZOS), ROOT / "brand/electron/icon.png")
    ico_base = rounded(master, 0.10).resize((256, 256), Image.LANCZOS)
    (ROOT / "brand/electron").mkdir(parents=True, exist_ok=True)
    ico_base.save(ROOT / "brand/electron/icon.ico", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
    print("  brand/electron/icon.ico  multi-size")

    print("in-app brand avatars (chat orbs / empty states) + dashboard favicon:")
    avatar = master.resize((384, 384), Image.LANCZOS)  # orbs render <=72pt@3x - 384px covers it
    save(avatar, ROOT / "apple/QuenderinKit/Sources/QuenderinKit/Resources/brand-avatar.png")
    save(avatar, ROOT / "android/app/src/main/res/drawable-nodpi/brand_avatar.png")
    save(rounded(master, 0.20).resize((64, 64), Image.LANCZOS), ROOT / "ui/public/favicon.png")

    print("website:")
    web = ROOT / "website"
    save(rounded(master, 0.20).resize((32, 32), Image.LANCZOS), web / "favicon-32.png")
    save(rounded(master, 0.20).resize((16, 16), Image.LANCZOS), web / "favicon-16.png")
    save(master.resize((180, 180), Image.LANCZOS), web / "apple-touch-icon.png")
    save(master.resize((512, 512), Image.LANCZOS), web / "icon-512.png")

    # favicon.svg: an SVG wrapper embedding the 64px PNG, so the existing
    # <link rel="icon" type="image/svg+xml"> keeps working with the raster art.
    import base64, io
    buf = io.BytesIO()
    rounded(master, 0.20).resize((64, 64), Image.LANCZOS).save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    (web / "favicon.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
        f'<image width="64" height="64" href="data:image/png;base64,{b64}"/></svg>\n'
    )
    print("  website/favicon.svg  (PNG-embedding wrapper)")

    # macOS .icns for electron-builder, via iconutil (needs the .iconset naming).
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "icon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            squircle.resize((pt, pt), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}.png")
            squircle.resize((pt * 2, pt * 2), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "brand/electron/icon.icns")], check=True)
    print("  brand/electron/icon.icns")
    print(f"\nDone. Android adaptive background color (for values/ic_launcher_background.xml): {bg}")


if __name__ == "__main__":
    main()
