# Building Trimline

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
