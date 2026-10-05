# Trimline architecture

Three layers; dependencies only point down:

```
Trimline/ (app)                SwiftUI and AppKit: window, menus, keys, Finder
        │  commands and state
TrimlineCore/Model             EditorModel (@MainActor, @Observable), Selection, TimeFormat, FileNaming
        │
TrimlineCore/Engine            MediaEngine + PlaybackController, MediaOpener (engine chosen by probing)
TrimlineCore/FFmpeg            thin wrappers over the FFmpeg C API: demuxing, playback, remuxing, transcoding
TrimlineCore/Tasks             thumbnails, waveform and its cache, export, each in its own actor
```

The UI and `EditorModel` talk to the `MediaEngine` protocol and don't know which engine opened the file
([decision 0001](decisions/0001-two-engines.md)). Below the protocol everything runs off the main thread and is
cancelled when the file changes. Product behavior is described in [`spec.md`](spec.md).

## Where to change what

Paths without a prefix are under `TrimlineCore/Sources/TrimlineCore/`.

| To change | File |
| --- | --- |
| Handle behavior, key-frame snapping, I/O | `Model/EditorModel+Selection.swift` |
| Selection constraints (minimum length, edges) | `Model/Selection.swift` |
| Opening a file, window states | `Model/EditorModel.swift` |
| Choosing the engine | `Engine/MediaOpener.swift` |
| Playback of FFmpeg-opened files | `Engine/FFmpegPlaybackController.swift`, `FFmpeg/PlaybackPipeline.swift` |
| Saving: name, bounds, progress | `Model/EditorModel+Saving.swift`, `Tasks/Exporter.swift` |
| Saving by copying: streams, timestamps, container | `FFmpeg/Remuxer.swift`, `Tasks/ExportContainer.swift` |
| Where a copied clip starts (key-frame search shared by saving and the start-handle snap) | `FFmpeg/KeyframeSearch.swift`, `FFmpeg/RemuxStart.swift`, `FFmpeg/FFmpegKeyframeLocator.swift` |
| Blocking FFmpeg work off Swift's cooperative pool (actor executors on serial queues) | `Tasks/BlockingWork.swift` |
| Re-encoding: what gets encoded, codecs, bitrate, container | `FFmpeg/TranscodePlan.swift`, `FFmpeg/Transcoder.swift`, `FFmpeg/VideoEncoderSettings.swift`, `Tasks/ExportContainer.swift` |
| Smart cut: where the splice and the tail go, which containers and profiles, parameter sets at the splice | `FFmpeg/SmartCut.swift`, `FFmpeg/SmartCutVideo.swift`, `FFmpeg/NALBitstream.swift` |
| Choosing between `AVAssetExportSession` and FFmpeg | `Tasks/Exporter+AssetExport.swift` (`usesAssetExport`) |
| Clip contents (video and sound, video only, sound only), format of the sound alone | `Model/EditorModel+Saving.swift` (`effectiveExportContent`), `Tasks/ExportContainer+Sound.swift` |
| Saving and copying a frame: name, writing, banner state | `Model/EditorModel+Frame.swift`, `Model/FrameNaming.swift`, `Tasks/FrameImageWriter.swift`; banner and clipboard: `Trimline/UI/FrameExportBanner.swift`, `Trimline/App/FramePasteboard.swift` |
| Exact full-size frame: decoding, rotation, HDR | `Engine/AVFoundationEngine.swift` (`frameImage`), `FFmpeg/FFmpegFrameGrabber.swift`, `FFmpeg/FrameStillRenderer.swift` |
| Time format and parsing typed times | `Model/TimeFormat.swift` |
| Timeline look and gestures | `Trimline/UI/` |
| Timeline zoom and scrolling, time-to-point conversion | `Model/TimelineViewport.swift`, `Model/TimelineGeometry.swift` |
| Keys and menus | `Trimline/App/` |
| Remembering the selection of reopened files | `Model/EditorModel+SelectionMemory.swift`, `Model/SelectionMemory.swift` (what counts as the same file), `Tasks/SelectionStore.swift` (the file in Application Support) |
| Undo and redo of selection changes | `Model/SelectionHistory.swift`, `Model/EditorModel+History.swift`; Edit menu: `Trimline/App/SelectionUndo.swift` |
| Settings and the clip name template | `Trimline/App/AppSettings.swift`, `Trimline/UI/SettingsView.swift`, `Model/FileNameTemplate.swift` |
| Updates (Sparkle) | `Trimline/App/UpdaterService.swift`, `Trimline/UI/UpdateSettingsSection.swift`, `Config/Updates.xcconfig` |
| About window and licenses | `Trimline/App/Acknowledgements.swift`, `Trimline/UI/AboutView.swift`, `Trimline/Resources/Licenses/` |
| Hang detection | `Trimline/App/HangMonitor.swift` |
| Opening from Finder, the "Trim in Trimline" service | `Trimline/App/AppDelegate.swift`, `Trimline/Resources/Info.plist` |

## Rules

- `TrimlineCore` doesn't import SwiftUI and builds without the app: `swift test --package-path TrimlineCore`.
- Views only show the model's state and pass actions on; no calculations or disk access in them.
- Anything that reads the disk or decodes lives in an actor or a background task and is cancelled when the file
  changes.
- FFmpeg pointers and calls stay in `FFmpeg/`; the rest of the code sees Swift types (`Tasks/ExportContainer+Sound.swift`
  only matches codec IDs).
- Time crosses module boundaries as `TimeInterval` in seconds ([decision 0002](decisions/0002-time-type.md)).
- UI strings live only in `Localizable.xcstrings`; `TrimlineCore` has no user-facing text. Errors are enums and the
  UI picks the wording.
- `swift-format` (settings in `.swift-format`) runs in CI, and compiler warnings are errors.

Decisions and their reasons are in [`decisions/`](decisions/).
