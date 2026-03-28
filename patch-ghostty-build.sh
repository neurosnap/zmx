#!/usr/bin/env bash
# Patch ghostty's build.zig in the zig cache to skip XCFramework/macOS
# app builds when emit_xcframework is false.
#
# Why: ghostty's build.zig unconditionally initializes XCFramework and
# macOS app artifacts on Darwin, which requires the iOS SDK. zmx only
# needs ghostty-vt and passes emit-xcframework=false, but the init
# happens before that option is checked. This patch moves the init
# inside the emit guard.
#
# Zig has no equivalent of pnpm patch or cargo patch — this script is
# the practical solution for a small dependency build-system fix.
set -euo pipefail

# Ensure dependencies are fetched
zig build --fetch 2>/dev/null || true

# Find ghostty's build.zig in the zig cache
GHOSTTY_BUILD=$(find ~/.cache/zig/p .zig-cache/p 2>/dev/null -maxdepth 2 -name "build.zig" -path "*/ghostty-*" -print -quit)

if [ -z "$GHOSTTY_BUILD" ]; then
  echo "Error: could not find ghostty build.zig in zig cache" >&2
  exit 1
fi

# Check if already patched
if grep -q "isDarwin() and config.emit_xcframework" "$GHOSTTY_BUILD"; then
  echo "Already patched: $GHOSTTY_BUILD"
  exit 0
fi

echo "Patching: $GHOSTTY_BUILD"

# We need to patch two specific blocks where XCFramework.init is called
# unconditionally on Darwin. Both are guarded by isDarwin() but should
# also require emit_xcframework.
#
# Block 1 (line ~150): xcframework + macos app init
# Block 2 (line ~205): xcframework_native for run step

python3 - "$GHOSTTY_BUILD" << 'PYTHON'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Patch 1: Main xcframework block
# Before: if (config.target.result.os.tag.isDarwin()) {\n        // Ghostty xcframework
# After:  if (config.target.result.os.tag.isDarwin() and config.emit_xcframework) {
old1 = 'if (config.target.result.os.tag.isDarwin()) {\n        // Ghostty xcframework'
new1 = 'if (config.target.result.os.tag.isDarwin() and config.emit_xcframework) {\n        // Ghostty xcframework'
assert old1 in content, "Patch 1 target not found — ghostty build.zig may have changed"
content = content.replace(old1, new1, 1)

# Patch 2: Run step xcframework block
# Before: if (config.target.result.os.tag.isDarwin()) {\n            const xcframework_native
# After:  if (config.target.result.os.tag.isDarwin() and config.emit_xcframework) {
old2 = 'if (config.target.result.os.tag.isDarwin()) {\n            const xcframework_native'
new2 = 'if (config.target.result.os.tag.isDarwin() and config.emit_xcframework) {\n            const xcframework_native'
assert old2 in content, "Patch 2 target not found — ghostty build.zig may have changed"
content = content.replace(old2, new2, 1)

with open(path, 'w') as f:
    f.write(content)

print(f"Applied 2 patches to {path}")
PYTHON
