# Socket Command Contracts: tmux Control Panel

**Date**: 2026-04-05  
**Feature**: 707-tmux-control-panel  
**Status**: Implemented in `Sources/TerminalController.swift` (V2 dispatch) and `CLI/cmux.swift` (CLI commands).

## Implementation notes

- **`tmux.list`**, **`tmux.create`**, **`tmux.kill`**, **`tmux.rename`**: implemented as both V2 methods (for in-app callers) and CLI commands (which run `TmuxService` directly without needing the cmux app to be running). The CLI versions are convenient for scripting from a fresh shell.
- **`tmux.attach`**: V2 method only (and a CLI command that calls it). Cannot run standalone in the CLI because it needs to open a pane in the running cmux instance.

## CLI command names

| V2 method | CLI command | Notes |
|-----------|-------------|-------|
| `tmux.list` | `cmux tmux-list` | direct subprocess; works without app running |
| `tmux.create` | `cmux tmux-create [name]` | direct subprocess |
| `cmux tmux-kill --name <name>` | `tmux.kill` | direct subprocess |
| `cmux tmux-rename --name <old> --new-name <new>` | `tmux.rename` | direct subprocess |
| `cmux tmux-attach --name <name>` | `tmux.attach` | sends V2 to running cmux |

These commands extend the cmux socket/CLI V2 protocol for tmux session management.

## tmux.list

List all tmux sessions with metadata.

**Method**: `tmux.list`  
**Parameters**: none

**Response** (success):
```json
{
  "ok": true,
  "sessions": [
    {
      "name": "dev",
      "windows": 3,
      "created": "2026-04-05T10:30:00Z",
      "attached": true,
      "clients": 1
    },
    {
      "name": "prod",
      "windows": 1,
      "created": "2026-04-04T08:00:00Z",
      "attached": false,
      "clients": 0
    }
  ]
}
```

**Response** (tmux not available):
```json
{
  "ok": false,
  "error": "tmux not found"
}
```

## tmux.create

Create a new tmux session.

**Method**: `tmux.create`  
**Parameters**:

| Param | Type   | Required | Description                    |
|-------|--------|----------|--------------------------------|
| name  | String | No       | Session name (tmux default if omitted) |

**Response** (success):
```json
{
  "ok": true,
  "session": {
    "name": "my-session",
    "windows": 1,
    "created": "2026-04-05T12:00:00Z",
    "attached": false,
    "clients": 0
  }
}
```

**Response** (duplicate name):
```json
{
  "ok": false,
  "error": "duplicate session name: my-session"
}
```

## tmux.kill

Kill/destroy a tmux session.

**Method**: `tmux.kill`  
**Parameters**:

| Param | Type   | Required | Description          |
|-------|--------|----------|----------------------|
| name  | String | Yes      | Session name to kill |

**Response** (success):
```json
{
  "ok": true
}
```

**Response** (not found):
```json
{
  "ok": false,
  "error": "session not found: my-session"
}
```

## tmux.rename

Rename a tmux session.

**Method**: `tmux.rename`  
**Parameters**:

| Param    | Type   | Required | Description      |
|----------|--------|----------|------------------|
| name     | String | Yes      | Current session name |
| new_name | String | Yes      | New session name     |

**Response** (success):
```json
{
  "ok": true,
  "session": {
    "name": "new-name",
    "windows": 3,
    "created": "2026-04-05T10:30:00Z",
    "attached": false,
    "clients": 0
  }
}
```

**Response** (conflict):
```json
{
  "ok": false,
  "error": "duplicate session name: new-name"
}
```

## tmux.attach

Attach to a tmux session by opening a new terminal pane running `tmux attach-session -t <name>`.

**Method**: `tmux.attach`  
**Parameters**:

| Param        | Type   | Required | Description                            |
|--------------|--------|----------|----------------------------------------|
| name         | String | Yes      | Session name to attach                 |
| workspace_id | String | No       | Target workspace (current if omitted)  |

**Response** (success):
```json
{
  "ok": true,
  "pane_id": "uuid-of-new-pane",
  "workspace_id": "uuid-of-workspace"
}
```

**Response** (not found):
```json
{
  "ok": false,
  "error": "session not found: my-session"
}
```
