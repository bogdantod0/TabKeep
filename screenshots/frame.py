#!/usr/bin/env python3
"""Composite raw simulator screenshots into framed, captioned App Store
images. Layout is proportional to the canvas, so any slot size works.

Defaults to the 6.5"/6.7" iPhone slot. Env overrides:
  SHOT_RAW / SHOT_OUT   input / output directories
  SHOT_W   / SHOT_H     output canvas size (e.g. 2064x2752 for 13" iPad)
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.environ.get("SHOT_RAW") or os.path.join(ROOT, "screenshots", "raw")
OUT = os.environ.get("SHOT_OUT") or os.path.join(ROOT, "screenshots", "framed")
os.makedirs(OUT, exist_ok=True)

W = int(os.environ.get("SHOT_W", 1284))   # App Store portrait canvas
H = int(os.environ.get("SHOT_H", 2778))

# Brand accent (#196C8A) family — see AppTheme.accent.
BG_TOP = (38, 132, 166)
BG_BOTTOM = (16, 78, 104)

# Layout — proportional to the canvas, so the output size can be retargeted
# by editing W, H alone.
MARGIN_TOP = round(H * 0.052)
CAPTION_FONT_SIZE = round(W * 0.065)
CAPTION_LINE_SPACING = round(W * 0.012)
GAP = round(H * 0.032)
DEVICE_WIDTH = round(W * 0.75)
CORNER_RADIUS = round(W * 0.067)

CAPTIONS = {
    "01-dashboard":   "See exactly where\nyour money goes",
    "02-groups":      "Every trip and household\nin one place",
    "03-groupDetail": "Track shared expenses\nas they happen",
    "04-editExpense": "Split evenly, by shares,\nor across payers",
    "05-balances":    "Know who owes who,\nthen settle in a tap",
    "06-activity":    "Stay in sync with a\nlive activity feed",
}


def load_font(size):
    """Bold marketing font — SF Pro if available, else Arial Bold."""
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
        for name in ("Heavy", "Bold", "Semibold"):
            try:
                f.set_variation_by_name(name)
                return f
            except Exception:
                continue
        return f
    except Exception:
        return ImageFont.truetype(
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf", size)


def gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=(
            int(top[0] + (bottom[0] - top[0]) * t),
            int(top[1] + (bottom[1] - top[1]) * t),
            int(top[2] + (bottom[2] - top[2]) * t),
        ))
    return img


def round_corners(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, img.size[0], img.size[1]], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def frame_one(name, raw_path):
    canvas = gradient(W, H, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    # --- caption ---
    font = load_font(CAPTION_FONT_SIZE)
    caption = CAPTIONS.get(name, "")
    draw.multiline_text(
        (W // 2, MARGIN_TOP), caption,
        font=font, fill=(255, 255, 255, 255),
        anchor="ma", align="center", spacing=CAPTION_LINE_SPACING)
    bbox = draw.multiline_textbbox(
        (W // 2, MARGIN_TOP), caption,
        font=font, anchor="ma", align="center", spacing=CAPTION_LINE_SPACING)
    caption_bottom = bbox[3]

    # --- device screenshot ---
    shot = Image.open(raw_path).convert("RGB")
    dw = DEVICE_WIDTH
    dh = round(dw * shot.height / shot.width)
    shot = shot.resize((dw, dh), Image.LANCZOS)
    shot = round_corners(shot, CORNER_RADIUS)

    dx = (W - dw) // 2
    dy = caption_bottom + GAP

    # soft drop shadow
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [dx, dy + 26, dx + dw, dy + dh + 26],
        radius=CORNER_RADIUS, fill=(0, 0, 0, 115))
    shadow = shadow.filter(ImageFilter.GaussianBlur(38))
    canvas = Image.alpha_composite(canvas, shadow)

    canvas.paste(shot, (dx, dy), shot)

    out_path = os.path.join(OUT, name + ".png")
    canvas.convert("RGB").save(out_path, "PNG")
    print(f"  {name}.png  ({W}x{H})")
    return out_path


def main():
    raws = sorted(f for f in os.listdir(RAW) if f.endswith(".png"))
    if not raws:
        raise SystemExit(f"No raw screenshots in {RAW}")
    print(f"Framing {len(raws)} screenshot(s) -> {OUT}")
    for f in raws:
        frame_one(os.path.splitext(f)[0], os.path.join(RAW, f))
    print("Done.")


if __name__ == "__main__":
    main()
