# 0009. Smart cut for exact-frame saving

**Decision.**

- For H.264 and HEVC, exact-frame saving doesn't re-encode the whole picture, only the **head**, the frames from
  the clip start to the **splice** (the nearest key frame from which copying can start), and, if needed, the
  **tail**, a few frames before the end. Everything in between is the source's packets as they are; audio and
  subtitles are copied as before (`FFmpeg/SmartCut.swift`, `FFmpeg/SmartCutVideo.swift`,
  `FFmpeg/NALBitstream.swift`).
- Where it applies:

  | Container | H.264 | HEVC |
  | --- | --- | --- |
  | MKV | smart cut | smart cut |
  | MPEG-TS (TS, MTS, M2TS) | smart cut | smart cut |
  | MOV, MP4, M4V | smart cut if the video is SDR | `AVAssetExportSession`, as before |
  | FLV, 3GP and others | fully re-encoded, as before | — |

  The profile must be one the hardware encoder writes: H.264 Baseline, Main or High (8-bit 4:2:0), HEVC Main or
  Main 10; the video must be progressive. Everything else (High 10, 4:2:2, 4:4:4, interlaced, MPEG-4, VP9…) is
  fully re-encoded as in [0008](0008-precise-export.md).
- **Splice.** In H.264 only an IDR frame qualifies: at the key frame of an open GOP (a recovery point) the
  parameters can't change, and its B-frames refer to the previous GOP. In HEVC any random access picture (IDR, CRA,
  BLA) qualifies. Leading pictures after the splice (RASL, RADL: after it in decoding order but shown earlier) are
  dropped from the copy; the head decodes them from the source and encodes them itself. A CRA at the splice is
  rewritten as BLA_N_LP by changing one type in the NAL header: only a "broken link" picture starts a new sequence
  in which the parameters may change, and it no longer has leading pictures. The splice is searched for within 5
  minutes of the start; if there is none before the clip end (or at all), the whole clip is re-encoded. If the
  start is exactly on a splice, there is no head.
- **Tail.** Frames shown before the end may refer to a frame shown after it (a P-frame at the end of a mini-GOP
  with B-frames). The copy ends at the last point in decoding order where everything before it is shown before
  everything after it; the frames from that point to the end are re-encoded by a separate session. Usually that
  is 0–3 frames. Without the tail the clip would be a frame or two longer than asked, and MKV and TS have no way to
  hide them.
- **Parameter sets (SPS/PPS/VPS).** VideoToolbox writes its own sets with the same IDs as the source (0), so they
  replace each other in the decoder. The head and the tail carry their sets before every key frame (the encoder
  runs without a global header), and every copied key frame gets the source's sets in front of it if it doesn't
  have them already: otherwise a player that showed the head and then seeked into the middle would decode the copy
  with the wrong sets. The track header (avcC/hvcC in MP4 and MKV) stays the source's, since nearly the whole file
  decodes with it. All other packets after the splice are byte-for-byte identical to the source.
- **Timing.** The head and the tail are encoded without B-frames, so their DTS = PTS − delay, where the delay is
  the PTS − DTS difference of the frame at the splice. That way DTS keeps increasing at the splice and into the
  tail, and PTS stays continuous. The encoder gets the source's time base, frame rate, size, color tags and bitrate
  (`VideoEncoderSettings.makeHeadEncoder`), and the same profile as the source.
- Trimline's player (`CompressedVideoSource`) sees parameter sets inside a key frame and, if they don't match the
  stream header, creates its own format description for those frames.
- MPEG-TS is sought by decoding time, while the file start is by presentation time, so seeking "to the start"
  skipped the first GOP. For TS and MPEG-PS `RemuxStart` seeks one second before the start (which also fixes
  saving without re-encoding).

**Why.**

- A two-hour film saves with exact frames in seconds, and the quality changes only in the head and the tail.
  Measured on M-series, one minute of 1080p30 from MKV: H.264 0.41 s against 6.7 s for full re-encoding, HEVC
  0.43 s against 7.0 s; memory peak 160–210 MB. The head is about 46–48 dB PSNR against the source; the copy is
  bit-exact.
- Sets before every key frame rather than different IDs: VideoToolbox's sets can only be renumbered together with
  the slice headers, which means fully parsing H.264 and HEVC slice headers and fixing up their alignment, a lot
  of code for the same result. Repeating the sets is what MPEG-TS always does anyway.
- Without B-frames in the head, DTS doesn't need to be shifted: offsetting by the splice delay keeps timestamps
  unambiguous.
- HEVC in MOV and MP4 stays with `AVAssetExportSession`: AVFoundation's HEVC decoder rejects in-band parameter
  sets that differ from the format description (error −12137 on the very first head frame), and `libavformat` 7.1
  writes only one format description per track. With H.264 the same scheme decodes frame-accurately in
  AVFoundation, which the tests check through `AVAssetReader`.
- HDR and Dolby Vision in MOV/MP4 stay with the session ([0008](0008-precise-export.md)). Noticed while testing:
  for H.264 and HEVC the `HighestQuality` presets on this macOS don't re-encode but copy the samples and hide the
  extra ones with an edit list, the same as saving without re-encoding. A smart cut of SDR H.264 gives a file
  without hidden frames that cuts the same in every player, at the cost of a re-encoded head.
- The tests build sources on the fly (ffmpeg), compare every frame of the clip with the source frame by color
  in FFmpeg and in the system decoder (AVFoundation for MP4/MOV, VideoToolbox through `CompressedVideoSource` for
  MKV and TS), check that copied packets match the source's, and cover an x265 open GOP, a start on a key frame,
  an end between references, an end before the next key frame, an unsuitable profile, and cancellation.

**Limitations.**

- Only H.264 and HEVC in the profiles the hardware encoder writes; H.264 with open GOPs and no IDR frames is fully
  re-encoded.
- The head carries no Dolby Vision RPU or HDR10+ SEI: in MKV and TS with Dolby Vision the first second may show as
  HDR10. VideoToolbox picks the head's level, which may differ from the one in the header.
- Players that don't accept in-band parameter set changes will show the head wrongly. Checked with FFmpeg,
  AVFoundation (H.264) and Trimline's player; hardware players (TVs, Infuse) were not checked.
- Checked on generated videos; not yet checked on real iPhone footage (SDR H.264 in MOV) or in QuickTime Player.

**Rejected.**

- Renumbering VideoToolbox's parameter sets (see "Why").
- Several format descriptions in MP4 (an stsd with two entries): this version of `libavformat` doesn't support
  them, and patching the `moov` atom after writing would be a separate MP4 editor.
- `avc3` and `hev1` (parameter sets in-band only): AVFoundation doesn't open such files.
- `AVMutableComposition` with a re-encoded head and a passthrough copy for MOV/MP4 (AVFoundation would then write
  two format descriptions itself): a third saving path for the same files just for HEVC, and audio, subtitles and
  metadata would have to be carried over by hand. Not tried; a candidate if HEVC in MP4 is ever needed.
