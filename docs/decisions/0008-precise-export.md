# 0008. Exact-frame saving: two re-encoding paths, and re-encoding of incompatible streams

**Decision.**

- Exact-frame saving of video that AVFoundation decodes and whose container stays the same (MOV, MP4, M4V, 3GP)
  goes through `AVAssetExportSession`, except SDR H.264, which gets a smart cut ([0009](0009-smart-cut.md)). For
  H.264 and HEVC the session doesn't actually re-encode: it copies the samples and hides the extra ones with an
  edit list. H.264 and HEVC in other containers also get a smart cut where possible. All other video is
  re-encoded by `FFmpeg/Transcoder.swift`: `libavcodec` decodes from the key frame up to the start, frames before
  the start are dropped, and the picture is encoded with `hevc_videotoolbox` or `h264_videotoolbox` (H.264 stays
  H.264, everything else becomes HEVC, 10-bit becomes HEVC Main 10); audio, subtitles and cover art are copied as
  packets.
- The container depends on the mode (`ExportContainer.forSource(_:mode:)`): if the source container doesn't take
  the new picture codec (HEVC in WebM, AVI, FLV, ASF, MPEG-PS, OGG), the clip becomes MKV and the save panel warns
  about the container change.
- In both modes, whatever the clip's container can't hold is re-encoded, as is everything from RealMedia:
  RealVideo → HEVC, Cook and other RealAudio → AAC (`aac_at`), Monkey's Audio and other lossless audio → FLAC (the
  LGPL `flac` encoder is in the build). Everything else is still copied by `Remuxer` when saving without
  re-encoding.

**Why.**

- iPhone video, the main source, is HEVC with HDR and Dolby Vision. According to Apple's documentation the HEVC
  presets of `AVAssetExportSession` preserve HDR, and the system handles Dolby Vision metadata itself; the FFmpeg
  path carries over only color tags and static HDR metadata and loses the Dolby Vision RPU. For these files the
  system path is no slower and already proven.
- For MKV, WebM, AVI and the rest `AVAssetExportSession` doesn't apply, and exact-frame saving has to work for all
  video.
- The picture bitrate is the source's (of the stream, or of the file minus the audio), but no less than 0.05 and
  no more than 0.5 bits per pixel per frame; 0.15 when the bitrate is unknown. A key frame every 2 s, so the clip
  is easy to cut again.
- Memory: each decoder thread holds several frames of its own, about 180 MB per thread for 4K 10-bit HEVC. The
  thread count follows the frame size (160 MB budget): 1–2 threads for 4K, 8 for Full HD. Measured on 4K 10-bit
  HEVC, VP9 and H.264: a peak of 230–250 MB against the 400 MB target; speed is limited by the hardware encoder
  (~60 fps in 4K on M-series), not by the decoder.
- RealMedia codecs can formally be written to MKV (RV40, RealAudio 14.4) but only FFmpeg-based players read them,
  and RV40 has no presentation timestamps. After re-encoding the clip opens wherever MKV does.

**Limitations.**

- The Dolby Vision RPU, HDR10+ and CEA-608 captions are not kept on the FFmpeg path; interlaced video is encoded
  as progressive.
- HEVC re-encoded into MOV, MP4 and M4V is tagged `hvc1` instead of `hev1`, which `libavformat` uses by default:
  AVFoundation and QuickTime don't open files tagged `hev1`.
- Decoding for re-encoding is done in software: hardware decoders (hwaccel) are not in the build.
- AAC in MKV stores the encoder delay (CodecDelay), so the length in the header is longer by that delay (~50 ms at
  44.1 kHz).
- Audio without timestamps after the clip start is laid out by sample count: gaps inside the clip collapse.
- Not yet checked on a real Dolby Vision recording.

**Rejected.**

- A single path through `Transcoder` for every format: it loses on Dolby Vision, and the gain is one code path
  instead of two.
- MP4 as the fallback container: MKV holds any audio and subtitles the source can copy (Vorbis, Opus, WMA,
  SubRip); in MP4 they would have to be re-encoded or dropped.
- Copying RV40 and RealAudio 14.4 into MKV for speed: a clip that only VLC opens is worse than a slightly longer
  save.
