# cli scaffolding implementation plan

This document outlines the plan for implementing the CLI scaffolding for the `zmx` tool, based on the `specs/cli.md` document.

## 1. Add `zig-clap` Dependency

- **Modify `build.zig.zon`**: Add `zig-clap` to the dependencies.
- **Modify `build.zig`**: Fetch the `zig-clap` module and make it available to the executable.

## 2. Create `src/cli.zig`

- Create a new file `src/cli.zig` to encapsulate all CLI-related logic.

## 3. Define Commands in `src/cli.zig`

- Use `zig-clap` to define the command structure specified in `specs/cli.md`.
- This includes the global options (`-h`, `-v`) and the subcommands:
  - `daemon`
  - `list`
  - `attach <session>`
  - `detach <session>`
  - `kill <session>`
- For each command, define the expected arguments and options.

## 4. Integrate with `src/main.zig`

- In `src/main.zig`, import the `cli` module.
- Call the CLI parsing logic from the `main` function.
- The `main` function will dispatch to the appropriate command handler based on the parsed arguments.
- When the `daemon` subcommand is invoked, the application will act as a long-running "server".

## 5. Single Executable

- The `build.zig` will define a single executable named `zmx`.
