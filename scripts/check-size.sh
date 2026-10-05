#!/usr/bin/env bash
# Size budget check for a built Trimline.app (docs/spec.md, "Size budget").
#
#   ./scripts/check-size.sh path/to/Trimline.app
#
# Fails (exit 1) when the bundle is larger than 30 MB, warns above the 28 MB target and when a
# part exceeds its own budget. 1 MB = 1 000 000 bytes, the unit Finder shows to users; sizes are the
# sum of file lengths (what the user downloads and installs), not disk blocks.
# On GitHub Actions it also adds ::error/::warning annotations and a table to the job summary.

set -euo pipefail

APP="${1:?usage: check-size.sh path/to/Trimline.app}"
[ -d "$APP/Contents" ] || { echo "error: $APP is not an app bundle" >&2; exit 2; }

LIMIT_MB=30        # CI fails above this
TARGET_MB=28       # sum of the part budgets below
FFMPEG_LIBS=(libavcodec libavformat libavutil libswresample libswscale)

# Sum of regular file sizes under a path (symlinks inside frameworks are not counted twice).
bytes_of() {
  [ -e "$1" ] || { echo 0; return; }
  find "$1" -type f -print0 | xargs -0 stat -f %z 2>/dev/null | awk '{s += $1} END {printf "%d\n", s}'
}
mb() { awk -v b="$1" 'BEGIN {printf "%.2f", b / 1000000}'; }
over() { awk -v b="$1" -v l="$2" 'BEGIN {exit !(b > l * 1000000)}'; }

annotate() {  # level message
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$1::$2"; else echo "$1: $2" >&2; fi
}

ROWS=()
row() { ROWS+=("$(printf '%-34s %9s MB %s' "$1" "$(mb "$2")" "${3:-}")"); }

FW="$APP/Contents/Frameworks"
total=$(bytes_of "$APP")
frameworks=$(bytes_of "$FW")
app_part=$((total - frameworks))

status=0
warnings=0
check_part() {  # label bytes budget_mb
  if over "$2" "$3"; then
    row "$1" "$2" "(budget ${3} MB)  OVER"
    annotate warning "$1 is $(mb "$2") MB, over its ${3} MB budget"
    warnings=$((warnings + 1))
  else
    row "$1" "$2" "(budget ${3} MB)"
  fi
}

check_part "App code and resources" "$app_part" 5

ffmpeg_total=0
for lib in "${FFMPEG_LIBS[@]}"; do
  b=$(bytes_of "$FW/$lib.framework")
  if [ "$b" -eq 0 ]; then
    annotate warning "$lib.framework is missing from the bundle"
    warnings=$((warnings + 1))
  fi
  row "  $lib.framework" "$b"
  ffmpeg_total=$((ffmpeg_total + b))
done
check_part "FFmpeg total" "$ffmpeg_total" 15
check_part "dav1d (libdav1d.framework)" "$(bytes_of "$FW/libdav1d.framework")" 3

sparkle=$(bytes_of "$FW/Sparkle.framework")
if [ "$sparkle" -gt 0 ]; then
  check_part "Sparkle.framework" "$sparkle" 5
else
  row "Sparkle.framework" 0 "(not embedded)"
fi

# Anything else in Contents/Frameworks has no budget of its own and needs a decision.
known=" ${FFMPEG_LIBS[*]} libdav1d Sparkle "
if [ -d "$FW" ]; then
  for item in "$FW"/*; do
    [ -e "$item" ] || continue
    name=$(basename "$item"); name=${name%.*}
    case "$known" in *" $name "*) continue ;; esac
    b=$(bytes_of "$item")
    row "  unbudgeted: $(basename "$item")" "$b" "(no budget)"
    annotate warning "$(basename "$item") ($(mb "$b") MB) is embedded but has no size budget"
    warnings=$((warnings + 1))
  done
fi

if over "$total" "$LIMIT_MB"; then
  verdict="FAIL: $(mb "$total") MB is over the ${LIMIT_MB} MB limit"
  annotate error "Trimline.app is $(mb "$total") MB, over the ${LIMIT_MB} MB limit"
  status=1
elif over "$total" "$TARGET_MB"; then
  verdict="WARN: $(mb "$total") MB is over the ${TARGET_MB} MB target (limit ${LIMIT_MB} MB)"
  annotate warning "Trimline.app is $(mb "$total") MB, over the ${TARGET_MB} MB target"
else
  verdict="OK: $(mb "$total") MB (target ${TARGET_MB} MB, limit ${LIMIT_MB} MB)"
fi

{
  echo "Size of $(basename "$APP") (1 MB = 10^6 bytes)"
  printf '%s\n' "${ROWS[@]}"
  printf '%-34s %9s MB\n' "Total" "$(mb "$total")"
  echo "$verdict"
} | tee "${SIZE_REPORT:-/dev/null}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### App size"
    echo '```'
    printf '%s\n' "${ROWS[@]}"
    printf '%-34s %9s MB\n' "Total" "$(mb "$total")"
    echo "$verdict"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$status"
