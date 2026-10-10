"""Renders the opening's background images ("plates") with physically based light.

A tiny numpy path tracer: boxes + spheres, area-sampled lights with soft shadows,
one bounce of indirect light, a glossy floor, light haze (god rays), filmic tone mapping
and bloom. Run:  python3 render.py <plate> <size> <spp> [out.png]
Plates: closed_bulb, closed_leak, open, stairs  (see PLATES below)
"""
import json
import math
import sys
import numpy as np

F = np.float32
rng = np.random.default_rng(int(__import__("os").environ.get("SEED", "1")))

# ------------------------------------------------------------------ noise
def _hash(ix, iy, iz):
    h = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    return ((h ^ (h >> 16)) & 0xFFFF).astype(F) / F(65535.0)

def vnoise(p):
    """Smooth value noise, p: (N,3)"""
    pi = np.floor(p).astype(np.int64)
    f = (p - pi).astype(F)
    u = f * f * (3 - 2 * f)
    out = np.zeros(len(p), F)
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (u[:, 0] if dx else 1 - u[:, 0]) * (u[:, 1] if dy else 1 - u[:, 1]) * (u[:, 2] if dz else 1 - u[:, 2])
                out += w * _hash(pi[:, 0] + dx, pi[:, 1] + dy, pi[:, 2] + dz)
    return out

def fbm(p, oct=4):
    s, a, tot = np.zeros(len(p), F), F(0.5), F(0)
    for i in range(oct):
        s += a * vnoise(p * (2 ** i) + i * 17.3)
        tot += a
        a *= F(0.5)
    return s / tot

# ------------------------------------------------------------------ scene
# materials
WALL, WAINS, TRIM, FLOOR, CEIL, DOOR, BRASS, STAIR, SWALL, EMIT, CORD, DARK, PANEL, RUG, BOOK, SHELF, LEATHER = range(17)
GLOSS = {FLOOR: (0.18, 40.0), WAINS: (0.08, 30.0), DOOR: (0.06, 25.0), TRIM: (0.08, 30.0), BRASS: (0.9, 120.0), STAIR: (0.08, 20.0), LEATHER: (0.05, 14.0)}

class Scene:
    def __init__(self):
        self.bmin, self.bmax, self.bmat = [], [], []
        self.sph = []  # (center, radius, mat, emission or None)
        self.lights = []  # dict(pos, radius, color, power)

    def box(self, x0, x1, y0, y1, z0, z1, mat, col=None, group=None):
        self.bmin.append((min(x0, x1), min(y0, y1), min(z0, z1)))
        self.bmax.append((max(x0, x1), max(y0, y1), max(z0, z1)))
        self.bmat.append(mat)
        if not hasattr(self, "bcol"):
            self.bcol, self.bgroup = [], []
        self.bcol.append(col if col is not None else (0, 0, 0))
        self.bgroup.append(group if group is not None else "_")

    def sphere(self, c, r, mat, emit=None):
        self.sph.append((np.array(c, F), F(r), mat, emit))

    def finish(self):
        self.bmin = np.array(self.bmin, F)
        self.bmax = np.array(self.bmax, F)
        self.bmat = np.array(self.bmat, np.int32)
        self.bcol = np.array(self.bcol, F)
        self.bgroup = np.array(self.bgroup)


def build(door=True, lights=("bulb", "sconce", "below")):
    s = Scene()
    W, H, Z = 0.85, 2.7, -4.2          # hallway half-width, height, back wall face
    T = 0.15                           # wall thickness
    DX, DH = 0.45, 2.05                # doorway half-width, height
    # hallway shell (boxes with thickness so normals face inward)
    s.box(-W - T, -W, -0.1, H + 0.1, Z - T, 1.0, WALL)       # left wall
    s.box(W, W + T, -0.1, H + 0.1, Z - T, 1.0, WALL)         # right wall
    s.box(-W, W, -T, 0, Z, 1.0, FLOOR)                       # floor
    s.box(-W, W, H, H + T, Z - T, 1.0, CEIL)                 # ceiling
    s.box(-W, -DX, 0, H, Z - T, Z, WALL)                     # back wall, left of door
    s.box(DX, W, 0, H, Z - T, Z, WALL)                       # back wall, right of door
    s.box(-DX, DX, DH, H, Z - T, Z, WALL)                    # back wall, over door
    s.box(-W, W, -T, 0, 0.9, 1.0, WALL)                      # behind camera (closes the box)
    s.box(-W, W, 0, H, 0.9, 1.0, WALL)
    # wainscot, chair rail and baseboard on the side walls and back wall
    for sgn in (-1, 1):
        s.box(sgn * W, sgn * (W - 0.012), 0, 0.95, Z, 0.9, WAINS)
        s.box(sgn * W, sgn * (W - 0.028), 0.95, 1.0, Z, 0.9, TRIM)
        s.box(sgn * W, sgn * (W - 0.022), 0, 0.15, Z, 0.9, TRIM)
    for x0, x1 in ((-W, -0.56), (0.56, W)):
        s.box(x0, x1, 0, 0.95, Z, Z + 0.012, WAINS)
        s.box(x0, x1, 0.95, 1.0, Z, Z + 0.028, TRIM)
        s.box(x0, x1, 0, 0.15, Z, Z + 0.022, TRIM)
    # door casing
    s.box(-0.56, -DX, 0, DH + 0.12, Z, Z + 0.03, TRIM)
    s.box(DX, 0.56, 0, DH + 0.12, Z, Z + 0.03, TRIM)
    s.box(-0.58, 0.58, DH, DH + 0.15, Z, Z + 0.035, TRIM)
    # the door: stiles and rails proud, panels recessed, a brass knob
    if door:
        dz0, dz1 = Z - 0.10, Z - 0.055       # set back in the jamb
        x0, x1, y0, y1 = -DX + 0.008, DX - 0.008, 0.016, DH - 0.006
        s.box(x0, x1, y0, y1, dz0, dz1 - 0.022, DOOR)              # slab (panels, recessed)
        sw = 0.13
        s.box(x0, x0 + sw, y0, y1, dz0, dz1, DOOR)                 # stiles
        s.box(x1 - sw, x1, y0, y1, dz0, dz1, DOOR)
        s.box(-0.04, 0.04, y0, y1, dz0, dz1, DOOR)                 # middle mullion
        for ya, yb in ((y0, y0 + 0.22), (0.93, 1.07), (y1 - 0.14, y1)):
            s.box(x0, x1, ya, yb, dz0, dz1, DOOR)                  # rails
        s.sphere((x1 - 0.075, 1.0, dz1 + 0.055), 0.03, BRASS)
        s.box(x1 - 0.095, x1 - 0.055, 0.93, 1.07, dz1, dz1 + 0.006, BRASS)   # backplate
        s.box(x1 - 0.08, x1 - 0.07, 1.0, 1.0001, dz1 + 0.006, dz1 + 0.055, BRASS)  # spindle (thin)
    # ---- the stairwell beyond ----
    SW = 0.5
    s.box(-SW - T, -SW, -3.2, 2.6, -10.2, Z - T, SWALL)
    s.box(SW, SW + T, -3.2, 2.6, -10.2, Z - T, SWALL)
    s.box(-SW, SW, 2.5, 2.6, -10.2, Z - T, SWALL)            # ceiling
    s.box(-SW, SW, -3.2, 2.6, -10.3, -10.2, SWALL)           # far wall
    s.box(-SW, SW, -0.2, 0, -4.6, Z - T, STAIR)              # short top landing
    run, rise = 0.27, 0.18
    z0 = -4.6
    for i in range(16):
        za, zb = z0 - run * i, z0 - run * (i + 1)
        top = -rise * (i + 1)
        s.box(-SW, SW, -3.4, top, zb, za, STAIR)
    s.box(-SW, SW, -3.4, -rise * 16, -10.2, z0 - run * 16, STAIR)          # bottom landing
    # handrail on the right wall, following the slope (fine segments read as one rail)
    segs = 60
    for k in range(segs):
        za = z0 + 0.25 - (16 * run + 0.25) * k / segs
        zb = z0 + 0.25 - (16 * run + 0.25) * (k + 1) / segs
        y = 0.9 - rise / run * max(0.0, (z0 - za)) if za < z0 else 0.9
        s.box(SW - 0.07, SW - 0.02, y - 0.05, y, zb, za, TRIM)
    # bulb on a cord
    bulb = (0.0, 2.24, -2.75)
    s.box(-0.004, 0.004, bulb[1] + 0.03, H, bulb[2] - 0.004, bulb[2] + 0.004, CORD)
    s.box(-0.012, 0.012, bulb[1] + 0.025, bulb[1] + 0.06, bulb[2] - 0.012, bulb[2] + 0.012, CORD)
    # sconce on the stairwell wall just inside the door; a lamp far below
    sconce = (-SW + 0.07, 1.85, -4.75)
    below = (0.15, -1.9, -9.6)
    s.box(-SW, -SW + 0.03, 1.72, 1.9, -4.81, -4.69, TRIM)
    L = {
        "bulb": dict(pos=bulb, radius=0.03, color=(1.0, 0.70, 0.40), power=2.2),
        "sconce": dict(pos=sconce, radius=0.045, color=(1.0, 0.62, 0.30), power=1.6),
        "below": dict(pos=below, radius=0.12, color=(1.0, 0.52, 0.20), power=22.0),
    }
    for k in lights:
        lt = L[k]
        s.lights.append(lt)
        s.sphere(lt["pos"], lt["radius"], EMIT, np.array(lt["color"], F) * F(lt["power"] * 6.0))
    s.finish()
    return s

# ------------------------------------------------------------------ intersection
def _slab(bmn, bmx, ox, oy, oz, ix, iy, iz):
    tx0, tx1 = (bmn[0] - ox) * ix, (bmx[0] - ox) * ix
    ty0, ty1 = (bmn[1] - oy) * iy, (bmx[1] - oy) * iy
    tz0, tz1 = (bmn[2] - oz) * iz, (bmx[2] - oz) * iz
    tn = np.maximum(np.maximum(np.minimum(tx0, tx1), np.minimum(ty0, ty1)), np.minimum(tz0, tz1))
    tf = np.minimum(np.minimum(np.maximum(tx0, tx1), np.maximum(ty0, ty1)), np.maximum(tz0, tz1))
    return tn, tf

def _groups(s):
    if getattr(s, "_grp", None) is None and getattr(s, "use_labels", False):
        sets = [np.nonzero(s.bgroup == g)[0] for g in dict.fromkeys(s.bgroup.tolist())]
        s._grp = [(s.bmin[g].min(0), s.bmax[g].max(0), g) for g in sets if len(g)]
    if getattr(s, "_grp", None) is None:
        # split boxes into the hallway part and the stairwell part (z beyond the back wall)
        cz = (s.bmin[:, 2] + s.bmax[:, 2]) / 2
        sets = [np.nonzero(cz >= -4.36)[0], np.nonzero(cz < -4.36)[0]]
        s._grp = [(s.bmin[g].min(0), s.bmax[g].max(0), g) for g in sets if len(g)]
    return s._grp

def hit_boxes(s, ro, rd, tmax):
    n = len(ro)
    best = np.full(n, np.inf, F)
    bidx = np.full(n, -1, np.int32)
    rdx = np.where(np.abs(rd) < 1e-8, F(1e-8), rd)
    inv = (F(1) / rdx).astype(F)
    tmaxv = np.broadcast_to(np.asarray(tmax, F), (n,))
    for gmn, gmx, members in _groups(s):
        tn, tf = _slab(gmn, gmx, ro[:, 0], ro[:, 1], ro[:, 2], inv[:, 0], inv[:, 1], inv[:, 2])
        sub = np.nonzero((tn <= tf) & (tf > 1e-4) & (tn < best) & (tn < tmaxv))[0]
        if not len(sub):
            continue
        ox, oy, oz = ro[sub, 0], ro[sub, 1], ro[sub, 2]
        ix, iy, iz = inv[sub, 0], inv[sub, 1], inv[sub, 2]
        b = best[sub]
        bi = bidx[sub]
        tm = tmaxv[sub]
        for i in members:
            tn, tf = _slab(s.bmin[i], s.bmax[i], ox, oy, oz, ix, iy, iz)
            tt = np.where(tn > 1e-4, tn, tf)
            ok = (tn <= tf) & (tf > 1e-4) & (tt < b) & (tt < tm)
            b = np.where(ok, tt, b)
            bi = np.where(ok, i, bi)
        best[sub] = b
        bidx[sub] = bi
    # normal from the face of the hit box nearest the hit point
    bnrm = np.zeros((n, 3), F)
    h = np.nonzero(bidx >= 0)[0]
    if len(h):
        p = ro[h] + rd[h] * best[h, None]
        mn, mx = s.bmin[bidx[h]], s.bmax[bidx[h]]
        d = np.concatenate([np.abs(p - mn), np.abs(p - mx)], 1)
        k = d.argmin(1)
        nn = np.zeros((len(h), 3), F)
        ax = k % 3
        nn[np.arange(len(h)), ax] = np.where(k < 3, -1.0, 1.0)
        bnrm[h] = nn
    return best, bidx, bnrm

def hit_spheres(s, ro, rd, best, skip_emit=False):
    n = len(ro)
    sidx = np.full(n, -1, np.int32)
    for j, (c, r, mat, emit) in enumerate(s.sph):
        if skip_emit and emit is not None:
            continue
        oc = ro - c
        b = (oc * rd).sum(1)
        cc = (oc * oc).sum(1) - r * r
        disc = b * b - cc
        ok = disc > 0
        sq = np.sqrt(np.maximum(disc, 0))
        t = -b - sq
        ok &= (t > 1e-4) & (t < best)
        best = np.where(ok, t, best)
        sidx = np.where(ok, j, sidx)
    return best, sidx

def trace(s, ro, rd, tmax=np.inf):
    t, bi, nrm = hit_boxes(s, ro, rd, tmax)
    t2, si = hit_spheres(s, ro, rd, t.copy())
    use_s = si >= 0
    p = ro + rd * np.where(np.isfinite(t2), t2, 0)[:, None]
    mat = np.where(bi >= 0, s.bmat[np.maximum(bi, 0)], -1)
    for j, (c, r, m, emit) in enumerate(s.sph):
        sel = si == j
        if sel.any():
            nrm[sel] = (p[sel] - c) / r
            mat[sel] = m
    s._last_bi = np.where(si >= 0, -1, bi)
    return t2, mat, nrm, p, si

def occluded(s, ro, rd, dist):
    t, bi, _ = hit_boxes(s, ro, rd, dist)
    t2, si = hit_spheres(s, ro, rd, t.copy(), skip_emit=True)
    return t2 < dist - 1e-3

# ------------------------------------------------------------------ materials
def albedo(mat, p, n, bi=None, s=None):
    N = len(p)
    a = np.zeros((N, 3), F)
    if s is not None and bi is not None:
        sel = (mat == BOOK) & (bi >= 0)
        if sel.any():
            b = bi[sel]
            col = s.bcol[b]
            q = p[sel]
            rel = (q[:, 1] - s.bmin[b, 1]) / np.maximum(s.bmax[b, 1] - s.bmin[b, 1], 1e-3)
            spine = n[sel, 2] > 0.5
            band = spine & (((rel > 0.82) & (rel < 0.86)) | ((rel > 0.12) & (rel < 0.15)))
            label = spine & (rel > 0.55) & (rel < 0.68) & (_hash(b, b, b * 3) > 0.5)
            wear = 0.8 + 0.25 * fbm(q * 30.0, 2)
            c = col * wear[:, None]
            c = np.where(band[:, None], np.array((0.45, 0.33, 0.12), F), c)
            c = np.where(label[:, None], c * 0.4 + np.array((0.25, 0.2, 0.12), F), c)
            a[sel] = c
    def put(m, col):
        sel = mat == m
        if sel.any():
            a[sel] = col(p[sel], n[sel]) if callable(col) else col
    def plaster(base, scale=1.0):
        def f(q, nn):
            v = fbm(q * 3.0 * scale, 4)
            fine = vnoise(q * 40.0)
            grime = np.clip(1.2 - q[:, 1:2] * 0.6, 0.7, 1.0)  # darker low on the wall
            return np.array(base, F) * (0.78 + 0.32 * v[:, None] + 0.06 * fine[:, None]) * grime
        return f
    def wood(base, along=2, ring=26.0, var=0.45):
        def f(q, nn):
            w = fbm(q * np.array([3, 3, 3], F), 3)
            g = q[:, (along + 1) % 3] * ring + w * 6.0 + q[:, (along + 2) % 3] * 3.0
            grain = 0.5 + 0.5 * np.sin(g)
            streak = fbm(q * np.array([1.0, 1.0, 1.0], F) * 9.0 + 3.1, 3)
            k = (1 - var) + var * (0.55 * grain + 0.45 * streak)
            return np.array(base, F) * k[:, None]
        return f
    def panel(q, nn):
        # dark wood wall panelling: vertical boards with grooves, rails top and bottom
        base = wood((0.075, 0.042, 0.022), along=1, ring=28.0, var=0.5)(q, nn)
        u = np.where(np.abs(nn[:, 0]) > 0.5, q[:, 2], q[:, 0])
        groove = np.abs(((u + 10.0) / 0.42) % 1.0 - 0.5) > 0.485
        rail = (np.abs(q[:, 1] - 0.95) < 0.03) | (q[:, 1] < 0.12)
        return base * np.where(groove, 0.35, np.where(rail, 0.75, 1.0))[:, None]
    put(PANEL, panel)
    def rug(q, nn):
        # an old oriental rug: border bands and a repeating medallion pattern
        x, z = q[:, 0], q[:, 2] + 1.6
        bx = np.minimum(np.abs(x) - 1.05, 0) * -1
        bz = np.minimum(np.abs(z) - 1.0, 0) * -1
        edge = np.minimum(bx, bz)
        border = (edge < 0.16) & (edge > 0.04)
        mot = 0.5 + 0.25 * np.cos(x * 23) * np.cos(z * 23) + 0.25 * np.cos((x + z) * 11)
        base = np.array((0.16, 0.035, 0.03), F)
        navy = np.array((0.04, 0.05, 0.10), F)
        cream = np.array((0.45, 0.38, 0.26), F)
        c = np.where(border[:, None], navy, base * (0.75 + 0.5 * mot)[:, None] + cream * 0.12 * (mot > 0.8)[:, None])
        c = np.where(((edge < 0.025))[:, None], cream * 0.5, c)
        return c * (0.7 + 0.4 * fbm(q * 25.0, 2))[:, None]
    put(RUG, rug)
    put(SHELF, wood((0.10, 0.055, 0.03), along=0, ring=24.0))
    put(WALL, plaster((0.24, 0.22, 0.19)))
    put(SWALL, plaster((0.30, 0.26, 0.21), 1.3))
    put(CEIL, plaster((0.16, 0.155, 0.15)))
    put(WAINS, lambda q, nn: np.array((0.03, 0.04, 0.05), F) * (0.85 + 0.25 * fbm(q * 6, 3))[:, None])
    put(TRIM, wood((0.07, 0.04, 0.025), along=1))
    put(DOOR, wood((0.075, 0.038, 0.018), along=1, ring=40.0, var=0.6))
    put(BRASS, (0.75, 0.55, 0.22))
    put(CORD, (0.03, 0.03, 0.03))
    put(DARK, (0.02, 0.02, 0.02))
    def floor(q, nn):
        plank = np.floor((q[:, 0] + 2.0) / 0.13)
        off = _hash(plank.astype(np.int64), np.zeros(len(q), np.int64), np.ones(len(q), np.int64))
        joint = np.floor((q[:, 2] + off * 3.0) / 1.6)
        tone = 0.75 + 0.5 * _hash(plank.astype(np.int64), joint.astype(np.int64), np.full(len(q), 7, np.int64))
        w = wood((0.11, 0.065, 0.035), along=2, ring=30.0, var=0.5)(q + off[:, None] * 5, nn)
        seam = np.minimum(np.abs(((q[:, 0] + 2.0) / 0.13) % 1.0 - 0.0), np.abs(((q[:, 0] + 2.0) / 0.13) % 1.0 - 1.0)) * 0.13
        seamz = np.abs(((q[:, 2] + off * 3.0) / 1.6) % 1.0) * 1.6
        dark = np.where((seam < 0.003) | (seamz < 0.004), 0.25, 1.0)
        return w * (tone * dark)[:, None]
    put(FLOOR, floor)
    def stair(q, nn):
        w = wood((0.16, 0.10, 0.06), along=0, ring=22.0)(q, nn)
        worn = 1.0 + 0.35 * np.exp(-(q[:, 0] / 0.22) ** 2) * (nn[:, 1] > 0.5)  # lighter where people walk
        return w * worn[:, None]
    put(STAIR, stair)
    lv = getattr(s, "lever", None) if s is not None else None
    if lv is not None:
        x0, x1, y0, y1, front, ribs, label = lv
        def leather(q, nn):
            # old oxblood calf: fine pebbled grain, mottled with age, rubbed brown at the edges
            # and at the head of the spine, where a finger pulls it
            grain = fbm(q * 220.0, 2)
            mott = fbm(q * 14.0 + 5.0, 3)
            c = np.array((0.17, 0.03, 0.024), F) * (0.72 + 0.35 * mott + 0.18 * grain)[:, None]
            cx = (x0 + x1) / 2
            edge = np.clip((np.abs(q[:, 0] - cx) / ((x1 - x0) / 2) - 0.6) / 0.4, 0, 1)
            head = np.clip((q[:, 1] - (y1 - 0.03)) / 0.03, 0, 1)
            rub = np.clip(0.55 * edge ** 2 + 0.8 * head + 0.25 * (fbm(q * 40.0, 2) - 0.5), 0, 1)
            c = c * (1 - rub[:, None]) + np.array((0.17, 0.085, 0.045), F) * rub[:, None]
            spine = nn[:, 2] > 0.5
            lab = spine & (q[:, 1] > label[0]) & (q[:, 1] < label[1]) & (np.abs(q[:, 0] - cx) < (x1 - x0) / 2 - 0.009)
            c = np.where(lab[:, None], np.array((0.045, 0.03, 0.022), F) * (0.8 + 0.4 * grain[:, None]), c)
            return c
        put(LEATHER, leather)
    return a

# ------------------------------------------------------------------ shading
def sample_sphere_pt(c, r, n):
    v = rng.normal(size=(n, 3)).astype(F)
    v /= np.linalg.norm(v, axis=1, keepdims=True)
    return c + v * r

def direct(s, p, n, mat, view, a, with_spec=True):
    out = np.zeros_like(p)
    for lt in s.lights:
        lp = sample_sphere_pt(np.array(lt["pos"], F), F(lt["radius"]), len(p))
        d = lp - p
        dist = np.linalg.norm(d, axis=1)
        l = d / dist[:, None]
        cos = (n * l).sum(1)
        ok = cos > 0
        if not ok.any():
            continue
        vis = np.zeros(len(p), bool)
        idx = np.nonzero(ok)[0]
        vis[idx] = ~occluded(s, p[idx] + n[idx] * 2e-3, l[idx], dist[idx])
        E = np.array(lt["color"], F) * F(lt["power"]) / (dist * dist + 4 * lt["radius"] ** 2)[:, None]
        diff = a / F(math.pi) * (cos * vis)[:, None] * E
        out += diff
        if with_spec:
            h = l - view
            h /= np.linalg.norm(h, axis=1, keepdims=True) + 1e-8
            for m, (ks, sh) in GLOSS.items():
                sel = (mat == m) & vis
                if sel.any():
                    nh = np.clip((n[sel] * h[sel]).sum(1), 0, 1)
                    spec = ks * (sh + 8) / (8 * math.pi) * nh ** sh * cos[sel]
                    tint = a[sel] / np.maximum(a[sel].max(1, keepdims=True), 1e-3) if m == BRASS else 1.0
                    out[sel] += spec[:, None] * E[sel] * tint
    return out

def cosine_dir(n):
    N = len(n)
    u1, u2 = rng.random(N).astype(F), rng.random(N).astype(F)
    r = np.sqrt(u1)
    th = 2 * math.pi * u2
    x, y, z = r * np.cos(th), r * np.sin(th), np.sqrt(1 - u1)
    t = np.where(np.abs(n[:, :1]) > 0.9, np.array([[0, 1, 0]], F), np.array([[1, 0, 0]], F))
    b1 = np.cross(n, t)
    b1 /= np.linalg.norm(b1, axis=1, keepdims=True)
    b2 = np.cross(n, b1)
    return b1 * x[:, None] + b2 * y[:, None] + n * z[:, None]

def haze(s, ro, rd, tmax, steps=4, sigma=0.022):
    sigma = getattr(s, 'haze_sigma', sigma)
    out = np.zeros_like(ro)
    tm = np.minimum(tmax, 12.0)
    for k in range(steps):
        tt = (k + rng.random(len(ro)).astype(F)) / steps * tm
        q = ro + rd * tt[:, None]
        for lt in s.lights:
            lp = sample_sphere_pt(np.array(lt["pos"], F), F(lt["radius"]), len(q))
            d = lp - q
            dist = np.linalg.norm(d, axis=1)
            vis = ~occluded(s, q, d / dist[:, None], dist)
            E = np.array(lt["color"], F) * F(lt["power"]) / (dist * dist + 0.02)[:, None]
            out += np.minimum(vis[:, None] * E, 6.0) * (sigma / (4 * math.pi)) * (tm / steps)[:, None]
    return out

# ------------------------------------------------------------------ camera + render
def camera_rays(cam, w, h, jitter=True):
    pos, yaw, pitch, vfov = np.array(cam["pos"], F), cam.get("yaw", 0.0), cam.get("pitch", 0.0), cam["vfov"]
    ys, xs = np.mgrid[0:h, 0:w].astype(F)
    if jitter:
        xs += rng.random(xs.shape).astype(F)
        ys += rng.random(ys.shape).astype(F)
    else:
        xs += 0.5
        ys += 0.5
    f = 0.5 * h / math.tan(math.radians(vfov) / 2)
    d = np.stack([(xs - w / 2) / f, -(ys - h / 2) / f, -np.ones_like(xs)], -1).reshape(-1, 3)
    cp, sp = math.cos(pitch), math.sin(pitch)
    d = d @ np.array([[1, 0, 0], [0, cp, sp], [0, -sp, cp]], F)
    cy, sy = math.cos(yaw), math.sin(yaw)
    d = d @ np.array([[cy, 0, -sy], [0, 1, 0], [sy, 0, cy]], F)
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    return np.broadcast_to(pos, d.shape).copy(), d

def render(s, cam, w, h, spp, haze_on=True):
    acc = np.zeros((w * h, 3), F)
    gA = np.zeros((w * h, 3), F)
    gN = np.zeros((w * h, 3), F)
    gD = np.zeros(w * h, F)
    for k in range(spp):
        ro, rd = camera_rays(cam, w, h)
        t, mat, n, p, si = trace(s, ro, rd)
        col = np.zeros_like(ro)
        hit = np.isfinite(t)
        em = np.zeros(len(ro), bool)
        for j, (c, r, m, emit) in enumerate(s.sph):
            if emit is not None:
                sel = si == j
                col[sel] = emit
                em |= sel
        surf = hit & ~em
        idx = np.nonzero(surf)[0]
        bi0 = s._last_bi
        a = albedo(mat[idx], p[idx], n[idx], bi0[idx], s)
        po, no, vo = p[idx], n[idx], rd[idx]
        c = direct(s, po, no, mat[idx], vo, a)
        # one bounce of indirect light
        bd = cosine_dir(no)
        t1, m1, n1, p1, s1 = trace(s, po + no * 2e-3, bd)
        bi1 = s._last_bi
        h1 = np.isfinite(t1)
        ind = np.zeros_like(po)
        j1 = np.nonzero(h1)[0]
        if len(j1):
            a1 = albedo(m1[j1], p1[j1], n1[j1], bi1[j1], s)
            ind[j1] = direct(s, p1[j1], n1[j1], m1[j1], bd[j1], a1, with_spec=False)
            for j, (cc, r, m, emit) in enumerate(s.sph):
                if emit is not None:
                    sel = s1 == j
                    ind[sel] = 0  # direct already counts lights
        c += a * np.minimum(ind, 1.5)   # clamp fireflies from bounces right next to a light
        col[idx] = c
        if haze_on:
            col += haze(s, ro, rd, np.where(hit, t, 12.0))
        acc += col
        if k == 0:
            gA[:] = 5.0          # lights and misses: a guide value nothing else has
            gN[:] = (0, 0, 1)
            gA[idx] = a
            gN[idx] = no
            gD[:] = np.where(hit, t, 50)
    img = (acc / spp).reshape(h, w, 3)
    return img, gA.reshape(h, w, 3), gN.reshape(h, w, 3), gD.reshape(h, w)

def denoise(img, alb, nrm, dep, r=4, sc=0.35):
    """Joint bilateral filter guided by albedo, normal and depth (keeps edges and texture)."""
    h, w, _ = img.shape
    lum = np.log1p(img.mean(2))
    pad = lambda x: np.pad(x, [(r, r), (r, r)] + [(0, 0)] * (x.ndim - 2), mode="edge")
    I, A, N, D, Lm = pad(img), pad(alb), pad(nrm), pad(dep), pad(lum)
    out = np.zeros_like(img)
    wsum = np.zeros((h, w, 1), F)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            sl = (slice(r + dy, r + dy + h), slice(r + dx, r + dx + w))
            ws = math.exp(-(dx * dx + dy * dy) / (2 * (r * 0.6) ** 2))
            wn = np.clip((N[sl] * nrm).sum(2), 0, 1) ** 16
            wd = np.exp(-np.abs(D[sl] - dep) / (0.02 + 0.03 * dep))
            wa = np.exp(-((A[sl] - alb) ** 2).sum(2) / 0.002)
            wl = np.exp(-(Lm[sl] - lum) ** 2 / (2 * sc * sc))
            wt = (ws * wn * wd * wa * wl)[..., None].astype(F)
            out += I[sl] * wt
            wsum += wt
    return out / np.maximum(wsum, 1e-6)

def tonemap(img, exposure):
    x = img * exposure
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14       # ACES (Narkowicz)
    y = np.clip((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1)
    # grade: cool shadows, warm highlights
    l = y.mean(2, keepdims=True)
    y = y + (0.03 * (1 - l) * np.array([-0.4, 0.0, 0.6], F)) * (1 - l)
    return np.clip(y, 0, 1) ** (1 / 2.2)

def bloom(lin, strength=0.08):
    from PIL import Image, ImageFilter
    br = np.clip(lin - 1.0, 0, 50)
    out = np.zeros_like(lin)
    for rad in (4, 14, 40):
        ims = [Image.fromarray(np.clip(br[..., c] * 20, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(rad * lin.shape[0] / 1000)) for c in range(3)]
        out += np.stack([np.asarray(i, F) / 20 for i in ims], -1)
    return lin + strength * out

CAM_HALL = dict(pos=(0.0, 1.62, 0.0), vfov=64.0, pitch=math.radians(-4.0))
CAM_STAIRS = dict(pos=(0.0, 1.55, -4.45), vfov=72.0, pitch=math.radians(-30.0))

PLATES = {
    "closed_bulb": dict(door=True, lights=("bulb",), cam=CAM_HALL),
    "closed_leak": dict(door=True, lights=("sconce", "below"), cam=CAM_HALL),
    "open": dict(door=False, lights=("bulb", "sconce", "below"), cam=CAM_HALL),
    "stairs": dict(door=False, lights=("bulb", "sconce", "below"), cam=CAM_STAIRS),
}

def project(cam, pts, w, h):
    """World points -> plate pixels (for placing the door and words in the app)."""
    pos = np.array(cam["pos"], F)
    pitch = cam.get("pitch", 0.0)
    f = 0.5 * h / math.tan(math.radians(cam["vfov"]) / 2)
    out = []
    for q in pts:
        v = np.array(q, F) - pos
        cp, sp = math.cos(pitch), math.sin(pitch)
        # inverse of the pitch rotation used for rays
        y = v[1] * cp + v[2] * sp
        z = -v[1] * sp + v[2] * cp
        x = v[0]
        out.append((w / 2 + f * x / -z, h / 2 - f * y / -z))
    return out

if __name__ == "__main__":
    name, size, spp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    out = sys.argv[4] if len(sys.argv) > 4 else f"{name}.npz"
    P = PLATES[name]
    sc = build(P["door"], P["lights"])
    img, A, N, D = render(sc, P["cam"], size, size, spp)
    np.savez_compressed(out, img=img, alb=A, nrm=N, dep=D)
    if name != "stairs":
        # doorway (top-left, bottom-right), door face (top-left, bottom-right), stairwell depths, hinge
        meta = project(CAM_HALL, [(-0.45, 2.05, -4.2), (0.45, 0.0, -4.2), (-0.437, 2.044, -4.255), (0.437, 0.016, -4.255),
                                  (0.0, -0.6, -7.5), (0.0, 1.0, -4.255)], size, size)
        json.dump({"size": size, "pts": [[float(a), float(b)] for a, b in meta], "focal": float(0.5 * size / math.tan(math.radians(CAM_HALL["vfov"]) / 2))},
                  open(out.replace(".npz", ".json"), "w"))
    print("rendered", name)
