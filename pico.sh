#!/usr/bin/env bash
set -euo pipefail

export ZMX_SESSION_PREFIX="${ZMX_SESSION_PREFIX:-ci.zmx.}"
EVENT="${PICI_EVENT:-manual}"

echo "running ci event=${EVENT} session=${ZMX_SESSION_PREFIX}"

zmx run build docker build -t zig-zmx .
zmx run fmt -d docker run --rm -t zig-zmx:latest zig fmt --check .
zmx run test -d docker run --rm -t zig-zmx:latest zig build test
zmx run integration -d docker run --rm -t zig-zmx:latest bats --jobs 1 test/*.bats
zmx wait "*"

zmx run upload-build docker build -t zmx-upload -f Dockerfile.upload .

if [[ $PICI_BRANCH = "main" ]]; then
  zmx run upload docker run --rm \
    -v "$(pwd)/README.md:/app/README.md:ro" \
    -v "$(pwd)/logo.png:/app/logo.png:ro" \
    -v "$(pwd)/index.tmpl:/app/index.tmpl:ro" \
    -v ~/.ssh:/root/.ssh:ro \
    zmx-upload
fi

if [[ $EVENT != "git.tag" ]]; then
  echo "success!"
  exit 0
fi

TAG="${PICI_TAG}"
NEW_VERSION="${PICI_TAG#v}"

zmx run semver sed -i "s/\.version = \"[^\"]*\"/.version = \"$NEW_VERSION\"/" build.zig.zon && cat build.zig.zon
zmx run update-readme sed -i "s/zmx-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/zmx-$NEW_VERSION/g" README.md
zmx run build-release -d docker run --rm -t zig-zmx:latest zig build release
zmx run brew -d bash gen-brew.sh "$NEW_VERSION"

echo "distributing bins"
zmx run upload docker run --rm \
  -v "$(pwd)/zig-out/dist:/app/dist:ro" \
  -v ~/.ssh:/root/.ssh:ro \
  zmx-upload rsync -rv dist/ pgs.sh:/zmx/a
zmx run gh-build docker build -t gh-release -f Dockerfile.release .
zmx run gh docker run --rm \
  -v "$(pwd)/zig-out/dist":/dist \
  -e GH_TOKEN \
  -e TAG="$TAG" \
  gh-release

echo "success!"
