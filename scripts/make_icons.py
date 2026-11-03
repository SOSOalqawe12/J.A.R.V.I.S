#!/usr/bin/env python3
"""Generates the JARVIS app icons (iOS + macOS asset catalogs) with Pillow.

Run from the repository root:  python3 scripts/make_icons.py
"""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE = 1024
CYAN = (61, 225, 255)


def draw_core(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size), (5, 12, 22))
    px = img.load()
    cx = cy = size / 2
    # Background radial gradient.
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / (size * 0.72)
            t = max(0.0, 1.0 - d)
            px[x, y] = (int(5 + 10 * t), int(12 + 40 * t), int(22 + 60 * t))

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse([cx - size * 0.30, cy - size * 0.30, cx + size * 0.30, cy + size * 0.30], fill=CYAN + (110,))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.08))
    img.paste(glow, (0, 0), glow)

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def arc(radius, width, start, end, alpha=255):
        box = [cx - radius, cy - radius, cx + radius, cy + radius]
        d.arc(box, start, end, fill=CYAN + (alpha,), width=int(width))

    # Segmented outer ring.
    for i in range(12):
        start = i * 30 + 4
        arc(size * 0.40, size * 0.035, start, start + 20, 235)
    arc(size * 0.32, size * 0.022, 20, 290, 210)
    arc(size * 0.25, size * 0.014, 200, 470, 180)
    # Tick marks.
    for i in range(48):
        a = math.radians(i * 7.5)
        r1, r2 = size * 0.445, size * (0.465 if i % 4 == 0 else 0.455)
        d.line([(cx + r1 * math.cos(a), cy + r1 * math.sin(a)), (cx + r2 * math.cos(a), cy + r2 * math.sin(a))],
               fill=CYAN + (150,), width=max(2, size // 300))
    layer = layer.filter(ImageFilter.GaussianBlur(size * 0.002))
    img.paste(layer, (0, 0), layer)

    core = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    c = ImageDraw.Draw(core)
    for i in range(40, 0, -1):
        r = size * 0.13 * i / 40
        t = 1 - i / 40
        col = (int(61 + 194 * t), int(225 + 30 * t), 255, 255)
        c.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
    core_glow = core.filter(ImageFilter.GaussianBlur(size * 0.03))
    img.paste(core_glow, (0, 0), core_glow)
    img.paste(core, (0, 0), core)
    return img


def rounded(img: Image.Image, inset: float, radius: float) -> Image.Image:
    size = img.size[0]
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * (1 - 2 * inset))
    scaled = img.resize((inner, inner), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (inner, inner), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, inner - 1, inner - 1], radius=int(inner * radius), fill=255)
    offset = int(size * inset)
    out.paste(scaled, (offset, offset), mask)
    return out


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def main():
    base = draw_core(SIZE)

    # iOS: single 1024 universal icon, no alpha.
    ios_set = os.path.join(ROOT, "iOS", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(ios_set, exist_ok=True)
    base.save(os.path.join(ios_set, "icon-1024.png"))
    write_json(os.path.join(ios_set, "Contents.json"), {
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    })

    # macOS: rounded-square icon in every required size.
    mac_set = os.path.join(ROOT, "macOS", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(mac_set, exist_ok=True)
    mac = rounded(base, inset=0.09, radius=0.225)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            mac.resize((px, px), Image.LANCZOS).save(os.path.join(mac_set, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    write_json(os.path.join(mac_set, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})

    for catalog in ("iOS", "macOS"):
        cat = os.path.join(ROOT, catalog, "Assets.xcassets")
        write_json(os.path.join(cat, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
        accent = os.path.join(cat, "AccentColor.colorset")
        os.makedirs(accent, exist_ok=True)
        write_json(os.path.join(accent, "Contents.json"), {
            "colors": [{"color": {"color-space": "srgb", "components": {"red": "0.240", "green": "0.880", "blue": "1.000", "alpha": "1.000"}}, "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        })

    launch = os.path.join(ROOT, "iOS", "Assets.xcassets", "LaunchBackground.colorset")
    os.makedirs(launch, exist_ok=True)
    write_json(os.path.join(launch, "Contents.json"), {
        "colors": [{"color": {"color-space": "srgb", "components": {"red": "0.020", "green": "0.050", "blue": "0.090", "alpha": "1.000"}}, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    })
    print("Icons written.")


if __name__ == "__main__":
    main()
