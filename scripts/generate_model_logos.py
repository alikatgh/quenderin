#!/usr/bin/env python3
"""Render the vendor logo SVGs (website/icons/*.svg, monochrome simpleicons paths) into
brand-colored transparent PNGs for the apps' model avatars.

The owner's call (2026-07-03): identify models by their OFFICIAL marks in-app — the way
LM Studio/Ollama do — instead of letter monograms. Nominative use to identify the vendor's
own models; the marks are never restyled beyond their own brand color.

macOS-only (uses qlmanage to rasterize the SVGs). Pillow required.

Usage: python3 scripts/generate_model_logos.py
Writes: apple/QuenderinKit/Sources/QuenderinKit/Resources/logo-<family>.png (256px)
        android/app/src/main/res/drawable-nodpi/logo_<family>.png
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

# family id prefix -> (svg name, official brand color)
LOGOS = {
    "llama": ("llama", "#0668E1"),      # Meta blue
    "qwen": ("qwen", "#615CED"),        # Qwen violet
    "deepseek": ("deepseek", "#4D6BFE"),
    "gemma": ("gemma", "#4285F4"),      # Google blue
    "mistral": ("mistral", "#FA5210"),
    "phi": ("phi", "#0078D4"),          # Microsoft blue
}


def main():
    apple = ROOT / "apple/QuenderinKit/Sources/QuenderinKit/Resources"
    android = ROOT / "android/app/src/main/res/drawable-nodpi"
    with tempfile.TemporaryDirectory() as td:
        for family, (svg, color) in LOGOS.items():
            src = ROOT / f"website/icons/{svg}.svg"
            subprocess.run(["qlmanage", "-t", "-s", "256", "-o", td, str(src)],
                           check=True, capture_output=True)
            im = Image.open(Path(td) / f"{svg}.svg.png").convert("L")
            r, g, b = (int(color[i:i + 2], 16) for i in (1, 3, 5))
            out = Image.new("RGBA", im.size, (r, g, b, 0))
            # Black glyph on white -> brand color with luminance-derived alpha.
            out.putalpha(im.point(lambda v: 255 - v))
            out.save(apple / f"logo-{family}.png")
            out.save(android / f"logo_{family}.png")
            print(f"logo-{family}.png  {color}")


if __name__ == "__main__":
    main()
