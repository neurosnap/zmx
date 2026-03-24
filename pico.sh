#!/usr/bin/env bash
set -xeo pipefail

# This is a little experiement seeing how we could use zmx as a job engine for CI

export ZMX_SESSION_PREFIX="ci-"

zmx run build podman build -t zig .
zmx wait

zmx run fmt podman run --rm -it -v "$(pwd)":/app zig zig fmt --check .
zmx run test podman run --rm -it -v "$(pwd)":/app zig zig build test --summary all
zmx wait

zmx kill

echo "success!"
