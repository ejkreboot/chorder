#!/bin/bash
set -euo pipefail

# Universal FFmpeg builder with optional safe mode (disable asm) and dSYM generation.
# Adds verification & single-arch capabilities for faster iteration.
# Usage: ./scripts/macos_build_ffmpeg_universal.sh [--sign] [--verify] [--arch arm64|x86_64] [--min-version 11.0]
#  --safe         : disables assembly for both arches (helps avoid SIGILL issues)
#  --sign         : code sign the final binary
#  --verify       : run 'ffmpeg -version' for each built slice and the universal binary (fail fast on SIGILL)
#  --arch <arch>  : build only a single architecture (arm64 or x86_64); skips lipo
#  --min-version <ver> : set MACOSX_DEPLOYMENT_TARGET (default 11.0)

FFMPEG_VERSION="6.1"
FFMPEG_DIR="ffmpeg-$FFMPEG_VERSION"
OUTPUT_DIR="build_ffmpeg"
SIGN=false
VERIFY=false
SINGLE_ARCH=""
MACOSX_MIN="11.0"
IDENTITY="${IDENTITY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN=true; shift ;;
    --verify) VERIFY=true; shift ;;
    --arch)
      SINGLE_ARCH="$2"; shift 2 ;;
    --min-version)
      MACOSX_MIN="$2"; shift 2 ;;
    --identity)
      IDENTITY="$2"; shift 2 ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [options]
  --sign                 Codesign resulting ffmpeg (requires --identity or IDENTITY env)
  --verify               Execute ffmpeg -version to validate slices
  --arch <arm64|x86_64>  Single-arch build (skip universal lipo)
  --min-version <ver>    Set MACOSX_DEPLOYMENT_TARGET (default 11.0)
  --identity "Developer ID Application: Your Name (XX9X9X9XX9)"  Override signing identity

Environment:
  IDENTITY  Developer ID Application identity if --sign used

Examples:
  IDENTITY="Developer ID Application: Your Name (XX9X9X9XX9)" $0 --sign --verify
  $0 --arch arm64 --verify
USAGE
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done


echo "▶ Building FFmpeg $FFMPEG_VERSION SIGN=$SIGN VERIFY=$VERIFY SINGLE_ARCH=${SINGLE_ARCH:-both} MACOSX_MIN=$MACOSX_MIN"

if [ ! -d "$FFMPEG_DIR" ]; then
  echo "Downloading FFmpeg $FFMPEG_VERSION..."
  curl -L -O https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2
  tar xjf ffmpeg-$FFMPEG_VERSION.tar.bz2
fi

if [[ -n "$SINGLE_ARCH" ]]; then
  if [[ "$SINGLE_ARCH" != "arm64" && "$SINGLE_ARCH" != "x86_64" ]]; then
    echo "Invalid --arch value: $SINGLE_ARCH"; exit 1
  fi
  mkdir -p "$OUTPUT_DIR/$SINGLE_ARCH"
else
  mkdir -p "$OUTPUT_DIR/arm64" "$OUTPUT_DIR/x86_64"
fi

common_flags=(
  --disable-everything
  --enable-protocol=file
  --enable-decoder=mp3,pcm_s16le
  --enable-encoder=pcm_s16le
  --enable-demuxer=mp3,wav
  --enable-muxer=wav,pcm_s16le
  --enable-filter=aresample
  --enable-small
  --disable-network
  --disable-autodetect
  --disable-doc
  --enable-static
  --disable-shared
  --disable-asm
)

build_arch() {
  local ARCH=$1
  local PREFIX=$2

  echo "⚙️  Configuring $ARCH -> $PREFIX"
  make distclean || true
  export MACOSX_DEPLOYMENT_TARGET="$MACOSX_MIN"
  ./configure \
    --prefix="$PREFIX" \
    --arch=$ARCH \
    --target-os=darwin \
    "${common_flags[@]}" \
    --cc="clang" \
    --extra-cflags="-arch $ARCH -g -mmacosx-version-min=$MACOSX_MIN" \
    --extra-ldflags="-arch $ARCH -mmacosx-version-min=$MACOSX_MIN" \
    --enable-cross-compile
  make -j"$(sysctl -n hw.ncpu)"
  make install
}

pushd "$FFMPEG_DIR" >/dev/null
if [[ -n "$SINGLE_ARCH" ]]; then
  build_arch "$SINGLE_ARCH" "../$OUTPUT_DIR/$SINGLE_ARCH"
else
  build_arch arm64 "../$OUTPUT_DIR/arm64"
  build_arch x86_64 "../$OUTPUT_DIR/x86_64"
fi
popd >/dev/null

if [[ -z "$SINGLE_ARCH" ]]; then
  mkdir -p "$OUTPUT_DIR/universal/bin"
  echo "🧬 Creating universal binary"
  lipo -create \
    "$OUTPUT_DIR/arm64/bin/ffmpeg" \
    "$OUTPUT_DIR/x86_64/bin/ffmpeg" \
    -output "$OUTPUT_DIR/universal/bin/ffmpeg"
  FINAL_BIN="$OUTPUT_DIR/universal/bin/ffmpeg"
else
  FINAL_BIN="$OUTPUT_DIR/$SINGLE_ARCH/bin/ffmpeg"
fi

require_identity() {
  if [[ -z "${IDENTITY:-}" ]]; then
    cat <<'EOF'
❌ No signing identity set (IDENTITY env var not defined).

Set your codesigning identity first, for example:
  export IDENTITY="Developer ID Application: Your Name (XX9X9X9XX9)"

List available identities:
  security find-identity -p codesigning -v
EOF
    exit 1
  fi
}

if [[ "$SIGN" == true ]]; then
  require_identity
  echo "🔏 Code signing with IDENTITY: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    "$FINAL_BIN"
fi

RESOURCE_TARGET="./macos/Runner/Resources"
FFMPEG_TARGET="$RESOURCE_TARGET/ffmpeg"
LICENSE_TARGET="$RESOURCE_TARGET/LICENSE.md"

echo "📦 Copying binary + LICENSE.md into $RESOURCE_TARGET"
mkdir -p "$RESOURCE_TARGET"
cp "$FINAL_BIN" "$FFMPEG_TARGET"
chmod +x "$FFMPEG_TARGET"

if [ -f "$FFMPEG_DIR/LICENSE.md" ]; then
  cp "$FFMPEG_DIR/LICENSE.md" "$LICENSE_TARGET"
else
  echo "⚠️  LICENSE.md missing; not copied"
fi

if $VERIFY; then
  echo "🔍 Verifying binary execution"
  if ! "$FINAL_BIN" -hide_banner -loglevel error -version >/dev/null 2>&1; then
    echo "❌ Verification failed (cannot execute ffmpeg)"; exit 1
  fi
  echo "✅ Verification succeeded"
fi

echo "✅ Built ffmpeg at $FINAL_BIN and copied to $FFMPEG_TARGET"
echo "(Artifacts retained for inspection; no cleanup performed.)"
