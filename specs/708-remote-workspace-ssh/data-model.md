# Data Model: Remote Workspace Mode

**Date**: 2026-04-07  
**Feature**: 708-remote-workspace-ssh

## Entities

### RemoteHost

A user-facing identity for a remote machine that cmux manages.

| Attribute        | Type                  | Description                                                                  |
|------------------|-----------------------|------------------------------------------------------------------------------|
| id               | UUID                  | Stable identifier across renames and reconnects                              |
| alias            | String                | Display name in the sidebar (e.g., "prod-1"); user-editable                 |
| destination      | String                | SSH destination string (`user@host` or SSH config alias)                    |
| sshOptions       | SSHConnectionOptions  | Reusable shape from `DetectedSSHSession` (port, identity, jump, etc.)       |
| addedAt          | Date                  | When the user added this host                                               |
| lastConnectedAt  | Date?                 | Last successful connection timestamp                                        |
| transient        | Bool                  | True if added implicitly via `cmux ssh` and not explicitly saved             |

**Identity & uniqueness**: `id` is the primary key. The combination `(destination, sshOptions)` is treated as a logical key for "is this the same host?" when matching `cmux ssh` invocations to existing hosts.

### SSHConnectionOptions

Mirrors the existing `DetectedSSHSession` data shape (extracted into a shared struct so both `DetectedSSHSession` and `RemoteHost` can use it).

| Attribute         | Type      | Description                                          |
|-------------------|-----------|------------------------------------------------------|
| port              | Int?      | TCP port (default 22)                                |
| identityFile      | String?   | Path to private key                                  |
| configFile        | String?   | Alternate `~/.ssh/config` path                       |
| jumpHost          | String?   | `-J` jump host                                       |
| useIPv4           | Bool      | Force IPv4 (`-4`)                                    |
| useIPv6           | Bool      | Force IPv6 (`-6`)                                    |
| forwardAgent      | Bool      | Forward SSH agent (`-A`)                             |
| compressionEnabled| Bool      | Enable compression (`-C`)                            |
| sshOptions        | [String]  | Additional `-o key=value` overrides                  |

### RemoteConnection

The live, authenticated SSH master connection to a `RemoteHost`. Owned by `RemoteHostManager`.

| Attribute         | Type                | Description                                                              |
|-------------------|---------------------|--------------------------------------------------------------------------|
| host              | RemoteHost          | Back-reference to the host                                               |
| controlSocket     | URL                 | Path to the SSH control socket (one per cmux instance + host)            |
| masterProcess     | Process             | Reference to the `ssh -M ...` background process                         |
| state             | ConnectionState     | `.disconnected`, `.connecting`, `.connected`, `.failed(reason:)`         |
| connectedAt       | Date?               | When the master finished authenticating                                  |
| lastHealthCheckAt | Date?               | Last successful `ssh -O check` time                                      |
| openTerminalCount | Int                 | Number of cmux terminal panes currently using this connection            |

**Lifecycle**:
```
disconnected → connecting → connected → disconnected
                       \→ failed
                connected → failed (drop / health-check failure)
```

**Invariants**:
- A connection in `.connected` state must have a live master process and a present control socket.
- Tearing down a connection runs `ssh -O exit -S <sock>` then waits for the master process to exit, then removes the socket file.
- On cmux quit, ALL connections are torn down before the app exits.

### RemoteTmuxSession

Same data shape as the existing `TmuxSessionInfo` (from 707), scoped to a host.

| Attribute    | Type     | Description                       |
|--------------|----------|-----------------------------------|
| hostId       | UUID     | The owning RemoteHost's id        |
| name         | String   | tmux session name                 |
| windowCount  | Int      | Number of windows                 |
| createdAt    | Date     | tmux-reported creation time       |
| isAttached   | Bool     | Any client attached?              |
| clientCount  | Int      | Number of clients                 |

The polling/parsing logic from 707 is reused unchanged; only the subprocess transport changes.

### RemoteTerminalPane

A logical association between a cmux terminal pane and a remote connection. Tracked so the connection knows when it has zero terminals (and so closing a host cleans up its panes).

| Attribute     | Type          | Description                                       |
|---------------|---------------|---------------------------------------------------|
| panelId       | UUID          | The cmux TerminalPanel UUID                       |
| connectionId  | UUID          | The owning RemoteConnection's host id             |
| kind          | enum          | `.tmuxAttach(sessionName)` or `.shell`            |
| openedAt      | Date          |                                                   |

### HostRegistry

The persistent collection of saved `RemoteHost` records. Stored at `~/Library/Application Support/cmux/remote-hosts.json`.

| Attribute  | Type           | Description                            |
|------------|----------------|----------------------------------------|
| version    | Int            | Schema version (currently 1)           |
| hosts      | [RemoteHost]   | Saved hosts (transient hosts excluded) |

**Persistence rules**:
- Saved hosts (`transient == false`) are written on add/edit/remove.
- Transient hosts (added via `cmux ssh`) are NOT written until the user explicitly saves them.
- Credentials, control sockets, and connection state are NOT persisted.
- The file is rewritten atomically (write-temp + rename) on every change.

### TmuxTransport (protocol)

The new abstraction that lets `TmuxService` run commands locally OR over an SSH master.

```
protocol TmuxTransport {
    var label: String { get }                           // for debug/logging
    func runTmux(arguments: [String]) throws -> ProcessResult
    func attachShellCommand(forSession name: String) -> String
}
```

Two implementations:
- **`LocalTmuxTransport`**: Existing behavior — runs `/path/to/tmux` directly.
- **`RemoteTmuxTransport`**: Wraps a `RemoteConnection`, runs `ssh -S <sock> <destination> tmux <args>`.

`TmuxService` becomes generic on transport at construction time. The local singleton (`TmuxService.shared`) uses `LocalTmuxTransport`. Per-host instances are constructed with `RemoteTmuxTransport(connection:)`.

## Relationships

```
HostRegistry (1) ─────owns─────> RemoteHost (N)
RemoteHost (1) ──has at most one──> RemoteConnection (0..1)
RemoteConnection (1) ──manages──> RemoteTerminalPane (0..N)
RemoteConnection (1) ──serves──> TmuxService (RemoteTmuxTransport)
TmuxService ──polls──> RemoteTmuxSession (0..N)
```

## Validation rules

- Host alias must be non-empty after trimming whitespace.
- Destination must be a syntactically valid SSH destination (`user@host` or alias). Validated lazily — only on connect.
- Two saved (non-transient) hosts may not share the same alias. If a user adds a host with a duplicate alias, prompt for a new alias.
- Connection state transitions must follow the lifecycle diagram. Invalid transitions are no-ops with a debug log.

## Data volume assumptions

- Typical user: 0–10 remote hosts; expect ~3 active concurrently
- Heavy user: ~50 hosts (e.g., a fleet operator)
- Per-host tmux sessions: same as local (1–10 typical)
- Per-cmux-instance control sockets: bounded by number of connected hosts
