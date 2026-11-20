#!/bin/sh
# Reads audio on stdin, in a format that ffmpeg can read. Writes WebVTT captions on stdout.
# install.sh copies this script next to the whisper.cpp build.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${LOOMY_WHISPER_MODEL:-$DIR/models/ggml-large-v3-turbo.bin}"
LANGUAGE="${LOOMY_WHISPER_LANGUAGE:-en}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

cat >"$TMP/input"
ffmpeg -nostdin -hide_banner -loglevel error -i "$TMP/input" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$TMP/audio.wav"
# -ml 80 -sow: a cue has a maximum of 80 characters, and a split occurs only between words.
if ! "$DIR/build/bin/whisper-cli" -m "$MODEL" -f "$TMP/audio.wav" -l "$LANGUAGE" -ovtt -of "$TMP/out" -np \
  -ml 80 -sow \
  >/dev/null 2>"$TMP/log"; then
  tail -20 "$TMP/log" >&2
  exit 1
fi
# whisper.cpp starts each cue text with a space.
sed 's/^ //' "$TMP/out.vtt"
