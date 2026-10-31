# Contributing

## prerequisites

- [Zig](https://ziglang.org/) `0.17.0`
- [bats-core](https://github.com/bats-core/bats-core) (integration tests)
- [Go](https://go.dev/) `1.23+` (docs site)

You can also use `nix develop` (`flake.nix`) or the `Dockerfile` (`docker build -t zig-zmx .`).

## build & test

```bash
zig build                        # build ./zig-out/bin/zmx
zig build check                  # fast compile check
zig build examples               # build examples/ against the zmx module
zig build test                   # run unit tests
bats --jobs 1 test/*.bats        # run integration tests
zig fmt --check .                # check formatting
```

## local debugging

Isolate development sessions from your running `zmx` sessions using `ZMX_DIR`:

```bash
ZMX_DIR=/tmp/zmx-dev ./zig-out/bin/zmx attach dev
```

Logs are written to `{log_dir}/zmx.log` and `{log_dir}/{session_name}.log` (run `zmx version` to see resolved socket and log paths).

## docs

Documentation lives in `docs/posts/` and is built with [`pdocs`](https://github.com/picosh/pdocs):

```bash
cd docs && make ssg
```

## a smol contract

- Write programs that solve a well defined problem.
- Write programs that behave the way most users expect them to behave.
- Write programs that a single person can maintain.
- Write programs that compose with other smol tools.
- Write programs that can be finished.

## guidelines

- Ensure `zig fmt --check .`, `zig build test`, and `bats --jobs 1 test/*.bats` pass.
- Bump `PROTOCOL_VERSION` in `src/ipc.zig` when changing IPC message layouts or tags.
- Add user-facing changes under `## Staged` in `CHANGELOG.md` and update `docs/posts/` when needed.
