#!/usr/bin/env python3
"""Find the teed ball and its impact time: YOLO finds static sports-ball
candidates (semantic — no brightness tuning), the validated white-outlier
disappearance step dates each one's departure, and the hit ball is the
candidate with a clean long-presence -> permanent-absence step.

Mirrors the in-app method (BallTrackingService.disappearanceSeeds) but with
YOLO as stage 1. Writes review crops (ball at rest / just after impact) so a
human can verify before labels are trusted.

  VisionLab/.venv/bin/python VisionLab/scripts/find_impact.py VIDEO [VIDEO...]
      [--review-dir /tmp/impact_review]
"""

import argparse
import sys
from pathlib import Path

import cv2
import numpy as np


def sample_frames(video, hz):
    cap = cv2.VideoCapture(str(video))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    stride = max(1, round(fps / hz))
    frames = []
    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if i % stride == 0:
            frames.append((i / fps, frame))
        i += 1
    cap.release()
    return frames


def content_rect(frame):
    """Crop away pillarbox/letterbox bars (some clips are a vertical strip
    inside a landscape container — YOLO would mostly see black)."""
    g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    lit_cols = np.nonzero(g.max(axis=0) > 24)[0]
    lit_rows = np.nonzero(g.max(axis=1) > 24)[0]
    if len(lit_cols) < 32 or len(lit_rows) < 32:
        return 0, 0, frame.shape[1], frame.shape[0]
    return int(lit_cols.min()), int(lit_rows.min()), int(lit_cols.max() + 1), int(lit_rows.max() + 1)


def static_ball_candidates(frames, model, rect):
    """YOLO sports-ball detections that sit still across >=3 samples."""
    rx0, ry0, rx1, ry1 = rect
    spots = []   # (x, y, size, hits, conf)
    step = max(1, round(0.5 * 7.5))
    for t, frame in frames[::step]:
        res = model.predict(frame[ry0:ry1, rx0:rx1], imgsz=1920, conf=0.05,
                            classes=[32], verbose=False)[0]
        h, w = frame.shape[:2]
        for b in res.boxes:
            x1, y1, x2, y2 = b.xyxy[0].tolist()
            cx, cy = (x1 + x2) / 2 + rx0, (y1 + y2) / 2 + ry0
            cx, cy = cx / w, cy / h
            size = max(x2 - x1, y2 - y1)
            conf = float(b.conf)
            for s in spots:
                if abs(s[0] - cx) < 0.012 and abs(s[1] - cy) < 0.012:
                    s[3] += 1
                    s[4] = max(s[4], conf)
                    break
            else:
                spots.append([cx, cy, size, 1, conf])
    return [s for s in spots if s[3] >= 2]


def white_outlier_series(frames, cx, cy, ball_px):
    """Count of luma outliers (> window median + 0.2) near (cx, cy)."""
    series = []
    for t, frame in frames:
        h, w = frame.shape[:2]
        r = max(8, int(ball_px * 1.5))
        ro = r * 4
        px, py = int(cx * w), int(cy * h)
        y0, y1 = max(0, py - ro), min(h, py + ro)
        x0, x1 = max(0, px - ro), min(w, px + ro)
        if y1 - y0 < r or x1 - x0 < r:
            series.append((t, 0))
            continue
        patch = cv2.cvtColor(frame[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
        med = float(np.median(patch))
        icy, icx = py - y0, px - x0
        inner = patch[max(0, icy - r):icy + r, max(0, icx - r):icx + r]
        series.append((t, int((inner > med + 0.2).sum())))
    return series


def disappearance_step(series):
    """Longest sustained presence run ending in sustained absence (the
    validated in-app rule)."""
    counts = [c for _, c in series]
    peak = max(counts) if counts else 0
    if len(series) < 8 or peak < 8:
        return None
    threshold = max(4, int(peak * 0.35))
    present = [c >= threshold for c in counts]
    best = None
    i = 0
    while i < len(present):
        if present[i]:
            j = i
            while j + 1 < len(present) and present[j + 1]:
                j += 1
            if j > i and (best is None or j - i >= best[1] - best[0]):
                best = (i, j)
            i = j + 1
        else:
            i += 1
    if best is None:
        return None
    run = best
    if run[1] + 3 >= len(series):
        return None
    if any(present[run[1] + 1:run[1] + 4]):
        return None
    impact = (series[run[1]][0] + series[run[1] + 1][0]) / 2
    return impact, run[1] - run[0], peak


def outlier_centroid(frame, cx, cy, r_px):
    """Centroid + count of luma outliers near (cx, cy) in one frame."""
    h, w = frame.shape[:2]
    px, py = int(cx * w), int(cy * h)
    ro = r_px * 4
    y0, y1 = max(0, py - ro), min(h, py + ro)
    x0, x1 = max(0, px - ro), min(w, px + ro)
    patch = cv2.cvtColor(frame[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    med = float(np.median(patch))
    icy, icx = py - y0, px - x0
    inner = patch[max(0, icy - r_px):icy + r_px, max(0, icx - r_px):icx + r_px]
    ys, xs = np.nonzero(inner > med + 0.2)
    if len(xs) < 8:
        return None, 0
    gx = (max(0, icx - r_px) + xs.mean() + x0) / w
    gy = (max(0, icy - r_px) + ys.mean() + y0) / h
    return (float(gx), float(gy)), len(xs)


def departure(frames, cx, cy, ball_px, depth=0):
    """Date this spot's departure; when something SURVIVES the step (the dim
    ball next to the bright resting club head), the step was the club's
    takeaway — recurse on the survivor with a tighter window."""
    step = disappearance_step(white_outlier_series(frames, cx, cy, ball_px))
    if not step:
        return None
    impact, run, peak = step
    after_t = impact + 0.4
    after = next((f for t, f in frames if t >= after_t), None)
    if after is not None and depth < 2:
        r = max(6, int(ball_px * 0.9))
        survivor, count = outlier_centroid(after, cx, cy, r)
        if survivor and count >= 8:
            deeper = departure(frames, survivor[0], survivor[1],
                               max(4, ball_px * 0.7), depth + 1)
            if deeper and deeper[2] > impact + 0.2:
                return deeper
    return cx, cy, impact, run, peak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("videos", nargs="+")
    ap.add_argument("--review-dir", default="/tmp/impact_review")
    args = ap.parse_args()

    from ultralytics import YOLO
    model = YOLO("yolov8x.pt")
    review = Path(args.review_dir)
    review.mkdir(parents=True, exist_ok=True)

    for video in args.videos:
        name = Path(video).stem
        frames = sample_frames(video, hz=7.5)
        if len(frames) < 16:
            print(f"{name}: too short"); continue
        h, w = frames[0][1].shape[:2]
        rect = content_rect(frames[len(frames) // 2][1])
        candidates = static_ball_candidates(frames, model, rect)
        results = []
        for cx, cy, size, hits, conf in candidates:
            d = departure(frames, cx, cy, size / 2)
            if d and d[3] >= 5:
                results.append((d[0], d[1], size, conf, d[2], d[3], d[4]))
        if not results:
            print(f"{name}: NO ball-with-clean-departure found "
                  f"({len(candidates)} static balls)"); continue
        # The hit ball: prefer high YOLO confidence, then long presence run.
        results.sort(key=lambda r: (r[3], r[5]), reverse=True)
        cx, cy, size, conf, impact, run, peak = results[0]
        print(f"{name}: ball ({cx:.4f},{cy:.4f}) size {size:.0f}px conf {conf:.2f} "
              f"IMPACT {impact:.2f}s (run {run}, peak {peak}, "
              f"{len(results)}/{len(candidates)} candidates departed)")
        # Review crops: at rest (impact-0.5) and just after (impact+0.3).
        cap = cv2.VideoCapture(str(video))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30
        for tag, t in [("rest", impact - 0.5), ("gone", impact + 0.3)]:
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(max(0, t) * fps))
            ok, frame = cap.read()
            if not ok:
                continue
            px, py = int(cx * w), int(cy * h)
            r = 150
            crop = frame[max(0, py - r):py + r, max(0, px - r):px + r].copy()
            ch, cw = crop.shape[:2]
            cv2.drawMarker(crop, (cw // 2, ch // 2), (0, 0, 255), cv2.MARKER_CROSS, 40, 2)
            cv2.imwrite(str(review / f"{name}_{tag}.png"), crop)
        cap.release()


if __name__ == "__main__":
    sys.exit(main())
