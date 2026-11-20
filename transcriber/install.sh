#!/bin/sh
# Installs the transcriber on a Linux machine: whisper.cpp, a Whisper model, and transcribe.sh.
# Run it on the transcriber machine. It does not need root.
#   sh install.sh [directory]      The default directory is ~/loomy-whisper.
# The build uses CUDA when nvcc is in /usr/local/cuda/bin or in PATH.
set -eu

VERSION="v1.9.5"
MODEL="large-v3-turbo"
DIR="${1:-$HOME/loomy-whisper}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for tool in git cmake make g++ ffmpeg; do
  command -v "$tool" >/dev/null || { echo "Install $tool first." >&2; exit 1; }
done

if [ ! -d "$DIR/.git" ]; then
  git clone --quiet --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$DIR"
fi
git -C "$DIR" -c advice.detachedHead=false fetch --quiet --depth 1 origin tag "$VERSION"
git -C "$DIR" -c advice.detachedHead=false checkout --quiet "$VERSION"

PATH="/usr/local/cuda/bin:$PATH"
CUDA="OFF"
command -v nvcc >/dev/null && CUDA="ON"
echo "Build whisper.cpp $VERSION (CUDA: $CUDA)."
cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA="$CUDA" \
  -DCMAKE_CUDA_ARCHITECTURES=native >"$DIR/cmake.log" 2>&1 || { tail -20 "$DIR/cmake.log" >&2; exit 1; }
cmake --build "$DIR/build" --config Release --target whisper-cli -j "$(nproc)" >"$DIR/build.log" 2>&1 \
  || { tail -20 "$DIR/build.log" >&2; exit 1; }

if [ ! -s "$DIR/models/ggml-$MODEL.bin" ]; then
  echo "Download the model $MODEL."
  sh "$DIR/models/download-ggml-model.sh" "$MODEL" >/dev/null
fi

cp "$HERE/transcribe.sh" "$DIR/transcribe"
chmod 755 "$DIR/transcribe"
echo "The transcriber is ready: $DIR/transcribe"
