# Trimline product specification

Trimline is a native macOS app that cuts a fragment out of almost any audio or video file in a couple of
seconds and saves it as a new file, leaving the original untouched. It is a compact window with a drop zone,
a small player, and a timeline with yellow trim handles. The name is *trim* + *line*, the trim line on the
timeline.

This document describes how the app behaves. How the code is organized is in
[`architecture.md`](architecture.md); why things are the way they are is in [`decisions/`](decisions/).

## Priorities

Four requirements outrank everything else and win any conflict between design choices:

1. **Formats.** Almost every file an ordinary user comes across opens and can be trimmed: video from phones,
   cameras, messengers and the web, music, voice messages and podcasts.
2. **Small size.** The installed app stays under 30 MB (it is about 24 MB). No Electron, no cross-platform
   frameworks, no libraries "just in case".
3. **Responsiveness.** The UI never freezes, including when opening a 50 GB file or saving a two-hour film.
4. **Safety.** The original file is never modified or overwritten. The result is written to a temporary file
   and appears on disk only when it is complete.

Out of scope: joining fragments, filters and effects, format conversion, subtitles as a feature, batch
processing.

## Technology

Swift and SwiftUI, with two media engines behind one interface: AVFoundation for Apple's native formats and a
trimmed-down build of the FFmpeg libraries for everything else. That is the only combination that gives nearly
every format, a small download and hardware decoding at the same time.

| Layer | Technology |
| --- | --- |
| Language | Swift 6 with strict concurrency checking |
| UI | SwiftUI; AppKit where needed (open and save panels, Services, opening files from Finder) |
| Minimum OS | macOS 14 Sonoma, Apple silicon and Intel. Liquid Glass on macOS 26, system materials on 14–15 |
| Native formats | AVFoundation (`AVPlayer`, `AVAssetImageGenerator`, `AVAssetReader`, `AVAssetExportSession`) |
| Other formats | FFmpeg 7.1 as dynamic libraries: `libavformat`, `libavcodec`, `libavutil`, `libswresample`, `libswscale`; dav1d for AV1 |
| Video output of the FFmpeg engine | `AVSampleBufferDisplayLayer`: H.264 and HEVC are decoded by VideoToolbox, other codecs by `libavcodec` |
| Audio output of the FFmpeg engine | `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` |
| Re-encoding | VideoToolbox hardware encoders (H.264, HEVC), AAC through AudioToolbox, FLAC from FFmpeg; no GPL encoders |
| Updates | Sparkle 2 |

Rejected: Electron, Tauri and Flutter (50–150 MB more, and their web engines don't play MKV, AVI or WMV
anyway); VLCKit and libmpv (tens of megabytes of dependencies and a playback model that is hard to fit to a
timeline); AVFoundation alone (no MKV, WebM, AVI, WMV, FLV or OGG); running an `ffmpeg` binary through
`Process` (poor progress and cancellation, and a process launch for every thumbnail or waveform chunk).

## Behavior

The app does one thing: open a file, select a fragment, save it as a new file.

### Opening a file

- Five ways: the "Choose in Finder…" button, dropping a file on the window in any state, dropping it on the
  Dock icon, the Finder context menu, and `open -a Trimline <file>`.
- The open panel shows audio and video by default but lets you pick any file: the content decides, not the
  extension.
- One window, one file. A new file replaces the current one without asking; there is no unsaved work apart from
  the handle positions. While a clip is being saved, Open, Open Recent and drops are disabled, and a file opened
  from Finder, the Dock or the service asks first whether to stop saving. Quitting during a save asks too.
- If a file can't be opened, the drop zone says why: the file is damaged or truncated, it contains no audio or
  video, or its codec (named) is not supported.
- Under the file name: kind, resolution, duration and size.
- A file opened again gets back the selection it was left with, with the playhead at the start of the clip; this
  is not an undo step. "The same file" means the same name, size and modification date: a moved file keeps its
  bounds, an edited or replaced one doesn't. A selection covering the whole file is not remembered. Bounds of the
  last 100 files are kept on this Mac only, in `~/Library/Application Support/<bundle id>/Selections.json`,
  without paths. Open Recent ▸ Clear Menu erases them too.

### Playback

- Buttons: play/pause, back and forward 5 seconds, loop clip. Next to them, the current time as `mm:ss.ss`, or
  `h:mm:ss.ss` for files of an hour or longer.
- Only the selection plays. If the playhead is outside it, playback starts at its beginning. Playback stops at the
  end of the selection, or starts over when looping.
- Volume follows the system; there is no volume control.

### Timeline and selection

- The yellow handles move the start and the end. Dragging inside the selection moves it as a whole; clicking the
  timeline moves the playhead.
- While a handle is dragged, the preview shows the frame under it, as in QuickTime Player.
- The selection is at least 0.1 s long. The handles can't cross.
- Clicking the start or end time turns it into a field for an exact value.
- Arrow keys move the selected handle by one frame (0.01 s for audio), by 1 second with Shift.
- Long files can be zoomed with a pinch or ⌘+ and ⌘−, and scrolled horizontally.
- Selection changes can be undone and redone (up to 100 steps).

### Saving a clip

- **By default nothing is re-encoded**: streams are copied, which takes seconds at any size and keeps the quality.
  MOV, MP4, M4V and 3GP are cut to the exact frame even so: frames before the cut stay in the file but are hidden
  by an edit list. In containers without edit lists, a video clip starts at the nearest earlier key frame: the
  start handle snaps to it when released, and the save panel shows the real bounds.
- **"Cut video to the exact frame"** is a checkbox in Settings, off by default. With it on, video is cut exactly
  to the frame. For H.264 and HEVC this is a smart cut: only the frames from the cut to the next key frame and a
  few frames before the end are re-encoded with the hardware encoder, the rest is copied, so even a long fragment
  saves in seconds. HEVC and HDR video in MOV and MP4 is saved through `AVAssetExportSession`, which keeps HDR
  and Dolby Vision metadata. Elsewhere, where a smart cut isn't possible (another codec or profile), the whole
  video is re-encoded, to its own codec if that is H.264 or HEVC and to HEVC otherwise. See decisions
  [0008](decisions/0008-precise-export.md), [0009](decisions/0009-smart-cut.md) and
  [0011](decisions/0011-save-mode-in-settings.md).
- The save panel doesn't offer a mode: saving always follows the setting.
- Audio files are always cut by copying. The precision is 20–30 ms, the length of one MP3 or AAC frame.
- All streams of the original are kept: every audio track, subtitles, chapters within the fragment, metadata
  and video rotation.
- **Clip contents.** For video with sound, the save panel offers "Video and sound" (the default), "Video only"
  (all audio tracks dropped) and "Sound only". Sound alone is always copied without re-encoding into the format of
  its codec: AAC and ALAC to M4A, MP3 to MP3, Opus to OPUS, Vorbis to OGG, FLAC to FLAC, AC-3 and E-AC-3 to AC3
  and EAC3, PCM to WAV or AIFF, anything else to MKA. The exact-frame setting doesn't apply to it, and its start
  is never snapped to a key frame. Opening another file resets the choice to "Video and sound"
  ([decision 0010](decisions/0010-track-choice.md)).
- The clip keeps the original container. If that container can't be written (RealMedia, Monkey's Audio), the
  clip becomes MKV or MKA and the save panel says so.
- Default name: `<name> (clip).<extension>`, then `(clip 2)` and so on; the word "clip" follows the app
  language. The folder is the original's. If that folder isn't writable, a save panel opens. A folder button next
  to the name opens the same panel to save this one clip elsewhere without changing the setting.
- Free space is checked before saving; the estimate is the bitrate times the length of the fragment.
- While saving, progress and a Cancel button are shown. The result goes to a temporary file on the same volume and
  is renamed to its final name only after it is complete.
- Afterwards: Show in Finder, Done and Share (the system share menu). The clip's icon in the panel can be dragged
  into Finder, a messenger or an email; the file itself goes with it.

### Frame as an image

- Save Frame (⇧⌘S) writes the frame under the playhead as PNG next to the original:
  `<name> (frame 01-23.45).png`, then `(frame 01-23.45 2)`. The time is in the UI format with colons replaced by
  hyphens. If the folder isn't writable or Settings say "Always ask where to save", a save panel opens. The file is
  written to a temporary file and renamed; an existing file is never overwritten.
- Copy Frame (⇧⌘C) puts the same frame on the clipboard (PNG, TIFF on request).
- For video, a Save Frame icon button sits next to Reset; Copy Frame is in its context menu.
- The frame is exact (not the nearest key frame), at full resolution, with rotation and pixel aspect ratio applied
  as in the player. HDR (PQ, HLG) is tone-mapped to SDR.
- A short banner over the video reports the result, with Show in Finder, and goes away by itself; errors are shown
  the same way. Decoding runs in the background and is cancelled when the file changes.

### Reset, another file, closing

- Reset sets the selection back to the whole file, moves the playhead to the start and forgets the bounds
  remembered for the file.
- "Another File…" opens the file chooser.
- The ✕ button next to it and File ▸ Close File (⌃⌘W) close the file and bring back the drop zone. ⌘W closes the
  window.

## Formats

The engine is chosen by probing, not by extension: AVFoundation tries first, and if it can't open the file or
finds no playable stream, FFmpeg takes over ([decision 0001](decisions/0001-two-engines.md)).

| Group | Formats and codecs | Engine | Clip saved as |
| --- | --- | --- | --- |
| Apple and phone video | MP4, MOV, M4V, 3GP; H.264, HEVC, ProRes | AVFoundation | Same container |
| Web video | MKV, WebM; VP8, VP9, AV1 | FFmpeg | Same container |
| Older and Windows video | AVI, WMV/ASF, FLV, F4V, MPG, VOB, OGV; MPEG-4 Part 2 (DivX, Xvid), MPEG-1/2, WMV 1–3, VC-1, Theora, H.263, MJPEG, DV | FFmpeg | Same container |
| Camera video | MTS, M2TS, TS (AVCHD) | FFmpeg | Same container |
| Read-only video | RM, RMVB | FFmpeg | MKV (RealVideo re-encoded to HEVC, RealAudio to AAC), with a notice |
| Apple audio | MP3, AAC/M4A, ALAC, WAV, AIFF, CAF, FLAC, AC-3 | AVFoundation | Same container |
| Other audio | Ogg Vorbis, Opus, WMA, WavPack, DTS, AMR | FFmpeg | Same container |
| Read-only audio | APE (Monkey's Audio) | FFmpeg | MKA (re-encoded to FLAC), with a notice |

AV1 is decoded by dav1d (BSD, about 2.5 MB) unless AVFoundation opens the file and the Mac decodes AV1 in
hardware (M3 and later).

The FFmpeg build (`scripts/build-ffmpeg.sh`):

- starts from `--disable-everything` and enables only the demuxers, muxers, decoders and parsers for the formats
  above, plus the bitstream filters needed for remuxing (`h264_mp4toannexb`, `hevc_mp4toannexb`, `aac_adtstoasc`,
  `vp9_superframe` and similar);
- enables `videotoolbox`, `audiotoolbox`, `libdav1d`, `libswresample` and `libswscale`; disables networking,
  devices, filters, the `ffmpeg` and `ffprobe` programs and the documentation;
- never uses `--enable-gpl` or `--enable-nonfree`, so the result is LGPL 2.1 (the script stops if either slips in);
- is universal (arm64 and x86_64).

## Finder integration

Trimline appears in the context menu of every audio and video file in two ways, under Open With and as a
"Trim in Trimline" item, without taking over double-click: files still open in QuickTime Player or whatever the
user chose.

- **Open With.** `Info.plist` declares `CFBundleDocumentTypes` with the `Viewer` role and
  `LSHandlerRank = Alternate` for `public.audiovisual-content`, `public.movie`, `public.audio` and specific types.
  Formats without a system type (MKV, WebM, FLV, WMV, APE, Opus and others) get `UTImportedTypeDeclarations`
  conforming to `public.movie` or `public.audio`; an imported declaration yields to an app that exports the type.
  The same declarations enable dropping files on the Dock icon.
- **Trim in Trimline.** A Service (`NSServices` with `NSSendFileTypes` `public.movie` and `public.audio`, handled
  by `NSApplication.servicesProvider`). Finder shows it at the bottom of the context menu, under Quick Actions or
  Services. The app calls `NSUpdateDynamicServices()` at launch so the item appears without a restart; users can
  turn it off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services. A Finder Sync extension would only
  work in folders the app watches.
- If the app isn't running when a file is opened from Finder, the window opens straight in the player. If several
  files are selected, the first one opens and the window shows "Opened 1 of 3 files".
- File ▸ Open Recent keeps the last 10 files.

## Interface

### Window and style

- One window, 560 pt wide by default and resizable from 480 to 1200 pt to lengthen the timeline; the height follows
  the content.
- A title bar without a toolbar.
- On macOS 26 the playback capsule uses `glassEffect(.regular, in: .capsule)` and the buttons use the `.glass` and
  `.glassProminent` styles; on macOS 14–15, `.regularMaterial` and standard capsule buttons.
- The accent color is the user's system accent. The trim frame is always yellow (`systemYellow`), as in QuickTime
  Player.
- Light and dark appearance follow the system.

### Window states

| State | What is shown | Leaves when |
| --- | --- | --- |
| Empty | Drop zone, "Choose in Finder…", supported formats | A file is chosen or dropped |
| File over the window | Highlighted frame; over the player, a "Release to open the file" layer | The file is dropped or dragged away |
| Loading | File row and an empty timeline with a spinner, shown only if opening takes longer than 0.3 s | The first frame is ready |
| Player | Preview (video only), timeline with thumbnails or a waveform, times, buttons | Saving, another file |
| Saving | Panel with the file name and the clip bounds, then progress | Done, cancelled, error |
| Error | The reason and an action, in the drop zone or the save panel | Another file, retry |

### Keyboard

| Action | Keys |
| --- | --- |
| Open a file | ⌘O |
| Close the file and return to the drop zone | ⌃⌘W |
| Save clip | ⌘S |
| Save frame as PNG | ⇧⌘S |
| Copy frame | ⇧⌘C |
| Play and pause | Space |
| Set clip start / end at the playhead | I / O |
| Previous / next frame (0.01 s for audio) | ← / →, or , / . |
| Back / forward 1 second | ⇧← / ⇧→ |
| Loop clip | L |
| Reset selection | ⌘R |
| Undo / redo a selection change | ⌘Z / ⇧⌘Z |
| Zoom the timeline in / out / to fit | ⌘+ / ⌘− / ⌘0 |
| Settings | ⌘, |

Single-key shortcuts work by physical key, so they work in any keyboard layout. With a handle selected, the arrow
keys move the handle instead of the playhead; Esc deselects it.

### Settings

- **Cut video to the exact frame** (off by default), with a short explanation below it of when it is needed.
- **Save clips:** next to the original, or always ask where to save.
- **Clip name:** a template where `{name}` stands for the original's name, with a live example; an invalid template
  falls back to the standard name.
- **Updates:** automatically check for updates (on by default) and automatically download and install them.

### Accessibility

- The trim handles are adjustable VoiceOver elements that announce their time. Every icon button has a label.
- Reduce Motion and Increase Contrast are respected.
- Text is never truncated with large system text or long translations.

## Languages

The app uses the system language: macOS picks the first preferred language Trimline has, or English if there is
none. There is no in-app language switch; a per-app language can be set in System Settings ▸ General ▸ Language &
Region ▸ Applications.

Supported: English, Russian, German, French, Spanish, Italian, Portuguese (Brazil), Japanese, Korean, Chinese
(Simplified and Traditional) and Ukrainian.

- All UI text lives in `Localizable.xcstrings`; the Finder service name and file type descriptions live in
  `InfoPlist.xcstrings` and `*.lproj/ServicesMenu.strings`, so the Finder menu is localized too.
- The name Trimline is never translated.
- The suffix in new file names is localized: "Vacation (clip).mov", "Urlaub (Clip).mov".
- Plurals use String Catalog variations.
- Numbers follow the region: file sizes come from `ByteCountFormatter`, and the decimal separator in times comes
  from the locale (`00:24.15` in English, `00:24,15` in Russian). The `mm:ss` structure is the same everywhere.
- Buttons and labels have no fixed widths: long translations wrap or widen the window instead of being truncated.

## Performance and large files

The main thread only draws the UI and never waits for the disk, a decoder or an encoder. Opening time doesn't
depend on file size: the app reads only the header and index and loads the rest as needed.

| Operation | Target | Conditions |
| --- | --- | --- |
| Launch to window | ≤ 0.5 s | Cold start, M1 |
| Open to first frame | ≤ 1 s | Any size, local SSD |
| Timeline thumbnails | first ≤ 0.3 s, all ≤ 2 s | Video up to 8K |
| Waveform | first data ≤ 0.5 s, complete ≤ 5 s | 2-hour MP3 |
| Handle drag response | ≤ 16 ms per frame | Always |
| Saving without re-encoding | ≤ 3 s per 10 GB of fragment | Limited by disk speed |
| Memory | ≤ 150 MB; ≤ 400 MB when re-encoding | Any file |

How:

- **Isolation.** Each engine and each background task (thumbnails, waveform, export) runs in its own actor. When
  the file changes, their tasks are cancelled and results for the old file are discarded.
- **Short probing.** The FFmpeg engine caps `probesize` and `analyzeduration` (5 MB and 5 s), so opening never
  scans the whole file looking for streams.
- **Thumbnails.** Only the visible frames, decoded from key frames only (`AVAssetImageGenerator` with unlimited
  tolerance; `AVDISCARD_NONKEY` in FFmpeg), appear one by one from left to right. When zoomed, only the visible
  part is loaded.
- **Waveform** (audio files only). Sound is decoded as a stream in chunks, never loaded whole. Peaks (min and max
  per bucket) are computed on the fly and drawn at once. Finished peaks are cached in
  `~/Library/Caches/<bundle id>/waveforms`, keyed by path, size and modification date, up to 100 MB.
- **Scrubbing.** While a handle is dragged, seeking is fast (to key frames); after release it is exact. At most one
  seek is in flight; intermediate ones are dropped.
- **Export.** Packets are copied as a stream through a fixed buffer. Progress comes from timestamps, and
  cancellation is checked on every packet. App Nap is disabled while saving (`ProcessInfo.beginActivity`).
- **Slow disks.** On external and network drives every operation shows its loading state without blocking the
  window.
- **Monitoring.** Debug builds log main-thread stalls over 100 ms; release builds write MetricKit hang reports
  to the local log.

## Privacy

Trimline collects no telemetry and needs no account. Its only network request is the Sparkle update check
(`SUEnableSystemProfiling = NO`, so it sends nothing but the usual `User-Agent` with the app version), and it can
be turned off in Settings ▸ Updates. Remembered selections and the waveform cache stay on the Mac.

## Distribution and updates

- Trimline is distributed outside the App Store and without an Apple Developer account: a DMG signed ad hoc, not
  notarized, attached to [GitHub Releases](https://github.com/ArtuhovichVladislav/Trimline/releases). This lets the
  app write the clip next to the original without extra dialogs, and keeps the question of LGPL and App Store terms
  from blocking releases.
- The price: on first launch the user approves the app once in System Settings ▸ Privacy & Security ▸ Open Anyway.
  Updates through Sparkle don't ask again.
- Updates come through Sparkle 2, signed with EdDSA. Without a Developer ID the EdDSA signature is the only thing
  Sparkle trusts, so the private key must never be lost or replaced. Details are in [`release.md`](release.md).

### Size budget

| Part | Budget |
| --- | --- |
| App code and resources | ≤ 5 MB |
| FFmpeg (universal) | ≤ 15 MB |
| dav1d | ≤ 3 MB |
| Sparkle | ≤ 5 MB |
| **Total** | **≤ 28 MB** |

`scripts/check-size.sh` warns when a part or the total is over budget and fails the build above 30 MB.

### Licenses

- Trimline's code is MIT ([`LICENSE`](../LICENSE)).
- FFmpeg (LGPL 2.1 or later) is linked only dynamically. The About window shows the notice and the license text;
  every GitHub release carries the exact FFmpeg and dav1d sources, the build script and any patches
  (`scripts/package-ffmpeg-source.sh`).
- dav1d (BSD 2-Clause) and Sparkle (MIT) need only a notice in the About window. All notices are in
  [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Testing

- **Unit and integration tests** in `TrimlineCore` (`swift test --package-path TrimlineCore`): time arithmetic,
  key-frame snapping, file naming, handle constraints, engine choice, and export on media generated on the fly
  (clip length matches the selection, stream count and types match the original, the original is unchanged).
- **Test media set** for manual checks before a release: phone video (HEVC, HDR, Dolby Vision, variable frame
  rate), messenger video and voice messages, screen recordings, 4K and 8K, 3-hour and 50 GB files, legacy formats,
  camera files, high-resolution and long audio, files with several tracks, subtitles, chapters and rotation, and
  damaged files. See [`test-media.md`](test-media.md).
