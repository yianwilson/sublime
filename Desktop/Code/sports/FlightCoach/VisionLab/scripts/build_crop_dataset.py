#!/usr/bin/env python3
"""Build the crop-based ball-detector dataset (Create ML JSON format).

Positives come free from the verified (ball position, impact) table: every
pre-impact frame contains the ball at a human-verified spot. Post-impact
frames at the SAME spot are hard negatives (bare tee/divot), plus the known
impostor catalog (shoes, club heads, markers) and random turf.

Crops are 600px so the ball stays detectable at Create ML's ~416px input
(full frames shrank it to ~6px — held-out was 0/5).

  VisionLab/.venv/bin/python VisionLab/scripts/build_crop_dataset.py
"""

import json
import random
from pathlib import Path

import cv2

random.seed(7)

ROOT = Path(__file__).resolve().parents[1] / "datasets"
SRC = ROOT / "source-videos"
OUT = ROOT / "ball-crops-v1"
CROP = 600

# Verified by disappearance probe + visual crop review (impact bracketing).
# x, y are top-down normalized ball-centre; ball_px at native resolution.
VIDEOS = {
    "IMG_4935": dict(file="IMG_4935.MOV",  x=0.6740, y=0.8460, ball=38, impact=5.53,
                     impostors=[(0.640, 0.846)]),                    # resting club head
    "IMG_0373": dict(file="IMG_0373.mov",  x=0.7830, y=0.6885, ball=50, impact=2.52,
                     impostors=[(0.700, 0.700)]),                    # club head at address
    "IMG_4165": dict(file="IMG_4165.mp4",  x=0.5907, y=0.9677, ball=14, impact=4.45,
                     impostors=[(0.313, 0.980), (0.320, 0.966)]),    # white shoes
    "IMG_1256": dict(file="IMG_1256.mov",  x=0.6099, y=0.7475, ball=18, impact=2.81,
                     impostors=[]),
    "IMG_3325": dict(file="IMG_3325.mov",  x=0.6268, y=0.7124, ball=17, impact=2.39,
                     impostors=[(0.750, 0.720)]),                    # range-ball tray edge
}
# Split by video, never by frame. Eval = one unseen DAYLIGHT video (0373:
# different golfer/course/120fps — the v1 generalization question) plus the
# night-mat clip as an explicit out-of-domain probe.
EVAL_VIDEOS = {"IMG_0373", "IMG_3325"}

POSITIVES_PER_VIDEO = 40
TEE_NEGATIVES = 16
IMPOSTOR_NEGATIVES = 16
TURF_NEGATIVES = 16


def relocate_ball(model, frame, cx_px, cy_px, ball_px):
    """Handheld framing drifts tens of px across a clip — re-find the ball
    SEMANTICALLY (YOLO) near the nominal spot for each sampled frame. Bright-
    blob matching latched onto club glints and signs. None when the ball is
    occluded or not confidently seen, so the frame is skipped."""
    h, w = frame.shape[:2]
    r = max(120, int(ball_px * 4))
    x0, x1 = max(0, int(cx_px - r)), min(w, int(cx_px + r))
    y0, y1 = max(0, int(cy_px - r)), min(h, int(cy_px + r))
    res = model.predict(frame[y0:y1, x0:x1], imgsz=640, conf=0.10,
                        classes=[32], verbose=False)[0]
    best = None
    for b in res.boxes:
        bx1, by1, bx2, by2 = b.xyxy[0].tolist()
        cx = x0 + (bx1 + bx2) / 2
        cy = y0 + (by1 + by2) / 2
        d = ((cx - cx_px) ** 2 + (cy - cy_px) ** 2) ** 0.5
        if d < ball_px * 3 and (best is None or float(b.conf) > best[3]):
            best = (cx, cy, max(bx2 - bx1, by2 - by1), float(b.conf))
    return best[:3] if best else None


def crop_at(frame, cx_px, cy_px, jitter):
    h, w = frame.shape[:2]
    jx = random.randint(-jitter, jitter)
    jy = random.randint(-jitter, jitter)
    x0 = int(min(max(0, cx_px + jx - CROP / 2), max(0, w - CROP)))
    y0 = int(min(max(0, cy_px + jy - CROP / 2), max(0, h - CROP)))
    return frame[y0:y0 + CROP, x0:x0 + CROP], x0, y0


def main():
    from ultralytics import YOLO
    model = YOLO("yolov8x.pt")
    for split in ("train", "eval"):
        (OUT / split).mkdir(parents=True, exist_ok=True)
    annotations = {"train": [], "eval": []}
    counts = {}

    for name, spec in VIDEOS.items():
        split = "eval" if name in EVAL_VIDEOS else "train"
        cap = cv2.VideoCapture(str(SRC / spec["file"]))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        dur = total / fps
        bx, by, ball = spec["x"] * w, spec["y"] * h, spec["ball"]
        pos = neg = 0

        # Positives: ball at rest, sampled across the whole pre-impact span.
        last_rest = spec["impact"] - 0.25
        times = [last_rest * (i + 0.5) / POSITIVES_PER_VIDEO for i in range(POSITIVES_PER_VIDEO)]
        for i, t in enumerate(times):
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
            ok, frame = cap.read()
            if not ok:
                continue
            located = relocate_ball(model, frame, bx, by, ball)
            if located is None:
                continue
            lx, ly, lsize = located
            crop, x0, y0 = crop_at(frame, lx, ly, jitter=180)
            cx, cy = lx - x0, ly - y0
            if not (20 < cx < CROP - 20 and 20 < cy < CROP - 20):
                continue
            fn = f"{name}_pos{i:03d}.png"
            cv2.imwrite(str(OUT / split / fn), crop)
            side = max(10, int(lsize * 1.15))
            annotations[split].append({
                "image": fn,
                "annotations": [{"label": "golfball",
                                 "coordinates": {"x": round(cx), "y": round(cy),
                                                 "width": side, "height": side}}]})
            pos += 1

        # Hard negatives: the SAME spot after impact (bare tee, divot, turf).
        for i in range(TEE_NEGATIVES):
            t = spec["impact"] + 0.4 + (dur - spec["impact"] - 0.6) * i / TEE_NEGATIVES
            if t >= dur - 0.1:
                break
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
            ok, frame = cap.read()
            if not ok:
                continue
            crop, _, _ = crop_at(frame, bx, by, jitter=120)
            fn = f"{name}_negtee{i:03d}.png"
            cv2.imwrite(str(OUT / split / fn), crop)
            annotations[split].append({"image": fn, "annotations": []})
            neg += 1

        # Impostor negatives (shoes, club heads, markers) + random turf.
        spots = [(ix * w, iy * h) for ix, iy in spec["impostors"]]
        for i in range(IMPOSTOR_NEGATIVES + TURF_NEGATIVES):
            t = random.uniform(0.2, dur - 0.2)
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
            ok, frame = cap.read()
            if not ok:
                continue
            if spots and i < IMPOSTOR_NEGATIVES:
                sx, sy = spots[i % len(spots)]
            else:
                sx = random.uniform(0.15, 0.85) * w
                sy = random.uniform(0.45, 0.95) * h
            # Never let the resting ball leak into a "negative" crop.
            if t < spec["impact"] and abs(sx - bx) < CROP * 0.75 and abs(sy - by) < CROP * 0.75:
                continue
            crop, _, _ = crop_at(frame, sx, sy, jitter=60)
            fn = f"{name}_negimp{i:03d}.png"
            cv2.imwrite(str(OUT / split / fn), crop)
            annotations[split].append({"image": fn, "annotations": []})
            neg += 1
        cap.release()
        counts[name] = (split, pos, neg)

    for split in ("train", "eval"):
        with open(OUT / split / "annotations.json", "w") as f:
            json.dump(annotations[split], f, indent=1)
    for name, (split, pos, neg) in counts.items():
        print(f"{name} [{split}]: {pos} positives, {neg} negatives")
    print(f"train: {len(annotations['train'])} images, eval: {len(annotations['eval'])} images -> {OUT}")


if __name__ == "__main__":
    main()
