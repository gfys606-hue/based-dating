"""Depth maps for the app's parallax: 8-bit inverse depth (near = bright), slightly softened.
  python3 depth.py <render.npz> <vfov_degrees> <out.png> [size]
The app decodes:  d = 1 / (v * (1/NEAR - 1/FAR) + 1/FAR)   with NEAR = 0.5 m, FAR = 14 m."""
import math, sys
import numpy as np
from PIL import Image, ImageFilter

NEAR, FAR = 0.5, 14.0

def export(npz, vfov, out, size=600):
    t = np.load(npz)["dep"].astype(np.float64)           # distance along each pixel's ray
    h, w = t.shape
    f = 0.5 * h / math.tan(math.radians(vfov) / 2)
    ys, xs = np.mgrid[0:h, 0:w] + 0.5
    z = t / np.sqrt(1 + ((xs - w / 2) / f) ** 2 + ((ys - h / 2) / f) ** 2)   # depth along the view axis
    z = np.clip(z, NEAR, FAR)
    v = (1 / z - 1 / FAR) / (1 / NEAR - 1 / FAR)
    im = Image.fromarray((v * 255).round().astype(np.uint8)).resize((size, size), Image.LANCZOS)
    im.filter(ImageFilter.GaussianBlur(1.2)).save(out, optimize=True)

if __name__ == "__main__":
    export(sys.argv[1], float(sys.argv[2]), sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 600)
