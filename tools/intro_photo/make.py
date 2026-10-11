"""Grades the two real photos used by the opening (free Pixabay photos, see src/):
  books-378903.jpg          a front-on antique bookcase  -> the hidden door
  vaulted-cellar-247391.jpg a vaulted brick cellar       -> what's behind it
Light stays photographic: the bookcase is dimmed to one warm pool of lamplight from above,
the cellar falls into darkness near you and glows warm at the far end.
  python3 make.py <src_dir> <out_dir>
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

src, out = sys.argv[1], sys.argv[2]


def lin(im):
    return (np.asarray(im).astype(np.float32) / 255.0) ** 2.2


def srgb(a):
    a = np.clip(a, 0, None)
    a = a / (1 + a * 0.35)                 # soft shoulder for the highlights
    return Image.fromarray((np.clip(a, 0, 1) ** (1 / 2.2) * 255).round().astype(np.uint8))


# ---- the bookcase: one lamp above, the rest falling off into shadow
b = lin(Image.open(f"{src}/books-378903.jpg").convert("RGB"))
h, w = b.shape[:2]
yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
pool = np.exp(-(((xx - w * 0.5) / (w * 0.55)) ** 2 + ((yy - h * 0.22) / (h * 0.48)) ** 2))
fall = 0.07 + 0.9 * pool                                  # lamp from above
floor = np.clip(1.0 - (yy / h - 0.78) / 0.22 * 0.45, 0.55, 1.0)  # darker toward the floor
b = b * (fall * floor)[..., None] * np.array([1.06, 0.93, 0.78], np.float32) * 0.95
srgb(b).save(f"{out}/photo_books.jpg", quality=88, optimize=True)

# ---- the cellar: dark near the camera, warm light down at the end of the arches
c = lin(Image.open(f"{src}/vaulted-cellar-247391.jpg").convert("RGB"))
h, w = c.shape[:2]
vx, vy = 693.0, 500.0                                      # vanishing point (pixels)
yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
d = np.sqrt(((xx - vx) / w) ** 2 + ((yy - vy) / h) ** 2)
deep = np.exp(-(d / 0.30) ** 2)
c = c * (0.22 + 0.95 * deep)[..., None] * np.array([1.08, 0.90, 0.72], np.float32)
glow = np.exp(-(d / 0.07) ** 2)[..., None] * np.array([1.0, 0.58, 0.24], np.float32) * 0.22
c = c + glow
srgb(c).save(f"{out}/photo_cellar.jpg", quality=86, optimize=True)
print("ok", b.shape, c.shape)
