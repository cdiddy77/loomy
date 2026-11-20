#!/bin/sh
# Builds "Loomy Recorder.app" and installs it in ~/Applications.
# Run it from a shell where node, ffmpeg, and ffprobe are in PATH. The app keeps these paths,
# because an app that starts from Finder does not get the PATH of the shell.
#   sh recorder/build.sh
# The build uses the first signing identity from this list:
#   1. LOOMY_SIGN_IDENTITY, when it is set.
#   2. An Apple Development certificate. Get one in Xcode: Settings > Accounts > Manage Certificates.
#   3. The certificate from make-signing-identity.sh. With it, macOS does not allow notifications.
# Without a certificate, the build has an ad-hoc signature,
# and macOS asks again for the screen recording permission after each new build.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$(cd "$HERE/../cli" && pwd)/dist/index.js"
# Build the bundle in a temporary folder. A second copy with the same bundle ID confuses Launch Services.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
APP="$STAGE/Loomy Recorder.app"
TARGET="$HOME/Applications/Loomy Recorder.app"

NODE="$(command -v node)" || { echo "Put node in PATH first." >&2; exit 1; }
FFMPEG="$(command -v ffmpeg)" || { echo "Put ffmpeg in PATH first." >&2; exit 1; }
[ -f "$CLI" ] || { echo "Build the CLI first: pnpm build" >&2; exit 1; }
TOOLS="$(dirname "$NODE"):$(dirname "$FFMPEG"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

swift build --package-path "$HERE" -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/.build/release/LoomyRecorder" "$APP/Contents/MacOS/LoomyRecorder"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
plutil -insert LoomyNode -string "$NODE" "$APP/Contents/Info.plist"
plutil -insert LoomyCLI -string "$CLI" "$APP/Contents/Info.plist"
plutil -insert LoomyPath -string "$TOOLS" "$APP/Contents/Info.plist"
KEYCHAIN="$HOME/Library/Keychains/loomy-signing.keychain-db"
SECRET="$HOME/.config/loomy/signing-keychain-password"
# An Apple Development certificate from Xcode is the best choice, because macOS allows notifications only from
# an app with an Apple certificate. Find its SHA-1 hash, so that no name goes into this script.
DEVELOPMENT="$(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2; exit }')"
if [ -n "${LOOMY_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$LOOMY_SIGN_IDENTITY" --identifier dev.loomy.recorder "$APP"
elif [ -n "$DEVELOPMENT" ]; then
  codesign --force --sign "$DEVELOPMENT" --identifier dev.loomy.recorder "$APP"
elif [ -f "$KEYCHAIN" ] && [ -f "$SECRET" ]; then
  # make-signing-identity.sh made this keychain.
  security unlock-keychain -p "$(cat "$SECRET")" "$KEYCHAIN"
  codesign --force --keychain "$KEYCHAIN" --sign "Loomy Recorder Local" --identifier dev.loomy.recorder "$APP"
else
  echo "Use an ad-hoc signature. Run make-signing-identity.sh to keep the permissions after a new build."
  codesign --force --sign - --identifier dev.loomy.recorder "$APP"
fi

# Stop the old copy before the new copy replaces it.
pkill -x LoomyRecorder 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
echo "Installed: $TARGET"
echo "Open it with: open \"$TARGET\""
