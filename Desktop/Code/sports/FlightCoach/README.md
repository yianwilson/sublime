# FlightCoach

A local-first iOS app for recording, importing, and analysing golf and tennis practice videos.
All analysis runs on-device using Apple Vision and AVFoundation. No backend. No cloud upload. No login.

## Supported Sports

| Sport  | Modes                           |
|--------|---------------------------------|
| Golf   | Range                           |
| Tennis | Serve, Rally, Forehand, Backhand |

## Features

- Import video from Photos or record directly with the camera
- Pose detection using Apple Vision (`VNDetectHumanBodyPoseRequest`)
- Ball tracking using inter-frame motion analysis (frame differencing)
- Impact / contact frame detection (ball movement + wrist acceleration heuristics)
- Pose overlay (green skeleton) and ball trail overlay (orange trail)
- Rule-based, deterministic feedback cards
- Confidence scores on every metric
- Manual correction of impact frame, shot type, and camera angle
- Session history with thumbnail browser
- Full offline operation

## Golf Metrics

| Metric              | How computed                          | Note                         |
|---------------------|---------------------------------------|------------------------------|
| Tempo ratio         | Backswing frames / downswing frames   | Estimate, not exact          |
| Head movement       | Nose landmark displacement            | 2D image-space only          |
| Spine angle change  | Shoulder–hip angle at address vs contact | 2D only                   |
| Hip sway            | Hip X-position at address vs contact  | 2D only                      |
| Balance at finish   | Hip–ankle midpoint alignment          | 2D only                      |
| Shot shape          | Ball trail curvature (behind angle)   | Requires specific camera angle|

## Tennis Metrics

| Metric              | How computed                          |
|---------------------|---------------------------------------|
| Contact point       | Wrist position relative to hip        |
| Balance at contact  | Hip–ankle midpoint alignment          |
| Follow-through      | Wrist trajectory direction post-contact |
| Body rotation       | Shoulder angle change through swing   |

## What is NOT measured

These metrics require specialist hardware or a backend and are explicitly excluded:

- Ball speed / racquet head speed
- Carry distance
- Spin rate
- Launch angle
- Smash factor
- Exact landing location

## Architecture

```
FlightCoach/
├── App/                       # Entry point, ContentView
├── Core/
│   ├── Models/                # PracticeSession (SwiftData), AnalysisResult, PoseFrame, BallTrackPoint
│   ├── Repository/            # SessionRepository (SwiftData CRUD)
│   └── Services/
│       ├── CameraManager          # AVCaptureSession recording
│       ├── VideoImportManager     # PhotosUI import
│       ├── VideoStorageService    # Local file storage
│       ├── VideoFrameExtractor    # AVAssetReader frame extraction
│       ├── PoseDetectionService   # Vision VNDetectHumanBodyPoseRequest
│       ├── BallTrackingService    # Frame-differencing ball tracker
│       ├── ContactDetectionService# Impact/contact frame heuristics
│       ├── GolfAnalysisService    # Golf metrics computation
│       ├── TennisAnalysisService  # Tennis metrics computation
│       ├── FeedbackEngine         # Rule-based deterministic feedback
│       ├── OverlayRenderer        # SwiftUI Canvas overlays
│       ├── ManualCorrectionService# User overrides
│       └── AnalysisPipeline       # Orchestrates the full pipeline
├── Features/
│   ├── Home/                  # HomeScreen
│   ├── SportSelect/           # SportSelectScreen
│   ├── SessionSetup/          # SessionSetupScreen (mode, angle, video source)
│   ├── Analysis/              # CameraRecordingScreen, AnalysisProgressScreen,
│   │                          # AnalysisResultScreen, ManualCorrectionSheet
│   ├── Playback/              # VideoPlayerView, FrameScrubberView
│   ├── SessionHistory/        # SessionHistoryScreen
│   └── Settings/              # SettingsScreen
└── Shared/
    ├── Components/            # FeedbackCard, MetricCard, ConfidenceBadge, etc.
    ├── Extensions/
    └── Utilities/             # AppTheme
```

## Setup

1. Open `FlightCoach.xcodeproj` in Xcode 15+.
2. Select your device or a simulator.
3. Build and run (⌘R).
4. No API keys or environment variables needed.

If you want to regenerate the project file from `project.yml`:

```bash
brew install xcodegen
xcodegen generate
```

## Extending for a backend (future)

The architecture is designed to add a backend later without structural changes:

- `VideoStorageService` can be extended to upload to S3/GCS after local save.
- `SessionRepository` wraps SwiftData — add a remote sync layer alongside it.
- `AnalysisPipeline` is a standalone actor — swap in a remote inference endpoint by replacing individual service calls.
- All data models are `Codable`, ready for API serialisation.

## Confidence system

Every metric and feedback item carries a `confidence: Float` in `[0, 1]`.

| Range     | Meaning                                    |
|-----------|--------------------------------------------|
| ≥ 0.70    | High — Vision detected clearly             |
| 0.40–0.69 | Medium — estimated, check manually         |
| < 0.40    | Low — displayed with orange warning banner |

Low-confidence metrics show "Low confidence" labels and the feedback engine surfaces a warning card prompting the user to use Manual Corrections.

## Known limitations

- Ball tracking works best with good contrast between ball and background.
- Pose detection requires the full body to be visible in frame.
- Shot shape requires the "Behind Ball Flight" camera angle.
- All metrics are 2D image-space — no 3D reconstruction.
- Slow devices may take 20–60 seconds to process a 30-second video.
