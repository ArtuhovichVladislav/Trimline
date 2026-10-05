# 0011. Save mode is a setting, not a choice in the save panel

**Decision.** The save panel doesn't offer a mode: a clip is always saved according to the setting. By default
nothing is re-encoded: MOV, MP4, M4V and 3GP are cut to the exact frame with an edit list, and in other containers
the start handle snaps to a key frame ([0006](0006-keyframe-snapping-and-arrows.md)). Exact-frame cutting
([0008](0008-precise-export.md), [0009](0009-smart-cut.md)) is turned on with the "Cut video to the exact frame"
checkbox in Settings, with an explanation below it of when it is needed. A stored value from earlier versions
(`defaultSaveMode` = `precise`) shows as a checked box. The checkbox doesn't apply to MOV, MP4, M4V and 3GP: they
are always saved without re-encoding (`EditorModel.effectiveExportMode`), since the edit list already makes the
copy exact.

**Why.**

- Users don't know what a key frame is, and choosing a mode before every save tells them nothing.
- Mainstream apps (QuickTime Player, Photos) trim without any choice. Apps that show "fast" and "re-encode" modes
  keep FAQ entries about why the clip started earlier.
- LosslessCut cuts at key frames by default and keeps smart cut as a separate option. For MOV and MP4, the main
  source, saving without re-encoding is already frame-exact.
- Re-encoding those containers anyway would cost time and quality for nothing the user asked for. The price is
  that the frames before the cut stay in the file, hidden by the edit list; a player that ignores edit lists shows
  them, where a smart cut ([0009](0009-smart-cut.md)) would not have kept them.

**Rejected.**

- A mode choice in the save panel with a hint under each option (start shift, what gets re-encoded): it explains
  key frames instead of sparing the user from them.
- Smart cut by default: it hasn't been checked on hardware players, and the limitations of
  [0009](0009-smart-cut.md) (in-band parameter sets, a head without Dolby Vision) would affect everyone.
