#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Meridian — AppIcon generator.

    python Tools/make-icon.py            # writes ios/Meridian/Assets.xcassets
    python Tools/make-icon.py --out DIR  # writes somewhere else (idempotent)

Why a script and not a checked-in PSD: the icon is part of the design system
(Palette.canvas / Palette.ember / Palette.ink live in Design/Theme.swift), so
the only sane source of truth is the three hex values below plus a little
geometry. Everything is drawn once on a 4096 px master and downsampled with
LANCZOS — drawing each size directly would make the 20 pt icon alias.

The art, per the brief:
  * near-black #08090B canvas with a very faint warm radial lift (#101010 centre)
  * one hairline amber needle from the centre toward 12 o'clock, +8° right,
    6 px wide at 1024, round caps, length 0.62 R
  * a 2.5 px ring at 0.78 R, white at 10 % — geometry, not a glow
  * four major ticks only (12/3/6/9), 0.06 R long, white at 22 %
  * an 8 px warm-white centre dot
No text, no gradient ball, no emoji, no glow stack. The corners are left square:
iOS applies the superellipse mask itself and cropping art to it by hand only
ever ends up misaligned.

Output is RGB, never RGBA: App Store validation rejects icons with an alpha
channel, and actool happily compiles a transparent icon that then gets rejected
at upload time. The script asserts the invariant before exiting.

No third-party packages beyond Pillow.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# --- Design tokens (must match ios/Meridian/Design/Theme.swift) -------------

CANVAS = (0x08, 0x09, 0x0B)        # Palette.canvas
CANVAS_LIFT = (0x10, 0x10, 0x10)   # the radial lift, barely there
EMBER = (0xE0, 0xA6, 0x62)         # Palette.ember
INK = (0xF4, 0xF1, 0xEC)           # Palette.ink

# --- Geometry, in 1024 pt units --------------------------------------------

DESIGN = 1024.0
MASTER = 4096                      # 4x supersample; downsampled per size
NEEDLE_ANGLE_DEG = 8.0             # clockwise from 12 o'clock
NEEDLE_LENGTH = 0.62               # × R
NEEDLE_WIDTH = 6.0                 # px at 1024
RING_RADIUS = 0.78                 # × R  (outermost ink → 11 % inset)
RING_WIDTH = 2.5                   # px at 1024
RING_ALPHA = 0.10
TICK_RADIUS = 0.72                 # inner end; tick runs out to the ring
TICK_LENGTH = 0.06                 # × R
TICK_WIDTH = 3.0                   # px at 1024
TICK_ALPHA = 0.22
CENTER_DOT_DIAMETER = 8.0          # px at 1024

# --- Naming: (folder filename, pixels, idiom, size string, scale) ----------


def icon_slots() -> list[dict]:
    """Every slot AppIcon.appiconset needs, plus the Xcode-16 single size.

    Xcode 15.x / 16 accepts the legacy all-sizes layout; Xcode 16 also accepts
    a single 1024x1024 'universal' + platform 'ios' entry. We emit both so the
    set compiles on either, which is what the brief asked for.
    """
    slots: list[dict] = []

    # iPhone slots. The canonical all-sizes template uses idiom "iphone"; the
    # single 1024 entry below is the only "universal" one, which is exactly
    # what Xcode 16 means by a single-size app icon.
    for size, scales in (
        ("20x20", (2, 3)),
        ("29x29", (2, 3)),
        ("40x40", (2, 3)),
        ("60x60", (2, 3)),
    ):
        for scale in scales:
            px = round(float(size.split("x")[0]) * scale)
            slots.append(
                dict(
                    filename=f"AppIcon-iphone-{size}@{scale}x.png",
                    px=px,
                    idiom="iphone",
                    size=size,
                    scale=f"{scale}x",
                )
            )

    # iPad-only slots (the app targets '1,2' and full screen on iPad).
    for size, scale in (
        ("20x20", 1),
        ("20x20", 2),
        ("29x29", 1),
        ("29x29", 2),
        ("40x40", 1),
        ("40x40", 2),
        ("76x76", 1),
        ("76x76", 2),
        ("83.5x83.5", 2),
    ):
        px = round(float(size.split("x")[0]) * scale)
        slots.append(
            dict(
                filename=f"AppIcon-ipad-{size}@{scale}x.png",
                px=px,
                idiom="ipad",
                size=size,
                scale=f"{scale}x",
            )
        )

    # Legacy marketing slot and the modern single-size slot, same art.
    slots.append(
        dict(
            filename="AppIcon-1024.png",
            px=1024,
            idiom="ios-marketing",
            size="1024x1024",
            scale="1x",
        )
    )
    slots.append(
        dict(
            filename="AppIcon-1024-universal.png",
            px=1024,
            idiom="universal",
            size="1024x1024",
            scale="1x",
            platform="ios",
        )
    )
    return slots


def _point(cx: float, cy: float, radius: float, angle_deg: float) -> tuple[float, float]:
    """Angle measured clockwise from 12 o'clock."""
    a = math.radians(angle_deg)
    return cx + radius * math.sin(a), cy - radius * math.cos(a)


def _radial_mask(px: int) -> Image.Image:
    """White in the centre, black at the corners, gentle falloff."""
    gradient = Image.radial_gradient("L").resize((px, px), Image.LANCZOS)

    def lut(v: int) -> int:
        # v: 0 at centre → 255 at edge. Keep the lift subtle; ^1.5 tightens it.
        return round(255 * ((255 - v) / 255.0) ** 1.5)

    return gradient.point(lut)


def _ring_and_ticks_mask(px: int) -> Image.Image:
    """One grayscale mask for the two translucent elements (ring + 4 ticks).

    Drawing them into a mask and compositing a solid colour over the canvas
    keeps the alpha exact at every size; ImageDraw itself does no
    antialiasing, so the 4x supersample is what smooths the circle.
    """
    mask = Image.new("L", (px, px), 0)
    d = ImageDraw.Draw(mask)
    s = px / DESIGN
    cx = cy = px / 2.0
    r = RING_RADIUS * (px / 2.0)

    ring_w = max(1, round(RING_WIDTH * s))
    d.ellipse(
        (cx - r, cy - r, cx + r, cy + r),
        outline=round(255 * RING_ALPHA),
        width=ring_w,
    )

    tick_w = max(1, round(TICK_WIDTH * s))
    tick_len = TICK_LENGTH * (px / 2.0)
    for angle in (0.0, 90.0, 180.0, 270.0):
        x0, y0 = _point(cx, cy, r - tick_len, angle)
        x1, y1 = _point(cx, cy, r, angle)
        d.line((x0, y0, x1, y1), fill=round(255 * TICK_ALPHA), width=tick_w)
        cap = tick_w / 2.0
        d.ellipse((x1 - cap, y1 - cap, x1 + cap, y1 + cap), fill=round(255 * TICK_ALPHA))
        d.ellipse((x0 - cap, y0 - cap, x0 + cap, y0 + cap), fill=round(255 * TICK_ALPHA))
    return mask


def render_master(px: int) -> Image.Image:
    """Canvas + needle + centre dot, drawn opaque at px×px."""
    s = px / DESIGN
    cx = cy = px / 2.0
    half = px / 2.0

    base = Image.new("RGB", (px, px), CANVAS)
    base = Image.composite(Image.new("RGB", (px, px), CANVAS_LIFT), base, _radial_mask(px))
    draw = ImageDraw.Draw(base)

    # The needle: one round-capped stroke from the centre, 8° past 12.
    length = NEEDLE_LENGTH * half
    nx, ny = _point(cx, cy, length, NEEDLE_ANGLE_DEG)
    width = max(1, round(NEEDLE_WIDTH * s))
    draw.line((cx, cy, nx, ny), fill=EMBER, width=width)
    cap = width / 2.0
    draw.ellipse((nx - cap, ny - cap, nx + cap, ny + cap), fill=EMBER)
    draw.ellipse((cx - cap, cy - cap, cx + cap, cy + cap), fill=EMBER)

    # Centre dot last so it sits on top of the needle's base.
    dot = max(1.0, CENTER_DOT_DIAMETER * s / 2.0)
    draw.ellipse((cx - dot, cy - dot, cx + dot, cy + dot), fill=INK)

    return base


def render_icon(master: Image.Image, px: int) -> Image.Image:
    """Downsample the master and lay the translucent ring/ticks over it."""
    icon = master.resize((px, px), Image.LANCZOS).convert("RGB")
    ring = _ring_and_ticks_mask(px).resize((px, px), Image.LANCZOS)
    white = Image.new("RGB", (px, px), (255, 255, 255))
    return Image.composite(white, icon, ring)


def contents_json(slots: list[dict]) -> dict:
    images = []
    for slot in slots:
        entry = {
            "filename": slot["filename"],
            "idiom": slot["idiom"],
            "scale": slot["scale"],
            "size": slot["size"],
        }
        if "platform" in slot:
            entry["platform"] = slot["platform"]
        images.append(entry)
    return {"images": images, "info": {"author": "xcode", "version": 1}}


def colorset(color: tuple[int, int, int], *, high_contrast: bool = False) -> dict:
    def components(rgb: tuple[int, int, int]) -> dict:
        return {
            "alpha": "1.000",
            "blue": f"{rgb[2] / 255:.3f}",
            "green": f"{rgb[1] / 255:.3f}",
            "red": f"{rgb[0] / 255:.3f}",
        }

    def entry(rgb: tuple[int, int, int], appearances=None) -> dict:
        item: dict = {"color": {"color-space": "srgb", "components": components(rgb)}, "idiom": "universal"}
        if appearances:
            item["appearances"] = appearances
        return item

    colors = [entry(color)]
    if high_contrast:
        # A slightly lifted ember: same hue, enough separation to stay legible
        # for users who turned on Increase Contrast.
        colors.append(
            entry(
                (0xEF, 0xB4, 0x77),
                [{"appearance": "contrast", "value": "high"}],
            )
        )
    return {"colors": colors, "info": {"author": "xcode", "version": 1}}


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the Meridian app icon set.")
    parser.add_argument(
        "--out",
        default=str(Path(__file__).resolve().parent.parent / "ios" / "Meridian" / "Assets.xcassets"),
        help="Assets.xcassets directory (default: ios/Meridian/Assets.xcassets)",
    )
    parser.add_argument("--quiet", action="store_true", help="only print the final summary")
    args = parser.parse_args()

    assets = Path(args.out)
    appicon = assets / "AppIcon.appiconset"
    accent = assets / "AccentColor.colorset"
    launch = assets / "LaunchBackground.colorset"
    for directory in (assets, appicon, accent, launch):
        directory.mkdir(parents=True, exist_ok=True)

    # Top-level catalog manifest.
    write_json(assets / "Contents.json", {"info": {"author": "xcode", "version": 1}})

    slots = icon_slots()
    master = render_master(MASTER)
    written: list[tuple[str, int]] = []
    for slot in slots:
        image = render_icon(master, slot["px"])
        if image.mode != "RGB":
            raise SystemExit(f"::error:: {slot['filename']} is {image.mode}, expected RGB (no alpha)")
        target = appicon / slot["filename"]
        image.save(target, format="PNG", optimize=True)
        written.append((slot["filename"], slot["px"]))

    # Remove PNGs from an older run whose slots no longer exist: an unreferenced
    # file in an appiconset is an "unassigned child" warning in actool.
    keep = {slot["filename"] for slot in slots}
    for stale in appicon.glob("*.png"):
        if stale.name not in keep:
            stale.unlink()

    write_json(appicon / "Contents.json", contents_json(slots))

    # The launch screen colour is referenced by Info.plist
    # (UILaunchScreen.UIColorName = LaunchBackground); deleting it makes iOS
    # fall back to a white letterbox.
    write_json(assets / "AccentColor.colorset" / "Contents.json", colorset(EMBER, high_contrast=True))
    write_json(assets / "LaunchBackground.colorset" / "Contents.json", colorset(CANVAS))

    # Verify on disk, not in memory: this is what actool will read.
    problems: list[str] = []
    for filename, px in written:
        path = appicon / filename
        with Image.open(path) as probe:
            probe.load()
            if probe.size != (px, px):
                problems.append(f"{filename}: size {probe.size}, expected ({px}, {px})")
            if probe.mode != "RGB":
                problems.append(f"{filename}: mode {probe.mode}, expected RGB (App Store rejects alpha)")
    if not (accent / "Contents.json").is_file() or not (launch / "Contents.json").is_file():
        problems.append("AccentColor.colorset / LaunchBackground.colorset Contents.json missing")

    if not args.quiet:
        print(f"master {MASTER}px -> {len(written)} icons in {appicon}")
        for filename, px in written:
            print(f"  {px:4d}px  {filename}")
    print(f"{'FAIL' if problems else 'OK'} — {len(written)} PNGs, all RGB, "
          f"AccentColor + LaunchBackground + catalog Contents.json")
    for problem in problems:
        print(f"  ! {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
