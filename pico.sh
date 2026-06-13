#!/usr/bin/env bash
set -euo pipefail

export ZMX_SESSION_PREFIX="${ZMX_SESSION_PREFIX:-ci.zmx.}"
EVENT_TYPE="${PICO_CI_EVENT_TYPE:-manual}"

echo "running ci event=${EVENT_TYPE} session=${ZMX_SESSION_PREFIX}"

zmx run build docker build -t zig-zmx .
zmx run fmt -d docker run --rm -t zig-zmx:latest zig fmt --check .
zmx run test -d docker run --rm -t zig-zmx:latest zig build test
zmx run integration -d docker run --rm -t zig-zmx:latest bats test/session.bats
zmx wait "*"

if [[ $EVENT_TYPE != "git.tag" ]]; then
  echo "success!"
  exit 0
fi

TAG="${PICO_CI_TAG_NAME}"
NEW_VERSION="${PICO_CI_TAG_NAME#v}"

zmx run semver sed -i "s/\.version = \"[^\"]*\"/.version = \"$NEW_VERSION\"/" build.zig.zon && cat build.zig.zon
zmx run update-readme sed -i "s/zmx-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/zmx-$NEW_VERSION/g" README.md
zmx run build-release -d docker run --rm -t zig-zmx:latest zig build release

echo "distributing bins"
zmx run upload-build docker build -t zmx-upload -f Dockerfile.upload .
zmx run upload docker run --rm \
  -v "$(pwd)/README.md:/app/README.md:ro" \
  -v "$(pwd)/logo.png:/app/logo.png:ro" \
  -v "$(pwd)/index.tmpl:/app/index.tmpl:ro" \
  -v "$(pwd)/zig-out/dist:/app/dist:ro" \
  -v ~/.ssh:/root/.ssh:ro \
  zmx-upload
zmx run gh-build docker build -t gh-release -f Dockerfile.release .
zmx run gh docker run --rm \
  -v "$(pwd)/zig-out/dist":/dist \
  -e GH_TOKEN \
  -e TAG="$TAG" \
  gh-release

echo "success!"
