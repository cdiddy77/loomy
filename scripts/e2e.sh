#!/usr/bin/env bash
# End-to-end test. It runs the Worker locally and publishes test videos with the CLI.
# The test does not use a Cloudflare account.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.e2e"
PORT=8799
export LOOMY_URL="http://127.0.0.1:$PORT"
export LOOMY_ADMIN_TOKEN="e2e-token-0123456789abcdef0123456789abcdef"
export LOOMY_DATA_DIR="$WORK/data"
export LOOMY_NO_CLIPBOARD=1
export LOOMY_ARCHIVE="$WORK/archive"
LOOMY="node $ROOT/cli/dist/index.js"
SERVER_PID=""

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
trap stop_server EXIT

start_server() { # $1 = storage budget in bytes
  (cd "$ROOT/worker" && exec npx wrangler dev --port "$PORT" --persist-to "$WORK/state" --test-scheduled \
    --var "ADMIN_TOKEN:$LOOMY_ADMIN_TOKEN" --var "STORAGE_BUDGET_BYTES:$1" >"$WORK/server.log" 2>&1) &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    curl -s -o /dev/null "$LOOMY_URL/" && return 0
    sleep 0.5
  done
  cat "$WORK/server.log" >&2
  fail "the Worker did not start"
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

rm -rf "$WORK" && mkdir -p "$WORK/archive"
# The local test does not use the database ID, so the example configuration is sufficient.
[ -f "$ROOT/worker/wrangler.jsonc" ] || cp "$ROOT/worker/wrangler.example.jsonc" "$ROOT/worker/wrangler.jsonc"
(cd "$ROOT" && pnpm -s build)
(cd "$ROOT/worker" && npx wrangler d1 migrations apply loomy --local --persist-to "$WORK/state" >/dev/null)

# A small video, and a large video that needs a multipart upload.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=1280x720:rate=30 -f lavfi -i sine=frequency=440 \
  -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$WORK/small.mov"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "nullsrc=size=1920x1080:rate=30,geq=random(1)*255:128:128" \
  -t 3 -c:v libx264 -preset ultrafast -qp 10 -pix_fmt yuv420p "$WORK/large.mov"

start_server 8000000000

# --- Publish -----------------------------------------------------------------
URL_A="$($LOOMY publish "$WORK/small.mov" --title 'Test <A> & "quotes"')"
ID_A="${URL_A##*/}"
[[ "$ID_A" =~ ^[A-Za-z0-9_-]{22}$ ]] || fail "the ID is not valid: $ID_A"
pass "publish prints a link"

PAGE="$(curl -s "$URL_A")"
grep -q 'Test &lt;A&gt; &amp; &quot;quotes&quot;' <<<"$PAGE" || fail "the watch page does not escape the title"
grep -q "<video" <<<"$PAGE" || fail "the watch page has no video element"
pass "the watch page shows the escaped title"

HEADERS="$(curl -s -D - -o /dev/null "$URL_A")"
grep -qi "content-security-policy: default-src 'none'" <<<"$HEADERS" || fail "no CSP header"
grep -qi "x-robots-tag: noindex" <<<"$HEADERS" || fail "no robots header"
pass "the watch page has the security headers"

# --- Media and ranges --------------------------------------------------------
curl -s -o "$WORK/a.mp4" "$URL_A/video.mp4"
cmp -s "$WORK/a.mp4" "$LOOMY_DATA_DIR/$ID_A/video.mp4" || fail "the downloaded video is different"
pass "the video downloads without changes"

RANGE="$(curl -s -D - -o "$WORK/range.bin" -H 'Range: bytes=100-199' "$URL_A/video.mp4")"
grep -q "206" <<<"$(head -1 <<<"$RANGE")" || fail "a range request does not return 206"
grep -qi "content-range: bytes 100-199/" <<<"$RANGE" || fail "the content-range header is wrong"
[ "$(wc -c <"$WORK/range.bin" | tr -d ' ')" = "100" ] || fail "the range body is not 100 bytes"
cmp -s "$WORK/range.bin" <(dd if="$WORK/a.mp4" bs=1 skip=100 count=100 2>/dev/null) || fail "the range bytes are wrong"
pass "range requests work"

SUFFIX="$(curl -s -D - -o /dev/null -H 'Range: bytes=-50' "$URL_A/video.mp4")"
grep -q "206" <<<"$(head -1 <<<"$SUFFIX")" || fail "a suffix range does not return 206"
pass "suffix range requests work"

[ "$(status "$URL_A/thumb.jpg")" = "200" ] || fail "no thumbnail"
[ "$(status "$URL_A/captions.vtt")" = "404" ] || fail "captions must not exist"
[ "$(status "$URL_A/other.txt")" = "404" ] || fail "an unknown file name must return 404"
pass "the thumbnail exists, and unknown files return 404"

# --- Access control ----------------------------------------------------------
[ "$(status "$LOOMY_URL/")" = "404" ] || fail "the root must return 404"
[ "$(status "$LOOMY_URL/v/AAAAAAAAAAAAAAAAAAAAAA")" = "404" ] || fail "an unknown ID must return 404"
[ "$(status "$LOOMY_URL/admin/videos")" = "404" ] || fail "admin without a token must return 404"
[ "$(status -H 'Authorization: Bearer wrong' "$LOOMY_URL/admin/videos")" = "404" ] || fail "admin with a wrong token must return 404"
[ "$(status -X PUT --data-binary x "$LOOMY_URL/admin/videos/$ID_A/files/video.mp4")" = "404" ] || fail "upload without a token must return 404"
[ "$(status -X POST "$URL_A")" = "405" ] || fail "POST to a watch page must return 405"
pass "the admin routes refuse callers without the token"

# --- Multipart upload --------------------------------------------------------
URL_B="$($LOOMY publish "$WORK/large.mov" --title 'Large')"
ID_B="${URL_B##*/}"
SIZE_B="$(wc -c <"$LOOMY_DATA_DIR/$ID_B/video.mp4" | tr -d ' ')"
[ "$SIZE_B" -gt 33554432 ] || fail "the large video is too small for a multipart test ($SIZE_B bytes)"
curl -s -o "$WORK/b.mp4" "$URL_B/video.mp4"
cmp -s "$WORK/b.mp4" "$LOOMY_DATA_DIR/$ID_B/video.mp4" || fail "the multipart video is different"
pass "a multipart upload works ($SIZE_B bytes)"

# --- Captions ----------------------------------------------------------------
printf 'WEBVTT\n\n00:00.000 --> 00:02.000\nHello\n' >"$LOOMY_DATA_DIR/$ID_B/captions.vtt"
[ "$($LOOMY publish "$ID_B")" = "$URL_B" ] || fail "publish again changed the link"
curl -s "$URL_B" | grep -q '<track kind="captions"' || fail "the watch page has no captions track"
[ "$(status "$URL_B/captions.vtt")" = "200" ] || fail "no captions file"
pass "publish again keeps the link and adds the captions"

# --- Eviction ----------------------------------------------------------------
[ "$($LOOMY list --json | grep -c '"state": "ready"')" = "2" ] || fail "list must show two ready videos"
# The budget has space for video B only. Video A is the least recently viewed.
BUDGET="$($LOOMY list --json | node -e 'const v=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(v.find(x=>x.id===process.argv[1]).size_bytes)' "$ID_B")"
stop_server
start_server "$BUDGET"
curl -s -o /dev/null "$LOOMY_URL/__scheduled?cron=17+9+*+*+*"
sleep 1
[ "$(status "$URL_A")" = "410" ] || fail "the eviction job did not evict video A"
[ "$(status "$URL_A/video.mp4")" = "404" ] || fail "the file of video A is not deleted"
[ "$(status "$URL_B")" = "200" ] || fail "the eviction job evicted video B"
pass "the eviction job removes the least recently viewed video"

[ "$($LOOMY publish "$ID_A")" = "$URL_A" ] || fail "publish again changed the link of video A"
[ "$(status "$URL_A")" = "200" ] || fail "video A is not available after publish again"
pass "an evicted video comes back with the same link"

# --- Archive -----------------------------------------------------------------
for f in meta.json video.mp4 thumb.jpg original.mov; do
  [ -f "$LOOMY_ARCHIVE/$ID_A/$f" ] || fail "the archive of video A has no $f"
done
cmp -s "$LOOMY_ARCHIVE/$ID_A/original.mov" "$WORK/small.mov" || fail "the archived original is different"
pass "publish copies the video and the original to the archive"

[ -f "$LOOMY_ARCHIVE/$ID_B/captions.vtt" ] || fail "publish again did not copy the captions to the archive"
pass "publish again updates the archive"

rm -rf "$LOOMY_DATA_DIR/$ID_A"
$LOOMY rm "$ID_A" 2>/dev/null
[ "$(status "$URL_A")" = "410" ] || fail "rm did not remove video A"
[ "$($LOOMY publish "$ID_A")" = "$URL_A" ] || fail "publish from the archive changed the link"
curl -s -o "$WORK/a2.mp4" "$URL_A/video.mp4"
cmp -s "$WORK/a2.mp4" "$WORK/a.mp4" || fail "the video from the archive is different"
[ ! -e "$LOOMY_DATA_DIR/$ID_A/original.mov" ] || fail "restore must not copy the original"
pass "publish gets a video from the archive when no local copy exists"

set +e
LOOMY_ARCHIVE="$WORK/small.mov/x" $LOOMY publish "$ID_A" >"$WORK/out.txt" 2>/dev/null
CODE=$?
set -e
[ "$CODE" = "2" ] || fail "a failed archive copy must give exit code 2, not $CODE"
[ "$(cat "$WORK/out.txt")" = "$URL_A" ] || fail "a failed archive copy must not stop the publish"
pass "a failed archive copy gives a warning and exit code 2"

# --- Transcript --------------------------------------------------------------
# The fake transcribe command keeps the audio that it gets, and writes a fixed transcript.
cat >"$WORK/fake-transcribe.sh" <<FAKE
cat >"$WORK/heard.aac"
printf 'WEBVTT\n\n00:00.000 --> 00:01.000\nFake words\n'
FAKE
FAKE_TRANSCRIBE="sh $WORK/fake-transcribe.sh"

LOOMY_TRANSCRIBE="$FAKE_TRANSCRIBE" $LOOMY transcribe "$ID_A" 2>/dev/null
[ "$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$WORK/heard.aac")" = "aac" ] \
  || fail "the transcribe command did not get the audio"
curl -s "$URL_A/captions.vtt" | grep -q "Fake words" || fail "transcribe did not upload the captions"
curl -s "$URL_A" | grep -q '<track kind="captions"' || fail "the watch page has no captions track after transcribe"
[ -f "$LOOMY_ARCHIVE/$ID_A/captions.vtt" ] || fail "transcribe did not copy the captions to the archive"
pass "transcribe adds the captions to a published video and to the archive"

URL_C="$(LOOMY_TRANSCRIBE="$FAKE_TRANSCRIBE" $LOOMY publish "$WORK/small.mov" --title C 2>/dev/null)"
[ "$(status "$URL_C/captions.vtt")" = "200" ] || fail "publish did not make the transcript"
pass "publish makes the transcript"

URL_D="$(LOOMY_TRANSCRIBE="$FAKE_TRANSCRIBE" $LOOMY publish "$WORK/small.mov" --title D --no-transcript 2>/dev/null)"
[ "$(status "$URL_D/captions.vtt")" = "404" ] || fail "--no-transcript made a transcript"
pass "--no-transcript skips the transcript"

set +e
URL_E="$(LOOMY_TRANSCRIBE="echo broken >&2; exit 3" $LOOMY publish "$WORK/small.mov" --title E 2>"$WORK/err.txt")"
CODE=$?
set -e
[ "$CODE" = "2" ] || fail "a failed transcript must give exit code 2, not $CODE"
[ "$(status "$URL_E")" = "200" ] || fail "a failed transcript must not stop the publish"
grep -q "broken" "$WORK/err.txt" || fail "the warning does not show the error of the transcribe command"
pass "a failed transcript gives a warning and exit code 2"

LOOMY_TRANSCRIBE="$FAKE_TRANSCRIBE" $LOOMY transcribe 2>/dev/null
[ "$(status "$URL_D/captions.vtt")" = "200" ] || fail "transcribe without an ID skipped video D"
[ "$(status "$URL_E/captions.vtt")" = "200" ] || fail "transcribe without an ID skipped video E"
pass "transcribe without an ID adds the missing transcripts"

# --- Time of creation --------------------------------------------------------
curl -s -o /dev/null -X PUT -H "Authorization: Bearer $LOOMY_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  --data '{"title":"Old","durationS":1,"createdAt":1500000000000}' "$LOOMY_URL/admin/videos/BBBBBBBBBBBBBBBBBBBBBB"
$LOOMY list --json | grep -q '"created_at": 1500000000000' || fail "the Worker did not keep the supplied time of creation"
pass "the publish tool can supply the time of creation"

# --- Remove ------------------------------------------------------------------
$LOOMY rm "$ID_B" 2>/dev/null
[ "$(status "$URL_B")" = "410" ] || fail "rm did not remove video B"
pass "rm removes a video"

echo "All end-to-end tests passed."
