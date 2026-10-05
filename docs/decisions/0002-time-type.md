# 0002. Time is a `TimeInterval` in seconds

**Decision.** Time crosses module boundaries as `TimeInterval` (seconds from the start of the file). `CMTime` is
used only inside the engines, and frames only when computing a step (`MediaInfo.frameStep`).

**Why.** One simple type for the model, the UI and the tests; `Double` is precise enough for any duration with
room to spare (nanoseconds over hours). The FFmpeg engine converts to its streams' `time_base` locally in the same
way.

**Rejected.** A custom wrapper type: extra noise with no gain in safety. `CMTime` in the model: it pulls
CoreMedia into the UI and complicates the arithmetic.
