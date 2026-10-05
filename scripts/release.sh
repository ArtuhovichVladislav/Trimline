#!/usr/bin/env bash
# End-to-end release of Trimline without an Apple Developer account: archive (signed ad hoc) →
# signature checks → size budget → DMG → Sparkle EdDSA signature and appcast → LGPL source bundle →
# SHA-256. The app is not notarized; users approve it once in System Settings (docs/release.md).
#
#   ./scripts/release.sh                                  full release (needs the Sparkle private key)
#   ./scripts/release.sh --allow-dirty --skip-sparkle     local dry run: archive → checks → DMG
#
# Options
#   --skip-ffmpeg        never build FFmpeg; fail if Frameworks/*.xcframework is missing
#   --skip-sparkle       don't sign the DMG for Sparkle and don't write the appcast
#   --skip-source        don't package the FFmpeg/dav1d sources (LGPL) for the GitHub release
#   --allow-dirty        don't require a clean git tree
#   --expect-version V   fail unless the app's CFBundleShortVersionString is V (CI passes the tag)
#   -h, --help           show this help
#
# Environment (secrets are only read from the environment and never printed)
#   SPARKLE_KEY_FILE     file with the Sparkle EdDSA private key (generate_keys -x FILE)
#     or SPARKLE_PRIVATE_KEY   the key itself (CI secret); otherwise the login keychain is used
#   SPARKLE_BIN          folder with sign_update/generate_appcast; default: the SwiftPM artifact
#   RELEASES_REPO        GitHub repository whose releases host the DMG and appcast, default ArtuhovichVladislav/Trimline
#   DOWNLOAD_URL_PREFIX  where the DMG will be downloaded from, default that repository's release for the version
#   APPCAST_SEED         previous appcast.xml (path or URL) to append the new release to
#   RELEASE_NOTES        HTML file with notes for this version, embedded in the appcast item
#   BUILD_NUMBER         CFBundleVersion (Sparkle compares it), default: git commit count
#   RELEASE_WORK         folder for intermediate files, default build/release
#   DIST_DIR             output folder, default dist

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RELEASE_WORK:-$ROOT/build/release}"
DIST="${DIST_DIR:-$ROOT/dist}"
DERIVED="$WORK/DerivedData"
ARCHIVE="$WORK/Trimline.xcarchive"
APP="$WORK/Trimline.app"

SCHEME="Trimline"
PROJECT="$ROOT/Trimline.xcodeproj"
FFMPEG_LIBS=(libavutil libswresample libswscale libavcodec libavformat libdav1d)
RELEASES_REPO="${RELEASES_REPO:-ArtuhovichVladislav/Trimline}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
HOMEPAGE="https://github.com/$RELEASES_REPO"

BUILD_FFMPEG=1 SPARKLE=1 SOURCE=1 ALLOW_DIRTY=0 EXPECT_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-ffmpeg) BUILD_FFMPEG=0 ;;
    --skip-sparkle) SPARKLE=0 ;;
    --skip-source) SOURCE=0 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --expect-version) EXPECT_VERSION="${2:?--expect-version needs a value}"; shift ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------- Helpers ----------
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; else printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; fi; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; else printf '\033[31merror:\033[0m %s\n' "$*" >&2; fi; exit 1; }

# Run a long command quietly, keep the full log, show errors and the tail when it fails.
run_logged() {  # log-file command...
  local log=$1; shift
  if ! "$@" > "$log" 2>&1; then
    grep -E '(error|warning):' "$log" | sort -u | head -40 >&2 || true
    tail -30 "$log" >&2
    die "failed: $1 … (full log: $log)"
  fi
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# ---------- 1. Preflight ----------
preflight() {
  step "Preflight"
  for tool in xcodebuild codesign hdiutil ditto lipo shasum git; do
    command -v "$tool" > /dev/null || die "$tool not found"
  done

  local xcode major
  xcode="$(xcodebuild -version | sed -n 1p)"
  major="$(echo "$xcode" | awk '{print $2}' | cut -d. -f1)"
  [ "${major:-0}" -ge 26 ] || die "Xcode 26 or newer is required, found: $xcode ($(xcode-select -p))"
  info "$xcode at $(xcode-select -p)"

  if [ "$ALLOW_DIRTY" = 0 ]; then
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "git tree is not clean (commit or pass --allow-dirty)"
  elif [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    warn "git tree is dirty; this build is not reproducible from a commit"
  fi
  info "commit $(git -C "$ROOT" rev-parse --short HEAD)"

  local missing=0
  for lib in "${FFMPEG_LIBS[@]}"; do
    [ -d "$ROOT/Frameworks/$lib.xcframework" ] || missing=1
  done
  if [ "$missing" = 1 ]; then
    [ "$BUILD_FFMPEG" = 1 ] || die "Frameworks/*.xcframework missing and --skip-ffmpeg given; run scripts/build-ffmpeg.sh"
    step "Building FFmpeg (≈15 min)"
    "$ROOT/scripts/build-ffmpeg.sh"
  else
    info "FFmpeg frameworks present"
  fi

  # Fail before the long build: a placeholder key makes an app that never accepts updates.
  if [ "$SPARKLE" = 1 ] && grep -q '^TRIMLINE_SPARKLE_PUBLIC_KEY *= *REPLACE' "$ROOT/Config/Updates.xcconfig"; then
    die "SUPublicEDKey is still a placeholder in Config/Updates.xcconfig (pass --skip-sparkle for a dry run)"
  fi
  info "signing: ad hoc, not notarized"
}

# ---------- 2. Archive ----------
# Ad hoc signature ("-"), as in the project settings: Xcode signs the app and re-signs every
# embedded framework on copy. Sparkle's nested helpers (Autoupdate, Updater.app, XPC services)
# arrive ad hoc signed with hardened runtime from the SwiftPM artifact and are sealed by the
# framework's signature, so the bundle is signed inside out without an extra pass.
archive() {
  step "Archive (Release, universal, ad hoc)"
  mkdir -p "$WORK"
  rm -rf "${ARCHIVE:?}" "${APP:?}"

  local build_number="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
  run_logged "$WORK/archive.log" xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$build_number" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  info "archive: $ARCHIVE"
  ditto "$ARCHIVE/Products/Applications/Trimline.app" "$APP"
  [ -d "$APP" ] || die "no Trimline.app in the archive"

  VERSION="$(plist_get "$APP/Contents/Info.plist" CFBundleShortVersionString)"
  BUILD="$(plist_get "$APP/Contents/Info.plist" CFBundleVersion)"
  [ -n "$VERSION" ] || die "CFBundleShortVersionString is empty"
  if [ -n "$EXPECT_VERSION" ] && [ "$VERSION" != "$EXPECT_VERSION" ]; then
    die "app version $VERSION does not match the expected $EXPECT_VERSION (bump MARKETING_VERSION)"
  fi
  info "Trimline $VERSION ($BUILD)"
}

# ---------- 3. Signature checks ----------
verify_signatures() {
  step "Verify code signatures, architectures and linkage"
  codesign --verify --deep --strict "$APP" || die "codesign --verify --deep --strict failed for $APP"
  info "codesign --verify --deep --strict: ok"

  # Every Mach-O file in the bundle: app binary, frameworks (FFmpeg, dav1d, Sparkle), Sparkle's
  # Autoupdate, Updater.app and XPC services.
  local failures=0 count=0 file details flags
  while IFS= read -r -d '' file; do
    file -b "$file" | grep -q '^Mach-O' || continue
    count=$((count + 1))
    local rel="${file#"$APP"/}"
    details="$(codesign -dvvv "$file" 2>&1 || true)"
    flags="$(echo "$details" | sed -n 's/.*flags=0x[0-9a-f]*(\([^)]*\)).*/\1/p' | sed -n 1p)"
    local problems=()
    [[ ",$flags," == *",runtime,"* ]] || problems+=("no hardened runtime (flags: ${flags:-none})")
    local archs; archs="$(lipo -archs "$file" 2>/dev/null || true)"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || problems+=("not universal ($archs)")
    # Every slice may only link to the bundle (@rpath, @loader_path, @executable_path) or the OS;
    # a build-machine path (e.g. .build-ffmpeg/x86_64/lib) works here and crashes on users' Macs.
    local bad_links
    bad_links="$(otool -arch all -L "$file" | awk '/^\t/ {print $1}' \
      | grep -Ev '^(@rpath/|@executable_path/|@loader_path/|/usr/lib/|/System/)' | sort -u | tr '\n' ' ' || true)"
    [ -z "$bad_links" ] || problems+=("links outside the bundle: $bad_links")
    [[ ",$flags," == *",adhoc,"* ]] || problems+=("not signed ad hoc like the app")
    if codesign -d --entitlements - --xml "$file" 2>/dev/null | grep -q "get-task-allow"; then
      problems+=("has get-task-allow entitlement")
    fi
    if [ "${#problems[@]}" -gt 0 ]; then
      failures=$((failures + 1))
      info "FAIL $rel: ${problems[*]}"
    else
      info "ok   $rel ($flags; $archs)"
    fi
  done < <(find "$APP/Contents" -type f -perm -u+x -print0)
  [ "$count" -gt 0 ] || die "no executables found in $APP"
  [ "$failures" = 0 ] || die "$failures of $count binaries failed the signature checks"
  # Without it the ad hoc app can't load its own ad hoc frameworks under the hardened runtime.
  codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "disable-library-validation" \
    || die "the app lacks com.apple.security.cs.disable-library-validation and would crash at launch"
}

# ---------- 4. DMG ----------
make_dmg() {
  step "Create DMG"
  mkdir -p "$DIST"
  DMG="$DIST/Trimline-$VERSION.dmg"
  local staging="$WORK/dmg"
  rm -rf "${staging:?}"
  rm -f "${DMG:?}"
  mkdir -p "$staging"
  ditto "$APP" "$staging/Trimline.app"
  ln -s /Applications "$staging/Applications"

  # hdiutil sometimes fails with "Resource busy" on CI runners; retry a few times.
  local attempt
  for attempt in 1 2 3; do
    if hdiutil create -volname "Trimline $VERSION" -srcfolder "$staging" -fs HFS+ -format ULMO -ov "$DMG" \
      > "$WORK/hdiutil.log" 2>&1; then
      break
    fi
    [ "$attempt" = 3 ] && { cat "$WORK/hdiutil.log" >&2; die "hdiutil create failed"; }
    warn "hdiutil create failed (attempt $attempt), retrying"
    sleep 5
  done
  rm -rf "${staging:?}"

  # The image itself stays unsigned: an ad hoc signature on a DMG carries no identity.
  hdiutil verify -quiet "$DMG"
  verify_dmg_contents
  info "$DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
}

# The app inside the image must still carry a valid signature.
verify_dmg_contents() {
  local mnt; mnt="$(mktemp -d "$WORK/mnt.XXXXXX")"
  hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$mnt" "$DMG" > /dev/null
  local ok=1
  [ -L "$mnt/Applications" ] || ok=0
  codesign --verify --deep --strict "$mnt/Trimline.app" || ok=0
  hdiutil detach -quiet "$mnt" || hdiutil detach -quiet -force "$mnt"
  rmdir "${mnt:?}"
  [ "$ok" = 1 ] || die "the app inside $DMG is missing or fails verification"
  info "DMG contents verified"
}

# ---------- 5. Gatekeeper ----------
# Informational: without notarization Gatekeeper rejects the app; users approve it once.
gatekeeper() {
  step "Gatekeeper (spctl, expected to reject an unnotarized app)"
  spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/    /' || true
}

# ---------- 6. Sparkle ----------
# An ad hoc app's designated requirement is its own cdhash, so Sparkle can never match a new
# version by Apple code signing: the EdDSA signature is the only way an update is accepted.
find_sparkle_bin() {
  if [ -n "${SPARKLE_BIN:-}" ]; then echo "$SPARKLE_BIN"; return; fi
  local tool
  tool="$(find "$DERIVED/SourcePackages/artifacts" "$ROOT/build/SourcePackages/artifacts" \
    -type f -name sign_update -path '*/bin/*' 2>/dev/null | sed -n 1p || true)"
  if [ -n "$tool" ]; then dirname "$tool"; fi
}

# Runs a Sparkle tool with the private key: from SPARKLE_KEY_FILE, from SPARKLE_PRIVATE_KEY via
# standard input (never on the command line or on disk), or from the login keychain.
sparkle_run() {  # tool args...
  local tool=$1; shift
  if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    "$tool" --ed-key-file "$SPARKLE_KEY_FILE" "$@"
  elif [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tool" --ed-key-file - "$@"
  else
    "$tool" "$@"
  fi
}

# Public key that belongs to the private key, to catch a key that doesn't match SUPublicEDKey
# before shipping an update nobody can install. Empty when there is no key; dies when a key is given
# but can't be read. The helper is compiled rather than run with `swift -e`, which fails on CI runners.
sparkle_public_key() {
  local secret=""
  if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    secret="$(cat "$SPARKLE_KEY_FILE")"
  elif [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    secret="$SPARKLE_PRIVATE_KEY"
  else
    "$1/generate_keys" -p 2>/dev/null | tail -n 1 || true
    return
  fi
  local helper="$WORK/sparkle-public-key"
  if [ ! -x "$helper" ]; then
    # generate_keys -x writes base64 of the 32-byte seed (or, for old keys, 64-byte private + public).
    cat > "$helper.swift" << 'SWIFT'
import CryptoKit
import Foundation

let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
  FileHandle.standardError.write(Data("the key is not base64\n".utf8))
  exit(1)
}
if raw.count == 96 {
  print(raw.suffix(32).base64EncodedString())
  exit(0)
}
guard raw.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
  FileHandle.standardError.write(Data("the key decodes to \(raw.count) bytes, expected 32\n".utf8))
  exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
    xcrun swiftc -O -o "$helper" "$helper.swift" > "$WORK/sparkle-public-key.log" 2>&1 \
      || { cat "$WORK/sparkle-public-key.log" >&2; die "could not compile the Sparkle key helper"; }
  fi
  printf '%s' "$secret" | "$helper" || die "the Sparkle private key can't be read (expected the output of generate_keys -x)"
}

sparkle() {
  if [ "$SPARKLE" = 0 ]; then step "Sparkle (skipped)"; return; fi
  step "Sparkle: EdDSA signature and appcast"
  [ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || die "Sparkle.framework is not embedded in the app"

  local bin; bin="$(find_sparkle_bin)"
  [ -n "$bin" ] && [ -x "$bin/sign_update" ] && [ -x "$bin/generate_appcast" ] \
    || die "Sparkle tools not found; set SPARKLE_BIN (looked in $DERIVED/SourcePackages/artifacts)"
  info "tools: $bin"

  local app_key signing_key
  app_key="$(plist_get "$APP/Contents/Info.plist" SUPublicEDKey)"
  signing_key="$(sparkle_public_key "$bin")" || exit 1
  if [ -z "$app_key" ] || [[ "$app_key" == REPLACE* ]]; then
    die "SUPublicEDKey in the app is a placeholder; set it in Config/Updates.xcconfig (or pass --skip-sparkle for a dry run)"
  fi
  [ -n "$signing_key" ] || die "no Sparkle private key: set SPARKLE_KEY_FILE or SPARKLE_PRIVATE_KEY, or import it with generate_keys -f"
  [ "$signing_key" = "$app_key" ] || die "the Sparkle private key does not match SUPublicEDKey ($app_key)"
  info "private key matches SUPublicEDKey $app_key"

  local signature
  signature="$(sparkle_run "$bin/sign_update" "$DMG")" || die "sign_update failed"
  info "sign_update: $signature"
  echo "$signature" > "$DMG.sparkle"

  # generate_appcast reads every archive in its folder: give it only this release and the
  # existing feed, so old items are kept and no delta updates have to be uploaded.
  local feed="$WORK/appcast"
  rm -rf "${feed:?}"
  mkdir -p "$feed"
  cp "$DMG" "$feed/"
  if [ -n "${APPCAST_SEED:-}" ]; then
    case "$APPCAST_SEED" in
      http://* | https://*) curl -fsSL "$APPCAST_SEED" -o "$feed/appcast.xml" || warn "no appcast at $APPCAST_SEED, starting a new one" ;;
      *) cp "$APPCAST_SEED" "$feed/appcast.xml" ;;
    esac
  elif [ -f "$DIST/appcast.xml" ]; then
    cp "$DIST/appcast.xml" "$feed/appcast.xml"
  fi
  local prefix="${DOWNLOAD_URL_PREFIX:-https://github.com/$RELEASES_REPO/releases/download/v$VERSION/}"
  local args=(--download-url-prefix "$prefix" --link "$HOMEPAGE" --maximum-deltas 0)
  if [ -n "${RELEASE_NOTES:-}" ]; then
    cp "$RELEASE_NOTES" "$feed/Trimline-$VERSION.html"
    args+=(--embed-release-notes)
  fi
  run_logged "$WORK/generate_appcast.log" sparkle_run "$bin/generate_appcast" "${args[@]}" "$feed"
  cp "$feed/appcast.xml" "$DIST/appcast.xml"
  local item; item="$(grep "Trimline-$VERSION.dmg" "$DIST/appcast.xml" || true)"
  [ -n "$item" ] || die "appcast has no item for Trimline-$VERSION.dmg"
  # generate_appcast silently leaves the enclosure unsigned when SUPublicEDKey is invalid.
  [[ "$item" == *"sparkle:edSignature="* ]] || die "the appcast item for $VERSION has no EdDSA signature"
  info "$DIST/appcast.xml"
}

# ---------- 7. LGPL source bundle ----------
ffmpeg_source() {
  if [ "$SOURCE" = 0 ]; then step "FFmpeg source bundle (skipped)"; return; fi
  step "FFmpeg source bundle (LGPL, published with the release)"
  run_logged "$WORK/package-ffmpeg-source.log" "$ROOT/scripts/package-ffmpeg-source.sh"
  # The packaging script always writes to <repo>/dist.
  if [ "$DIST" != "$ROOT/dist" ]; then
    mv -f "$ROOT"/dist/trimline-ffmpeg-source-* "$DIST/" 2> /dev/null || true
  fi
  ls "$DIST"/trimline-ffmpeg-source-*.tar.xz > /dev/null 2>&1 || die "package-ffmpeg-source.sh produced no tarball in $DIST"
  info "$(cd "$DIST" && ls trimline-ffmpeg-source-*.tar.xz)"
}

# ---------- 8. Checksums ----------
finish() {
  step "Checksums"
  local sha; sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  echo "$sha  $(basename "$DMG")" > "$DMG.sha256"
  # The site links to releases/latest/download/Trimline.dmg, so every release also carries this name.
  cp -f "$DMG" "$DIST/Trimline.dmg"
  info "version $VERSION, sha256 $sha"

  step "Done"
  find "$DIST" -maxdepth 1 -type f -exec ls -lh {} + | sed "s/^/    /"
  [ "$SPARKLE" = 1 ] || warn "built with --skip-sparkle: no appcast, do not publish"
  return 0
}

preflight
archive
verify_signatures
step "Size budget"
SIZE_REPORT="$WORK/size-report.txt" "$ROOT/scripts/check-size.sh" "$APP"
make_dmg
gatekeeper
sparkle
ffmpeg_source
finish
