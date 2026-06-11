"""Measure inner-disk vs annulus luma contrast at the address-ball position
over time. Goal: find a presence signal that cleanly steps down at impact.

Usage: probe_disappearance.py <video> <x_norm> <y_norm_topleft> [fps]
"""
import sys
import cv2
import numpy as np

video, xn, yn = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
sample_fps = float(sys.argv[4]) if len(sys.argv) > 4 else 10.0

cap = cv2.VideoCapture(video)
fps = cap.get(cv2.CAP_PROP_FPS)
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
stride = max(1, round(fps / sample_fps))
cx, cy = int(xn * w), int(yn * h)
r_inner = max(4, int(0.006 * max(w, h)))   # ~ball radius
r_outer = r_inner * 4

yy, xx = np.mgrid[-r_outer:r_outer + 1, -r_outer:r_outer + 1]
dist = np.sqrt(xx**2 + yy**2)
inner_mask = dist <= r_inner
annulus_mask = (dist > r_inner * 2) & (dist <= r_outer)

print(f"video {w}x{h} @ {fps:.1f}fps, probe ({cx},{cy}) r_inner={r_inner} r_outer={r_outer}")
i = 0
while True:
    ok, frame = cap.read()
    if not ok:
        break
    if i % stride == 0:
        t = i / fps
        y0, y1 = cy - r_outer, cy + r_outer + 1
        x0, x1 = cx - r_outer, cx + r_outer + 1
        if y0 >= 0 and x0 >= 0 and y1 <= h and x1 <= w:
            patch = cv2.cvtColor(frame[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
            inner = float(patch[inner_mask].mean())
            outer = float(np.median(patch[annulus_mask]))
            print(f"t={t:7.2f}  inner={inner:.3f}  annulus={outer:.3f}  contrast={inner - outer:+.3f}")
    i += 1
cap.release()
