# Cutting a perfect app icon out of AI-generated artwork

**Audience: a future agent session** (written for Opus 4.8, works for anyone) that needs to
extract an icon plate from a generated image — here or in another project — without the
half-rim slivers and off-center crops that scream "automated". The working implementation is
[`scripts/generate_icons.py`](../scripts/generate_icons.py); this file is the reasoning, so
you can re-derive the technique instead of cargo-culting it.

## The setup

The source (`brand/icon-source.png`) is a full Gemini artwork: a crisp **rounded-square icon
plate** (the elf) sitting on a **blurred decorative backdrop**, with a thin bright rim around
the plate. The goal is a clean, full-bleed, exactly-square 1024px master with **zero rim and
zero backdrop** in any corner — every platform asset derives from that one master.

## Step 1 — find the plate by SHARPNESS, not brightness

The obvious approach — scan for bright pixels to find the plate edges — **fails on this kind
of art**: the subject's skin and hair are brighter than the rim, so a brightness scan latches
onto the face and crops a portrait, not the plate. (We shipped that mistake first. It looked
insane.)

The property that actually separates plate from backdrop is **focus**: the backdrop is
heavily blurred, the plate is crisp. So measure per-column and per-row *high-frequency
energy* — the sum of absolute differences between neighboring pixels:

```python
small = img.convert("L").resize((512, 512), Image.BILINEAR)   # cheap + denoised
col = [sum(abs(px[x, y] - px[x, y-1]) for y in range(1, h, 2)) for x in range(w)]
row = [sum(abs(px[x, y] - px[x-1, y]) for x in range(1, w, 2)) for y in range(h)]
```

Blur means small neighbor differences; crisp detail means large ones. The profiles are
near-flat over the backdrop and spike across the plate. Take the band where the profile
exceeds **22% of its own maximum** (a *relative* threshold — absolute thresholds break when
the artwork changes), first-index to last-index, on both axes. That's the plate's bounding
box. Scale back up to full resolution.

- Work at 512×512: fast, and the downsample itself suppresses backdrop noise.
- Stride 2 in the inner loops: half the work, no measurable loss.
- If `band()` finds nothing above threshold, **fail loudly** — a wrong crop shipped silently
  is far worse than a script that stops.

## Step 2 — the inset: geometry, not taste

The bounding box hugs the plate's **outer** edge, which includes the bright rim — and the
plate has rounded corners, so a square crop at the box edge puts **backdrop in all four
corners**. Inset the crop so the square's corners land inside the rounded corner arc:

- For corner radius `r` (as a fraction of plate width), a square corner intrudes past the
  arc by `r · (1 − 1/√2)` ≈ `0.293 · r`. This plate's radius ≈ 12% → **≈3.5%**.
- Add the rim's own thickness (≈2.3% here).
- Total: **5.8% inset** from each side of the detected box.

We got there empirically too — 1.5% left rim slivers in the corners, 4.5% still clipped the
arc on one side — but compute the geometric floor first and you start one iteration from
done, not four.

Then **force the crop square around the box center** (`half = min(w, h) / 2`): detection can
read a few pixels non-square, and resizing a 1017×1024 "square" smears the art. Resize with
`LANCZOS` to 1024.

## Step 3 — verify like a user, not like a script

The script printing `1024x1024` proves nothing. Render the actual outputs and look:

1. Zoom into **all four corners** of the master — any bright arc = rim residue, increase inset.
2. Check the **smallest** favicon (16px) — off-center crops that are invisible at 1024 are
   glaring at 16.
3. On-device/in-simulator if you can: macOS docks and Android launchers apply their own
   masks, which is where margin mistakes appear.

## Step 4 — one master, many shapes (never re-cut per platform)

Every platform asset is a *transform of the master*, so a better cut later fixes everything
by re-running one script:

| Target | Transform |
|---|---|
| iOS | the master, full-bleed 1024 (Apple rounds it) |
| macOS | Big-Sur squircle: master → 824×824 rounded-rect (r=186) centered on transparent 1024 — Apple's grid margins |
| Android adaptive | master at **70%** of the 108dp canvas, centered (launcher masks to ~72dp circle); background color = **median of the art's top/bottom border bands** (median ignores motif outliers; mean doesn't) |
| Android legacy | rounded (r=15%) + circle mipmaps per density |
| Electron/Windows/Linux | rounded (r=10%) → multi-size `.ico` via Pillow, `.icns` via macOS `iconutil` |
| Web favicons | rounded (r=20%) 32/16px; `favicon.svg` is an **SVG wrapper embedding the 64px PNG base64** — keeps an existing `<link type="image/svg+xml">` working with raster art |

## Pitfalls that cost us real time

- **Brightness-based detection** → crops the subject's face. Sharpness is the signal.
- **Too-small inset** → backdrop slivers in corners, visible only when zoomed or masked.
- **Trusting the box to be square** → 7px of anisotropic smear after resize.
- **Per-platform manual crops** → drift; the second platform never matches the first.
- **Skipping the 16px check** → the favicon is where every error is loudest.

Regenerate everything: `python3 scripts/generate_icons.py` (Pillow required; `iconutil`
needs macOS). Companion for the in-app vendor logos: `scripts/generate_model_logos.py`.
Brand rules: [BRAND.md](BRAND.md).
