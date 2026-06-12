# Tracer Development Method — Agent Handoff Guide

How to make progress on FlightCoach ball tracking without fooling yourself.
This is the working method that produced every real fix so far. Follow the
cycle; do not skip the validation steps. Companion docs: `TRACER_PLAN.md`
(the four-layer architecture), `CLAUDE.md` (build commands, agent roles).

## Prime directive

**Never claim a trace/detection is correct from looking at it.** Club
follow-through, shadows, and wrong-coordinate-space coincidences all look
plausible. Every claim must be backed by a numeric comparison against
independently measured ground truth. This failed twice by eye and once even
numerically (a raw-space trajectory coincidentally paralleled the
display-space GT path) — see "Traps" below.

## The cycle

1. **Reproduce with the gate test** (~1–4 min/run):
   ```bash
   xcodebuild -scheme FlightCoach \
     -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' \
     test -only-testing:FlightCoachTests/TrajectoryServiceTests \
     -derivedDataPath /tmp/FCDD 2>&1 \
     | grep -E "TrajectoryDetection:|VNSVC|Test Case '|error:"
   ```
   Keep `/tmp/FCDD` warm — never clean it unless builds go stale.
   `TracerGroundTruthTests` (with `GT_STRICT=1` via `TEST_RUNNER_GT_STRICT=1`)
   is the older pixel-level gate for the legacy tracer.

2. **When a number looks wrong, measure reality OUTSIDE the app first.**
   Use the Python venv (`VisionLab/.venv/bin/python` — system python3 has
   broken x86 PIL; ALWAYS use the venv) against the fixture videos in
   `FlightCoachTests/Resources/`:
   - `VisionLab/scripts/probe_disappearance.py <video> <x_norm> <y_norm_topleft> [fps]`
     — inner-disk vs annulus luma contrast at a point over time.
   - White-outlier count probe (the validated ball-presence metric):
     count pixels with `luma > window_median + 0.2` in a ±1.5-ball-diameter
     window; see `/tmp/probe3.py` pattern in session history or rewrite (20 lines).
   - YOLO spot-check: `YOLO("yolov8x.pt").predict(frame, imgsz=1920, conf=0.05, classes=[32])`
     (AGPL — labeling/diagnosis ONLY, never ship).
   - Dump crops to LOOK at pixels: ffmpeg `-noautorotate` for raw buffer view,
     default for display view. Compare both when orientation is in doubt.

3. **Design the algorithm from the measured signal, then port to Swift.**
   The Python probe defines expected numbers (peaks, step times). The Swift
   implementation must reproduce them; when it doesn't, instrument the Swift
   side (debug prints behind `#if DEBUG`, frame dumps behind
   `TEST_RUNNER_<FLAG>=1` env) and diff against Python until you know why.

4. **In-app validation is the only "done".** The unit test must compare the
   full app-path output (same APIs the pipeline calls) against GT
   geometrically (worst GT-point distance < 0.08 normalized).

## Hard-won invariants (violate = silent garbage)

- **Clocks:** there are at least FOUR timelines per iPhone MOV: player,
  ffmpeg/cv2, AVAssetReader PTS, and VN observation time. They disagree by
  0.5–2s on edit-listed 60fps MOVs. VN observation `timeRange` is NOT the
  buffer PTS. The only safe pattern: measure every time-anchor in the SAME
  loop from the SAME buffers and re-stamp VN updates with the producing
  buffer's PTS (see `TrajectoryDetectionService.runDetection`).
- **Orientation:** sample buffers are RAW; rotation −90 MOVs are landscape
  buffers. cv2 8.x auto-rotates; ffprobe `stream_side_data=rotation` tells
  you the tag. The extractor's `displayOrientedImage` must use
  `CIImage.oriented(_:)` (manual `transformed(by: preferredTransform)`
  produced 180°-flipped frames). VN trajectory coords are in raw-buffer
  space; map to display via the winning disappearance-probe index
  (self-validating, no transform table) — `toDisplay` in
  `TrajectoryDetectionService.ballFlight`.
- **Scale:** `BallTrackingService.workingScale = 0.35` makes the ball ~2px —
  any per-pixel ball signal must run on full-res crops or the raw luma plane,
  never on scaled frames.
- **The ball-presence signal** (validated on both fixtures): white-outlier
  pixel count (luma > local median + 0.2) in a tight window. Ball present =
  high count; absolute counts vary 26–1093 across clips, so threshold
  RELATIVE to clip peak (0.35×). Impact = end of the LONGEST sustained
  presence run with ≥3 absent samples after (NOT the last run — the golfer
  retrieving the tee re-brightens the window).
- **GolfImpactWindowEstimator is broken** (off 1.6–3.3s on both fixtures);
  it remains only as a fallback. The disappearance anchor replaces it.

## Ground truth (fixtures in FlightCoachTests/Resources/)

| | IMG_4165.mp4 (1080×1920, 30fps, no rotation) | IMG_4935.MOV (3840×2160 raw, rot −90, 60fps) |
|---|---|---|
| Address (display, y-up) | (0.5907, 0.0323) | (0.6856, 0.1607) |
| Impact (PTS clock) | ~4.45s | 5.50–5.53s |
| Flight GT (display, y-up) | (0.4963,0.4286),(0.4898,0.4875),(0.4963,0.5177) | (0.6579,0.2326),(0.6264,0.3133),(0.5870,0.4135) |
| Character | slow vertical riser, x≈0.49 | hard pull up-left, exits left edge fast |

GT derivation recipe: ffmpeg frame-differencing for flight, YOLO + pixel
crops for tee/address, manual crop inspection for impact bracketing.

## Current state (2026-06-12): IN-APP TRACE VERIFIED ON SIMULATOR

The REAL app flow (Photos import → auto seed → flight → on-screen trail)
draws the true flight on IMG_4935: trail pixels vs GT worst 0.076; seed at
0.004 from the tee; impact 5.55s. Verify with `FullTraceFlowUITests` +
orange-pixel extraction (see `/tmp/verify_trail2.py` pattern: detect the
pillarboxed video rect, extract orange px, min-distance to GT points).
App stdout (pipeline prints) is captured in the xcresult:
`xcrun xcresulttool export diagnostics` → `StandardOutputAndStandardError-
com.flightcoach.app.txt`. Persisted points: SwiftData sqlite at the app
container (`simctl get_app_container`), table ZPRACTICESESSION, column
ZANALYSISRESULTDATA (JSON).

Key architecture now: `disappearanceSeeds` (pose-free, full-res, cluster
+grid-probed white-blob departures; within a cluster the ball departs
LAST) → `TrajectoryDetectionService.ballFlight(seeds:)` (one VN pass, all
seeds cross-validated, latest-validated-impact wins, physics gates) →
spec-v3 tracer fallback from seeds[0]. Photos picker uses
`preferredItemEncoding: .current` — the default rendition transcodes
4K60→30fps where VN cannot see a fast pull (~7 frames); the transcode
fixture (IMG_4935_imported.mov) keeps that path tested: exact seed+impact
but NO reliable flight at 30fps (fallback follows the club — known gap).

Open gaps: 4165-class (slow riser; VN-blind, seeds ambiguous among
shoes/markers — needs layer-2 ML ball recognition); 30fps-transcode
flights; pose unavailable on simulator (works on device, would improve
seed veto). PipelineSeedTests is the fast full-pipeline mirror — run it
before any sim E2E.

## Previous state (2026-06-11, end of session)

- **Both `TrajectoryServiceTests` GREEN, stable across 4 consecutive runs.**
  - 4935: real flight selected, worst GT distance **0.027** (space-verified).
  - 4165: VN returns **nil** (it never emits the slow receding riser — proven
    by dumping all trajectories: best possible 0.172); pipeline falls back to
    spec-v3 tracer. The test accepts nil-or-correct, never a wrong path.
- Impact-by-disappearance anchor working on both fixtures (4165: 4.50s vs
  estimator's 7.80s; 4935: 5.50/5.53s vs estimator's 1.90s); implemented in
  `BallTrackingService.impactTimeByDisappearance` (extractor clock, pipeline
  fallback) and in-loop in `TrajectoryDetectionService` (primary).
- Selection gates (display space): near-address < 0.10, above-tee
  (first.y > address.y − 0.015), rise > 0.03, straightness net/path > 0.7,
  density (≥60% of inter-point dts ≤ 3.5 frames), start ∈ [impact−0.25,
  impact+1.6] (slack above because VN reports ~1.4s late). Selection rule:
  **latest-starting candidate** (club crosses address BEFORE impact; the ball
  is the last riser), score only tie-breaks near-simultaneous duplicates.
- Diagnostic hook: `TEST_RUNNER_VN_DUMP_DIR=/tmp` dumps all VN trajectories
  + impact + orientation to `/tmp/vn_<video>.json`; analyze with the
  `/tmp/analyze_vn.py` pattern (map raw→display by orientation index, rank
  by worst-GT distance).
- Known perf concern: rare test runs took 4–14 min (VN on 4K60 under
  simulator load); typical is ~30s. If persistent, profile `runDetection`.

## Next large tasks (in order)

1. **4165 flight coverage**: VN cannot see slow receding risers; either the
   spec-v3 fallback must pass `TracerGroundTruthTests` on it, or layer 2
   (Create ML detector + Kalman) covers this class.
2. **In-app E2E on fixtures** via `FullTraceFlowUITests` or direct
   `AnalysisPipeline` test; verify the on-screen trail matches GT, not just
   the service output.
3. **Label remaining videos** (IMG_0373, IMG_1256, IMG_3325, IMG_6067,
   IMG_9596, IMG_9899) with `VisionLab/scripts/autolabel_ball_yolo.py`
   (needs manual `--impact-sec`); expand the GT test table.
4. **Crop-based Create ML retrain** (600px crops + negatives) — first
   attempt was 0/5 held-out; full-frame training is useless at ~416px input.
5. **Fix orphaned-video bug**: sessions store absolute paths; re-resolve
   container-relative on launch.

## Traps that already burned this project

- Validating traces by eye (club follow-through looks like a ball flight).
- Trusting any single clock or converting between clocks by constant offset.
- Trusting coordinate space without a pixel-level cross-check (the 0.041
  "pass" that was a raw-space coincidence).
- Hand-tuning brightness/motion thresholds against imagination instead of
  measured pixel values (8 failed labeler iterations).
- `xcodebuild test` without `-derivedDataPath /tmp/FCDD` (cold rebuilds).
- Simulator wedging: `Application failed preflight checks / Busy` →
  `xcrun simctl shutdown <UDID>; xcrun simctl boot <UDID>; sleep 20`.
