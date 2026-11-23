#!/bin/bash
# 可选独立 macOS 驱动；parent 仍负责接入原 run_media_tests.sh/main。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TESTS="$ROOT/Tests/Media"
python3 "$TESTS/Support/check_avatar_runtime_test_contract.py"
if ! command -v xcrun >/dev/null 2>&1; then
  echo 'FAIL AvatarRuntime: xcrun required; not executed on this non-macOS host.' >&2
  exit 2
fi
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dyyy-avatar-runtime.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
cat > "$BUILD_DIR/main.m" <<'MAIN'
#import <Foundation/Foundation.h>
extern int DYYYRunAvatarActionRuntimeTests(void);
int main(void) { @autoreleasepool { return DYYYRunAvatarActionRuntimeTests(); } }
MAIN
xcrun --sdk macosx clang -fobjc-arc -fblocks -O1 -g \
  -Werror=implicit-function-declaration \
  -I"$TESTS/Support" -I"$ROOT/Sources/Features" \
  "$TESTS/DYYYAvatarActionRuntimeTests.m" "$BUILD_DIR/main.m" \
  -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -o "$BUILD_DIR/DYYYAvatarActionRuntimeTests"
"$BUILD_DIR/DYYYAvatarActionRuntimeTests"
