import re, sys, html
from PIL import Image, ImageDraw, ImageFont
src = open(sys.argv[1]).read()
m = re.search(r'width="(\d+)" height="(\d+)"', src)
W, H = int(m.group(1)), int(m.group(2))
sc = 0.8
img = Image.new("RGB", (int(W*sc), int(H*sc)), (0, 0, 0))
d = ImageDraw.Draw(img)
font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", int(14*sc))
bfont = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", int(14*sc), index=1)
for x, y, w, h, fill in re.findall(r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)" fill="(#[0-9a-fA-F]{6})"', src):
    x, y, w, h = float(x)*sc, float(y)*sc, float(w)*sc, float(h)*sc
    d.rectangle([x, y, x+w, y+h], fill=fill)
for attrs, text in re.findall(r'<text ([^>]*)>([^<]*)</text>', src):
    a = dict(re.findall(r'([a-z-]+)="([^"]*)"', attrs))
    t = html.unescape(text)
    if not t.strip(): continue
    f = bfont if a.get("font-weight") == "bold" else font
    d.text((float(a["x"])*sc, (float(a["y"])-13)*sc), t, fill=a.get("fill", "#ffffff"), font=f)
img.save(sys.argv[2])
