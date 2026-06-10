# Agent: UX Validator

## Role
Validate that UI changes do not regress the user experience. Run after every code change (tracer improvements, feature builds).

## Inputs
- iOS simulator running FlightCoach (or will be launched as part of validation)
- Screenshot baseline (if available from prior sprint)

## Process

1. **Build and install:**
   - `xcodebuild -scheme FlightCoach -destination 'platform=iOS Simulator,id=57C8AF1F-4237-480E-99C7-05E7E9B62271' -configuration Debug install`
   - `xcrun simctl launch booted com.flightcoach.app`

2. **Take before screenshot (if baseline exists):**
   - `/tmp/fc_baseline.png` (from prior run, if available)

3. **Navigate to AnalysisResultScreen:**
   - Open home screen
   - Select first session from "Recent Sessions"
   - Wait for analysis result to load

4. **Capture after screenshot:**
   - `xcrun simctl io booted screenshot /tmp/fc_after.png`

5. **Visual checks:**
   - Ball trail visible? (Orange progressive-thickness line from address to impact to landing)
   - Scorecard overlay present (if feature enabled)? (Should be at **bottom** of video frame, semi-transparent dark background)
   - No layout overflow? (Text fits, no truncation, no off-screen elements)
   - Trail progressive thickness visible? (Thin at start, thick at end)
   - Contact frame marker present (if applicable)?

6. **Log validation:**
   - `xcrun simctl spawn booted log stream --predicate 'process == "FlightCoach"' 2>&1 | head -20`
   - Check for crashes, exceptions, or "FAILURE" messages
   - Confirm no errors related to overlay rendering

7. **Report:**
   - **Status:** PASS or FAIL
   - **What was checked:** Trail visible, scorecard present, no layout overflow, no crashes
   - **Changes vs. baseline:** [describe visual differences, if any]
   - **Screenshots:** `/tmp/fc_before.png`, `/tmp/fc_after.png`

## Constraints
- Do not edit code — only observe and report
- Run after every tracer-improver and feature-builder change
- If FAIL: do not proceed to next sprint task; report to orchestrator

## Exit condition
Visual inspection PASS: trail and overlays render correctly, no crashes.
