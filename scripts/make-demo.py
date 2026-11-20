#!/usr/bin/env python3
"""Builds a short promo video (MP4) and GIF of Tally from offscreen snapshots.

    ./scripts/make-demo.sh        # renders snapshots, then runs this

Frames are drawn with Pillow and piped straight into ffmpeg. Project names are
hidden in the snapshots (TALLY_PRIVATE=1), so the output is safe to post.
"""
import math, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SNAP = Path(sys.argv[1])          # folder with p7.png, p24.png, p30.png, p7t.png, mb.png
OUT = Path(sys.argv[2])           # output folder
ICON = Path(__file__).resolve().parent.parent / "docs/icon-1024.png"
W, H, FPS = 1920, 1080, 30
DUR = 20.0

def font(size, weight="Regular", mono=False):
    f = ImageFont.truetype("/System/Library/Fonts/" + ("SFNSMono.ttf" if mono else "SFNS.ttf"), size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def ease(x):  # ease-in-out cubic, clamped
    x = max(0.0, min(1.0, x))
    return 4 * x**3 if x < .5 else 1 - (-2 * x + 2)**3 / 2

def clamp01(x): return max(0.0, min(1.0, x))

# ---------- assets ----------
states = {k: Image.open(SNAP / f"{k}.png").convert("RGB") for k in ("p7", "p24", "p30", "p7t")}
PW, PH = states["p7"].size
for k, im in states.items():  # periods can differ in height; pad to match so crossfades line up
    if im.height != PH:
        pad = Image.new("RGB", (PW, PH), im.getpixel((PW // 2, im.height - 1)))
        pad.paste(im.crop((0, 0, PW, min(im.height, PH)))); states[k] = pad
mb = Image.open(SNAP / "mb.png").convert("RGB")
row = mb.crop((0, 0, mb.width, mb.height // 3))
row = row.resize((row.width // 4, row.height // 4), Image.LANCZOS)
# trim the row's right padding to its content
arr = np.asarray(row).astype(int); bg = arr[2, 2]
cols = np.where((np.abs(arr - bg).sum(axis=2) > 30).any(axis=0))[0]
row = row.crop((max(cols.min() - 6, 0), 0, cols.max() + 6, row.height))
icon = Image.open(ICON).convert("RGBA").resize((220, 220), Image.LANCZOS)

# ---------- dithered wallpaper ----------
def wallpaper():
    bayer = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16 + 1 / 32
    cell = 6
    gw, gh = W // cell + 1, H // cell + 1
    yy, xx = np.mgrid[0:gh, 0:gw] * cell
    blobs = [((230, 120, 60), 260, 760, 620), ((66, 192, 141), 1500, 980, 560), ((130, 110, 230), 980, 120, 520)]
    base = np.array([16, 16, 19], float)
    img = np.tile(base, (gh, gw, 1))
    thr = bayer[(yy // cell) % 4, (xx // cell) % 4]
    for color, cx, cy, r in blobs:
        v = np.exp(-(((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * r * r))) * 0.62
        on = v > thr
        img[on] = img[on] * 0.25 + np.array(color) * 0.42
    small = Image.fromarray(img.astype(np.uint8))
    big = small.resize((gw * cell, gh * cell), Image.NEAREST).crop((0, 0, W, H))
    # turn each cell into a rounded-ish dot by darkening the cell gaps
    mask = Image.new("L", (W, H), 255); d = ImageDraw.Draw(mask)
    for x in range(0, W, cell): d.line([(x, 0), (x, H)], fill=0, width=2)
    for y in range(0, H, cell): d.line([(0, y), (W, y)], fill=0, width=2)
    return Image.composite(big, Image.new("RGB", (W, H), tuple(int(c) for c in base)), mask)

WALL = wallpaper()

# ---------- layout ----------
MBH = 48
PANEL_X, PANEL_Y = W - PW - 24, MBH + 12
VIS_H = H - PANEL_Y - 24
CLOCK = "Wed 9:41"
f_clock = font(26, "Semibold")
clock_w = f_clock.getlength(CLOCK)
METER_X = int(W - 28 - clock_w - 36 - row.width)
METER_Y = (MBH - row.height) // 2
METER_C = (METER_X + row.width // 2, MBH // 2)

def pill(px, py): return (PANEL_X + px, PANEL_Y + py)
P24, P7, P30, PCOST, PTOK = pill(82, 290), pill(158, 290), pill(234, 290), pill(342, 290), pill(448, 290)

# panel chrome: rounded mask + soft shadow
R = 26
pmask = Image.new("L", (PW, VIS_H), 0)
ImageDraw.Draw(pmask).rounded_rectangle((0, 0, PW - 1, VIS_H - 1), R, fill=255)
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((PANEL_X, PANEL_Y + 18, PANEL_X + PW, PANEL_Y + VIS_H + 18), R, fill=(0, 0, 0, 170))
shadow = shadow.filter(ImageFilter.GaussianBlur(30))

# ---------- timeline ----------
events = [(0, "p7"), (4.3, "p24"), (5.9, "p30"), (7.5, "p7"), (8.8, "p7t"), (10.6, "p7")]
cursor_keys = [(0.0, 700, 900), (1.4, *METER_C), (2.3, *METER_C), (4.1, *P24), (5.7, *P30), (7.3, *P7),
               (8.6, *PTOK), (10.4, *PCOST), (11.1, PANEL_X + 640, 640), (15.0, PANEL_X + 640, 640)]
clicks = [(1.5, METER_C), (4.3, P24), (5.9, P30), (7.5, P7), (8.8, PTOK), (10.6, PCOST)]
OPEN_T = 1.55
SCROLL = (11.3, 15.0)
END_T = 16.8
captions = [
    (1.0, 2.0, "Every AI plan, one glance", "Claude · Codex · OpenCode"),
    (2.0, 4.1, "Live limits for every plan", "Session, weekly and monthly windows"),
    (4.1, 8.5, "Know when you'll run out", "Resets, pace and runway forecasts"),
    (8.5, 11.3, "Dollars or tokens", "What your usage costs at API prices"),
    (11.3, 16.8, "See where it all went", "Spend by plan, tool and model"),
]
f_cap, f_sub = font(68, "Bold"), font(34, "Medium")

def panel_frame(t):
    i = max(k for k, (te, _) in enumerate(events) if te <= t)
    cur = states[events[i][1]]
    a = clamp01((t - events[i][0]) / 0.22)
    img = cur if i == 0 or a >= 1 else Image.blend(states[events[i - 1][1]], cur, a)
    off = int(ease((t - SCROLL[0]) / (SCROLL[1] - SCROLL[0])) * (PH - VIS_H))
    return img.crop((0, off, PW, off + VIS_H))

def cursor_pos(t):
    for (t0, x0, y0), (t1, x1, y1) in zip(cursor_keys, cursor_keys[1:]):
        if t0 <= t <= t1:
            e = ease((t - t0) / (t1 - t0))
            return x0 + (x1 - x0) * e, y0 + (y1 - y0) * e
    return cursor_keys[-1][1:]

ARROW = [(0, 0), (0, 25), (6, 19), (10.5, 28.5), (14, 27), (9.8, 17.8), (18, 17.8)]
def draw_cursor(d, x, y, s=1.7):
    pts = [(x + px * s, y + py * s) for px, py in ARROW]
    d.polygon(pts, fill=(0, 0, 0))
    inner = [(x + px * s * 0.8 + 2.4, y + py * s * 0.8 + 3.6) for px, py in ARROW]
    d.polygon(inner, fill=(255, 255, 255))

def text_center(d, cx, y, s, f, fill):
    d.text((cx - f.getlength(s) / 2, y), s, font=f, fill=fill)

def scene(t):
    frame = WALL.copy()
    d = ImageDraw.Draw(frame, "RGBA")
    # menu bar
    d.rectangle((0, 0, W, MBH), fill=(42, 42, 46, 255))
    frame.paste(row, (METER_X, METER_Y))
    d.text((W - 28 - clock_w, 9), CLOCK, font=f_clock, fill=(232, 232, 234))
    # panel
    if t >= OPEN_T:
        a = ease((t - OPEN_T) / 0.3)
        sh = shadow.copy(); sh.putalpha(sh.getchannel("A").point(lambda v: int(v * a)))
        frame.paste(sh, (0, 0), sh)
        p = panel_frame(t)
        m = pmask.point(lambda v: int(v * a))
        frame.paste(p, (PANEL_X, PANEL_Y + int((1 - a) * -14)), m)
        d = ImageDraw.Draw(frame, "RGBA")
    # captions on the left
    cx = PANEL_X // 2
    for t0, t1, a_, b_ in captions:
        if t0 <= t < t1:
            fade = min(clamp01((t - t0) / 0.35), clamp01((t1 - t) / 0.35))
            col = int(255 * fade)
            text_center(d, cx, 440, a_, f_cap, (245, 245, 247, col))
            text_center(d, cx, 532, b_, f_sub, (170, 170, 178, col))
    # click ripples + cursor
    for tc, (x, y) in clicks:
        k = (t - tc) / 0.4
        if 0 <= k <= 1:
            r = 10 + 26 * k
            d.ellipse((x - r, y - r, x + r, y + r), outline=(255, 255, 255, int(200 * (1 - k))), width=3)
    if t < SCROLL[1] + 0.6:
        x, y = cursor_pos(t)
        draw_cursor(d, x, y)
    # end card
    if t >= END_T - 0.5:
        a = clamp01((t - (END_T - 0.5)) / 0.5)
        card = WALL.copy(); cd = ImageDraw.Draw(card)
        card.paste(icon, ((W - 220) // 2, 250), icon)
        text_center(cd, W / 2, 500, "Tally", font(96, "Bold"), (245, 245, 247))
        text_center(cd, W / 2, 628, "Every AI subscription, at a glance.", font(40, "Medium"), (200, 200, 206))
        text_center(cd, W / 2, 730, "github.com/PratikRai0101/tally", font(34, "Medium", mono=True), (66, 192, 141))
        text_center(cd, W / 2, 790, "Free & open source · macOS 14+", font(28), (140, 140, 148))
        frame = Image.blend(frame, card, a)
    # open on a close-up of the menu bar meters, then pull back
    z = 1 + 1.6 * (1 - ease((t - 0.7) / 1.0))
    if z > 1.001:
        fx, fy = METER_C[0] + row.width * 0.15, 0
        cw, chh = W / z, H / z
        x0 = min(max(fx - cw * 0.55, 0), W - cw); y0 = 0
        frame = frame.crop((int(x0), int(y0), int(x0 + cw), int(y0 + chh))).resize((W, H), Image.LANCZOS)
    return frame

OUT.mkdir(parents=True, exist_ok=True)
mp4 = OUT / "tally-demo.mp4"
ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                       "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "16",
                       "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)], stdin=subprocess.PIPE)
n = int(DUR * FPS)
for i in range(n):
    ff.stdin.write(scene(i / FPS).tobytes())
    if i % 60 == 0: print(f"frame {i}/{n}", flush=True)
ff.stdin.close(); ff.wait()

gif = OUT / "tally-demo.gif"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(mp4), "-vf",
                "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];"
                "[b][p]paletteuse=dither=none:diff_mode=rectangle", str(gif)], check=True)
print(f"wrote {mp4}\nwrote {gif}")
