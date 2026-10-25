#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build 512x512 Steam Workshop covers for AutoEquipRareAncillaries.

Art is taken from the user's own WH3 screenshots:
  * character: _analysis/screen_v151_state.png
  * executioner's axe icon: _analysis/screen_after_drag.png
No external images are downloaded.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

ROOT = Path(r"E:\dev\wh3mod")
SCREEN_CHAR = ROOT / "_analysis" / "screen_v151_state.png"
SCREEN_ICON = ROOT / "_analysis" / "screen_after_drag.png"
OUT_DIR = Path(r"E:\dev\wh3mod\auto-equip-rare-ancillaries\workshop")
OUT_DIR.mkdir(parents=True, exist_ok=True)

SIZE = 512
GOLD = (214, 171, 90)
GOLD_LIGHT = (250, 231, 178)
GOLD_DARK = (117, 73, 28)
INK = (15, 10, 7)
BLUE = (70, 155, 255)
BLUE_LIGHT = (160, 220, 255)

CN_FONT = r"C:\Windows\Fonts\msyhbd.ttc"
CN_FONT_FALLBACK = r"C:\Windows\Fonts\simhei.ttf"
EN_FONT = r"C:\Windows\Fonts\constanb.ttf"
EN_FONT_FALLBACK = r"C:\Windows\Fonts\georgiab.ttf"


def load_font(path: str, fallback: str, size: int) -> ImageFont.FreeTypeFont:
    for p in (path, fallback):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    raise RuntimeError("no usable font")


def gradient_text(
    text: str,
    font: ImageFont.FreeTypeFont,
    *,
    top=GOLD_LIGHT,
    bottom=GOLD_DARK,
    outline=INK,
    glow=GOLD,
    stroke: int = 3,
    glow_size: int = 10,
) -> Image.Image:
    """Return an RGBA text layer with outline, soft glow and a gold gradient."""
    dummy = Image.new("RGBA", (10, 10))
    d = ImageDraw.Draw(dummy)
    box = d.textbbox((0, 0), text, font=font, stroke_width=stroke)
    pad = glow_size * 2 + 8
    w = box[2] - box[0] + pad * 2
    h = box[3] - box[1] + pad * 2
    origin = (pad - box[0], pad - box[1])

    mask = Image.new("L", (w, h), 0)
    md = ImageDraw.Draw(mask)
    md.text(origin, text, font=font, fill=255, stroke_width=stroke, stroke_fill=255)

    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    # soft outer glow
    glow_mask = Image.new("L", (w, h), 0)
    gd = ImageDraw.Draw(glow_mask)
    gd.text(origin, text, font=font, fill=255, stroke_width=stroke + glow_size, stroke_fill=255)
    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(glow_size * 0.55))
    glow_layer = Image.new("RGBA", (w, h), glow + (0,))
    glow_layer.putalpha(glow_mask.point(lambda v: int(v * 0.65)))
    layer.alpha_composite(glow_layer)

    # dark outline / drop shadow
    outline_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    od = ImageDraw.Draw(outline_layer)
    od.text(
        (origin[0], origin[1] + 4),
        text,
        font=font,
        fill=outline + (235,),
        stroke_width=stroke + 2,
        stroke_fill=outline + (235,),
    )
    layer.alpha_composite(outline_layer)

    # gradient fill
    grad = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gp = grad.load()
    for y in range(h):
        t = max(0.0, min(1.0, (y - pad) / max(1, (h - 2 * pad))))
        col = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)) + (255,)
        for x in range(w):
            gp[x, y] = col
    grad.putalpha(mask)
    layer.alpha_composite(grad)
    return layer


def spaced_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    font: ImageFont.FreeTypeFont,
    fill,
    spacing: int = 2,
    anchor_center: bool = True,
) -> None:
    widths = [draw.textlength(ch, font=font) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x, y = xy
    if anchor_center:
        x -= total / 2
    for ch, cw in zip(text, widths):
        draw.text((x, y), ch, font=font, fill=fill)
        x += cw + spacing


def make_axe_badge(screen: Image.Image, size: int) -> Image.Image:
    """Gold executioner's axe icon on a blue field, with a custom gold frame."""
    inner = screen.crop((3238, 792, 3348, 908)).convert("RGBA")  # 110x116, includes frame
    inner = ImageOps.fit(inner, (size, size), method=Image.LANCZOS)
    inner = inner.filter(ImageFilter.UnsharpMask(radius=2, percent=120, threshold=2))
    inner = ImageEnhance.Contrast(inner).enhance(1.04)

    pad = max(8, size // 10)
    full = size + pad * 2
    badge = Image.new("RGBA", (full, full), (0, 0, 0, 0))
    d = ImageDraw.Draw(badge)

    # dark backing and gold bevel
    d.rounded_rectangle((0, 0, full - 1, full - 1), radius=pad // 2, fill=(20, 14, 10, 255))
    d.rounded_rectangle((2, 2, full - 3, full - 3), radius=pad // 2, outline=GOLD_DARK + (255,), width=3)
    d.rounded_rectangle((5, 5, full - 6, full - 6), radius=pad // 3, outline=GOLD + (255,), width=2)
    badge.paste(inner, (pad, pad), inner)
    # inner gold line
    d.rectangle((pad - 1, pad - 1, pad + size, pad + size), outline=GOLD_LIGHT + (180,), width=1)
    return badge


def add_glow(canvas: Image.Image, center: tuple[int, int], radius: int, color=BLUE) -> None:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(8, 0, -1):
        r = int(radius * (1 + i * 0.16))
        alpha = int(24 * (9 - i) / 8)
        d.ellipse(
            (center[0] - r, center[1] - r, center[0] + r, center[1] + r),
            fill=color + (alpha,),
        )
    layer = layer.filter(ImageFilter.GaussianBlur(radius * 0.28))
    canvas.alpha_composite(layer)


def vignette(canvas: Image.Image, strength: int = 190) -> None:
    w, h = canvas.size
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse((-w * 0.25, -h * 0.25, w * 1.25, h * 1.25), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(w * 0.18))
    inv = mask.point(lambda v: int((255 - v) * strength / 255))
    dark = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    dark.putalpha(inv)
    canvas.alpha_composite(dark)


def border(canvas: Image.Image) -> None:
    d = ImageDraw.Draw(canvas)
    # outer / inner gold lines
    d.rectangle((8, 8, SIZE - 9, SIZE - 9), outline=GOLD_DARK + (255,), width=4)
    d.rectangle((11, 11, SIZE - 12, SIZE - 12), outline=GOLD + (255,), width=2)
    d.rectangle((17, 17, SIZE - 18, SIZE - 18), outline=GOLD_LIGHT + (120,), width=1)
    # corner diamonds
    for cx, cy in ((15, 15), (SIZE - 16, 15), (15, SIZE - 16), (SIZE - 16, SIZE - 16)):
        pts = [(cx, cy - 7), (cx + 7, cy), (cx, cy + 7), (cx - 7, cy)]
        d.polygon(pts, fill=GOLD_LIGHT + (255,), outline=GOLD_DARK + (255,))


def title_block(canvas: Image.Image, small: str, title: str, sub: str) -> None:
    # dark plaque behind the title, so the character art does not fight the text
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((22, 20, SIZE - 23, 148), radius=10, fill=(8, 6, 5, 190))
    d.rounded_rectangle((22, 20, SIZE - 23, 148), radius=10, outline=GOLD_DARK + (255,), width=2)
    d.rounded_rectangle((26, 24, SIZE - 27, 144), radius=8, outline=GOLD + (120,), width=1)

    f_small = load_font(EN_FONT, EN_FONT_FALLBACK, 11)
    f_title = load_font(CN_FONT, CN_FONT_FALLBACK, 50)
    f_sub = load_font(EN_FONT, EN_FONT_FALLBACK, 12)

    spaced_text(d, (SIZE // 2, 32), small, f_small, GOLD_LIGHT + (235,), 2)
    # crisp gold title: dark shadow + dark stroke, no heavy glow
    d.text((SIZE // 2, 89 + 3), title, font=f_title, fill=(0, 0, 0, 235),
           stroke_width=4, stroke_fill=(0, 0, 0, 235), anchor="mm")
    d.text((SIZE // 2, 89), title, font=f_title, fill=GOLD_LIGHT + (255,),
           stroke_width=3, stroke_fill=INK + (255,), anchor="mm")
    spaced_text(d, (SIZE // 2, 120), sub, f_sub, GOLD + (235,), 2)


def bottom_block(canvas: Image.Image, line1: str, line2: str) -> None:
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((22, 440, SIZE - 23, 492), radius=8, fill=(8, 6, 5, 205))
    d.rounded_rectangle((22, 440, SIZE - 23, 492), radius=8, outline=GOLD_DARK + (255,), width=2)
    f1 = load_font(CN_FONT_FALLBACK, CN_FONT_FALLBACK, 18)
    f2 = load_font(CN_FONT_FALLBACK, CN_FONT_FALLBACK, 12)
    d.text((SIZE // 2, 447), line1, font=f1, fill=GOLD_LIGHT + (245,), anchor="ma")
    d.text((SIZE // 2, 472), line2, font=f2, fill=(205, 190, 160, 230), anchor="ma")


def base_character() -> Image.Image:
    im = Image.open(SCREEN_CHAR).convert("RGB")
    # head + torso, with the character slightly left of centre
    crop = im.crop((1180, 300, 2200, 1320))
    bg = ImageOps.fit(crop, (SIZE, SIZE), method=Image.LANCZOS, centering=(0.42, 0.38))
    bg = ImageEnhance.Brightness(bg).enhance(0.82)
    bg = ImageEnhance.Contrast(bg).enhance(1.08)
    bg = bg.filter(ImageFilter.GaussianBlur(0.7))
    canvas = bg.convert("RGBA")

    # cool dark grade
    canvas.alpha_composite(Image.new("RGBA", canvas.size, (8, 10, 24, 54)))
    # top/bottom cinematic gradients
    grad = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(190):
        gd.line((0, y, SIZE, y), fill=(0, 0, 0, int(180 * (1 - y / 190))))
    for y in range(360, SIZE):
        gd.line((0, y, SIZE, y), fill=(0, 0, 0, int(190 * (y - 360) / (SIZE - 360))))
    canvas.alpha_composite(grad)
    vignette(canvas, 175)
    return canvas


def cover_character() -> Image.Image:
    bg = base_character()

    screen = Image.open(SCREEN_ICON).convert("RGB")
    badge = make_axe_badge(screen, 108)
    add_glow(bg, (412, 82), 72, BLUE)
    bg.alpha_composite(badge, (358, 28))

    d = ImageDraw.Draw(bg)
    f_small = load_font(EN_FONT, EN_FONT_FALLBACK, 11)
    # top line: dark drop shadow so it stays readable on the forest
    spaced_text(d, (SIZE // 2, 26), "TOTAL WAR : WARHAMMER III", f_small, (0, 0, 0, 220), 2)
    spaced_text(d, (SIZE // 2, 24), "TOTAL WAR : WARHAMMER III", f_small, GOLD_LIGHT + (245,), 2)

    # bottom title plaque, keeping the character's head visible
    d.rounded_rectangle((22, 382, SIZE - 23, 492), radius=10, fill=(8, 6, 5, 205))
    d.rounded_rectangle((22, 382, SIZE - 23, 492), radius=10, outline=GOLD_DARK + (255,), width=2)
    d.rounded_rectangle((26, 386, SIZE - 27, 488), radius=8, outline=GOLD + (120,), width=1)

    f_title = load_font(CN_FONT, CN_FONT_FALLBACK, 46)
    d.text((SIZE // 2, 414 + 3), "一键装备蓝装", font=f_title, fill=(0, 0, 0, 235),
           stroke_width=4, stroke_fill=(0, 0, 0, 235), anchor="mm")
    d.text((SIZE // 2, 414), "一键装备蓝装", font=f_title, fill=GOLD_LIGHT + (255,),
           stroke_width=3, stroke_fill=INK + (255,), anchor="mm")

    f_sub = load_font(EN_FONT, EN_FONT_FALLBACK, 11)
    spaced_text(d, (SIZE // 2, 450), "AUTO EQUIP RARE ANCILLARIES", f_sub, GOLD + (235,), 2)
    f_tag = load_font(CN_FONT_FALLBACK, CN_FONT_FALLBACK, 13)
    d.text((SIZE // 2, 470), "默认每回合自动装备 · 只填空槽", font=f_tag, fill=(215, 198, 165, 235), anchor="ma")

    border(bg)
    return bg


def cover_item() -> Image.Image:
    im = Image.open(SCREEN_CHAR).convert("RGB")
    crop = im.crop((1180, 300, 2200, 1320))
    bg = ImageOps.fit(crop, (SIZE, SIZE), method=Image.LANCZOS)
    bg = bg.filter(ImageFilter.GaussianBlur(7))
    bg = ImageEnhance.Brightness(bg).enhance(0.42)
    bg = ImageEnhance.Contrast(bg).enhance(1.1)
    canvas = bg.convert("RGBA")
    canvas.alpha_composite(Image.new("RGBA", canvas.size, (6, 12, 30, 120)))
    vignette(canvas, 210)

    add_glow(canvas, (256, 292), 145, BLUE)

    screen = Image.open(SCREEN_ICON).convert("RGB")
    badge = make_axe_badge(screen, 158)
    canvas.alpha_composite(badge, ((SIZE - badge.width) // 2, 202))

    title_block(canvas, "TOTAL WAR : WARHAMMER III", "一键装备蓝装", "AUTO EQUIP RARE ANCILLARIES")
    bottom_block(canvas, "默认每回合自动装备", "只填空槽 · 不替换已有装备")
    border(canvas)
    return canvas


def main() -> None:
    a = cover_character()
    b = cover_item()
    a.save(OUT_DIR / "cover_character.png")
    b.save(OUT_DIR / "cover_item.png")
    # 512 is the Workshop preview size; keep both candidates for review.
    print("saved", OUT_DIR / "cover_character.png", a.size)
    print("saved", OUT_DIR / "cover_item.png", b.size)


if __name__ == "__main__":
    main()
