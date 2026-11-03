# Running tests

Run all Zig unit tests, including the capability tests, with

```sh
zig build test
```

Capability implementations in tests use libzmx's public API. In-memory fixtures
drive the internal runtime. Shared fixtures live in `capabilities/`, and
protocol-specific tests live in `program_status/` and `working_directory/`.

Build the executable before running the daemon integration tests

```sh
zig build
bats --recursive test
```

Recursive discovery includes the working-directory suite in `working_directory/`.
BATS gives each case its own temporary socket directory so these tests do not
use existing zmx sessions.
