# Contributing

## prerequisites

- [Zig](https://ziglang.org/) `0.17.0`
- [bats-core](https://github.com/bats-core/bats-core) (integration tests)
- [Go](https://go.dev/) `1.23+` (docs site)

You can also use `nix develop` (`flake.nix`) or the `Dockerfile` (`docker build -t zig-zmx .`).

## build & test

```bash
zig build                        # build ./zig-out/bin/zmx
zig build examples               # build examples/ against the zmx module
zig build test                   # run unit tests
bats --jobs 1 test/*.bats        # run integration tests
```

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

## ai usage

*In this section, "AI" refers to generative artificial intelligence tools, including Large Language Models and similar technologies.*

All contributions are expected to be made by humans. AI tools may be used for research and learning, but all content in contributions must originate from and be understood by the contributor. This includes code, documentation, issues, security reports, pull request descriptions, and comments in all zmx community spaces.

ALL usage of AI tools MUST be disclosed.

Do not bring AI review tools into pull requests.

Usage of AI-powered human-language translation tools is acceptable to facilitate contributions across language barriers.

*Copied from [Void Linux's CONTRIBUTING doc](https://github.com/void-linux/.github/blob/f244fb52f5c3ac586e832f69bfcdd886d24f7332/CONTRIBUTING.md#ai-usage).*
