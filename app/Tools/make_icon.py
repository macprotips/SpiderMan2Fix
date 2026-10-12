#!/usr/bin/env python3
# Draws Resources/AppIcon.iconset:  python3 Tools/make_icon.py Resources/AppIcon.iconset  (needs Pillow)
# A minimal spider hanging from a single thread on a deep red-to-ink background.
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096                      # drawn large, scaled down for clean edges
out = sys.argv[1]
U = S / 1024                  # 1 unit = 1 px at 1024

def px(v): return int(round(v * U))

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# macOS icon grid: 824 x 824 body, corner radius 185
box = [px(100), px(100), px(924), px(924)]
radius = px(185)

# background: diagonal deep red -> ink
top, bottom = (206, 30, 50), (28, 20, 40)
grad = Image.new("RGBA", (S, S))
g = ImageDraw.Draw(grad)
for y in range(S):
    t = min(1, max(0, (y - box[1]) / (box[3] - box[1])))
    t = t ** 1.35
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    g.line([(0, y), (S, y)], fill=c)
# soft light from the top left
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([px(-200), px(-260), px(700), px(560)], fill=(255, 120, 120, 60))
glow = glow.filter(ImageFilter.GaussianBlur(px(140)))
grad.alpha_composite(glow)

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([box[0], box[1] + px(10), box[2], box[3] + px(10)], radius, fill=(0, 0, 0, 110))
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(18))))
body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
body.paste(grad, (0, 0), mask)
img.alpha_composite(body)

# the spider
ink = (255, 255, 255, 255)
art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(art)
cx = 512
head_y, abdomen_y = 470, 590          # centres
W = px(19)                            # leg stroke

def dot(x, y, r):
    d.ellipse([px(x - r), px(y - r), px(x + r), px(y + r)], fill=ink)

def seg(a, b, w=W):
    d.line([px(a[0]), px(a[1]), px(b[0]), px(b[1])], fill=ink, width=w)
    for p in (a, b):
        d.ellipse([px(p[0]) - w // 2, px(p[1]) - w // 2, px(p[0]) + w // 2, px(p[1]) + w // 2], fill=ink)

# thread from the top edge of the body to the head
seg((cx, 60), (cx, head_y - 40), px(6))

# eight legs: (hip angle, knee distance, foot) per side, mirrored
legs = [  # (hip y, knee (dx, dy), foot (dx, dy))
    (456, (100, -100), (178, -52)),
    (476, (128, -48), (212, 18)),
    (498, (126, 12), (200, 104)),
    (520, (98, 62), (148, 178)),
]
for hip_y, (kx, ky), (fx, fy) in legs:
    for side in (-1, 1):
        hip = (cx + side * 20, hip_y)
        knee = (cx + side * kx, hip_y + ky)
        foot = (cx + side * fx, hip_y + fy)
        seg(hip, knee)
        seg(knee, foot)

# body: head and abdomen
dot(cx, head_y, 46)
d.ellipse([px(cx - 70), px(abdomen_y - 88), px(cx + 70), px(abdomen_y + 88)], fill=ink)
# keep everything inside the icon shape
clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
clipped.paste(art, (0, 0), mask)
art = clipped

# soft drop shadow under the spider
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh.paste((0, 0, 0, 90), (0, 0), art.split()[3])
img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(px(10))), (0, px(8)))
img.alpha_composite(art)

os.makedirs(out, exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        p = size * scale
        img.resize((p, p), Image.LANCZOS).save(os.path.join(out, f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"))
img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(os.path.dirname(os.path.abspath(out)), "icon-preview.png"))
