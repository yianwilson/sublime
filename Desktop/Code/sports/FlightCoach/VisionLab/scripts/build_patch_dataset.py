#!/usr/bin/env python3
"""Build a ball/not-ball PATCH classification dataset.

The in-app integration point (scoring disappearance seeds) supplies candidate
positions already — recognition is a classification problem, not detection.
Classification generalizes from far less data than the Create ML detector,
which memorized 3 training scenes (train mAP@50 0.80, held-out 0/57).

Patches are 96px around the (YOLO-relocated) verified ball, scaled so the
ball fills a consistent ~40% of the patch regardless of native ball size.
Negatives: bare tee post-impact at the same spot, the impostor catalog,
random turf.

  VisionLab/.venv/bin/python VisionLab/scripts/build_patch_dataset.py
"""

import random
from pathlib import Path

import cv2

from build_crop_dataset import VIDEOS, EVAL_VIDEOS, SRC, relocate_ball

random.seed(11)
OUT = Path(__file__).resolve().parents[1] / "datasets" / "ball-patches-v1"
PATCH = 96
BALL_FRACTION = 0.4
PER_VIDEO = 60
NEG_PER_VIDEO = 60


def extract(frame, cx, cy, ball_px, out_path):
    """Cut a window so the ball occupies ~BALL_FRACTION, resize to PATCH."""
    h, w = frame.shape[:2]
    half = max(16, int(ball_px / BALL_FRACTION / 2))
    x0, y0 = int(cx - half), int(cy - half)
    x0 = min(max(0, x0), max(0, w - 2 * half))
    y0 = min(max(0, y0), max(0, h - 2 * half))
    win = frame[y0:y0 + 2 * half, x0:x0 + 2 * half]
    if win.shape[0] < 8 or win.shape[1] < 8:
        return False
    cv2.imwrite(str(out_path), cv2.resize(win, (PATCH, PATCH)))
    return True


def main():
    from ultralytics import YOLO
    model = YOLO("yolov8x.pt")
    for split in ("train", "eval"):
        for cls in ("ball", "notball"):
            (OUT / split / cls).mkdir(parents=True, exist_ok=True)

    for name, spec in VIDEOS.items():
        split = "eval" if name in EVAL_VIDEOS else "train"
        cap = cv2.VideoCapture(str(SRC / spec["file"]))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        dur = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) / fps
        bx, by, ball = spec["x"] * w, spec["y"] * h, spec["ball"]
        pos = neg = 0

        last_rest = spec["impact"] - 0.25
        for i in range(PER_VIDEO):
            t = last_rest * (i + 0.5) / PER_VIDEO
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
            ok, frame = cap.read()
            if not ok:
                continue
            located = relocate_ball(model, frame, bx, by, ball)
            if located is None:
                continue
            lx, ly, lsize = located
            # small centring jitter so the classifier tolerates imperfect seeds
            jx, jy = random.randint(-4, 4), random.randint(-4, 4)
            if extract(frame, lx + jx, ly + jy, lsize,
                       OUT / split / "ball" / f"{name}_{i:03d}.png"):
                pos += 1

        spots = [(ix * w, iy * h) for ix, iy in spec["impostors"]]
        for i in range(NEG_PER_VIDEO):
            kind = i % 3
            if kind == 0:           # bare tee / divot after impact
                t = random.uniform(spec["impact"] + 0.4, max(spec["impact"] + 0.5, dur - 0.2))
                sx, sy = bx, by
            elif kind == 1 and spots:   # impostor catalog
                t = random.uniform(0.2, dur - 0.2)
                sx, sy = spots[i % len(spots)]
            else:                   # random turf, never near the resting ball
                t = random.uniform(0.2, dur - 0.2)
                sx = random.uniform(0.15, 0.85) * w
                sy = random.uniform(0.45, 0.95) * h
                if t < spec["impact"] and abs(sx - bx) < ball * 4 and abs(sy - by) < ball * 4:
                    continue
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
            ok, frame = cap.read()
            if not ok:
                continue
            size = ball * random.uniform(0.8, 1.3)
            if extract(frame, sx + random.randint(-6, 6), sy + random.randint(-6, 6),
                       size, OUT / split / "notball" / f"{name}_{i:03d}.png"):
                neg += 1
        cap.release()
        print(f"{name} [{split}]: {pos} ball, {neg} notball")
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
