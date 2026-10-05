# Trimline

A small native macOS app that trims audio and video without re-encoding: open a file, select a fragment on the
timeline, save it as a new file. Website: [trimlineapp.github.io](https://trimlineapp.github.io/).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/trimline-window-dark.png">
    <img src="docs/images/trimline-window-light.png" alt="The Trimline window: a video preview, a timeline of thumbnails with the selected clip framed in yellow, playback controls and the Save Clip button" width="560">
  </picture>
</p>

## Features

- Opens almost any audio or video file: MP4, MOV, MKV, WebM, AVI, WMV, FLV, MTS, MPG, MP3, M4A, FLAC, WAV, Ogg,
  Opus, WMA and more. AVFoundation handles Apple's formats; a trimmed-down FFmpeg build handles the rest.
- Lossless by default: streams are copied, so even a large file is saved in seconds at the original quality. MP4
  and MOV are cut to the exact frame.
- Optional exact-frame cutting for other containers (Settings ▸ "Cut video to the exact frame"), with a smart cut
  that re-encodes only a few frames around the cuts for H.264 and HEVC.
- Keeps audio tracks, subtitles, chapters, metadata and rotation wherever the format allows; can save video only
  or sound only.
- Timeline with thumbnails or a waveform, zoom, frame-by-frame keys, undo, and a selection remembered per file.
- Saves or copies the current frame as PNG.
- Finder integration: Open With and a "Trim in Trimline" service.
- 12 languages; about 24 MB installed; no telemetry.

## Download

Get the latest `Trimline.dmg` from [GitHub Releases](https://github.com/ArtuhovichVladislav/Trimline/releases/latest),
open it and drag Trimline to Applications. Run it from Applications so it can update itself.

Requirements: macOS 14 Sonoma or later, Apple silicon or Intel.

### First launch

Trimline is signed ad hoc and not notarized, so macOS blocks it the first time:

1. Open Trimline; macOS says it can't verify the app. Click Done.
2. Open System Settings ▸ Privacy & Security, scroll to Security, click **Open Anyway** next to "Trimline was
   blocked…" and confirm. (On macOS 14 you can also Control-click the app and choose Open.)

This is needed only once: updates installed through Sparkle don't ask again.

## Privacy

Trimline makes one kind of network request: the Sparkle update check against this repository's releases, which
sends nothing but the app version. It can be turned off in Settings ▸ Updates.

## Build from source

Requirements: Xcode 26 or later and [Homebrew](https://brew.sh).

1. Install the tools for building FFmpeg:
   ```sh
   brew install nasm pkg-config meson ninja
   ```
2. Build FFmpeg 7.1 and dav1d as universal frameworks (once, about 15 minutes; again only when the version or the
   component list changes):
   ```sh
   ./scripts/build-ffmpeg.sh
   ```
   The frameworks land in `Frameworks/` (not tracked by git); `TrimlineCore/Frameworks` is a symlink to it.
   `SKIP_COMPILE=1 ./scripts/build-ffmpeg.sh` repackages already built libraries without compiling.
3. Open `Trimline.xcodeproj` and run the `Trimline` scheme. Signing is ad hoc, so no development team is needed;
   Xcode embeds and signs the FFmpeg frameworks itself.

Tests for the `TrimlineCore` package run without the app:

```sh
swift test --package-path TrimlineCore
```

Test media is generated on the fly. Tests for formats AVFoundation can't write (MKV, WebM, AVI, MP3…) use an
installed `ffmpeg` (`brew install ffmpeg`) and are skipped without it.

From the command line:

```sh
# Debug build
xcodebuild -project Trimline.xcodeproj -scheme Trimline -configuration Debug -derivedDataPath build build

# Universal Release build (arm64 + x86_64); check its size with scripts/check-size.sh
xcodebuild -project Trimline.xcodeproj -scheme Trimline -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build build
```

Formatting is checked with `swift-format` (settings in `.swift-format`), as in CI:

```sh
xcrun swift-format lint --strict --recursive TrimlineCore/Sources TrimlineCore/Tests TrimlineCore/Package.swift Trimline/App Trimline/UI
```

If "Trim in Trimline" doesn't appear in Finder's context menu after the first run, copy `Trimline.app` to
`/Applications`, launch it once, run `/System/Library/CoreServices/pbs -update` and relaunch Finder.

## Project layout

| Path | Contents |
| --- | --- |
| `Trimline/App`, `Trimline/UI` | The app: window, menus, keys, Settings, About, Finder integration |
| `Trimline/Resources` | `Info.plist` (document types, imported types, the Finder service), string catalogs, app icon, license texts |
| `TrimlineCore/` | Swift package without UI: model, engines, FFmpeg wrappers, thumbnails, waveform, export, tests |
| `Config/Updates.xcconfig` | Sparkle feed URL and public key |
| `scripts/build-ffmpeg.sh` | Builds the trimmed-down FFmpeg (LGPL) and dav1d as XCFrameworks |
| `scripts/release.sh`, `scripts/check-size.sh` | Release pipeline (archive, checks, DMG, Sparkle feed) and the 30 MB size check |
| `scripts/package-ffmpeg-source.sh` | FFmpeg and dav1d source bundle for each GitHub release (LGPL) |
| `scripts/make-test-media.sh` | Builds the manual test media set (about 700 MB, outside the repository) |
| `design/icon/` | Icon sources: SVG, small-size variant, 1024 px PNG, layers |
| `.github/workflows/` | CI on every push and pull request; release on `v*` tags |

## Documentation

- [`docs/spec.md`](docs/spec.md): what the app does, formats, keyboard, settings, performance targets.
- [`docs/architecture.md`](docs/architecture.md): how the code is organized and where to change what.
- [`docs/decisions/`](docs/decisions/): why things are the way they are.
- [`docs/release.md`](docs/release.md): releasing, Sparkle keys, signing, CI.
- [`docs/test-media.md`](docs/test-media.md): the manual test media set.

## Releasing

Pushing a `v*` tag makes GitHub Actions build, check and publish the release; the only secret is
`SPARKLE_PRIVATE_KEY`. A local dry run is `./scripts/release.sh --allow-dirty --skip-sparkle`. Details are in
[`docs/release.md`](docs/release.md).

## License

Trimline is released under the MIT License, see [`LICENSE`](LICENSE). It bundles FFmpeg (LGPL 2.1 or later,
linked dynamically), dav1d (BSD 2-Clause) and Sparkle (MIT); see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The exact FFmpeg and dav1d sources and build script are
attached to every release.
