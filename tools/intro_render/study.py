"""The secret entrance: a dim study lined with bookcases. The middle bookcase is a hidden
door; behind it, a stairwell goes down toward warm light.

  python3 study.py <closed|open|stairs> <size> <spp> <out.npz>
Writes <out>.json with where things sit in the image (for the app).
"""
import json
import math
import sys

import numpy as np

import render as R
from render import (BOOK, BRASS, EMIT, FLOOR, PANEL, RUG, SHELF, STAIR, SWALL, TRIM, CEIL, Scene, F)

Z = -3.6            # back wall face
CASE_D = 0.34       # how far the bookcases stand out from the wall
FRONT = Z + CASE_D  # front face of the bookcases
H = 2.75            # ceiling
W = 1.75            # room half-width
SECRET = (-0.5, 0.5)
CASE_TOP = 2.36
SHELVES = [0.10, 0.475, 0.85, 1.225, 1.60, 1.975]   # top of each shelf board

PALETTE = [(0.20, 0.03, 0.03), (0.05, 0.11, 0.06), (0.04, 0.06, 0.14), (0.16, 0.09, 0.04), (0.03, 0.03, 0.03),
           (0.30, 0.22, 0.12), (0.12, 0.02, 0.06), (0.07, 0.10, 0.10), (0.22, 0.12, 0.05), (0.26, 0.24, 0.20)]
LEVER_BOOK = None   # (x0, x1, y0, y1) of the book that tilts out


def lever_only_here(lever, k, x, x0, x1):
    # keep the lever's shelf free of stacks near where it goes
    return lever and k == 3


def bookcase(s, x0, x1, tag, rng, lever=False):
    global LEVER_BOOK
    t = 0.025
    g = f"case{tag}"
    s.box(x0, x0 + t, 0, CASE_TOP, Z, FRONT, SHELF, group=g)            # sides
    s.box(x1 - t, x1, 0, CASE_TOP, Z, FRONT, SHELF, group=g)
    s.box(x0, x1, CASE_TOP - 0.05, CASE_TOP, Z, FRONT + 0.015, SHELF, group=g)  # top + cornice
    s.box(x0 - 0.01, x1 + 0.01, CASE_TOP, CASE_TOP + 0.04, Z, FRONT + 0.03, SHELF, group=g)
    s.box(x0, x1, 0, 0.10, Z, FRONT, SHELF, group=g)                     # plinth
    s.box(x0, x1, 0, CASE_TOP, Z, Z + 0.012, SHELF, group=g)             # back
    for k, top in enumerate(SHELVES):
        s.box(x0 + t, x1 - t, top - 0.022, top, Z, FRONT - 0.005, SHELF, group=g)
        nxt = SHELVES[k + 1] - 0.022 if k + 1 < len(SHELVES) else CASE_TOP - 0.05
        clear = nxt - top
        gb = f"{g}s{k}"
        x = x0 + t + rng.uniform(0.0, 0.03)
        end = x1 - t - 0.01
        while x < end - 0.02:
            if rng.random() < 0.06:                      # a gap
                x += rng.uniform(0.04, 0.12)
                continue
            bw = rng.uniform(0.018, 0.05)
            if x + bw > end:
                break
            bh = min(clear - 0.02, rng.uniform(0.18, 0.33))
            bd = rng.uniform(0.14, 0.24)
            front = FRONT - rng.uniform(0.015, 0.05)
            col = PALETTE[rng.integers(len(PALETTE))]
            k_ = rng.uniform(0.6, 1.1)
            col = tuple((0.55 * c + 0.45 * 0.07) * k_ for c in col)   # aged and faded
            is_lever = lever and k == 3 and LEVER_BOOK is None and x > (x0 + x1) / 2 + 0.05
            if is_lever:                                 # the lever: a thick old leather-bound volume, standing a little proud
                bw = 0.07
                bh = min(clear - 0.012, 0.33)
                front = FRONT + 0.010
                bd = 0.24
                L = R.LEATHER
                s.box(x, x + bw, top, top + bh, front - bd, front - 0.008, L, group=gb)                 # boards + text block
                s.box(x + 0.003, x + bw - 0.003, top + 0.002, top + bh - 0.002, front - bd, front - 0.004, L, group=gb)
                s.box(x + 0.010, x + bw - 0.010, top + 0.004, top + bh - 0.004, front - bd, front, L, group=gb)  # rounded spine
                ribs = [top + bh * f for f in (0.20, 0.40, 0.60, 0.80)]
                for yr in ribs:                          # raised bands, each edged with a gilt fillet
                    s.box(x + 0.006, x + bw - 0.006, yr - 0.005, yr + 0.005, front - bd, front + 0.004, L, group=gb)
                    for yf in (yr - 0.009, yr + 0.0072):
                        s.box(x + 0.011, x + bw - 0.011, yf, yf + 0.0018, front - 0.01, front + 0.0008, BRASS, group=gb)
                label = (ribs[2] + 0.012, ribs[3] - 0.012)  # dark title label between the top bands
                for yf in (label[0] + 0.004, label[1] - 0.006):
                    s.box(x + 0.013, x + bw - 0.013, yf, yf + 0.0015, front - 0.01, front + 0.0006, BRASS, group=gb)
                for i in range(4):                       # a few tooled letters, barely legible
                    lx = x + 0.019 + i * 0.0085
                    s.box(lx, lx + 0.0045, (label[0] + label[1]) / 2 - 0.004, (label[0] + label[1]) / 2 + 0.004,
                          front - 0.01, front + 0.0005, BRASS, group=gb)
                s.lever = (x, x + bw, top, top + bh, front, ribs, label)
                LEVER_BOOK = (x, x + bw, top, top + bh, front + 0.004)
                x += bw + 0.004
                continue
            if not lever_only_here(lever, k, x, x0, x1) and rng.random() < 0.06 and x + 0.2 < end:
                # a short stack of books lying flat, spines out
                sw_ = rng.uniform(0.15, 0.21)
                y = top
                for j in range(int(rng.integers(2, 5))):
                    th = rng.uniform(0.025, 0.045)
                    inset = rng.uniform(0.0, 0.02)
                    c2 = PALETTE[rng.integers(len(PALETTE))]
                    c2 = tuple((0.55 * c + 0.45 * 0.07) * rng.uniform(0.6, 1.1) for c in c2)
                    f2 = FRONT - rng.uniform(0.01, 0.04)
                    s.box(x + inset, x + sw_ - inset * 0.5, y, y + th, f2 - rng.uniform(0.15, 0.22), f2, BOOK, col=c2, group=gb)
                    y += th
                x += sw_ + rng.uniform(0.005, 0.02)
                continue
            # boards + text block, with the rounded spine standing slightly proud of the boards
            s.box(x, x + bw, top, top + bh, front - bd, front - 0.003, BOOK, col=col, group=gb)
            if bw > 0.026:
                s.box(x + 0.004, x + bw - 0.004, top + 0.002, top + bh - 0.002, front - bd, front, BOOK, col=col, group=gb)
            x += bw + rng.uniform(0.0, 0.004)


def build(secret=True, lights=("picture", "sconceL", "sconceR", "sconce", "below")):
    global LEVER_BOOK
    LEVER_BOOK = None
    s = Scene()
    s.use_labels = True
    rng = np.random.default_rng(42)
    T = 0.15
    # room shell
    s.box(-W - T, -W, -0.1, H + 0.1, Z - T, 1.5, PANEL, group="room")
    s.box(W, W + T, -0.1, H + 0.1, Z - T, 1.5, PANEL, group="room")
    s.box(-W, W, -T, 0, Z, 1.5, FLOOR, group="room")
    s.box(-W, W, H, H + T, Z - T, 1.5, CEIL, group="room")
    s.box(-W, W, -T, H + T, 1.4, 1.5, PANEL, group="room")
    s.box(-W, SECRET[0], 0, H, Z - T, Z, PANEL, group="room")
    s.box(SECRET[1], W, 0, H, Z - T, Z, PANEL, group="room")
    s.box(SECRET[0], SECRET[1], 2.3, H, Z - T, Z, PANEL, group="room")
    s.box(-W, W, H - 0.12, H, Z, Z + 0.06, TRIM, group="room")          # crown
    s.box(-1.15, 1.15, 0.0, 0.008, -2.6, -0.6, RUG, group="room")         # rug
    # bookcases: left, the secret one, right
    bookcase(s, -1.62, -0.52, "L", rng)
    if secret:
        bookcase(s, SECRET[0], SECRET[1], "C", rng, lever=True)
    bookcase(s, 0.52, 1.62, "R", rng)
    # brass picture light over the middle case, sconces on the side walls
    s.box(-0.32, 0.32, 2.47, 2.50, FRONT - 0.02, FRONT + 0.14, BRASS, group="fix")
    s.box(-0.02, 0.02, 2.42, 2.47, FRONT - 0.02, FRONT + 0.02, BRASS, group="fix")
    for sx in (-1, 1):
        s.box(sx * W, sx * (W - 0.02), 1.72, 1.92, -2.05, -1.95, BRASS, group="fix")
    # a side table with a lamp, left foreground
    s.box(-1.55, -1.05, 0.0, 0.70, -1.9, -1.4, SHELF, group="table")
    for i, (h0, h1, c) in enumerate([(0.70, 0.75, (0.12, 0.03, 0.03)), (0.75, 0.79, (0.04, 0.06, 0.05)), (0.79, 0.84, (0.10, 0.08, 0.05))]):
        s.box(-1.46 + i * 0.01, -1.18 - i * 0.015, h0, h1, -1.80 + i * 0.01, -1.55, BOOK, col=c, group="table")
    # ---- stairwell behind the secret case ----
    SW = 0.5
    s.box(-SW - T, -SW, -3.4, 2.6, -9.6, Z - T, SWALL, group="stair")
    s.box(SW, SW + T, -3.4, 2.6, -9.6, Z - T, SWALL, group="stair")
    s.box(-SW, SW, 2.3, 2.6, -9.6, Z - T, SWALL, group="stair")
    s.box(-SW, SW, -3.4, 2.6, -9.7, -9.6, SWALL, group="stair")
    z0 = Z - T - 0.45
    s.box(-SW, SW, -0.2, 0, z0, Z - T, STAIR, group="stair")
    s.box(-SW, SW, -0.2, 0, Z - T, Z, STAIR, group="stair")
    run, rise = 0.27, 0.18
    for i in range(16):
        za, zb = z0 - run * i, z0 - run * (i + 1)
        s.box(-SW, SW, -3.4, -rise * (i + 1), zb, za, STAIR, group="steps")
    s.box(-SW, SW, -3.4, -rise * 16, -9.6, z0 - run * 16, STAIR, group="steps")
    for k in range(60):
        za = z0 + 0.25 - (16 * run + 0.25) * k / 60
        zb = z0 + 0.25 - (16 * run + 0.25) * (k + 1) / 60
        y = 0.9 - rise / run * max(0.0, (z0 - za)) if za < z0 else 0.9
        s.box(SW - 0.07, SW - 0.02, y - 0.05, y, zb, za, TRIM, group="rail")
    s.box(-SW, -SW + 0.03, 1.72, 1.9, z0 - 0.06, z0 + 0.06, TRIM, group="stair")
    L = {
        "picture": dict(pos=(0.0, 2.44, FRONT + 0.10), radius=0.035, color=(1.0, 0.72, 0.42), power=1.1),
        "sconceL": dict(pos=(-W + 0.09, 1.86, -2.0), radius=0.035, color=(1.0, 0.66, 0.36), power=0.75),
        "sconceR": dict(pos=(W - 0.09, 1.86, -2.0), radius=0.035, color=(1.0, 0.66, 0.36), power=0.75),
        "lamp": dict(pos=(-1.30, 1.12, -1.65), radius=0.07, color=(1.0, 0.62, 0.32), power=0.9),
        "sconce": dict(pos=(-SW + 0.07, 1.85, z0), radius=0.045, color=(1.0, 0.62, 0.30), power=1.6),
        "below": dict(pos=(0.15, -1.9, -9.0), radius=0.12, color=(1.0, 0.52, 0.20), power=22.0),
    }
    for k in lights:
        lt = L[k]
        s.lights.append(lt)
        s.sphere(lt["pos"], lt["radius"], EMIT, np.array(lt["color"], F) * F(lt["power"] * 6.0))
    s.haze_sigma = 0.006
    s.finish()
    return s


CAM_ROOM = dict(pos=(0.0, 1.58, 0.9), vfov=58.0, pitch=math.radians(-3.0))
CAM_STAIRS = dict(pos=(0.0, 1.55, Z - 0.35), vfov=72.0, pitch=math.radians(-30.0))
PLATES = {
    "closed": dict(secret=True, lights=("picture", "sconceL", "sconceR"), cam=CAM_ROOM),
    "open": dict(secret=False, lights=("picture", "sconceL", "sconceR", "sconce", "below"), cam=CAM_ROOM),
    "stairs": dict(secret=False, lights=("picture", "sconce", "below"), cam=CAM_STAIRS),
}

if __name__ == "__main__":
    name, size, spp, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    P = PLATES[name]
    sc = build(P["secret"], P["lights"])
    img, A, N, D = R.render(sc, P["cam"], size, size, spp, haze_on=True)
    np.savez_compressed(out, img=img, alb=A, nrm=N, dep=D)
    build(True)  # sets LEVER_BOOK
    lb = LEVER_BOOK
    pts = R.project(CAM_ROOM, [
        (SECRET[0], 2.3, Z), (SECRET[1], 0.0, Z),                  # opening in the wall
        (SECRET[0], CASE_TOP + 0.04, FRONT), (SECRET[1], 0.0, FRONT),  # front of the secret case
        (0.0, -0.6, -7.0),                                          # down in the stairwell
        (lb[0], lb[3], lb[4]), (lb[1], lb[2], lb[4]),               # the lever book
    ], size, size)
    json.dump({"size": size, "pts": [[float(a), float(b)] for a, b in pts],
               "focal": float(0.5 * size / math.tan(math.radians(CAM_ROOM["vfov"]) / 2))},
              open(out.replace(".npz", ".json"), "w"))
    print("rendered", name, "boxes", len(sc.bmat))
