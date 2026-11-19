#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FEATURES="$ROOT/Sources/Features"
TESTS="$ROOT/Tests/Media"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dyyy-media-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

for file in \
  "$TESTS/DYYYLikeMediaTests.m" \
  "$FEATURES/DYYYLikeLivePhotoBuilder.h" \
  "$FEATURES/DYYYLikeLivePhotoBuilder.m" \
  "$FEATURES/DYYYLikeAnimatedImage.h" \
  "$FEATURES/DYYYLikeAnimatedImage.m"; do
  if [[ ! -f "$file" ]]; then
    echo "FAIL missing required media test/helper file: $file" >&2
    exit 2
  fi
done

if ! command -v xcrun >/dev/null 2>&1; then
  echo "FAIL xcrun is required; run this test on macOS (e.g. GitHub Actions macos-latest)." >&2
  exit 2
fi

set -x
xcrun --sdk macosx clang \
  -fobjc-arc -fblocks -O1 -g \
  -I"$FEATURES" \
  "$TESTS/DYYYLikeMediaTests.m" \
  "$FEATURES/DYYYLikeLivePhotoBuilder.m" \
  "$FEATURES/DYYYLikeAnimatedImage.m" \
  -framework Foundation \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework AudioToolbox \
  -o "$BUILD_DIR/DYYYLikeMediaTests"
set +x
"$BUILD_DIR/DYYYLikeMediaTests"
