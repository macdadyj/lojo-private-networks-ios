#!/usr/bin/env python3
"""Render App/Resources/AppIcon.png (1024x1024, opaque) for LOJO Networks.

Run with any Python that has Pillow, e.g. ~/.local/share/ios-dev-venv/bin/python.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 3
S = SIZE * SS

TOP = (14, 116, 128)
BOTTOM = (38, 42, 112)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Resources", "AppIcon.png")
if len(sys.argv) > 1:
    out = sys.argv[1]

img = Image.new("RGB", (S, S))
px = img.load()
for y in range(S):
    for x in range(S):
        t = min(1.0, max(0.0, (0.65 * y + 0.35 * x) / S))
        px[x, y] = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))

glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy = S * 0.5, S * 0.53
gd.ellipse([cx - S * 0.36, cy - S * 0.36, cx + S * 0.36, cy + S * 0.36], fill=(120, 230, 220, 60))
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.06))
img.paste(glow, (0, 0), glow)

d = ImageDraw.Draw(img)
r = S * 0.27
nodes = []
for k in range(3):
    a = math.radians(-90 + k * 120)
    nodes.append((cx + r * math.cos(a), cy + r * math.sin(a)))

line_w = int(S * 0.028)
for i in range(3):
    a, b = nodes[i], nodes[(i + 1) % 3]
    d.line([a, b], fill=(225, 250, 248), width=line_w)
for n in nodes:
    d.line([(cx, cy), n], fill=(225, 250, 248), width=int(line_w * 0.8))

hub_r = S * 0.085
d.ellipse([cx - hub_r, cy - hub_r, cx + hub_r, cy + hub_r], fill=(255, 255, 255))
inner = hub_r * 0.45
d.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=(20, 110, 124))

node_r = S * 0.062
for n in nodes:
    d.ellipse([n[0] - node_r, n[1] - node_r, n[0] + node_r, n[1] + node_r], fill=(255, 255, 255))
    ring = node_r * 0.5
    d.ellipse([n[0] - ring, n[1] - ring, n[0] + ring, n[1] + ring], fill=(72, 214, 160))

img = img.resize((SIZE, SIZE), Image.LANCZOS)
os.makedirs(os.path.dirname(out), exist_ok=True)
img.save(out, "PNG")
print(out)
