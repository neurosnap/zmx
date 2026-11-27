# Running tests

Run unit tests, including capability runtime and Program Status tests, with
`zig build test`. Capability implementations use libzmx's public API and shared
in-memory terminal fixtures in `capabilities/`.

Build the executable with `zig build`, then run daemon integration tests with
`bats --jobs 1 test/*.bats`. Each case uses a temporary socket directory.
