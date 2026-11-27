# Running tests

Run unit tests, including capability runtime tests, with `zig build test`.
The capability tests use test-only definitions through libzmx's public API.
Shared in-memory terminal fixtures live in `capabilities/`.

Build the executable with `zig build`, then run daemon integration tests with
`bats --jobs 1 test/*.bats`. Each case uses a temporary socket directory.
