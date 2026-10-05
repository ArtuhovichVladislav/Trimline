#!/bin/bash
# Builds the test media set described in docs/test-media.md outside the repository:
# real-world samples are downloaded, everything else is generated with ffmpeg.
#
#   scripts/make-test-media.sh [--big] [output dir]
#
# Default output: ~/Projects/Trimline-TestMedia. Existing files are kept, so a rerun only adds
# what is missing. --big also writes a 20 GB MOV and a 50 GB MKV (needs ~75 GB free).
# Requires: ffmpeg with libx264, libx265, libvpx, libsvtav1, libopus, libmp3lame (Homebrew build).

set -euo pipefail
# Filter expressions contain "*", which must not expand to file names.
set -f

BIG=0
if [[ "${1:-}" == "--big" ]]; then BIG=1; shift; fi
OUT="${1:-$HOME/Projects/Trimline-TestMedia}"
CACHE="${TRIMLINE_MEDIA_CACHE:-${TMPDIR:-/tmp}/trimline-media-cache}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$CACHE"

FF=(ffmpeg -hide_banner -loglevel error -nostdin -y)
export SVT_LOG=1
FAILED=()

# 10 s sources: a moving test pattern and a tone whose loudness swells, so the waveform has shape.
video() { echo -f lavfi -i "testsrc2=size=${1:-1280x720}:rate=${2:-30}:duration=${3:-10}"; }
audio() {
    echo -f lavfi -i "aevalsrc=0.7*sin(2*PI*${4:-440}*t)*(0.55+0.45*sin(2*PI*0.25*t)):s=${2:-48000}:c=${3:-stereo}:d=${1:-10}"
}

note() { printf '  %s\n' "$1"; }

# gen <output relative to the set, or absolute> <ffmpeg arguments without the output>
gen() {
    local out="$1"; shift
    [[ "$out" == /* ]] || out="$OUT/$out"
    [[ -s "$out" ]] && return 0
    mkdir -p "$(dirname "$out")"
    [[ "$out" == "$WORK"/* ]] || note "${out#"$OUT"/}"
    if ! "${FF[@]}" "$@" "$out"; then
        rm -f "$out"; FAILED+=("${out#"$OUT"/}"); return 1
    fi
}

# fetch <url> [curl options] — downloads into the cache once and prints the cached path.
fetch() {
    local url="$1"; shift
    local file="$CACHE/$(basename "${url//%20/ }")"
    if [[ ! -s "$file" ]]; then
        curl -fsSL --retry 3 "$@" -o "$file.part" "$url" && mv "$file.part" "$file"
    fi
    echo "$file"
}

# take <relative output> <url> [curl options] — copies a downloaded sample as is.
take() {
    local out="$OUT/$1" url="$2"; shift 2
    [[ -s "$out" ]] && return 0
    mkdir -p "$(dirname "$out")"
    note "${out#"$OUT"/}  ← $(basename "$url")"
    local src
    if src="$(fetch "$url" "$@")"; then cp "$src" "$out"; else FAILED+=("${out#"$OUT"/}"); fi
}

MPLAYER=https://samples.mplayerhq.hu
HDR=https://raw.githubusercontent.com/haasn/hdr-tests/master
DOLBY=https://media.githubusercontent.com/media/DolbyLaboratories/dolby-vision-contents/main/SolLevante_Netflix

echo "Test media → $OUT"

echo "01 phones"
DV84="$(fetch "$DOLBY/BL_RPU_dvhe-08-84_1920x1080@24fps_0_6313.mp4")" || DV84=missing
DV5="$(fetch "$DOLBY/BL_RPU_dvhe-05_1920x1080@24fps_0_6313.mp4")" || DV5=missing
# Cut from the start: parameter sets are only in the first key frame. The MOV muxer drops the
# Dolby Vision configuration, so these stay MP4.
gen 01-phones/dolby-vision-8.4-hlg.mp4 -i "$DV84" -t 12 -map 0 -c copy -strict unofficial
gen 01-phones/dolby-vision-5.mp4 -i "$DV5" -t 12 -map 0 -c copy -strict unofficial
gen 01-phones/iphone-hevc-hlg-10bit.mov $(video 1920x1080 30) $(audio) -c:v libx265 -preset fast -crf 28 \
    -pix_fmt yuv420p10le -x265-params log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc \
    -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -tag:v hvc1 -c:a aac -b:a 128k
gen 01-phones/iphone-hevc-sdr.mov $(video 1920x1080 30) $(audio) -c:v libx265 -preset fast -crf 28 \
    -x265-params log-level=error -tag:v hvc1 -c:a aac -b:a 128k
gen 01-phones/iphone-h264-60fps.mov $(video 1920x1080 60) $(audio) -c:v libx264 -crf 26 -c:a aac
gen "$WORK/portrait.mov" $(video 1920x1080 30) $(audio) -c:v libx264 -crf 26 -c:a aac
gen 01-phones/iphone-portrait-rotated-90.mov -display_rotation 90 -i "$WORK/portrait.mov" -c copy
gen 01-phones/android-h264-vfr.mp4 $(video 1920x1080 60 12) $(audio 12) \
    -vf "select='lt(mod(t\,4)\,2)+not(mod(n\,2))'" -fps_mode vfr -c:v libx264 -crf 26 -c:a aac
gen 01-phones/old-phone-h263.3gp $(video 176x144 15) $(audio 10 16000 mono) -c:v h263 -b:v 128k \
    -c:a aac -b:a 32k
gen 01-phones/itunes-h264.m4v $(video 1280x720 24) $(audio) -c:v libx264 -crf 26 -c:a aac
gen 01-phones/prores-422-proxy.mov $(video 1280x720 25 4) $(audio 4) -c:v prores_ks -profile:v 0 -c:a pcm_s16le

echo "02 messengers"
gen 02-messengers/telegram-video.mp4 $(video 1280x720 30 15) $(audio 15) -c:v libx264 -crf 28 \
    -c:a aac -b:a 96k -movflags +faststart
gen 02-messengers/telegram-video-note.mp4 $(video 384x384 30 8) $(audio 8 48000 mono) -c:v libx264 -crf 28 \
    -c:a aac -b:a 64k -movflags +faststart
gen 02-messengers/telegram-voice.ogg $(audio 20 48000 mono 220) -c:a libopus -b:a 32k -application voip
gen 02-messengers/whatsapp-video.mp4 $(video 848x480 30 15) $(audio 15 44100) -c:v libx264 -profile:v baseline \
    -crf 30 -c:a aac -b:a 64k -movflags +faststart
gen 02-messengers/whatsapp-voice.opus $(audio 20 16000 mono 220) -c:a libopus -b:a 16k -application voip

echo "03 screen, high resolution, long"
gen 03-large/screen-recording-2880x1800.mov $(video 2880x1800 60 8) $(audio 8) -c:v libx264 -preset veryfast \
    -crf 24 -c:a aac
gen 03-large/4k-hevc.mp4 $(video 3840x2160 30 8) $(audio 8) -c:v hevc_videotoolbox -b:v 20M -tag:v hvc1 -c:a aac
gen 03-large/8k-hevc.mp4 $(video 7680x4320 30 5) $(audio 5) -c:v libx265 -preset ultrafast \
    -x265-params log-level=error -tag:v hvc1 -c:a aac
gen 03-large/3-hours.mp4 $(video 320x180 10 10800) $(audio 10800 22050 mono) -c:v libx264 -preset veryfast \
    -crf 38 -g 300 -c:a aac -b:a 24k
gen 03-large/2-hours.mp3 $(audio 7200 44100 mono) -c:a libmp3lame -b:a 64k
gen 03-large/10-hours.mp3 $(audio 36000 16000 mono) -c:a libmp3lame -b:a 8k
if (( BIG )); then
    # 4K ProRes HQ, as from a camera; looped by stream copy up to the target size.
    gen "$WORK/heavy.mov" $(video 3840x2160 30 10) $(audio 10) -c:v prores_ks -profile:v 3 -c:a pcm_s16le
    loops() { echo $(( $1 * 1024 * 1024 * 1024 / $(stat -f %z "$WORK/heavy.mov") )); }
    gen 03-large/20GB.mov -stream_loop "$(loops 20)" -i "$WORK/heavy.mov" -c copy
    gen 03-large/50GB.mkv -stream_loop "$(loops 50)" -i "$WORK/heavy.mov" -c copy
fi

echo "04 legacy and Windows"
take 04-legacy/divx-5-qpel.avi "$MPLAYER/archive/all/avi+mpeg4+++DivX51-Qpel.avi"
gen 04-legacy/xvid-mp3.avi $(video 640x480 25) $(audio 10 44100) -c:v mpeg4 -vtag XVID -q:v 5 -c:a libmp3lame
gen 04-legacy/divx3-mp3.avi $(video 640x480 25) $(audio 10 44100) -c:v msmpeg4 -vtag DIV3 -q:v 5 -c:a libmp3lame
gen 04-legacy/mjpeg-pcm.avi $(video 640x480 25 5) $(audio 5) -c:v mjpeg -q:v 5 -c:a pcm_s16le
take 04-legacy/wmv9-wmav2.wmv "$MPLAYER/archive/all/asf+wmv3+wmav2++audio_stutter.wmv"
take 04-legacy/vc1-advanced.wmv "$MPLAYER/ffmpeg-bugs/trac/ticket2993/vc1.wmv"
gen 04-legacy/wmv8-wmav2.wmv $(video 640x480 25) $(audio 10 44100) -c:v wmv2 -b:v 1M -c:a wmav2
gen 04-legacy/wmv7-wmav2.asf $(video 640x480 25) $(audio 10 44100) -c:v wmv1 -b:v 1M -c:a wmav2
take 04-legacy/sorenson-real.flv "$MPLAYER/FLV/zelda.flv"
gen 04-legacy/h264-aac.flv $(video 1280x720 30) $(audio 10 44100) -c:v libx264 -crf 26 -c:a aac
gen 04-legacy/sorenson-mp3.flv $(video 640x360 30) $(audio 10 44100) -c:v flv -q:v 5 -c:a libmp3lame
gen 04-legacy/h264-aac.f4v $(video 1280x720 30) $(audio) -c:v libx264 -crf 26 -c:a aac -f f4v
gen 04-legacy/mpeg1-mp2.mpg $(video 352x288 25) $(audio 10 44100) -c:v mpeg1video -b:v 1.5M -c:a mp2 -f mpeg
gen 04-legacy/mpeg2-mp2.mpg $(video 720x576 25) $(audio) -c:v mpeg2video -b:v 5M -c:a mp2 -f vob
gen 04-legacy/dvd-generated.vob $(video 720x576 25) $(audio) -target pal-dvd
take 04-legacy/dvd-real.vob "$MPLAYER/archive/all/mpeg+mpeg2video+ac3++dvd_dump_small.vob"
take 04-legacy/theora-vorbis.ogv "$MPLAYER/ffmpeg-bugs/roundup/issue746/746-theora-vorbis-sample.ogg"
gen 04-legacy/dv-pal.dv $(video 720x576 25 5) $(audio 5) -target pal-dv

echo "05 cameras"
# AVCHD uses 192-byte packets, so a cut on that boundary is still a valid stream.
take 05-cameras/canon-hg10-avchd.mts \
    "$MPLAYER/archive/all/mpegts+h264+ac3++canon-hg10-avchd-1080-50i-plays-half-speed.mts" -r "0-$((192 * 65536 - 1))"
gen 05-cameras/avchd-h264-ac3.m2ts $(video 1920x1080 25) $(audio) -c:v libx264 -crf 24 -c:a ac3 \
    -f mpegts -mpegts_m2ts_mode 1
gen 05-cameras/sony-h264-ac3.mts $(video 1920x1080 50) $(audio) -c:v libx264 -crf 24 -c:a ac3 \
    -f mpegts -mpegts_m2ts_mode 1
gen 05-cameras/broadcast-mpeg2.ts $(video 720x576 25) $(audio) -c:v mpeg2video -b:v 5M -c:a mp2 -f mpegts

echo "06 audio"
gen "$WORK/cover.png" -f lavfi -i "color=c=0x3478F6:s=600x600,drawbox=x=150:y=200:w=300:h=200:c=yellow:t=12" \
    -frames:v 1
gen 06-audio/song-with-cover.mp3 $(audio 30 44100) -i "$WORK/cover.png" -map 0 -map 1 -c:a libmp3lame -b:a 320k \
    -c:v copy -disposition:v attached_pic -id3v2_version 3 -metadata title="Тестовая песня"
gen 06-audio/song-with-cover.m4a $(audio 30 44100) -i "$WORK/cover.png" -map 0 -map 1 -c:a aac -b:a 256k \
    -c:v copy -disposition:v attached_pic
gen 06-audio/alac.m4a $(audio 20 44100) -c:a alac
gen 06-audio/aac-5.1.m4a $(audio 20 48000 5.1) -c:a aac -b:a 384k
gen 06-audio/cd-16bit-44k.wav $(audio 20 44100) -c:a pcm_s16le
gen 06-audio/studio-24bit-96k.wav $(audio 20 96000) -c:a pcm_s24le
gen 06-audio/pcm.aiff $(audio 20 44100) -c:a pcm_s16be
gen 06-audio/alac.caf $(audio 20 44100) -c:a alac
gen 06-audio/hires-24bit-192k.flac $(audio 20 192000) -c:a flac -sample_fmt s32 -bits_per_raw_sample 24
gen 06-audio/surround-5.1.flac $(audio 20 48000 5.1) -c:a flac
gen 06-audio/dolby-digital-5.1.ac3 $(audio 20 48000 5.1) -c:a ac3 -b:a 448k
gen 06-audio/dts-5.1.dts $(audio 20 48000 5.1) -c:a dca -strict -2
gen 06-audio/vorbis.ogg $(audio 20 44100) -c:a vorbis -strict -2
gen 06-audio/opus.opus $(audio 20 48000) -c:a libopus -b:a 96k
gen 06-audio/wma-v2.wma $(audio 20 44100) -c:a wmav2 -b:a 128k
take 06-audio/wma-lossless.wma "$MPLAYER/A-codecs/lossless/luckynight.wma"
gen 06-audio/wavpack.wv $(audio 20 44100) -c:a wavpack
take 06-audio/wavpack-real.wv "$MPLAYER/A-codecs/lossless/luckynight.wv"
take 06-audio/voice-amr-nb.amr "$MPLAYER/A-codecs/amr/sample.amr"

echo "07 tracks, subtitles, chapters, rotation"
cat > "$WORK/chapters.txt" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10000
title=Вступление
[CHAPTER]
TIMEBASE=1/1000
START=10000
END=20000
title=Середина
[CHAPTER]
TIMEBASE=1/1000
START=20000
END=30000
title=Финал
EOF
printf '1\n00:00:01,000 --> 00:00:05,000\nПервый субтитр\n\n2\n00:00:12,000 --> 00:00:18,000\nВторой субтитр\n' \
    > "$WORK/ru.srt"
printf '1\n00:00:01,000 --> 00:00:05,000\nFirst subtitle\n\n2\n00:00:12,000 --> 00:00:18,000\nSecond subtitle\n' \
    > "$WORK/en.srt"
TRACKS=($(video 1280x720 25 30) $(audio 30 48000 stereo 440) $(audio 30 48000 5.1 660)
    -i "$WORK/ru.srt" -i "$WORK/en.srt" -i "$WORK/chapters.txt"
    -map 0 -map 1 -map 2 -map 3 -map 4 -map_chapters 5 -c:v libx264 -crf 26
    -metadata:s:a:0 language=rus -metadata:s:a:0 title=Русский
    -metadata:s:a:1 language=eng -metadata:s:a:1 title="English 5.1"
    -metadata:s:s:0 language=rus -metadata:s:s:1 language=eng)
gen 07-tracks/2-audio-2-subs-chapters.mkv "${TRACKS[@]}" -c:a:0 aac -c:a:1 ac3 -c:s srt
gen 07-tracks/2-audio-2-subs-chapters.mp4 "${TRACKS[@]}" -c:a aac -c:s mov_text
gen 07-tracks/2-audio-2-subs-chapters.mov "${TRACKS[@]}" -c:a aac -c:s mov_text
gen "$WORK/rotate.mp4" $(video 1280x720 30) $(audio) -c:v libx264 -crf 26 -c:a aac
gen 07-tracks/rotated-90.mp4 -display_rotation 90 -i "$WORK/rotate.mp4" -c copy
gen 07-tracks/rotated-180.mp4 -display_rotation 180 -i "$WORK/rotate.mp4" -c copy
gen 07-tracks/rotated-270.mov -display_rotation 270 -i "$WORK/rotate.mp4" -c copy
gen 07-tracks/video-only-no-audio.mp4 $(video 1280x720 30) -c:v libx264 -crf 26
gen 07-tracks/subtitles-only.mkv -i "$WORK/ru.srt" -c:s srt

echo "08 web formats"
gen 08-web/vp8-vorbis.webm $(video 1280x720 30) $(audio 10 48000) -c:v libvpx -b:v 2M -c:a vorbis -strict -2
gen 08-web/vp9-opus.webm $(video 1280x720 30) $(audio) -c:v libvpx-vp9 -b:v 1.5M -deadline realtime -cpu-used 8 \
    -c:a libopus
gen 08-web/av1-opus.webm $(video 1280x720 30) $(audio) -c:v libsvtav1 -preset 10 -crf 35 -c:a libopus
gen 08-web/av1-aac.mp4 $(video 1280x720 30) $(audio) -c:v libsvtav1 -preset 10 -crf 35 -c:a aac
gen 08-web/h264-aac.mkv $(video 1920x1080 30) $(audio) -c:v libx264 -crf 26 -c:a aac
gen 08-web/hevc-flac.mkv $(video 1920x1080 30) $(audio) -c:v libx265 -preset fast -crf 28 \
    -x265-params log-level=error -c:a flac
gen 08-web/vp9-opus.mkv $(video 1280x720 30) $(audio) -c:v libvpx-vp9 -b:v 1.5M -deadline realtime -cpu-used 8 \
    -c:a libopus
take 08-web/hdr10-pq.mp4 "$HDR/RED_XMAS_OpenDRT_0080_HDR_FCPX_PQ.mp4"
take 08-web/hlg-grayscale.mkv "$HDR/Grayscale%20BT.2100%20HLG.mkv"
take 08-web/dolby-vision.mkv "$HDR/quietvoid/02themeg-dovi.mkv"

echo "09 read-only formats (saved as MKV/MKA)"
take 09-read-only/rv40-cook-5.1.rmvb "$MPLAYER/real/AC-cook/cook_5.1/hotel_california_ra5.1_640x480_30s.rmvb"
take 09-read-only/realvideo.rm "$MPLAYER/real/90009885H.rm"
take 09-read-only/monkeys-audio.ape "$MPLAYER/A-codecs/lossless/luckynight.ape"
take 09-read-only/monkeys-audio-2.ape "$MPLAYER/monkeyaudio/sh3.ape"

echo "10 damaged"
gen "$WORK/base.mp4" $(video 1280x720 30 60) $(audio 60) -c:v libx264 -crf 26 -c:a aac
gen "$WORK/base-faststart.mp4" -i "$WORK/base.mp4" -c copy -movflags +faststart
gen "$WORK/base.mkv" -i "$WORK/base.mp4" -c copy
gen "$WORK/base.mp3" $(audio 60 44100) -c:a libmp3lame
cut_file() { # <source> <percent> <relative output>
    [[ -s "$OUT/$3" ]] && return 0
    note "$3"
    head -c $(( $(stat -f %z "$1") * $2 / 100 )) "$1" > "$OUT/$3"
}
mkdir -p "$OUT/10-damaged"
cut_file "$WORK/base.mp4" 70 10-damaged/truncated-no-index.mp4
cut_file "$WORK/base-faststart.mp4" 50 10-damaged/truncated-index-points-past-end.mp4
cut_file "$WORK/base.mkv" 50 10-damaged/truncated.mkv
cut_file "$WORK/base.mp3" 50 10-damaged/truncated.mp3
if [[ ! -s "$OUT/10-damaged/mkv-without-cues.mkv" ]]; then
    note "10-damaged/mkv-without-cues.mkv"
    # Matroska written to a pipe gets neither Cues (the seek index) nor a duration.
    "${FF[@]}" -i "$WORK/base.mp4" -c copy -f matroska pipe:1 > "$OUT/10-damaged/mkv-without-cues.mkv"
fi
if [[ ! -s "$OUT/10-damaged/garbage-in-the-middle.mp4" ]]; then
    note "10-damaged/garbage-in-the-middle.mp4"
    cp "$WORK/base-faststart.mp4" "$OUT/10-damaged/garbage-in-the-middle.mp4"
    dd if=/dev/urandom of="$OUT/10-damaged/garbage-in-the-middle.mp4" bs=1k count=512 conv=notrunc \
        seek=$(( $(stat -f %z "$WORK/base-faststart.mp4") / 2048 )) 2>/dev/null
fi
cp -n "$WORK/base.mkv" "$OUT/10-damaged/mkv-named-as.mp4" 2>/dev/null || true
cp -n "$WORK/base.mp3" "$OUT/10-damaged/mp3-named-as.wav" 2>/dev/null || true
cp -n "$OUT/08-web/vp9-opus.webm" "$OUT/10-damaged/webm-named-as.mov" 2>/dev/null || true
cp -n "$WORK/base.mp4" "$OUT/10-damaged/mp4-without-extension" 2>/dev/null || true
[[ -e "$OUT/10-damaged/text-named-as.mp4" ]] || echo "Это не видео, а текстовый файл." > "$OUT/10-damaged/text-named-as.mp4"
[[ -e "$OUT/10-damaged/empty.mov" ]] || : > "$OUT/10-damaged/empty.mov"

echo "11 file system"
mkdir -p "$OUT/11-file-system"
cp -n "$WORK/rotate.mp4" "$OUT/11-file-system/Отпуск на море 🎬 (финал) — v2.mp4" 2>/dev/null || true
cp -n "$WORK/rotate.mp4" "$OUT/11-file-system/name.with.many.dots.mp4" 2>/dev/null || true
ln -sf "Отпуск на море 🎬 (финал) — v2.mp4" "$OUT/11-file-system/symlink.mp4"
if [[ ! -d "$OUT/11-file-system/read-only-folder" ]]; then
    mkdir -p "$OUT/11-file-system/read-only-folder"
    cp "$WORK/rotate.mp4" "$OUT/11-file-system/read-only-folder/clip.mp4"
    chmod 555 "$OUT/11-file-system/read-only-folder"
fi
if [[ ! -e "$OUT/11-file-system/locked-file.mp4" ]]; then
    cp "$WORK/rotate.mp4" "$OUT/11-file-system/locked-file.mp4"
    chflags uchg "$OUT/11-file-system/locked-file.mp4"
fi

cp "$(dirname "$0")/../docs/test-media.md" "$OUT/README.md"
echo
du -sh "$OUT"
if (( ${#FAILED[@]} )); then
    echo "Failed: ${FAILED[*]}" >&2
    exit 1
fi
