# Tracer Architecture Plan (2026-06-10)

Four layers, each independently testable against the ground-truth gate
(`TracerGroundTruthTests`, `GT_STRICT=1` enforces).

## 1. Impact window — SwingNet/GolfDB-style event detection
**Replaces:** `GolfImpactWindowEstimator` (wrist-speed/global-motion heuristic;
source of the constant "Impact: Low confidence" warnings).
**Approach:** MobileNetV2+LSTM swing-event detector trained on GolfDB
(1,400 annotated swings, 8 events incl. impact) → CoreML. Few-MB model,
frame-accurate impact. Check GolfDB repo license before shipping weights;
retraining on the dataset ourselves is clean.
**Win:** every downstream layer anchors on the impact frame — today it can be
off by ±0.5s, which alone breaks launch detection.

## 2. Find the ball — Create ML object detector
**Replaces:** address-ball heuristics in `BallTrackingService.findAddressBall`.
**Approach:** dataset labeled by `VisionLab/scripts/autolabel_ball_yolo.py`
(pretrained YOLOv8x, AGPL — labeling only, never shipped) → train with
Create ML object detection (or YOLOX/Apache) → CoreML, ANE-native.
**Status:** labeler proven on IMG_4935 (teed ball conf 0.75, full flight chain,
review crop verified). Needs batch run over more videos.

## 3. Follow the launched ball — VNDetectTrajectoriesRequest
**Replaces:** `TracerCandidateDetector` + `LaunchTrackSelector` for flight.
**Proven:** finds both fixture ball flights at confidence 1.00 with zero
tuning, including the two cases that defeated all motion heuristics
(slow vertical riser on clear sky; hard pull on overcast).
See `FlightCoachTests/VNTrajectoryProbeTests.swift`.
**Filtering (cheap):** thousands of shimmer trajectories reduce to the ball via
start-near-address (layer 2) + rising + within impact window (layer 1).
**Note:** VN reports raw media-time; trajectories self-locate spatially, so the
iPhone-MOV multi-timeline problem (player ≈ ffmpeg+0.5s ≈ VN+2.4s on
IMG_4935) doesn't bite here.

## 4. Sanity — Kalman + physics gates
**Mostly exists:** `TrackValidator` (reversal/loop/efficiency/displacement),
upward-launch gate, deceleration step-ratio gate, fps-aware velocity damping.
**Upgrade:** replace `VelocityPredictor` with a constant-acceleration Kalman
filter; keep all gates as the final arbiter. Honest failure beats wrong trace.

## Order of work
1. Integrate layer 3 (VN) into `AnalysisPipeline` behind the existing gates —
   biggest proven win, no training required.
2. Batch-label videos → train layer 2 Create ML detector.
3. Layer 1 SwingNet (needs GolfDB training run).
4. Layer 4 Kalman upgrade last — current gates suffice meanwhile.

## Licensing
- YOLOv8/ultralytics: AGPL — internal labeling only.
- VNDetectTrajectoriesRequest / Create ML: no constraints.
- GolfDB/SwingNet: verify repo license; retrain rather than ship third-party weights.
