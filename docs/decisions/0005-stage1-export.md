# 0005. Early export through AVAssetExportSession

**Status.** Superseded. Saving without re-encoding now goes through `libavformat` for every format
(`FFmpeg/Remuxer.swift`); `AVAssetExportSession` remains only for exact-frame saving of some MOV and MP4 files
([0008](0008-precise-export.md), [0009](0009-smart-cut.md)).

**Decision.** Before the FFmpeg build existed, saving without re-encoding went through `AVAssetExportSession` with
the passthrough preset, and exact-frame saving re-encoded with a system preset. The temporary file was on the same
volume and was moved into place only after success.

**Why.** It gave working saving for native formats from the first build.

**Limitations.** Not every stream and not all metadata were kept; passthrough doesn't write some formats (MP3, for
example). Hence the move to `libavformat`.
