#!/usr/bin/env python3
"""Складывает снимки настоящих сайтов «с блокировкой» и «без» в одну картинку рядом.

Использование: side_by_side.py <папка-снимков> <папка-вывода>

Ищет пары <тест>__<сайт>-ON-<шаг>.png / <тест>__<сайт>-OFF-<шаг>.png (их пишет
RealSitesUITests через export_screenshots.py) и сохраняет <сайт>-<шаг>.png: слева
«Блокировка ВКЛ», справа «ВЫКЛ». Нужен Pillow.
"""
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

PATTERN = re.compile(r"^(?:.*__)?(?P<site>[\w.]+)-ON-(?P<step>[\w-]+)\.png$")


def font(size: int):
    for path in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                 "/System/Library/Fonts/Helvetica.ttc",
                 "/Library/Fonts/Arial.ttf"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    names = sorted(os.listdir(src)) if os.path.isdir(src) else []
    made = 0
    for name in names:
        m = PATTERN.match(name)
        if not m:
            continue
        off_name = name.replace(f"{m['site']}-ON-{m['step']}", f"{m['site']}-OFF-{m['step']}")
        if not os.path.exists(os.path.join(src, off_name)):
            continue
        on = Image.open(os.path.join(src, name)).convert("RGB")
        off = Image.open(os.path.join(src, off_name)).convert("RGB")
        height = max(on.height, off.height)
        gap, header = 24, 90
        canvas = Image.new("RGB", (on.width + off.width + gap, height + header), (28, 27, 34))
        canvas.paste(on, (0, header))
        canvas.paste(off, (on.width + gap, header))
        draw = ImageDraw.Draw(canvas)
        f = font(48)
        draw.text((24, 18), f"{m['site']} · Блокировка ВКЛ", fill=(167, 139, 250), font=f)
        draw.text((on.width + gap + 24, 18), f"{m['site']} · ВЫКЛ", fill=(251, 251, 254), font=f)
        result = os.path.join(out, f"{m['site']}-{m['step']}.png")
        # Уменьшаем вдвое: так пару удобно смотреть целиком.
        canvas = canvas.resize((canvas.width // 2, canvas.height // 2), Image.LANCZOS)
        canvas.save(result, optimize=True)
        made += 1
        print("  ", os.path.basename(result))
    print(f"пар ВКЛ/ВЫКЛ: {made}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
