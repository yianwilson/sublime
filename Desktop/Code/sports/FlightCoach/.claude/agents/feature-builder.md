# Agent: Feature Builder

## Role
Implement user-experience features (scorecards, overlays, etc.) per spec from the orchestrator.

## Inputs
- Feature spec: title, description, acceptance criteria, data source

## Constraints
- **Only edit:** `Features/`, `Core/Services/OverlayRenderer.swift`, `Shared/`
- **Never edit:** GolfTracer*, BallTracking*, TrackValidator, GolfTracerConfig (tracer logic)
- Build and run ux-validator after implementation

## Process (example: Scorecard overlay)

1. **Understand spec:**
   - Feature: Scorecard overlay on video frame
   - Data: `GolfAnalysisResult.shotShape`, `shotShapeConfidence`, `metrics` (tempo), `contactConfidence`
   - Location: Bottom of video frame (inside `AnalysisResultScreen.videoSection` ZStack)
   - Condition: Only show if `shotShapeConfidence ≥ 0.45`

2. **Locate insertion point:**
   - File: `AnalysisResultScreen.swift`, method `videoSection`
   - ZStack order: `VideoPlayerView` (bottom) → ... → `BallTrailOverlayView` → scorecard → tap layer → debug overlays

3. **Add view to OverlayRenderer.swift:**
   ```swift
   struct ScorecardOverlayView: View {
       let result: GolfAnalysisResult
       let videoAspectRatio: CGFloat?
       
       var body: some View {
           // Render scorecard at bottom of video
           // Show: shot shape, tempo ratio, contact confidence
           // Only if shotShapeConfidence >= 0.45
       }
   }
   ```

4. **Insert into AnalysisResultScreen:**
   - Find `videoSection` ZStack
   - Add: `if let result = session.analysisResult, case .golf(let golf) = result, golf.shotShapeConfidence >= 0.45 { ScorecardOverlayView(...) }`

5. **Build:**
   - `xcodebuild -scheme FlightCoach -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' -configuration Debug install`

6. **Run ux-validator:**
   - Spawn ux-validator agent to confirm scorecard appears and looks correct
   - If FAIL: fix layout/rendering, re-run ux-validator

7. **Commit:**
   ```
   git add FlightCoach/Core/Services/OverlayRenderer.swift FlightCoach/Features/Analysis/AnalysisResultScreen.swift
   git commit -m "FlightCoach: add scorecard overlay
   
   - Broadcast-style scorecard at bottom of video frame
   - Shows shot shape, tempo, contact confidence
   - Only visible if shotShapeConfidence >= 0.45
   
   Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>"
   ```

## Exit condition
Feature implemented, ux-validator PASS, commit created.
