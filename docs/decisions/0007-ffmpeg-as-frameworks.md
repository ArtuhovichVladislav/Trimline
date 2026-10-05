# 0007. FFmpeg as a set of macOS frameworks

**Decision.** `scripts/build-ffmpeg.sh` builds FFmpeg 7.1 and dav1d (arm64 + x86_64, `--enable-small`) and wraps
each library in a `.framework` named after its header folder (`libavutil.framework`, `libavcodec.framework`…),
then in an XCFramework. `TrimlineCore` links them as `binaryTarget`s, and Swift sees the modules `libavformat`,
`libavcodec` and so on. The wrappers over the C API live in `TrimlineCore/Sources/TrimlineCore/FFmpeg/`.

**Why.**
- FFmpeg's headers include each other as `<libavutil/frame.h>`; with a framework named `libavutil` that path
  resolves by itself, without header search flags.
- SwiftPM and Xcode embed and sign `binaryTarget` frameworks themselves, so both `swift test` and the app build
  work.
- `--enable-small` shrank the libraries from 21 to 14 MB when this was decided. The current sizes against the
  budgets (FFmpeg 15 MB, dav1d 3 MB) are in the report of `scripts/check-size.sh`.
- Rewriting library paths (`install_name_tool`) needs spare room in the Mach-O headers, so everything links with
  `-headerpad_max_install_names`.

**Rejected.** An XCFramework of bare `.dylib` files: SwiftPM supports dynamic libraries outside a framework poorly,
and the headers would need flags. Static linking: the LGPL requires that the library can be replaced.
