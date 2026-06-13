#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: generate-brew.sh <version>}"
DIST="${2:-zig-out/dist}"

if [[ ! -f brew.tmpl ]]; then
  echo "error: brew.tmpl not found" >&2
  exit 1
fi

shasum() {
  local platform="$1"
  local file="${DIST}/zmx-${VERSION}-${platform}.tar.gz.sha256"
  if [[ ! -f "$file" ]]; then
    echo "error: missing $file" >&2
    exit 1
  fi
  cut -d ' ' -f1 < "$file"
}

sed \
  -e "s/{ver}/${VERSION}/g" \
  -e "s/{shasum_macos-aarch64}/$(shasum macos-aarch64)/" \
  -e "s/{shasum_macos-x86_64}/$(shasum macos-x86_64)/" \
  -e "s/{shasum_linux-aarch64}/$(shasum linux-aarch64)/" \
  -e "s/{shasum_linux-x86_64}/$(shasum linux-x86_64)/" \
  brew.tmpl
