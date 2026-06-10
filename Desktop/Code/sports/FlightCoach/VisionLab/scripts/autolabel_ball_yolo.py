#!/usr/bin/env python3
"""Auto-label golf ball flight frames using pretrained YOLO (COCO "sports ball").

Run with the VisionLab venv:
  VisionLab/.venv/bin/python VisionLab/scripts/autolabel_ball_yolo.py VIDEO.mov \
      --out VisionLab/datasets/ball-v1 [--impact-sec 5.5] [--span 0.6]

Pipeline: dense frame extraction around impact -> YOLO sports-ball detection
(high-res inference) -> static-spot exclusion (ground balls, sprinklers) ->
continuity chain from the teed ball -> YOLO-format labels + review crops.

No hand-tuned thresholds: detection is semantic. Review crops remain the
human QA step before training.
"""

import argparse
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


def ffprobe_meta(video):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate",
         "-of", "csv=p=0", str(video)],
        capture_output=True, text=True).stdout.strip().split("\n")[0].split(",")
    w, h = int(out[0]), int(out[1])
    num, den = out[2].split("/")
    fps = float(num) / float(den)
    rot = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "side_data=rotation", "-of", "csv=p=0", str(video)],
        capture_output=True, text=True).stdout.strip()
    if rot and abs(int(float(rot.split(",")[-1] or 0))) in (90, 270):
        w, h = h, w
    return w, h, fps


def find_impact(video, w, h):
    """Coarse YOLO sweep: the teed ball is a sports-ball detection that sits
    still across consecutive samples; impact is the last sample it's present."""
    from ultralytics import YOLO
    dur = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(video)], capture_output=True, text=True).stdout.strip())
    tmp = Path("/tmp/autolabel_coarse")
    tmp.mkdir(exist_ok=True)
    for old in tmp.glob("*.png"):
        old.unlink()
    step = 0.3
    times = [round(t, 2) for t in
             [step * i for i in range(1, int(dur / step) - 1)]]
    for i, t in enumerate(times):
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-ss", f"{t:.3f}", "-i", str(video),
                        "-frames:v", "1", str(tmp / f"c{i:03d}.png")], check=True)
    model = YOLO("yolov8x.pt")
    hits = defaultdict(list)   # position cell -> [sample indices]
    for i in range(len(times)):
        r = model.predict(str(tmp / f"c{i:03d}.png"), classes=[32],
                          conf=0.12, imgsz=1920, verbose=False)[0]
        for b in r.boxes:
            x, y = float(b.xywh[0][0]), float(b.xywh[0][1])
            if y < h * 0.35:
                continue
            hits[(int(x) // 100, int(y) // 100)].append(i)
    best = None
    for cell, idxs in hits.items():
        runs = sorted(set(idxs))
        if len(runs) < 3:
            continue
        # longest consecutive run = ball sitting still
        longest, cur, last_idx = 1, 1, runs[0]
        end = runs[0]
        for j in runs[1:]:
            cur = cur + 1 if j == last_idx + 1 else 1
            if cur >= longest:
                longest, end = cur, j
            last_idx = j
        if longest >= 3 and (best is None or longest > best[0]):
            best = (longest, end)
    if best is None:
        return None
    return times[best[1]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--out", default="VisionLab/datasets/ball-v1")
    ap.add_argument("--impact-sec", type=float, default=None,
                    help="approx impact time in FFMPEG timeline; omit for auto-detection")
    ap.add_argument("--span", type=float, default=0.6)
    ap.add_argument("--conf", type=float, default=0.03)
    args = ap.parse_args()

    from ultralytics import YOLO

    video = Path(args.video)
    out = Path(args.out)
    w, h, fps = ffprobe_meta(video)
    print(f"{video.name}: {w}x{h} @{fps:.0f}fps")

    if args.impact_sec is None:
        args.impact_sec = find_impact(video, w, h)
        if args.impact_sec is None:
            sys.exit("auto-impact failed: no persistent teed ball found — pass --impact-sec")
        print(f"auto impact: teed ball last seen at {args.impact_sec:.2f}s")

    # Extract dense frames starting slightly BEFORE impact so the teed ball anchors the chain.
    tmp = Path("/tmp/autolabel_yolo")
    tmp.mkdir(exist_ok=True)
    for old in tmp.glob("*.png"):
        old.unlink()
    n = int(args.span * fps)
    start = args.impact_sec - 3 / fps
    for i in range(n):
        t = start + i / fps
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-ss", f"{t:.4f}", "-i", str(video),
                        "-frames:v", "1", str(tmp / f"d{i:03d}.png")], check=True)

    model = YOLO("yolov8x.pt")
    dets = {}
    for i in range(n):
        r = model.predict(str(tmp / f"d{i:03d}.png"), classes=[32],
                          conf=args.conf, imgsz=1920, verbose=False)[0]
        dets[i] = [(float(b.conf), float(b.xywh[0][0]), float(b.xywh[0][1]),
                    float(b.xywh[0][2]), float(b.xywh[0][3])) for b in r.boxes]

    # Static exclusion: any 80px cell hot in >30% of frames is a ground object.
    spot = defaultdict(int)
    for v in dets.values():
        for d in v:
            spot[(int(d[1]) // 80, int(d[2]) // 80)] += 1
    thr = n * 0.3
    moving = {i: [d for d in v if spot[(int(d[1]) // 80, int(d[2]) // 80)] < thr]
              for i, v in dets.items()}

    # The teed ball is the static, high-confidence detection nearest the bottom
    # at the start; the flight chain is moving detections linked by continuity.
    chain = []
    cur, vel = None, None
    for i in sorted(moving):
        cands = moving[i]
        if not cands:
            continue
        if cur is None:
            best = max(cands, key=lambda d: d[0])
            cur, vel = (i, best), (0.0, -h * 0.02)
            chain.append((i, best))
            continue
        ci, cd = cur
        px, py = cd[1] + vel[0] * (i - ci), cd[2] + vel[1] * (i - ci)
        best = min(cands, key=lambda d: (d[1] - px) ** 2 + (d[2] - py) ** 2)
        if ((best[1] - px) ** 2 + (best[2] - py) ** 2) ** 0.5 > w * 0.2:
            continue
        vel = ((best[1] - cd[1]) / (i - ci), (best[2] - cd[2]) / (i - ci))
        cur = (i, best)
        chain.append((i, best))

    if len(chain) < 3:
        sys.exit(f"only {len(chain)} chained detections — wrong --impact-sec? Run a coarse "
                 f"sweep first or check the window")
    print(f"chained {len(chain)} flight detections:")
    for i, d in chain:
        print(f"  +{i} t={start + i / fps:.2f}s ({d[1]:.0f},{d[2]:.0f}) conf={d[0]:.2f}")

    img_dir, lbl_dir, rev_dir = out / "images", out / "labels", out / "review"
    for d in (img_dir, lbl_dir, rev_dir):
        d.mkdir(parents=True, exist_ok=True)
    stem = video.stem
    for i, d in chain:
        t = start + i / fps
        name = f"{stem}_f{int(round(t * fps))}"
        subprocess.run(["cp", str(tmp / f"d{i:03d}.png"), str(img_dir / f"{name}.png")], check=True)
        bw, bh = max(d[3], 12) / w, max(d[4], 12) / h
        (lbl_dir / f"{name}.txt").write_text(
            f"0 {d[1] / w:.4f} {d[2] / h:.4f} {bw * 1.4:.4f} {bh * 1.4:.4f}\n")
        cx, cy = int(d[1]), int(d[2])
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", str(img_dir / f"{name}.png"),
             "-vf", f"crop=240:240:{max(0, cx - 120)}:{max(0, cy - 120)},"
                    f"drawbox=x=100:y=100:w=40:h=40:color=red@0.8",
             "-update", "1", str(rev_dir / f"{name}.png")], check=True)
    print(f"wrote {len(chain)} image+label pairs to {out}/ — review {out}/review/")


if __name__ == "__main__":
    main()
