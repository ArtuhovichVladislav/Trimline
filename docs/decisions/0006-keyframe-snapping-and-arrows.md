# 0006. Key-frame snapping only without an edit list; arrows step by frame

**Decision.** When saving without re-encoding, the clip start snaps to a key frame only if the container has no
edit list (`StreamCopyStart.isExact`). MOV, MP4, M4V, M4A and 3GP are cut exactly even when copying: the extra
frames before the cut stay in the file but are hidden by the edit list. The ← → keys step by one frame, by 1 second
with Shift; the 5-second skip buttons show the interval on their icons.

**Why.** In videos with rare key frames (screen recordings, x264 by default: one every 8–10 s) the start handle
jumped back to the start of the file when released, which looked like trimming didn't work. A test with
`avconvert --preset PresetPassthrough --start 3` on a video with key frames at 0 and 8.3 s produced a clip of
exactly 2.00 s whose first frame is at 3 s. A 1-second arrow step was unexpected and too coarse for precise
positioning.

**Rejected.** Snapping in every container, as originally specified.
