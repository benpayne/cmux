# Socket Command Contracts: Remote Workspace Mode

**Date**: 2026-04-07  
**Feature**: 708-remote-workspace-ssh

These commands extend the cmux V2 socket protocol to support managing remote hosts and to let the `cmux ssh` CLI integrate with the remote host manager.

## host.list

List all known managed hosts (saved + transient), with their current connection state.

**Method**: `host.list`  
**Parameters**: none

**Response**:
```json
{
  "ok": true,
  "hosts": [
    {
      "id": "uuid",
      "alias": "prod-1",
      "destination": "deploy@prod-1.example.com",
      "transient": false,
      "state": "connected",
      "connected_at": "2026-04-07T10:00:00Z",
      "open_terminals": 2
    },
    {
      "id": "uuid",
      "alias": "staging",
      "destination": "deploy@staging.example.com",
      "transient": false,
      "state": "disconnected"
    }
  ]
}
```

## host.add

Add a new host to the registry. Does NOT connect.

**Method**: `host.add`  
**Parameters**:

| Param          | Type     | Required | Description                            |
|----------------|----------|----------|----------------------------------------|
| destination    | String   | Yes      | SSH destination (`user@host` or alias) |
| alias          | String   | No       | Display name (default: derived from destination) |
| ssh_options    | Object   | No       | Connection options (port, identity, etc.) |
| save           | Bool     | No       | Default true. False marks transient.   |

**Response (success)**:
```json
{ "ok": true, "host": { ... same shape as host.list entry ... } }
```

**Response (duplicate alias)**:
```json
{ "ok": false, "error": "alias_in_use", "message": "alias 'prod-1' already used" }
```

## host.remove

Remove a host. If connected, also disconnects and closes any open terminals on it.

**Method**: `host.remove`  
**Parameters**:

| Param | Type   | Required | Description     |
|-------|--------|----------|-----------------|
| id    | String | Yes      | Host UUID       |

**Response**:
```json
{ "ok": true }
```

## host.connect

Open the SSH master connection for a host. Idempotent — no-op if already connected.

**Method**: `host.connect`  
**Parameters**:

| Param | Type   | Required | Description |
|-------|--------|----------|-------------|
| id    | String | Yes      | Host UUID   |

**Response (success)**:
```json
{
  "ok": true,
  "host": { ... },
  "state": "connected"
}
```

**Response (auth failure)**:
```json
{
  "ok": false,
  "error": "auth_failed",
  "message": "ssh: Permission denied (publickey,password)"
}
```

**Response (unreachable)**:
```json
{
  "ok": false,
  "error": "unreachable",
  "message": "ssh: Could not resolve hostname prod-1.example.com"
}
```

## host.disconnect

Tear down the SSH master connection for a host. Closes any open terminals on it.

**Method**: `host.disconnect`  
**Parameters**:

| Param | Type   | Required | Description |
|-------|--------|----------|-------------|
| id    | String | Yes      | Host UUID   |

**Response**:
```json
{ "ok": true }
```

## host.connect_or_get

Used by the `cmux ssh` CLI to find or create a managed host for an SSH destination. If a host with a matching destination exists, returns it (and reuses its connection). Otherwise creates a transient host, connects, and returns it.

**Method**: `host.connect_or_get`  
**Parameters**:

| Param         | Type    | Required | Description                                       |
|---------------|---------|----------|---------------------------------------------------|
| destination   | String  | Yes      | SSH destination string                            |
| save          | Bool    | No       | Default false (transient)                         |
| open_terminal | Bool    | No       | If true, also open a new pane on the host         |

**Response**:
```json
{
  "ok": true,
  "host": { ... },
  "surface_id": "uuid-of-new-pane",
  "workspace_id": "uuid-of-workspace"
}
```

## host.tmux.list

List tmux sessions on a connected remote host.

**Method**: `host.tmux.list`  
**Parameters**:

| Param | Type   | Required | Description |
|-------|--------|----------|-------------|
| id    | String | Yes      | Host UUID   |

**Response**: same shape as `tmux.list` from feature 707, but session entries include `host_id`.

## host.tmux.attach

Attach to a remote tmux session in a new pane.

**Method**: `host.tmux.attach`  
**Parameters**:

| Param        | Type   | Required | Description           |
|--------------|--------|----------|-----------------------|
| id           | String | Yes      | Host UUID             |
| name         | String | Yes      | tmux session name     |
| workspace_id | String | No       | Target workspace      |

**Response**: same shape as `tmux.attach` from feature 707.

## host.shell.open

Open a plain interactive shell pane on a connected remote host.

**Method**: `host.shell.open`  
**Parameters**:

| Param        | Type   | Required | Description           |
|--------------|--------|----------|-----------------------|
| id           | String | Yes      | Host UUID             |
| workspace_id | String | No       | Target workspace      |

**Response**:
```json
{
  "ok": true,
  "surface_id": "uuid",
  "workspace_id": "uuid"
}
```

## CLI commands

| CLI command                              | Method                  | Notes                                       |
|------------------------------------------|-------------------------|---------------------------------------------|
| `cmux host-list`                         | `host.list`             | human-readable + `--json`                   |
| `cmux host-add <dest> [--alias N]`       | `host.add`              | adds saved by default                       |
| `cmux host-remove <id-or-alias>`         | `host.remove`           |                                             |
| `cmux host-connect <id-or-alias>`        | `host.connect`          |                                             |
| `cmux host-disconnect <id-or-alias>`     | `host.disconnect`       |                                             |
| `cmux ssh <dest>`                        | `host.connect_or_get` (with `open_terminal=true`) | existing CLI; new behavior   |
| `cmux host-tmux-list <host>`             | `host.tmux.list`        |                                             |
| `cmux host-tmux-attach <host> <name>`    | `host.tmux.attach`      |                                             |
| `cmux host-shell <host>`                 | `host.shell.open`       |                                             |
