# 0003. Playback on the main actor

**Decision.** `MediaEngine` (opening, thumbnails, waveform, key frames) works off the main thread, while
`PlaybackController` is `@MainActor`.

**Why.** In the macOS 26 SDK `AVPlayer` is isolated to the UI actor (`NS_SWIFT_UI_ACTOR`). Its calls don't block:
seeking and starting are asynchronous, so the rule "the main thread never waits for the disk" still holds. The
FFmpeg player built on `AVSampleBufferDisplayLayer` implements the same protocol, and packet reading runs in its
own actor (`PlaybackPipeline`).

**Rejected.** An engine actor with an `AVPlayer` inside, as first sketched: it contradicts the isolation of the
system class.
