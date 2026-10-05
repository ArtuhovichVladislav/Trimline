#!/usr/bin/env bash
# Builds a trimmed-down FFmpeg (LGPL 2.1) and dav1d for Trimline.
# Output: Frameworks/*.xcframework, universal (arm64 + x86_64) dynamic libraries.
#
# Prerequisites (once):  brew install nasm pkg-config meson ninja
# Run from the project root:  ./scripts/build-ffmpeg.sh
#
# The component lists below follow the formats in docs/spec.md. Size budget: FFmpeg ≤ 15 MB, dav1d ≤ 3 MB
# (scripts/check-size.sh).

set -euo pipefail

FFMPEG_VERSION="n7.1"
DAV1D_VERSION="1.5.1"
MIN_MACOS="14.0"
ARCHS=(arm64 x86_64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build-ffmpeg"
OUT="$ROOT/Frameworks"
mkdir -p "$WORK/src" "$OUT"

# ---------- Components ----------
DEMUXERS=(mov matroska avi asf flv mpegts mpegps ogg rm mp3 aac wav w64 aiff caf flac ac3 eac3 dts wv ape amr dv mpegvideo)
# configure names: 3gp is tgp, mpg is mpeg1system, vob is mpeg2vob.
MUXERS=(mov mp4 ipod tgp matroska webm avi asf flv mpegts mpeg1system mpeg2vob ogg oga opus mp3 adts wav w64 aiff caf flac ac3 eac3 dts wv amr dv)
DECODERS=(
  h264 hevc prores vp8 vp9 av1 libdav1d mpeg4 msmpeg4v1 msmpeg4v2 msmpeg4v3 mpeg1video mpeg2video
  wmv1 wmv2 wmv3 vc1 theora h263 flv mjpeg dvvideo rv10 rv20 rv30 rv40 vp6 vp6f vp6a
  aac aac_latm mp3 mp3float mp2 alac flac ac3 eac3 dca vorbis opus wmav1 wmav2 wmapro wmalossless
  wavpack ape amrnb amrwb cook sipr ra_144 ra_288 adpcm_ima_qt adpcm_ms
  pcm_s8 pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be pcm_f32le pcm_f32be pcm_f64le pcm_alaw pcm_mulaw
)
ENCODERS=(h264_videotoolbox hevc_videotoolbox aac_at flac)   # precise saving and re-encoding of sound the clip's container can't hold
PARSERS=(h264 hevc vp8 vp9 av1 mpeg4video mpegvideo vc1 h263 mjpeg aac aac_latm mpegaudio ac3 dca flac opus vorbis)
BSFS=(h264_mp4toannexb hevc_mp4toannexb aac_adtstoasc vp9_superframe vp9_superframe_split extract_extradata)

join() { local IFS=,; echo "$*"; }

# ---------- Sources ----------
cd "$WORK/src"
[ -d ffmpeg ] || git clone --depth 1 --branch "$FFMPEG_VERSION" https://github.com/FFmpeg/FFmpeg.git ffmpeg
[ -d dav1d ]  || git clone --depth 1 --branch "$DAV1D_VERSION" https://code.videolan.org/videolan/dav1d.git dav1d

# ---------- dav1d ----------
build_dav1d() {
  local arch=$1 prefix="$WORK/$1"
  local cross="$WORK/cross-$arch.txt"
  cat > "$cross" <<EOF
[binaries]
c = ['clang', '-arch', '$arch', '-mmacosx-version-min=$MIN_MACOS']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = '$( [ "$arch" = arm64 ] && echo aarch64 || echo x86_64 )'
cpu = '$arch'
endian = 'little'
[built-in options]
c_link_args = ['-Wl,-headerpad_max_install_names']
EOF
  rm -rf "$WORK/dav1d-$arch"
  meson setup "$WORK/dav1d-$arch" "$WORK/src/dav1d" --cross-file "$cross" \
    --prefix "$prefix" --libdir lib --default-library shared --buildtype release \
    -Denable_tools=false -Denable_tests=false
  ninja -C "$WORK/dav1d-$arch" install
}

# ---------- FFmpeg ----------
build_ffmpeg() {
  local arch=$1 prefix="$WORK/$1"
  rm -rf "$WORK/ffmpeg-$arch" && mkdir -p "$WORK/ffmpeg-$arch" && cd "$WORK/ffmpeg-$arch"
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" "$WORK/src/ffmpeg/configure" \
    --prefix="$prefix" \
    --arch="$arch" --target-os=darwin --enable-cross-compile \
    --cc="clang -arch $arch" \
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
    --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -Wl,-headerpad_max_install_names" \
    --enable-small \
    --install-name-dir='@rpath' \
    --enable-shared --disable-static --enable-pic \
    --disable-programs --disable-doc --disable-network --disable-avdevice --disable-avfilter \
    --disable-everything \
    --disable-autodetect \
    --enable-protocol=file \
    --enable-demuxer="$(join "${DEMUXERS[@]}")" \
    --enable-muxer="$(join "${MUXERS[@]}")" \
    --enable-decoder="$(join "${DECODERS[@]}")" \
    --enable-encoder="$(join "${ENCODERS[@]}")" \
    --enable-parser="$(join "${PARSERS[@]}")" \
    --enable-bsf="$(join "${BSFS[@]}")" \
    --enable-videotoolbox --enable-audiotoolbox --enable-libdav1d \
    --enable-zlib --enable-bzlib \
    --enable-swscale --enable-swresample
  # License guard: the build must never be GPL or nonfree
  if grep -Eq '^#define CONFIG_(GPL|NONFREE) 1' config.h; then echo "GPL/nonfree is enabled, stopping"; exit 1; fi
  make -j"$(sysctl -n hw.ncpu)" && make install
}

# SKIP_COMPILE=1 repackages the libraries already built, without compiling again
if [ "${SKIP_COMPILE:-0}" != 1 ]; then
  for arch in "${ARCHS[@]}"; do
    build_dav1d "$arch"
    build_ffmpeg "$arch"
  done
fi

# ---------- Merge into universal dylibs ----------
U="$WORK/universal"; rm -rf "$U"; mkdir -p "$U/lib"
cp -R "$WORK/arm64/include" "$U/include"
for lib in "$WORK/arm64/lib/"*.dylib; do
  [ -L "$lib" ] && continue                 # skip symlinks, take the real files
  real=$(basename "$lib")
  lipo -create "$WORK/arm64/lib/$real" "$WORK/x86_64/lib/$real" -output "$U/lib/$real"
  strip -x "$U/lib/$real"
done

# ---------- Frameworks ----------
# Each library becomes a macOS framework named after its header folder (libavutil and so on):
# then #include <libavutil/frame.h> inside FFmpeg's headers resolves as a framework header,
# and SwiftPM and Xcode embed and sign the frameworks of a binaryTarget themselves.
LIBS=(libavutil libswresample libswscale libavcodec libavformat libdav1d)
# Each header must belong to exactly one module, or Swift sees its declarations only in files that
# happen to be compiled together with an importer of the "owning" module. So every header of the
# library goes into its module map, except bindings for other platforms' APIs.
NON_APPLE_HEADERS='^(hwcontext_(cuda|d3d11va|d3d12va|drm|dxva2|mediacodec|opencl|qsv|vaapi|vdpau|vulkan|amf)|d3d11va|d3d12va|dxva2|jni|mediacodec|qsv|vdpau|xvmc)\.h$'
module_headers() {
  [ "$1" = libdav1d ] && return
  ls "$U/include/$1" | grep '\.h$' | grep -Ev "$NON_APPLE_HEADERS"
}

dylib_of() { ls "$U/lib/$1".*dylib | head -n 1; }
binary_in_framework() { echo "@rpath/$1.framework/Versions/A/$1"; }

F="$WORK/frameworks"; rm -rf "$F"; mkdir -p "$F"
for name in "${LIBS[@]}"; do
  fw="$F/$name.framework"; v="$fw/Versions/A"
  mkdir -p "$v/Resources"
  cp "$(dylib_of "$name")" "$v/$name"
  install_name_tool -id "$(binary_in_framework "$name")" "$v/$name"
  for dep in "${LIBS[@]}"; do
    # Each slice of the universal binary refers to the dylibs of its own build folder (arm64/, x86_64/)
    for old in $(otool -arch all -L "$v/$name" | awk '{print $1}' | grep "/$dep\.[0-9]*\.dylib$" | sort -u); do
      install_name_tool -change "$old" "$(binary_in_framework "$dep")" "$v/$name"
    done
  done
  # Dependency lines start with a tab; the first output line is the file's own path (inside $WORK).
  # Only the bundle and the OS may be linked: a Homebrew library found on the build machine (configure
  # picked up libX11 on a CI runner once) is missing on users' Macs.
  outside="$(otool -arch all -L "$v/$name" | awk '/^\t/ {print $1}' | grep -Ev '^(@rpath/|/usr/lib/|/System/)' | sort -u || true)"
  if [ -n "$outside" ]; then echo "$name links outside the bundle and the OS: $outside, stopping"; exit 1; fi
  if [ -n "$(module_headers "$name")" ]; then
    mkdir -p "$v/Headers" "$v/Modules"
    cp "$U/include/$name/"*.h "$v/Headers/"
    {
      echo "framework module $name [system] {"
      for h in $(module_headers "$name"); do echo "  header \"$h\""; done
      echo "  export *"
      echo "}"
    } > "$v/Modules/module.modulemap"
  fi
  cat > "$v/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${FFMPEG_VERSION#n}</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
  ln -s A "$fw/Versions/Current"
  for item in "$name" Resources $( [ -d "$v/Headers" ] && echo Headers Modules ); do
    ln -s "Versions/Current/$item" "$fw/$item"
  done
done

# ---------- One XCFramework per library ----------
rm -rf "$OUT"/*.xcframework
for name in "${LIBS[@]}"; do
  xcodebuild -create-xcframework -framework "$F/$name.framework" -output "$OUT/$name.xcframework" >/dev/null
done

echo
echo "Done. Library sizes:"
du -sh "$OUT"/*.xcframework
du -ch "$U/lib/"*.dylib | tail -1
