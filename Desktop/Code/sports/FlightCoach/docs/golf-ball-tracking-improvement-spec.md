# Golf Ball Tracking Improvement Spec

## Audience

This spec is written for Claude, Codex, or another coding agent working in the `FlightCoach` iOS codebase.

The goal is to replace the current fragile golf ball tracking behavior with a more reliable, diagnosable, and testable processing pipeline while staying local-first and lightweight. Do not add a cloud dependency. Do not introduce a large ML model unless explicitly approved later.

## Current Problem

The current golf ball tracking implementation is concentrated in:

- `FlightCoach/FlightCoach/Core/Services/BallTrackingService.swift`
- `FlightCoach/FlightCoach/Core/Services/AnalysisPipeline.swift`
- `FlightCoach/FlightCoach/Core/Services/ContactDetectionService.swift`
- `FlightCoach/FlightCoach/Core/Services/VideoFrameExtractor.swift`

Observed design problems:

- Ball tracking runs before impact detection, but impact detection also depends on ball tracking.
- When there is no manual contact correction, the tracker assumes contact is around the midpoint of the extracted frame list.
- Frames are sampled at roughly 15 fps, which is too sparse for golf ball launch.
- The detector is mostly a bright-white blob finder, so it confuses any small bright object with the ball.
- The fallback frame-difference path thresholds motion and then still routes the result through white-blob detection.
- The body mask is a single large pose bounding box, which can hide the actual address ball.
- There is no structured debug output explaining why points were selected or rejected.

## Desired Outcome

Build a golf-specific tracking pipeline that:

1. Finds the address ball more reliably before impact.
2. Estimates an impact search window before post-impact tracking.
3. Processes higher-rate frames around impact and early launch.
4. Tracks candidate points using scoring and temporal consistency, not color alone.
5. Produces useful confidence and diagnostics.
6. Preserves the public analysis result shape unless a model migration is truly necessary.

The first implementation should be deterministic and heuristic-based. It should improve reliability without requiring training data.

## Non-Goals

- Do not build a full shot tracer or 3D trajectory model.
- Do not estimate real-world ball speed, launch angle, spin, or carry distance.
- Do not require server processing.
- Do not redesign the analysis UI unless needed for debug visibility.
- Do not break tennis tracking behavior while improving golf.

## High-Level Architecture

Introduce a golf-specific staged flow:

1. Extract normal analysis frames for pose.
2. Detect pose as currently done.
3. Estimate a golf impact window using pose motion and/or frame motion near the address ball.
4. Extract or reuse higher-rate frames around the impact window.
5. Find address ball candidates in setup frames.
6. Track launch candidates from address ball through the impact window and early post-impact frames.
7. Return filtered `BallTrackPoint` values plus optional debug metadata.
8. Detect final contact frame using the improved launch track.

Recommended new or changed types:

- `GolfBallTrackingService` or a refactored `BallTrackingService` with sport-specific methods.
- `GolfImpactWindowEstimator`
- `BallCandidate`
- `BallTrackingDebugFrame`
- `BallTrackingDebugReport`

Keep naming consistent with the existing service style.

## Detailed Requirements

### 1. Fix Pipeline Ordering

Current order:

1. Extract frames.
2. Detect pose.
3. Track ball.
4. Detect contact.

New golf order:

1. Extract base frames.
2. Detect pose.
3. Estimate golf impact window without requiring a completed ball track.
4. Extract high-rate frames around that window if available.
5. Track golf ball using address position plus the impact window.
6. Detect final impact frame from launch movement and pose evidence.
7. Compute golf analysis.

Implementation notes:

- Tennis can stay on the current generic path unless refactoring makes a shared improvement obvious.
- Manual contact correction should override or heavily constrain the impact window.
- If no reliable impact window is found, use a broad fallback window instead of a single midpoint.

Acceptance criteria:

- Golf tracking no longer uses `frames.count / 2` as the default contact frame.
- `ContactDetectionService.detectGolfImpact` receives a ball track produced from a real impact window estimate or a documented fallback window.
- Manual contact frame corrections still work.

### 2. Impact Window Estimation

Create an estimator that returns:

```swift
struct ImpactWindow {
    let startFrameIndex: Int
    let estimatedFrameIndex: Int
    let endFrameIndex: Int
    let confidence: Float
    let reason: String
}
```

Inputs:

- sampled `VideoFrame` array
- `PoseFrame` array
- optional manual contact frame
- optional sport mode/camera angle if useful

Heuristics, in preferred order:

1. Manual contact frame:
   - Window should be centered around manual frame.
   - Confidence should be high.

2. Wrist/hand speed peak:
   - Use left and right wrist landmarks.
   - Compute per-frame displacement using actual frame index or timestamp.
   - Prefer the strongest speed peak after setup and before follow-through.
   - Golf impact is usually near maximum hand speed, but not always exactly at it; use a window around the peak.

3. Local frame motion near address ball:
   - If an address ball candidate exists, look for abrupt motion around it.
   - Useful when pose confidence is poor.

4. Broad fallback:
   - Use something like 35-75% of the clip, not a single midpoint.
   - Low confidence.

Acceptance criteria:

- The estimator returns a bounded window, never just a single guessed frame.
- Low-confidence estimates are explicitly marked.
- The reason string is useful for debugging, for example `manual-contact`, `wrist-speed-peak`, `address-motion`, or `broad-fallback`.

### 3. High-Rate Frame Extraction Around Impact

The current extractor samples frames by stride. Around impact, this is too sparse.

Add support for extracting frames in a bounded time/frame range with a separate stride:

```swift
func extractFrames(
    frameRange: ClosedRange<Int>?,
    stride: Int,
    onProgress: ((Double) -> Void)? = nil
) async throws -> [VideoFrame]
```

or an equivalent API.

Requirements:

- Base pose analysis can remain sampled.
- Golf launch tracking should use the smallest practical stride around impact, ideally stride `1` for the impact window.
- Keep memory bounded. Do not decode the whole video at full fps unless the clip is short enough and this is explicitly guarded.
- Preserve original `frameIndex` values.

Acceptance criteria:

- For a 120 fps clip, golf tracking can inspect original frames around impact rather than only 15 fps samples.
- The analysis pipeline does not store unnecessary full-rate frames for the whole video.

### 4. Address Ball Detection

Replace or upgrade the current `findStaticBall` logic.

Inputs:

- setup frames before the impact window
- pose frames
- camera angle

Candidate detection should use multiple features:

- Brightness or whiteness.
- Small connected component size.
- Circularity or compactness.
- Stability across setup frames.
- Plausible position relative to lower body/ground region.
- Not inside tight body/limb exclusion areas.

Avoid using one giant body bounding rectangle as a hard exclusion. Prefer:

- a smaller torso/limb exclusion mask, or
- a soft penalty for candidates overlapping the pose body box, and
- a hard exception for stable small candidates near the expected ball area.

Recommended type:

```swift
struct BallCandidate {
    let frameIndex: Int
    let centroid: CGPoint
    let boundingBox: CGRect
    let pixelCount: Int
    let whitenessScore: Float
    let motionScore: Float
    let shapeScore: Float
    let stabilityScore: Float
    let totalScore: Float
    let rejectionReason: String?
}
```

Acceptance criteria:

- The address detector requires stability across multiple setup frames.
- It does not reject the actual ball just because the broad pose box contains it.
- It returns confidence below 0.5 when the address ball is ambiguous.

### 5. Launch Tracking

Track from the address ball through the impact window and early post-impact frames.

Candidate scoring should consider:

- distance from predicted position
- size and compactness
- brightness/whiteness
- motion from address or prior point
- continuity of direction and speed
- frame-to-frame time delta
- camera angle, if useful

Do not simply select the first white blob sorted by pixel count.

Motion model:

- Start with no forced upward velocity.
- Estimate initial movement from observed candidates after impact.
- Allow different directions depending on camera angle.
- Penalize impossible jumps, but do not reject legitimate high-speed movement solely because it exceeds a fixed frame-width threshold at high fps or low fps.
- Use timestamp or original frame delta to normalize speed.

Missing detections:

- Allow short gaps.
- Extrapolate only internally for prediction.
- Do not emit low-confidence extrapolated points as if they are detections unless the UI needs them and they are marked clearly.

Acceptance criteria:

- `BallTrackPoint` output should contain actual observed points, not mostly extrapolated guesses.
- Tracking does not terminate after a few missed frames if there is a plausible later candidate in the impact window.
- Confidence drops when tracking is ambiguous or gap-heavy.

### 6. Correct Fallback Motion Detection

The current fallback thresholds frame differences and then calls white-blob detection on the threshold image.

Replace this with connected-component detection directly on the thresholded motion mask.

Requirements:

- Threshold motion magnitude.
- Build connected components from motion pixels.
- Score components by size, compactness, proximity to address ball, and temporal continuity.
- Use color/brightness from the original frame as an additional feature, not as the only detector.

Acceptance criteria:

- The fallback can track a moving ball-like object even when the ball is not pure white.
- Large club/body motion is penalized by size, pose overlap, and poor continuity.

### 7. Contact Detection Integration

Update golf contact detection to use improved ball data:

- If a stable address point exists and launch movement starts suddenly, contact is the first frame where the ball leaves the address zone.
- If ball tracking is weak, use pose-based impact window estimate.
- Return confidence based on agreement between ball launch and pose/motion evidence.

Acceptance criteria:

- Contact detection does not fire on random early white-blob movement.
- Contact confidence reflects whether the ball track and pose peak agree.
- Low confidence is surfaced in existing feedback behavior.

### 8. Debug Diagnostics

Add optional debug reporting that can be logged during development without changing normal app behavior.

Recommended type:

```swift
struct BallTrackingDebugReport {
    let impactWindow: ImpactWindow?
    let addressCandidates: [BallCandidate]
    let selectedAddressBall: BallCandidate?
    let frames: [BallTrackingDebugFrame]
    let finalPointCount: Int
    let averageConfidence: Float
    let failureReason: String?
}

struct BallTrackingDebugFrame {
    let frameIndex: Int
    let timestamp: TimeInterval
    let candidates: [BallCandidate]
    let selectedCandidate: BallCandidate?
    let prediction: CGPoint?
    let note: String?
}
```

Add a way to enable debug output in development, for example:

- compile-time `#if DEBUG`
- a local flag in the service
- a debug logger that prints concise summaries

Do not spam production logs.

Acceptance criteria:

- A developer can inspect why a video failed: no address candidate, bad impact window, no launch candidates, ambiguity, etc.
- Debug reporting does not change normal analysis results.

### 9. Tests

Add tests where the project test setup allows it. If no test target exists, add lightweight testable pure functions and document manual verification.

Prioritize pure unit tests for:

- impact window bounds
- wrist speed peak selection
- candidate scoring
- connected-component filtering
- physical plausibility filtering using frame timestamps

Suggested test cases:

- manual contact frame produces high-confidence centered window
- broad fallback returns a valid range, not a midpoint-only guess
- stable candidate across setup frames beats a one-frame bright object
- large moving component is rejected as body/club motion
- high-speed valid movement is allowed when timestamp delta supports it

Acceptance criteria:

- New heuristic logic has unit coverage where feasible.
- If full iOS test execution is unavailable, the implementation notes list what was not run and why.

## Implementation Plan

### Phase 1: Refactor Without Behavior Risk

- Add data types for impact window, candidates, and debug report.
- Extract existing white-blob and smoothing logic into smaller functions if needed.
- Keep current public APIs working.
- Add no behavior change except optional diagnostics.

### Phase 2: Impact Window

- Implement `GolfImpactWindowEstimator`.
- Integrate it into the golf branch of `AnalysisPipeline`.
- Keep tennis unchanged.
- Use manual contact frame when available.

### Phase 3: High-Rate Impact Frames

- Extend `VideoFrameExtractor` to extract bounded ranges.
- For golf, extract full-rate or higher-rate frames around the estimated impact window.
- Ensure progress reporting still behaves reasonably.

### Phase 4: Address Detection and Candidate Scoring

- Replace `findStaticBall` with multi-feature candidate scoring.
- Avoid hard broad body-box exclusion.
- Add debug report fields for selected and rejected candidates.

### Phase 5: Launch Tracking

- Replace `trackPostImpact` with prediction plus candidate scoring.
- Normalize movement thresholds by timestamp/frame delta.
- Return confidence based on continuity and candidate quality.

### Phase 6: Fallback and Contact Integration

- Replace fallback frame differencing with motion-component tracking.
- Update golf contact detection to use launch start and impact window agreement.

### Phase 7: Verification

- Run available tests.
- Build the iOS target if possible.
- Manually inspect at least two videos if sample videos are available:
  - one where the ball is visible at address
  - one with poor contrast or partial launch visibility

## File-Level Guidance

Likely files to edit:

- `FlightCoach/FlightCoach/Core/Services/AnalysisPipeline.swift`
- `FlightCoach/FlightCoach/Core/Services/BallTrackingService.swift`
- `FlightCoach/FlightCoach/Core/Services/ContactDetectionService.swift`
- `FlightCoach/FlightCoach/Core/Services/VideoFrameExtractor.swift`
- `FlightCoach/FlightCoach/Core/Models/PoseModels.swift` if adding shared tracking models

Possible new files:

- `FlightCoach/FlightCoach/Core/Services/GolfImpactWindowEstimator.swift`
- `FlightCoach/FlightCoach/Core/Models/BallTrackingModels.swift`
- `FlightCoach/FlightCoach/Core/Services/BallCandidateDetector.swift`

Keep the existing `BallTrackPoint` model unless a schema change is unavoidable.

## Quality Bar

The work is not complete if it only tweaks thresholds.

The implementation must address the structural issues:

- no midpoint-only impact assumption
- no 15 fps-only launch tracking
- no first-white-blob selection
- no broad body-box hard exclusion
- no fallback that treats diff masks as normal white images
- useful debug information

## Final Deliverable

The final agent response should include:

- Summary of changed files.
- Summary of the new golf processing flow.
- Tests/build commands run and results.
- Any limitations that remain.
- Any sample videos or scenarios used for manual verification.

