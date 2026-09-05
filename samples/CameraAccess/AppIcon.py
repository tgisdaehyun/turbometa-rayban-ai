from PIL import Image, ImageDraw, ImageFilter
import math

SS = 4096          # supersample canvas
OUT = 1024
C = SS // 2

def lerp(a, b, t): return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

# --- background: deep vertical gradient, near-black plum -> ink blue -------------
top, bot = (26, 16, 34), (9, 10, 20)
col = Image.new("RGB", (1, SS))
for y in range(SS):
    col.putpixel((0, y), lerp(top, bot, y / (SS - 1)))
bg = col.resize((SS, SS), Image.BILINEAR)

# --- warm radial glow behind the mark -------------------------------------------
glow = Image.radial_gradient("L").resize((SS, SS), Image.BILINEAR)
glow = Image.eval(glow, lambda v: max(0, 255 - v * 2))        # bright core, fast falloff
glow = glow.filter(ImageFilter.GaussianBlur(SS // 40))
bg = Image.composite(Image.new("RGB", (SS, SS), (86, 26, 44)), bg, glow.point(lambda v: v // 3))

# --- the mark: a solid core with three broken rings, gaps rotating ---------------
ACCENT = (255, 92, 92)          # recordAccent.colorset
mark = Image.new("RGB", (SS, SS), (0, 0, 0))
mask = Image.new("L", (SS, SS), 0)
d, m = ImageDraw.Draw(mark), ImageDraw.Draw(mask)

def ring(radius, width, gap_center_deg, gap_deg, alpha, tint):
    box = [C - radius, C - radius, C + radius, C + radius]
    start = gap_center_deg + gap_deg / 2
    end = gap_center_deg - gap_deg / 2 + 360
    d.arc(box, start, end, fill=tint, width=width)
    m.arc(box, start, end, fill=alpha, width=width)

# core
d.ellipse([C - 380, C - 380, C + 380, C + 380], fill=ACCENT)
m.ellipse([C - 380, C - 380, C + 380, C + 380], fill=255)
# rings sweep outward, each gap advanced 118 deg -> reads as motion
ring(700,  118, -28,  52, 235, ACCENT)
ring(1062, 104,  90,  74, 176, lerp(ACCENT, (255, 190, 150), .25))
ring(1424,  92, 208,  96, 112, lerp(ACCENT, (255, 214, 170), .45))

out = Image.composite(mark, bg, mask.filter(ImageFilter.GaussianBlur(2)))
out = out.resize((OUT, OUT), Image.LANCZOS).convert("RGB")   # opaque, no alpha
out.save("metarec-icon.png", optimize=True)
print("wrote metarec-icon.png", out.size, out.mode)
