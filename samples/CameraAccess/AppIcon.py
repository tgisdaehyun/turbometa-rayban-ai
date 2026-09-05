#!/usr/bin/env python3
"""Regenerates Assets.xcassets/AppIcon.appiconset/AppIcon.png.

The mark is abstract on purpose — no device, no lens, and nothing that can be
read as an eye: three rounded squares, each rotated a little further than the
last, closing on a solid centre. Teal on a light ground, so it also stands
apart from the dark icons around it on the home screen.

Drawn at 4x and downsampled for clean edges, and saved opaque: iOS rejects an
app icon with an alpha channel.

    python3 AppIcon.py
"""
from PIL import Image, ImageDraw, ImageFilter

SS, OUT, C = 4096, 1024, 2048
BG_TOP, BG_BOT = (242, 244, 248), (214, 222, 235)
INK_A, INK_B = (0, 168, 160), (20, 60, 120)
# (half-extent, stroke width, rotation) per ring, outermost first
RINGS = [(1290, 190, 0), (980, 175, 18), (670, 160, 36)]
CORE, CORE_RADIUS = 330, 120


def _lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def _vertical(top, bottom):
    strip = Image.new("RGB", (1, SS))
    for y in range(SS):
        strip.putpixel((0, y), _lerp(top, bottom, y / (SS - 1)))
    return strip.resize((SS, SS), Image.BILINEAR)


def _diagonal(a, b):
    small = Image.new("RGB", (64, 64))
    for y in range(64):
        for x in range(64):
            small.putpixel((x, y), _lerp(a, b, (x + y) / 126))
    return small.resize((SS, SS), Image.BICUBIC)


def build():
    mask = Image.new("L", (SS, SS), 0)
    solid = Image.new("L", (SS, SS), 255)
    for half, width, rot in RINGS:
        layer = Image.new("L", (SS, SS), 0)
        ImageDraw.Draw(layer).rounded_rectangle(
            [C - half, C - half, C + half, C + half],
            radius=half // 3, outline=255, width=width,
        )
        layer = layer.rotate(rot, resample=Image.BICUBIC, center=(C, C))
        mask = Image.composite(solid, mask, layer)
    ImageDraw.Draw(mask).rounded_rectangle(
        [C - CORE, C - CORE, C + CORE, C + CORE], radius=CORE_RADIUS, fill=255
    )
    icon = Image.composite(
        _diagonal(INK_A, INK_B), _vertical(BG_TOP, BG_BOT),
        mask.filter(ImageFilter.GaussianBlur(3)),
    )
    return icon.resize((OUT, OUT), Image.LANCZOS).convert("RGB")


if __name__ == "__main__":
    out = "CameraAccess/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    build().save(out, optimize=True)
    print("wrote", out)
