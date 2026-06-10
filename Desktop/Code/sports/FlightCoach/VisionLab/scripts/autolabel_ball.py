#!/usr/bin/env python3
"""Auto-label golf ball flight frames for YOLO training.

Uses frame differencing to find the ball after impact (the technique that
produced the TracerGroundTruthTests labels), chains detections by velocity
continuity, and writes YOLO-format labels + annotated review images.

Usage:
  python3 autolabel_ball.py VIDEO.mov --out dataset/ [--impact-sec 6.2]

Output layout (YOLO):
  dataset/images/<video>_fNNN.png
  dataset/labels/<video>_fNNN.txt      "0 cx cy w h" (normalised)
  dataset/review/<video>_fNNN.png      crop around the ball for human review

Review every crop before training. Delete bad pairs; the ball must be
clearly visible and centred.
"""

import argparse
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np


def ffprobe_meta(video):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate,nb_frames",
         "-of", "csv=p=0", str(video)],
        capture_output=True, text=True).stdout.strip().split("\n")[0].split(",")
    w, h = int(out[0]), int(out[1])
    num, den = out[2].split("/")
    fps = float(num) / float(den)
    # Rotation metadata: portrait phones store landscape + rotate.
    rot = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "side_data=rotation", "-of", "csv=p=0", str(video)],
        capture_output=True, text=True).stdout.strip()
    if rot and abs(int(float(rot.split(",")[-1] or 0))) in (90, 270):
        w, h = h, w
    return w, h, fps


def gray_frames(video, scale_w, start, count, fps):
    """Decode `count` frames from `start` seconds as grayscale at scale_w wide."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", f"{start:.3f}", "-i", str(video),
         "-frames:v", str(count), "-vf", f"scale={scale_w}:-2",
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True).stdout
    if not out:
        sys.exit("ffmpeg produced no frames")
    row = len(out) // count // scale_w
    return np.frombuffer(out, dtype=np.uint8).reshape(-1, row, scale_w).astype(np.float32)


def find_impact_sec(video, w, h, fps, duration_frames):
    """Peak motion in the lower-centre (golfer) region."""
    fr = gray_frames(video, 160, 0, duration_frames, fps)
    hh, ww = fr.shape[1], fr.shape[2]
    reg = fr[:, int(hh * 0.45):, int(ww * 0.15):int(ww * 0.85)]
    energy = np.abs(np.diff(reg, axis=0)).mean(axis=(1, 2))
    # Ignore first/last second (handling noise).
    pad = int(fps)
    energy[:pad] = 0
    energy[-pad:] = 0
    return float(np.argmax(energy)) / fps


def chain_ball(video, w, h, fps, impact_sec, span=1.6):
    """Diff frames after impact, cluster movers, chain by velocity continuity.

    Works at ~720px width: at full 4K the ball moves further per frame than the
    chain continuity radius and can never link up.
    """
    n = int(span * fps)
    fr = gray_frames(video, min(720, w), impact_sec, n, fps)
    detections = []  # (frame_offset, x, y, npix)
    for i in range(1, len(fr)):
        d = np.abs(fr[i] - fr[i - 1])
        base = np.median(d)
        ys, xs = np.where(d > base + 14)
        if len(xs) < 2:
            continue
        cl = defaultdict(list)
        for x, y in zip(xs, ys):
            cl[(x // 60, y // 60)].append((x, y))
        for c in cl.values():
            if len(c) < 3:
                continue
            cx = float(np.mean([p[0] for p in c]))
            cy = float(np.mean([p[1] for p in c]))
            # The ball is WHITE: its patch must be brighter than the local
            # neighbourhood, else this is club/shadow/grass churn.
            xi, yi = int(cx), int(cy)
            H, W = fr.shape[1], fr.shape[2]
            if not (12 < xi < W - 12 and 12 < yi < H - 12):
                continue
            patch = fr[i, yi - 3:yi + 4, xi - 3:xi + 4].mean()
            ring = fr[i, yi - 12:yi + 13, xi - 12:xi + 13].mean()
            if patch < ring + 6:
                continue
            detections.append((i, cx, cy, len(c)))

    # Static-spot suppression: positions recurring across >40% of frames.
    spot_count = defaultdict(set)
    for f, x, y, _ in detections:
        spot_count[(int(x) // 50, int(y) // 50)].add(f)
    nframes = len(fr)
    moving = [d for d in detections
              if len(spot_count[(int(d[1]) // 50, int(d[2]) // 50)]) < nframes * 0.4]

    # Try every early mover as a chain seed; the ball is the chain with the
    # greatest net displacement (body/club jiggle stays put, the ball LEAVES).
    by_frame = defaultdict(list)
    for d in moving:
        by_frame[d[0]].append(d)
    frames_sorted = sorted(by_frame)

    def build(seed):
        chain = [seed]
        cur, vel = seed, (0.0, -8.0)
        for f in frames_sorted:
            if f <= cur[0]:
                continue
            px = cur[1] + vel[0] * (f - cur[0])
            py = cur[2] + vel[1] * (f - cur[0])
            best = min(by_frame[f], key=lambda d: (d[1] - px) ** 2 + (d[2] - py) ** 2)
            if ((best[1] - px) ** 2 + (best[2] - py) ** 2) ** 0.5 > 120:
                continue
            dt = best[0] - cur[0]
            step = (((best[1] - cur[1]) ** 2 + (best[2] - cur[2]) ** 2) ** 0.5) / dt
            if step < 6:        # body jiggle, not flight
                continue
            vel = ((best[1] - cur[1]) / dt, (best[2] - cur[2]) / dt)
            cur = best
            chain.append(best)
        return chain

    seeds = [d for f in frames_sorted[:6] for d in by_frame[f]]
    best_chain = []
    best_score = 0.0
    # Kinematics alone cannot separate ball from club in the launch window
    # (both bright, fast, straight-ish, same origin). Return the top distinct
    # chains and let a human pick — one decision per video.
    edge = fr.shape[1] * 0.04
    scored = []
    for seed in seeds:
        c = build(seed)
        if len(c) < 4:
            continue
        net_up = c[0][2] - c[-1][2]
        if net_up < 10:
            continue
        if any(p[2] > fr.shape[1] - edge or p[2] < edge for p in c):
            continue
        net = ((c[-1][1] - c[0][1]) ** 2 + (c[-1][2] - c[0][2]) ** 2) ** 0.5
        scored.append((net * len(c), c))
    scored.sort(key=lambda s: -s[0])

    # Deduplicate chains sharing endpoints.
    chains = []
    for _, c in scored:
        end = (round(c[-1][1] / 80), round(c[-1][2] / 80))
        if any((round(o[-1][1] / 80), round(o[-1][2] / 80)) == end for o in chains):
            continue
        chains.append(c)
        if len(chains) == 5:
            break
    return chains, fr.shape[2], fr.shape[1]


def export(video, out, chain, scale_w, scale_h, w, h, fps, impact_sec, box_frac=0.02):
    stem = Path(video).stem
    img_dir = out / "images"
    lbl_dir = out / "labels"
    rev_dir = out / "review"
    for d in (img_dir, lbl_dir, rev_dir):
        d.mkdir(parents=True, exist_ok=True)

    written = 0
    for f_off, x, y, npix in chain:
        t = impact_sec + f_off / fps
        nx, ny = x / scale_w, y / scale_h
        frame_no = int(round(t * fps))
        name = f"{stem}_f{frame_no}"
        # Full-res frame for training.
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-ss", f"{t:.4f}", "-i", str(video),
             "-frames:v", "1", str(img_dir / f"{name}.png")], check=True)
        bw = max(box_frac, (npix ** 0.5 * 2.5) / scale_w)
        (lbl_dir / f"{name}.txt").write_text(f"0 {nx:.4f} {ny:.4f} {bw:.4f} {bw * w / h:.4f}\n")
        # Review crop, 240px around the ball at full res.
        cx, cy = int(nx * w), int(ny * h)
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", str(img_dir / f"{name}.png"),
             "-vf", f"crop=240:240:{max(0, cx - 120)}:{max(0, cy - 120)},"
                    f"drawbox=x=100:y=100:w=40:h=40:color=red@0.8",
             "-update", "1", str(rev_dir / f"{name}.png")], check=True)
        written += 1
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--out", default="VisionLab/datasets/ball-v1")
    ap.add_argument("--impact-sec", type=float, default=None)
    ap.add_argument("--span", type=float, default=1.6, help="seconds after impact to label")
    ap.add_argument("--pick", type=int, default=None,
                    help="chain number to export (run once without to see chains.png)")
    args = ap.parse_args()

    video = Path(args.video)
    out = Path(args.out)
    w, h, fps = ffprobe_meta(video)
    print(f"{video.name}: {w}x{h} @{fps:.0f}fps")

    impact = args.impact_sec
    if impact is None:
        impact = find_impact_sec(video, w, h, fps, int(fps * 30))
        print(f"impact (auto, golfer-region motion peak): {impact:.2f}s — verify in review/")

    chains, sw, sh = chain_ball(video, w, h, fps, impact, args.span)
    if not chains:
        sys.exit("no candidate chains found — pass/adjust --impact-sec")

    if args.pick is None:
        # Render every chain on the impact frame, one colour each, for human pick.
        out.mkdir(parents=True, exist_ok=True)
        colours = ["red", "yellow", "lime", "cyan", "magenta"]
        boxes = []
        for i, c in enumerate(chains):
            col = colours[i % len(colours)]
            pts = " ".join(f"({int(p[1] * w / sw)},{int(p[2] * h / sh)})" for p in c[:4])
            print(f"chain {i + 1} [{col}]: {len(c)} pts, frames +{c[0][0]}..+{c[-1][0]}, starts {pts}")
            for p in c:
                x, y = int(p[1] * w / sw), int(p[2] * h / sh)
                boxes.append(f"drawbox=x={x - 18}:y={y - 18}:w=36:h=36:color={col}@0.9:t=6")
        comp = out / f"{Path(video).stem}_chains.png"
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-ss", f"{impact:.3f}", "-i", str(video),
             "-frames:v", "1", "-vf", ",".join(boxes), str(comp)], check=True)
        print(f"\nwrote {comp} — find the chain following the BALL, then re-run with --pick N")
        return

    chain = chains[args.pick - 1]
    n = export(video, out, chain, sw, sh, w, h, fps, impact)
    print(f"wrote {n} image+label pairs to {out}/ — REVIEW {out}/review/ before training")


if __name__ == "__main__":
    main()
