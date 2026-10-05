# 0010. Clip contents: video only or sound only

**Decision.**

- For video with sound the save panel offers "Video and sound", "Video only" and "Sound only" (`ExportContent`).
  The choice lives in `EditorModel.exportContent`, resets when the file changes and is part of `SaveProposal` and
  `ExportRequest`. Audio files and video without sound get no choice. There is no setting for it: it is a decision
  about a particular clip, not a habit.
- Streams are dropped by the container rules (`ContainerRules.keeping`): "video only" leaves no room for audio,
  "sound only" none for the picture and subtitles. `Remuxer` and `TranscodePlan` don't know about the choice; they
  only see the rules. The "did we lose the picture or the sound" check takes into account that one of them was
  dropped on purpose.
- Sound alone is always copied (the mode is forced to saving without re-encoding) into the format of its codec,
  based on the first audio track (`ExportContainer+Sound.swift`):

  | Codec | File | Tracks |
  | --- | --- | --- |
  | AAC, ALAC | M4A | all, if M4A takes each of them; otherwise MKA with all |
  | MP3 | MP3 | first |
  | Opus | OPUS (Ogg) | first |
  | Vorbis | OGG | first |
  | FLAC | FLAC | first |
  | AC-3, E-AC-3 | AC3, EAC3 | first |
  | PCM | WAV; big-endian: AIFF; what neither takes: CAF | first |
  | Everything else (MP2, DTS, WMA…) | MKA | all |

  Cover art stays where the format can hold it (M4A, MP3, FLAC, MKA). Codecs that were re-encoded before
  (RealAudio, Monkey's Audio) still follow the `TranscodePlan` rules and end up in MKA as AAC or FLAC. There is no
  container-change warning, since the format is chosen on purpose; the panel simply says "The clip will be saved as
  M4A."
- The start of the sound alone doesn't snap to a key frame: the bound is the requested one, as for audio files.
- "Video only" with exact-frame saving of MOV, MP4, M4V and 3GP stays with `AVAssetExportSession`: the audio tracks
  are removed from an `AVMutableMovie` opened on the same file, and the session reads it just like the file itself.
  Other video, including SDR H.264 in these containers that gets a smart cut ([0009](0009-smart-cut.md)), goes
  through `Transcoder`, where the audio simply isn't in the plan.
- Size estimate for the free space check: for sound alone, the bitrate of the audio tracks; for video without
  sound, the total minus the audio; if the audio bitrate is unknown, the total.

**Why.**

- A format per codec rather than one for all: M4A, MP3 or OPUS open in any player or music app, and copying
  without re-encoding is only possible into a container that holds the codec. MKA takes anything, so it is the
  fallback.
- Ogg can technically hold several tracks, but players play the first one; several tracks are kept only in M4A and
  MKA, where they are visible and selectable.
- `AVMutableMovie` rather than `AVMutableComposition`: the movie keeps rotation, track metadata and format
  descriptions as they are, so HDR and Dolby Vision go the same way as without removing the sound; a composition
  would have to be rebuilt and all of that carried over by hand.

**Limitations.**

- Single-track formats keep the first audio track, not the one marked as default.
- Dolby Vision in "video only" has not been checked on a real recording (as in [0008](0008-precise-export.md)).
- PCM that WAV, AIFF and CAF all refuse (`pcm_bluray`, `pcm_dvd`) goes to MKA and, if Matroska refuses it too, is
  re-encoded by the `TranscodePlan` rules.

**Rejected.**

- Re-encoding the sound to AAC to have one format for everything: it loses quality and speed, and the point of
  "sound only" is to pull the track out quickly as it is.
- Raw `.aac` (ADTS) for AAC: M4A keeps metadata, cover art and several tracks, and M4A is the native AAC format on
  the Mac.
- A setting for the default clip contents: the choice is needed rarely and for a particular file.
