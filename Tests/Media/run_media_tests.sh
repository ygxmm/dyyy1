#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FEATURES="$ROOT/Sources/Features"
TESTS="$ROOT/Tests/Media"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dyyy-media-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

for file in \
  "$TESTS/DYYYLikeMediaTests.m" \
  "$TESTS/DYYYMediaSourceSelectionTests.m" \
  "$TESTS/DYYYVideoQualityPolicyTests.m" \
  "$TESTS/DYYYSettingsBackupValidationTests.m" \
  "$TESTS/DYYYABConfigValidationTests.m" \
  "$TESTS/DYYYDownloadLifecycleTests.m" \
  "$TESTS/DYYYHDRMetadataTests.m" \
  "$TESTS/DYYYAvatarSurroundingPolicyTests.m" \
  "$TESTS/DYYYAvatarInteractionPolicyTests.m" \
  "$TESTS/DYYYAvatarActionRuntimeTests.m" \
  "$TESTS/DYYYFullscreenGeometryTests.m" \
  "$TESTS/DYYYNowPlayingPolicyTests.m" \
  "$TESTS/check_fullscreen_frame_stability.py" \
  "$ROOT/Sources/Features/DYYYFullscreenGeometry.h" \
  "$ROOT/Sources/Features/DYYYFullscreenGeometry.m" \
  "$FEATURES/DYYYNowPlayingPrivacy.h" \
  "$FEATURES/DYYYNowPlayingPrivacy.m" \
  "$FEATURES/DYYYNowPlayingPolicy.h" \
  "$FEATURES/DYYYNowPlayingPolicy.m" \
  "$ROOT/Sources/Media/DYYYVideoQualityPolicy.h" \
  "$ROOT/Sources/Media/DYYYVideoQualityPolicy.m" \
  "$ROOT/Sources/Core/DYYYABConfigValidation.m" \
  "$ROOT/Sources/Settings/DYYYSettingsBackupValidation.m" \
  "$FEATURES/DYYYAvatarSurroundingPolicy.h" \
  "$FEATURES/DYYYAvatarInteractionPolicy.h" \
  "$FEATURES/DYYYAvatarActionRuntime.h" \
  "$TESTS/check_avatar_interaction_integration.py" \
  "$TESTS/Support/UIKit/UIKit.h" \
  "$TESTS/Support/DYYYAvatarUIKitDouble.inc" \
  "$TESTS/Support/DYYYAvatarRuntimeDispatch.inc" \
  "$TESTS/Support/check_avatar_runtime_test_contract.py" \
  "$ROOT/Sources/Media/DYYYMediaSourceSelection.h" \
  "$ROOT/Sources/Media/DYYYMediaSourceSelection.m" \
  "$FEATURES/DYYYLikeLivePhotoBuilder.h" \
  "$FEATURES/DYYYLikeLivePhotoBuilder.m" \
  "$FEATURES/DYYYLikeAnimatedImage.h" \
  "$FEATURES/DYYYLikeAnimatedImage.m" \
  "$ROOT/Sources/Media/DYYYAlbumImageDescription.h" \
  "$ROOT/Sources/Media/DYYYAlbumImageDescription.m"; do
  if [[ ! -f "$file" ]]; then
    echo "FAIL missing required media test/helper file: $file" >&2
    exit 2
  fi
done

python3 "$TESTS/check_video_quality_integration.py"
python3 "$TESTS/check_maintenance_integration.py"
python3 "$TESTS/check_avatar_interaction_integration.py"
python3 "$TESTS/Support/check_avatar_runtime_test_contract.py"
python3 "$TESTS/check_story_layout_integration.py"
python3 "$TESTS/check_fullscreen_frame_stability.py"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "FAIL xcrun is required; run this test on macOS (e.g. GitHub Actions macos-latest)." >&2
  exit 2
fi

set -x
xcrun --sdk macosx clang \
  -fobjc-arc -fblocks -O1 -g \
  -I"$FEATURES" \
  -I"$TESTS/Support" \
  -I"$ROOT/Sources/Core" \
  -I"$ROOT/Sources/Media" \
  -I"$ROOT/Sources/Settings" \
  "$TESTS/DYYYLikeMediaTests.m" \
  "$TESTS/DYYYMediaSourceSelectionTests.m" \
  "$TESTS/DYYYVideoQualityPolicyTests.m" \
  "$TESTS/DYYYSettingsBackupValidationTests.m" \
  "$TESTS/DYYYABConfigValidationTests.m" \
  "$TESTS/DYYYDownloadLifecycleTests.m" \
  "$TESTS/DYYYHDRMetadataTests.m" \
  "$TESTS/DYYYAvatarSurroundingPolicyTests.m" \
  "$TESTS/DYYYAvatarInteractionPolicyTests.m" \
  "$TESTS/DYYYAvatarActionRuntimeTests.m" \
  "$TESTS/DYYYFullscreenGeometryTests.m" \
  "$FEATURES/DYYYFullscreenGeometry.m" \
  "$TESTS/DYYYNowPlayingPolicyTests.m" \
  "$FEATURES/DYYYNowPlayingPolicy.m" \
  "$ROOT/Sources/Media/DYYYVideoQualityPolicy.m" \
  "$ROOT/Sources/Core/DYYYABConfigValidation.m" \
  "$ROOT/Sources/Settings/DYYYSettingsBackupValidation.m" \
  "$ROOT/Sources/Media/DYYYMediaSourceSelection.m" \
  "$FEATURES/DYYYLikeLivePhotoBuilder.m" \
  "$FEATURES/DYYYLikeAnimatedImage.m" \
  "$ROOT/Sources/Media/DYYYAlbumImageDescription.m" \
  -framework Foundation \
  -framework QuartzCore \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework AudioToolbox \
  -o "$BUILD_DIR/DYYYLikeMediaTests"
set +x
"$BUILD_DIR/DYYYLikeMediaTests"
