# Orchestrator: FlightCoach Autonomous Sprint Loop

## Overview

This orchestrator runs a sprint cycle that iteratively improves ball tracking accuracy, validates UX, builds features, and analyzes competitors. Invoked with `/loop` in the conversation.

Each sprint includes:
1. **Competitive analysis** (once per sprint, cached)
2. **Tracer improvement** (one accuracy pass)
3. **UX validation** (confirm no regressions)
4. **Feature building** (implement next feature from backlog)
5. **UX validation** (confirm feature renders correctly)
6. **Commit & report** (log sprint summary)

---

## Sprint Cycle Instructions

### Step 1: Competitive Analysis (Run Once)

Check if `.claude/research/golf_tracer_competitive_analysis.md` exists. If not, run:

**Agent: competitive-analyst**

Prompts the agent to research leading golf tracer apps and produce a markdown report with:
- Table: App name, Trace UX, Scorecard visibility, Contact accuracy, Key differentiators
- Summary of patterns across competitors
- Gaps in FlightCoach vs. competitors
- Quick-win features to implement

**Output:** `.claude/research/golf_tracer_competitive_analysis.md` + commit

---

### Step 2: Tracer Improvement (One Pass)

**Agent: tracer-improver**

Prompts the agent to:
1. Check for `VisionLab/results/latest.json` (if exists)
2. Parse failure reasons; identify most-common
3. Map failure to file (see CLAUDE.md for mapping table)
4. Edit one threshold or logic in the tracer
5. Build app
6. Run integration test → inspect `/tmp/tracer_eval/` frames
7. Report changes + commit (if improved)

**Note:** If no VisionLab results exist, agent skips and reports "No VisionLab data; skipping accuracy pass."

---

### Step 3: UX Validation (Post-Tracer)

**Agent: ux-validator**

Prompts the agent to:
1. Build and install app
2. Launch and navigate to `AnalysisResultScreen`
3. Take screenshot `/tmp/fc_post_tracer.png`
4. Check visually: trail visible? no crashes? layout correct?
5. Report PASS/FAIL

**If FAIL:** Stop sprint, report to user. Do not proceed to feature-builder.

---

### Step 4: Feature Building (Scorecard First)

**Agent: feature-builder**

Prompts the agent with feature spec:

```
Feature: Scorecard Overlay on Golf Video
Title: Add broadcast-style scorecard at bottom of video frame
Description: Show shot shape, tempo ratio, contact confidence
Acceptance criteria:
  - Visible at bottom of video (inside videoSection ZStack)
  - Shows: shot shape badge, tempo ratio (X.X:1), carry ("—"), contact confidence (green/amber/red dot)
  - Only renders if shotShapeConfidence >= 0.45
  - Semi-transparent dark background
Data source: GolfAnalysisResult (shotShape, shotShapeConfidence, metrics, contactConfidence)
Files to edit:
  - FlightCoach/Core/Services/OverlayRenderer.swift (add ScorecardOverlayView)
  - FlightCoach/Features/Analysis/AnalysisResultScreen.swift (insert into videoSection ZStack)
```

Agent:
1. Implements `ScorecardOverlayView` in `OverlayRenderer.swift`
2. Inserts it into `videoSection` ZStack in `AnalysisResultScreen.swift`
3. Builds app
4. Runs ux-validator to confirm scorecard appears
5. Commits with message "FlightCoach: add scorecard overlay"

---

### Step 5: UX Validation (Post-Feature)

**Agent: ux-validator**

Prompts the agent to:
1. Build and install app
2. Launch and navigate to `AnalysisResultScreen`
3. Take screenshot `/tmp/fc_post_scorecard.png`
4. Check: scorecard present? visible at bottom? correct data shown? no layout overflow?
5. Report PASS/FAIL + screenshot

**If FAIL:** Stop sprint, report to user.

---

### Step 6: Commit Sprint Summary

Orchestrator commits a summary log to `.claude/sprint_log.md`:

```markdown
## Sprint [N] — [timestamp]

### Competitive Analysis
- ✅ Produced golf_tracer_competitive_analysis.md (7 apps surveyed)
- Key findings: [1-2 sentence summary from research]

### Tracer Improvement
- ✅ [failure reason fixed, file edited, metric delta]
- OR ❌ Skipped (no VisionLab data)

### UX Validation (post-tracer)
- ✅ PASS: trail visible, no crashes, layout correct

### Feature: Scorecard Overlay
- ✅ Implemented ScorecardOverlayView
- Data: shot shape, tempo ratio, contact confidence
- Visible if shotShapeConfidence >= 0.45

### UX Validation (post-feature)
- ✅ PASS: scorecard visible at bottom, correct metrics shown, no overflow

### Next Sprint Candidates
- [Feature 2 idea based on competitive analysis]
- [Feature 3 idea]

### Commits
- [commit hash] Competitive analysis
- [commit hash] Tracer improvement
- [commit hash] Scorecard overlay
- [commit hash] Sprint [N] complete
```

---

## Backlog of Features (Subsequent Sprints)

After scorecard is done, the feature-builder can tackle:

1. **Manual correction UI improvements** (from competitive analysis gaps)
2. **Slow-motion playback** (if competitors have it)
3. **Comparison mode** (vs. previous swings)
4. **Video annotations** (draw on frame, mark points)
5. **Swing plane visualization** (if pose landmarks allow)

Each feature follows the same cycle: feature-builder → ux-validator → commit.

---

## Loop Control

The orchestrator is invoked with:
```
/loop Sprint cycle for FlightCoach: improve accuracy, validate UX, build features
```

After each sprint completes, the loop can:
- **Continue:** User confirms → next sprint
- **Pause:** User requests break
- **Exit:** User types `/loop exit` or sprint encounters FAIL

---

## Debugging Notes

**Tracer improvement finds no failures:**
- VisionLab data may not exist (no golf-v1 dataset collected yet)
- Agent skips accuracy pass and reports "No VisionLab data"
- This is OK — UI feature work still proceeds

**UX validator shows FAIL:**
- Sprint halts; no commits; agent reports exact failure (e.g., "Scorecard text overflows video")
- Next sprint attempts fix or a different feature

**Feature builder gets stuck on compilation:**
- Likely import missing or coordinate conversion error
- Agent reports line number + error; manual intervention may be needed

---

## References

- **CLAUDE.md:** Full architecture, build commands, agent roles
- **Plan:** `/Users/edwardwilson/.claude/plans/cached-gliding-hamming.md`
- **Agents:** `.claude/agents/tracer-improver.md`, `.claude/agents/ux-validator.md`, `.claude/agents/feature-builder.md`, `.claude/agents/competitive-analyst.md`
