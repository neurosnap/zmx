#!/usr/bin/env bash
set -euo pipefail

export ZMX_SESSION_PREFIX="${ZMX_SESSION_PREFIX:-ci.zmx.}"
EVENT_TYPE="${PICO_CI_EVENT_TYPE:-manual}"

echo "running ci event=${EVENT_TYPE} session=${ZMX_SESSION_PREFIX}"

zmx run build docker build -t zig-zmx .
zmx run fmt -d docker run --rm -it zig-zmx zig fmt --check .
zmx run test -d docker run --rm -it zig-zmx zig build test
zmx run integration -d docker run --rm -it zig-zmx zig build test-integration
zmx wait "*"

if [[ $EVENT_TYPE != "release" ]]; then
  echo "success!"
  exit 0
fi

NEW_VERSION="0.6.0"
zmx run semver sed -i "s/\.version = \"[^\"]*\"/.version = \"$NEW_VERSION\"/" build.zig.zon && cat build.zig.zon
zmx run build-release -d docker run --rm -it -v "$(pwd)":/app zig-zmx zig build release
# zmx run upload -d docker run --rm -it -v "$(pwd)":/app -v ~/.ssh:/root/.ssh:ro zig-zmx zig build upload
zmx wait "*"

echo "success!"
