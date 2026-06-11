# FlightCoach — Claude Code Agent System Guide

> **Working on ball tracking / the tracer?** Read `TRACER_DEV_METHOD.md`
> FIRST — it is the validated diagnostic cycle (ground-truth probes, clock
> and orientation invariants, fixture GT tables, current state, next tasks).
> `TRACER_PLAN.md` holds the four-layer target architecture.

## Overview

This guide enables sub-agents (via Claude Code `/loop` and Agent tool) to iteratively improve ball tracking accuracy, validate UX changes, build features, and analyze competitive products. The system is autonomous: agents read test results, identify failure modes, edit code, re-test, and commit.

---

## Architecture Quick Reference

### Coordinate System (CRITICAL)
- **Internal (Core/Models, Core/Services):** Vision-normalised, origin **bottom-left**, y-up, `[0, 1]` range
- **UI (Features/):** View-space, origin **top-left**, y-down
- **Conversion boundary:** `OverlayRenderer.swift` and `pointToView()` methods in overlay views

### Pipeline Stages
1. **Frame extraction** → `VideoFrameExtractor` (stride 1–15 fps)
2. **Pose detection** → `PoseDetectionService` + `Vision.VNDetectHumanBodyPoseRequest`
3. **Ball tracking (golf):**
   - Auto path: `BallTrackingService.detectAddressOnly()` → `GolfTracerPipeline.trace()` (addresses, launch, flight)
   - Seed path: one manual point → `trackGolfBallFromSeed()`
   - Manual path: user-drawn points (≥ 2) used directly
4. **Metrics** → `GolfAnalysisService.analyse()` → tempo, head move, spine angle, hip sway, balance, shot shape
5. **Feedback** → `FeedbackEngine` (rule-based, deterministic)
6. **Persist** → `AnalysisResult` encoded to `session.analysisResultData`

### Key Files by Responsibility
| File | Role |
|---|---|
| `GolfTracerPipeline.swift` | Entry point; stages 4–6 orchestration |
| `TracerCandidateDetector.swift` | Pixel-level blob detection (static, contrast, motion) |
| `TracerTracking.swift` | `LaunchTrackSelector`, `BallTracker`, `VelocityPredictor` |
| `TrackValidator.swift` | Final 6-check gate before render |
| `BallTrackingService.swift` | Address detection, launch tracking (normalised coords) |
| `AnalysisResultScreen.swift` | UI entry; result display, trace overlay insertion |
| `OverlayRenderer.swift` | All overlay views: `BallTrailOverlayView`, `ScorecardOverlayView`, pose overlays |
| `GolfTracerConfig.swift` | All thresholds: address confidence (0.50), validation gates, search radii |

---

## Build & Test Commands

### Build
```bash
xcodebuild -scheme FlightCoach -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' -configuration Debug install
```

### Install on booted simulator
```bash
xcrun simctl install booted /path/to/FlightCoach.app
```

### Launch app
```bash
xcrun simctl launch booted com.flightcoach.app
```

### Screenshot
```bash
xcrun simctl io booted screenshot /tmp/fc_screenshot.png
```

### Stream logs (golf trace messages only)
```bash
xcrun simctl spawn booted log stream --predicate 'process == "FlightCoach"' | grep -i "address\|confidence\|trace"
```

### Run integration test (generates annotated frames)
```bash
xcodebuild -scheme FlightCoach -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' test -only-testing:FlightCoachTests/TracerIntegrationTests/testDetectorCoverageOnRealVideo
# Frames exported to: /tmp/tracer_eval/
```

### VisionLab (accuracy validation)
Requires a manifest JSON at `~/FlightCoachDatasets/golf-v1/dataset.json` with the schema in `VisionLab/manifests/dataset.example.json`.

```bash
# Validate manifest schema
python3 VisionLab/scripts/validate_manifest.py ~/FlightCoachDatasets/golf-v1/dataset.json

# Score detector output against ground truth
python3 VisionLab/scripts/score_tracking_results.py ~/FlightCoachDatasets/golf-v1/dataset.json VisionLab/results/latest.json

# Check release gates
python3 VisionLab/scripts/gate_results.py ~/FlightCoachDatasets/golf-v1/dataset.json VisionLab/results/latest.json
```

---

## Code Style Rules for Agents

**No comments.** Well-named identifiers are sufficient.

**No premature abstraction.** Duplicate code is acceptable if it's small and localized. Three similar lines do not warrant a helper function.

**SwiftUI Canvas for overlays.** Use `Canvas { context, size in … }` for drawing trails, scorecard, debug dots. Do not use `Path()` + `stroke()` modifiers outside Canvas.

**Vision-normalised throughout Core.** Every coordinate in `Core/Models/` and `Core/Services/` is Vision space (`[0, 1]`, bottom-left origin). Convert to view space only at the render boundary (overlay views in `OverlayRenderer.swift`).

**Never add forward-compatibility shims.** If you change a threshold or gate, update the code that reads it. No `// TODO` or `// FIXME` comments.

**Trust framework guarantees.** Don't validate that `Array.first` exists unless the algorithm requires it. Don't add guards for cases that can't happen.

---

## Agent Roles (defined in `.claude/agents/`)

### tracer-improver
- **Trigger:** Orchestrator or manual `/loop tracer-improver`
- **Input:** `VisionLab/results/latest.json` (failure reasons, sample IDs)
- **Process:**
  1. Parse JSON; identify most-common failure reason
  2. Map reason to file: `noLaunchTrack` → `TracerTracking.swift`, `pathTooShort` → `GolfTracerConfig.swift`, etc.
  3. Edit thresholds or logic
  4. Build app
  5. Run `testDetectorCoverageOnRealVideo` → inspect `/tmp/tracer_eval/f*.png` for changes
  6. If improved: commit with message "FlightCoach tracer: [specific fix]"
  7. Report: change made, metric delta (if measurable from frame inspection)

### ux-validator
- **Trigger:** After any code change (run by orchestrator or feature-builder)
- **Input:** None (reads from simulator state)
- **Process:**
  1. Build and install app
  2. Launch app, take screenshots of `AnalysisResultScreen` with an existing session that has a trace
  3. Check visually: trail visible? scorecard overlay present (if enabled)? no layout overflow?
  4. Stream logs briefly (< 5 sec) to confirm no crashes
  5. Report: pass/fail, paths to screenshots

### feature-builder
- **Trigger:** With explicit feature spec (title, description, acceptance criteria)
- **Input:** None (reads from request)
- **Constraints:**
  - Only edits `Features/`, `Core/Services/OverlayRenderer.swift`, `Shared/`
  - Never edits pipeline (GolfTracer*, BallTracking*, TrackValidator, etc.)
  - Runs `ux-validator` after building to confirm no regressions
- **Process:**
  1. Parse spec
  2. Locate insertion point (e.g., add overlay to `videoSection` ZStack)
  3. Implement (UI-only)
  4. Build, run ux-validator
  5. Commit with message "FlightCoach: [feature title]"

### competitive-analyst
- **Trigger:** Once per sprint (or on demand)
- **Input:** None
- **Process:**
  1. Research top golf tracer apps: Hudl Technique, Swing Vision, The Grint, Shot Tracer (video), V1 Golf, FlightScope Mevo+, Trackman
  2. Extract: trace UX (line style, colour, width progression), scorecard overlays, contact detection accuracy, feature set
  3. Write to `.claude/research/golf_tracer_competitive_analysis.md` as a markdown table + summary
  4. Commit results

---

## Scorecard Overlay (Feature 1)

**Acceptance criteria:**
- Visible at **bottom of video frame** (inside `videoSection` ZStack, above tap layer)
- Shows: shot shape badge (Fade, Draw, Straight), tempo ratio (X.X:1), carry estimate (placeholder "—"), contact confidence (green/amber/red dot)
- Only rendered if `shotShapeConfidence ≥ 0.45`
- Semi-transparent dark background (SwiftUI `.black.opacity(0.6)`)
- Uses data from `GolfAnalysisResult` — no new models

**Files:**
- `FlightCoach/Core/Services/OverlayRenderer.swift` — add `ScorecardOverlayView` struct
- `FlightCoach/Features/Analysis/AnalysisResultScreen.swift` — insert into `videoSection` ZStack, condition on golf + high confidence

---

## Sprint Cycle (Orchestrator)

```
Each sprint:
1. Run competitive-analyst ONCE (check if .claude/research/golf_tracer_competitive_analysis.md already exists)
2. Run tracer-improver (1 accuracy pass)
3. Run ux-validator (confirm no regressions)
4. Run feature-builder with spec for next feature (scorecard, then next)
5. Run ux-validator (confirm feature looks correct)
6. Commit sprint summary to .claude/sprint_log.md
```

The orchestrator is invoked with `/loop` and manages sub-agent sequencing.

---

## Debugging Tips

**Ball not detected:**
- Check `GolfTracerConfig.minimumAddressConfidence` (currently 0.50). If you lower it further, validate that false positives don't spike in VisionLab.
- Check `BallTrackingService.findAddressBall()` — logs will show address candidate scores and rejection reasons.
- Run `testDetectorCoverageOnRealVideo` to see all candidate blobs in `/tmp/tracer_eval/` — if candidates are there but address detection fails, the issue is in Stage 2 (scoring/confidence).

**Trace breaks mid-flight:**
- Check `TracerTracker.track()` — missing frames → prediction-only points. If too many predictions, validation will reject the track.
- Check hard gates in `TracerAssociation.passesHardGates()` — angle, speed, forward-direction.

**Trace loops or reverses:**
- `TrackValidator.validate()` checks for reversals and loops. If triggered, check `TracerGeometry.isCompactLoopLike()` or `hasImmediateReversal()`.

**Layout overflow (scorecard too big):**
- Scorecard is anchored to bottom of video. If text wraps, reduce font size or abbreviate "Tempo Ratio" → "Tempo".

---

## References

- **Architecture:** See `/Users/edwardwilson/Desktop/Code/sports/FlightCoach/ARCHITECTURE.md`
- **VisionLab:** See `/Users/edwardwilson/Desktop/Code/sports/FlightCoach/VisionLab/README.md`
- **Tracer Spec:** Inline comments in `GolfTracerPipeline.swift` and `TracerTracking.swift` (spec §5–§17)
