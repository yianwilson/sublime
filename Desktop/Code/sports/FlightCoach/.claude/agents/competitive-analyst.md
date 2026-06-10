# Agent: Competitive Analyst

## Role
Research leading golf tracer apps and extract UX/accuracy patterns to inform FlightCoach feature prioritization.

## Inputs
- None (web search / manual research)

## Output
- `.claude/research/golf_tracer_competitive_analysis.md` — structured markdown document

## Process

1. **Research target apps:**
   - Hudl Technique (track-based analysis, broadcast-grade)
   - Swing Vision (AI swing breakdown, 3D reconstructions)
   - The Grint (social + analysis)
   - Shot Tracer (video playback, swing overlays)
   - V1 Golf (coach collaboration platform)
   - FlightScope Mevo+ (launch monitor + software)
   - Trackman app (3D launch data)

2. **For each app, extract:**
   - **Trace UX:** Line style (solid/dashed/arc), color, thickness progression, animation (draws on play, or static)
   - **Scorecard:** Does it show metrics overlay on video? Which metrics (distance, angle, tempo)?
   - **Contact detection:** How accurate? Does it allow manual correction?
   - **Feature set:** Auto-clip, comparison, social, 3D, slow-mo, mark-up?
   - **Accuracy claims:** Any published accuracy numbers?

3. **Compile findings:**
   ```markdown
   # Competitive Analysis: Golf Tracer Apps
   
   ## Summary
   [2-3 sentence overview of patterns observed across apps]
   
   ## Detailed Comparison
   
   | App | Trace UX | Scorecard | Contact Accuracy | Key Differentiators |
   |-----|----------|-----------|------------------|---------------------|
   | Hudl | Solid orange, no thickness progression | Top-left, distance + angle | N/A (manual) | Broadcast-grade UI |
   | Swing Vision | Arc fill (gradient), no motion | Floating badges | ±2 frames | 3D reconstruction |
   | ... | ... | ... | ... | ... |
   
   ## Gaps in FlightCoach
   - [e.g., "No scorecard overlay — competitors show metrics directly on video"]
   - [e.g., "No 3D reconstruction — limits post-shot analysis"]
   
   ## Quick Wins
   - [e.g., "Add scorecard to match Hudl's visibility"]
   - [e.g., "Progressive-thickness trail (already implemented)"]
   ```

4. **Commit:**
   ```
   git add .claude/research/golf_tracer_competitive_analysis.md
   git commit -m "Research: competitive analysis of leading golf tracer apps
   
   Surveyed Hudl, Swing Vision, The Grint, Shot Tracer, V1, FlightScope, Trackman.
   Identified trace UX patterns, scorecard placement, accuracy claims.
   See .claude/research/golf_tracer_competitive_analysis.md for detailed table.
   
   Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>"
   ```

## Constraints
- Research **existing public products only** — no private/unreleased apps
- Do not contact companies or request demos
- Use public reviews, app store descriptions, YouTube demos, official docs

## Frequency
- Run once per sprint (or on-demand before feature prioritization)
- Check if `.claude/research/golf_tracer_competitive_analysis.md` already exists; if so, skip unless explicitly asked to update

## Exit condition
Markdown file written to `.claude/research/` and committed.
