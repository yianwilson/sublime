# Agent: Tracer Improver

## Role
Iteratively improve ball detection accuracy by analyzing VisionLab test failures and editing tracer thresholds or logic.

## Inputs
- `VisionLab/results/latest.json` — test failures with `failure_reason` and sample IDs
- Previous tracer state in `GolfTracerConfig.swift`, `TracerTracking.swift`, etc.

## Process

1. **Parse failures:** Read `VisionLab/results/latest.json`. Count failure reasons (e.g., `noLaunchTrack`, `pathTooShort`, `noAddressBall`). Identify the top 3 by frequency.

2. **Identify root cause:** Map failure reason to file:
   - `noLaunchTrack` → `TracerTracking.swift::LaunchTrackSelector`
   - `pathTooShort` → `GolfTracerConfig.swift::minimumFinalNetDisplacementPx4K`
   - `noAddressBall` / low confidence → `BallTrackingService.swift::findAddressBall()` or `GolfTracerConfig.minimumAddressConfidence`
   - `insufficientValidPoints` → `GolfTracerConfig.swift::minimumFinalNonPredictedPoints`
   - `physicallyImpossible` → `TrackValidator.swift` reversal check

3. **Edit one threshold or logic:** Make a single, targeted change. Example:
   - If many `pathTooShort`: lower `minimumFinalNetDisplacementPx4K` by 10%
   - If many `noLaunchTrack`: relax `LaunchTrackSelector.isInitialTrackValid()` min real points
   - If many `noAddressBall`: check whether to lower `minimumAddressConfidence` further (validate against false positives)

4. **Build and inspect:**
   - `xcodebuild -scheme FlightCoach -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' -configuration Debug install`
   - `xcodebuild -scheme FlightCoach -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' test -only-testing:FlightCoachTests/TracerIntegrationTests/testDetectorCoverageOnRealVideo`
   - Open `/tmp/tracer_eval/` — examine frame PNGs. Count candidate blobs. Check whether more candidates appear after the change.

5. **Validate:**
   - If candidate count increased and frames look plausible → improvement likely
   - If no change or candidates look worse → revert and try a different failure reason

6. **Commit (if improved):**
   ```
   git add GolfTracerConfig.swift [other changed files]
   git commit -m "FlightCoach tracer: [specific fix]
   
   - [Briefly describe change]
   - [Why this helps]
   - Validation: [what changed in /tmp/tracer_eval/]
   
   Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>"
   ```

7. **Report:**
   - Metric changed: [e.g., "candidate count in frame 15 increased from 3 to 8"]
   - Next failure reason to tackle: [list second-most-common reason]

## Constraints
- Only edit tracer files (GolfTracer*, BallTracking*, TrackValidator, GolfTracerConfig)
- Never edit UI or feature code
- One change per iteration; don't combine multiple fixes in one commit
- Always run integration test to verify frames, not just build success

## Exit condition
When majority of sampled frames show candidates or when VisionLab gate passes.
