"""Denoise (lighting only, so textures stay sharp), bloom, tone map -> JPEG."""
import sys
import numpy as np
from PIL import Image
from render import denoise, tonemap, bloom

def finish(npz, out, exposure, r=4):
    d = np.load(npz)
    img, alb = d["img"], d["alb"]
    surf = alb.max(2) < 4.9                        # lights/misses carry the guide value 5
    a = np.where(surf[..., None], np.maximum(alb, 0.02), 1.0)
    light = img / a                                # demodulate: just the light hitting each surface
    light = denoise(light, alb, d["nrm"], d["dep"], r=r)
    img = np.where(surf[..., None], light * a, img)
    img = bloom(img, 0.06)
    Image.fromarray((tonemap(img, exposure) * 255).astype(np.uint8)).save(out, quality=88)

if __name__ == "__main__":
    finish(sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) > 4 else 4)
