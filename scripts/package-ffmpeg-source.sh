#!/usr/bin/env bash
# Source bundle required by LGPL 2.1, attached to every GitHub release: the exact FFmpeg and dav1d sources
# the libraries in Trimline.app were built from, the build script, patches (if the sources were changed)
# and instructions for replacing the libraries.
#
# Run from the project root:  ./scripts/package-ffmpeg-source.sh
# Output: dist/trimline-ffmpeg-source-<version>.tar.xz with a .sha256 next to it.
#
# Uses the sources in .build-ffmpeg/src if they are on the pinned tags, otherwise clones the tags again.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/build-ffmpeg.sh"
SOURCES="$ROOT/.build-ffmpeg/src"
DIST="$ROOT/dist"
FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
DAV1D_REPO="https://code.videolan.org/videolan/dav1d.git"

pinned() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$BUILD_SCRIPT"; }
FFMPEG_VERSION="$(pinned FFMPEG_VERSION)"
DAV1D_VERSION="$(pinned DAV1D_VERSION)"
[ -n "$FFMPEG_VERSION" ] && [ -n "$DAV1D_VERSION" ] || { echo "No pinned versions found in $BUILD_SCRIPT"; exit 1; }

NAME="trimline-ffmpeg-source-${FFMPEG_VERSION#n}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
OUT="$STAGE/$NAME"
mkdir -p "$OUT/src" "$DIST"

# Copies the clean tree of the tag, saves local changes as a separate patch and prints the commit hash.
export_tree() {
  local name=$1 tag=$2 repo=$3 checkout="$SOURCES/$1"
  if [ -d "$checkout/.git" ]; then
    local actual
    actual="$(git -C "$checkout" describe --tags --exact-match HEAD 2>/dev/null || echo "?")"
    if [ "$actual" != "$tag" ]; then
      echo "$checkout is at \"$actual\", but build-ffmpeg.sh pins \"$tag\"." >&2
      echo "The libraries were not built from the pinned version: rebuild them (delete $checkout and run build-ffmpeg.sh)." >&2
      exit 1
    fi
  else
    checkout="$STAGE/clone-$name"
    git clone --quiet --depth 1 --branch "$tag" "$repo" "$checkout"
  fi
  mkdir -p "$OUT/src/$name"
  git -C "$checkout" archive --format=tar HEAD | tar -x -C "$OUT/src/$name"
  if ! git -C "$checkout" diff --quiet HEAD; then
    mkdir -p "$OUT/patches"
    git -C "$checkout" diff HEAD > "$OUT/patches/$name.patch"
    echo "$name has local changes, saved to patches/$name.patch" >&2
  fi
  if [ -n "$(git -C "$checkout" ls-files --others --exclude-standard)" ]; then
    echo "$checkout has untracked files; they are left out of the bundle, so check that the build does not need them." >&2
  fi
  git -C "$checkout" rev-parse HEAD
}

FFMPEG_COMMIT="$(export_tree ffmpeg "$FFMPEG_VERSION" "$FFMPEG_REPO" | tail -n 1)"
DAV1D_COMMIT="$(export_tree dav1d "$DAV1D_VERSION" "$DAV1D_REPO" | tail -n 1)"
cp "$BUILD_SCRIPT" "$OUT/build-ffmpeg.sh"
[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ] && cp "$ROOT/THIRD_PARTY_NOTICES.md" "$OUT/"

if [ -d "$OUT/patches" ]; then
  PATCH_NOTE="The \`patches/\` folder holds the changes made to these sources before the build. Apply them with
\`git apply\` (or \`patch -p1\`) inside \`src/ffmpeg\` or \`src/dav1d\` before step 2."
else
  PATCH_NOTE="FFmpeg and dav1d are built from the unmodified release sources; there are no patches."
fi

cat > "$OUT/README.md" <<README
# FFmpeg and dav1d sources for Trimline

Trimline uses FFmpeg under the GNU Lesser General Public License 2.1 or later and dav1d under the BSD
2-Clause License. Both are linked dynamically, as separate frameworks inside
\`Trimline.app/Contents/Frameworks\`, so you can rebuild them and replace the ones that come with the app.

| Library | Version | Commit | Upstream |
| --- | --- | --- | --- |
| FFmpeg | ${FFMPEG_VERSION} | \`${FFMPEG_COMMIT}\` | ${FFMPEG_REPO} |
| dav1d | ${DAV1D_VERSION} | \`${DAV1D_COMMIT}\` | ${DAV1D_REPO} |

Contents:

- \`src/ffmpeg\`, \`src/dav1d\` — the exact source trees the libraries were built from;
- \`build-ffmpeg.sh\` — the build script with the configure flags and the list of enabled components;
- \`THIRD_PARTY_NOTICES.md\` — license notices for everything Trimline includes.

${PATCH_NOTE}

## 1. Install the tools

Xcode command line tools and, from Homebrew:

\`\`\`sh
brew install nasm pkg-config meson ninja
\`\`\`

## 2. Build

\`build-ffmpeg.sh\` expects the sources in \`.build-ffmpeg/src\` next to its \`scripts\` folder:

\`\`\`sh
mkdir -p work/scripts work/.build-ffmpeg
cp build-ffmpeg.sh work/scripts/
cp -R src work/.build-ffmpeg/src
cd work && ./scripts/build-ffmpeg.sh
\`\`\`

You can change the sources or the configure flags before building. Keep the major versions of the
libraries (FFmpeg ${FFMPEG_VERSION#n}: libavcodec 61, libavformat 61, libavutil 59, libswresample 5,
libswscale 8; dav1d: libdav1d 7): Trimline is linked against them.

The result is a set of universal (arm64 + x86_64) frameworks in \`work/.build-ffmpeg/frameworks\`, and
the same frameworks wrapped as XCFrameworks in \`work/Frameworks\`.

## 3. Replace the libraries in Trimline

Quit Trimline, then:

\`\`\`sh
APP=/Applications/Trimline.app
for lib in libavutil libswresample libswscale libavcodec libavformat libdav1d; do
  rm -rf "\$APP/Contents/Frameworks/\$lib.framework"
  cp -R "work/.build-ffmpeg/frameworks/\$lib.framework" "\$APP/Contents/Frameworks/"
done
codesign --force --deep --sign - "\$APP"
\`\`\`

Replacing files breaks the original signature, so the last command signs the app again for this Mac
only. If macOS refuses to open it, run \`xattr -dr com.apple.quarantine "\$APP"\` and open it again.
Updating Trimline installs its own copies of the libraries again.
README

ARCHIVE="$DIST/$NAME.tar.xz"
tar -C "$STAGE" -cJf "$ARCHIVE" "$NAME"
(cd "$DIST" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")

echo
echo "Done: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
cat "$ARCHIVE.sha256"
