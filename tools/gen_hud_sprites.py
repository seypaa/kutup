#!/usr/bin/env python3
"""Generates the HUD sprites used by biohazard.sma (needs sprites_on_hud.sma).

Output: ../sprites/*.spr  (copy the folder to cstrike/sprites on the server and FastDL).
Pure Python, no dependencies. Sprites are 48x48 8-bit paletted, index 255 is transparent.
"""
import math
import os
import struct

SIZE = 48
TRANSPARENT = 255

# Palette indices
BG, WHITE, RED, YELLOW, GREEN, ORANGE, DARK = 255, 1, 2, 3, 4, 5, 6
PALETTE = {
    0: (0, 0, 0),
    WHITE: (255, 255, 255),
    RED: (255, 50, 40),
    YELLOW: (255, 215, 0),
    GREEN: (80, 255, 90),
    ORANGE: (255, 150, 30),
    DARK: (40, 40, 40),
}

FONT = {  # 5x7 digits
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
}


class Canvas:
    def __init__(self):
        self.px = [[BG] * SIZE for _ in range(SIZE)]

    def set(self, x, y, c):
        if 0 <= x < SIZE and 0 <= y < SIZE:
            self.px[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.set(x, y, c)

    def circle(self, cx, cy, r, c):
        for y in range(cy - r, cy + r + 1):
            for x in range(cx - r, cx + r + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    self.set(x, y, c)

    def polygon(self, pts, c):
        ys = [p[1] for p in pts]
        for y in range(int(min(ys)), int(max(ys)) + 1):
            for x in range(SIZE):
                if inside(pts, x + 0.5, y + 0.5):
                    self.set(x, y, c)

    def text(self, s, scale, c, y0=None):
        w = len(s) * 5 * scale + (len(s) - 1) * scale
        h = 7 * scale
        x = (SIZE - w) // 2
        y = (SIZE - h) // 2 if y0 is None else y0
        for ch in s:
            for ry, row in enumerate(FONT[ch]):
                for rx, bit in enumerate(row):
                    if bit == "1":
                        self.rect(x + rx * scale, y + ry * scale, x + rx * scale + scale - 1, y + ry * scale + scale - 1, c)
            x += 6 * scale


def inside(pts, x, y):
    ok = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            ok = not ok
        j = i
    return ok


def star(cx, cy, r, c, canvas):
    pts = []
    for i in range(10):
        ang = -math.pi / 2 + i * math.pi / 5
        rad = r if i % 2 == 0 else r * 0.45
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    canvas.polygon(pts, c)


def write_spr(path, canvas):
    pal = bytearray(768)
    for i, (r, g, b) in PALETTE.items():
        pal[i * 3:i * 3 + 3] = bytes((r, g, b))
    data = bytearray()
    data += b"IDSP"
    data += struct.pack("<ii", 2, 2)               # version, type (vp_parallel)
    data += struct.pack("<i", 3)                    # texFormat: alphatest (index 255 transparent)
    data += struct.pack("<f", SIZE / 2.0 * 1.414)   # bounding radius
    data += struct.pack("<iii", SIZE, SIZE, 1)      # width, height, frames
    data += struct.pack("<f", 0.0)                  # beam length
    data += struct.pack("<i", 0)                    # sync type
    data += struct.pack("<h", 256) + bytes(pal)
    data += struct.pack("<iiiii", 0, -SIZE // 2, SIZE // 2, SIZE, SIZE)  # group, origin x/y, w, h
    for row in canvas.px:
        data += bytes(row)
    with open(path, "wb") as f:
        f.write(data)


def make_countdown(n):
    c = Canvas()
    s = str(n)
    c.text(s, 4 if len(s) == 1 else 3, YELLOW if n > 3 else RED)
    return c


def make_mutation(level):
    c = Canvas()
    level = min(level, 5)
    cols = [GREEN, GREEN, YELLOW, ORANGE, RED, RED][level]
    r = 9 if level <= 3 else 7
    gap = 2 * r + 2
    total = level * gap - 2
    x = (SIZE - total) // 2 + r
    for _ in range(level):
        star(x, SIZE // 2, r, cols, c)
        x += gap
    return c


def make_last_survivor():
    c = Canvas()
    c.polygon([(24, 4), (45, 42), (3, 42)], YELLOW)
    c.polygon([(24, 12), (38, 37), (10, 37)], BG)
    c.rect(22, 18, 25, 30, YELLOW)
    c.rect(22, 33, 25, 36, YELLOW)
    return c


def make_no_respawn():
    c = Canvas()
    c.circle(24, 20, 14, WHITE)
    c.rect(15, 28, 33, 40, WHITE)
    c.circle(18, 20, 4, BG)
    c.circle(30, 20, 4, BG)
    c.polygon([(24, 24), (21, 30), (27, 30)], BG)
    for x in (18, 22, 26, 30):
        c.rect(x, 34, x + 1, 40, BG)
    return c


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sprites")
    os.makedirs(out, exist_ok=True)

    for n in range(1, 11):
        write_spr(os.path.join(out, "bh_cd_%d.spr" % n), make_countdown(n))
    for level in range(1, 6):
        write_spr(os.path.join(out, "bh_mut_%d.spr" % level), make_mutation(level))
    write_spr(os.path.join(out, "bh_last.spr"), make_last_survivor())
    write_spr(os.path.join(out, "bh_norespawn.spr"), make_no_respawn())
    print("Done:", len(os.listdir(out)), "sprites in", os.path.abspath(out))


if __name__ == "__main__":
    main()
