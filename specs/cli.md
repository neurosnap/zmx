# zmx cli specification

This document outlines the command-line interface for the `zmx` tool.

## third-party libraries

We will use the `zig-clap` library for parsing command-line arguments. It provides a robust and flexible way to define commands, subcommands, and flags.

## command structure

The `zmx` tool will follow a subcommand-based structure.

```
zmx [command] [options]
```

### global options

- `-h`, `--help`: Display help information.
- `-v`, `--version`: Display the version of the tool.

### commands

#### `daemon`

This is the background process that manages all the shell sessions (pty processes) that the client interacts with.

**Usage:**

```
zmx daemon
```

**Arguments:**

- `<socket>`: The location of the unix socket file. Clients connecting will also have to pass the same flag.

#### `list`

List all active sessions.

**Usage:**

```
zmx list
```

**Output:**

The `list` command will output a table with the following columns:

- `SESSION`: The name of the session.
- `STATUS`: The status of the session (e.g., `attached`, `detached`).
- `CLIENTS`: The number of clients currently attached to the session.
- `CREATED_AT`: The date when the session was created

______________________________________________________________________

#### `attach`

Attach to a session.

**Usage:**

```
zmx attach <session>
```

**Arguments:**

- `<session>`: The name of the session to attach to. This is a required argument.
- `<socket>`: The location of the unix socket file.

______________________________________________________________________

#### `detach`

Detach from a session.

**Usage:**

```
zmx detach <session>
```

**Arguments:**

- `<session>`: The name of the session to detach from. This is a required argument.
- `<socket>`: The location of the unix socket file.

______________________________________________________________________

#### `kill`

Kill a session.

**Usage:**

```
zmx kill <session>
```

**Arguments:**

- `<session>`: The name of the session to kill. This is a required argument.
- `<socket>`: The location of the unix socket file.
