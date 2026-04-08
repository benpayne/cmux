# Quickstart: Remote Workspace Mode

**Date**: 2026-04-07  
**Feature**: 708-remote-workspace-ssh

## Overview

Add a remote-workspace concept to cmux. Users add remote hosts via the sidebar; cmux opens a single authenticated SSH master connection per host, then runs all subsequent operations (tmux list/attach, new shells) over the shared connection. No re-auth, no daemon on the remote, fully reuses standard OpenSSH and the user's existing config.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  cmux App                                                        │
│                                                                  │
│  ┌────────────────────┐                                          │
│  │  Sidebar           │                                          │
│  │                    │                                          │
│  │ LOCAL SESSIONS     │                                          │
│  │  • dev (3) ●       │       ┌──────────────────────────────┐   │
│  │  • prod (1)        │       │ TmuxService                  │   │
│  │  + New             │◄──────┤  ├─ LocalTmuxTransport      │   │
│  │                    │       │  └─ RemoteTmuxTransport(c1) │   │
│  │ REMOTE: prod-1 ●   │       │  └─ RemoteTmuxTransport(c2) │   │
│  │  • api (5)         │       └──────────────────────────────┘   │
│  │  • db-tail (1) ●   │                       │                  │
│  │  + New session     │                       │                  │
│  │  + New terminal    │                       ▼                  │
│  │                    │       ┌──────────────────────────────┐   │
│  │ REMOTE: staging ○  │       │ RemoteHostManager            │   │
│  │  (disconnected)    │◄──────┤  - hosts: [RemoteHost]       │   │
│  │  + Add host        │       │  - connections: [Connection] │   │
│  └────────────────────┘       │  - persistent registry       │   │
│                               └──────────────────────────────┘   │
│                                            │                     │
│                                            ▼                     │
│   ┌─────────────────────────────────────────────────────────┐    │
│   │ ssh -M -S ~/Library/.../instance/prod-1.sock -fnNT host │    │
│   │ ssh -S .../prod-1.sock host tmux list-sessions -F ...   │    │
│   │ ssh -S .../prod-1.sock -t host tmux attach -t api       │    │
│   │ ssh -S .../prod-1.sock -t host $SHELL                   │    │
│   └─────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

## Key design decisions (from research.md)

1. **cmux owns the SSH master process** (not delegated to user's `ControlMaster=auto`). Required by the "tear down on quit" clarification.
2. **`TmuxTransport` protocol** generalizes the existing `TmuxService` from feature 707. Local and remote share the parser, polling, and UI; only the subprocess transport differs.
3. **Persistence at `~/Library/Application Support/cmux/remote-hosts.json`** as a versioned JSON file. Credentials never persisted.
4. **Per-cmux-instance control sockets** at `~/Library/.../cmux/ssh/<instance-id>/<alias>.sock` so multiple cmux processes don't collide.
5. **Reuse `DetectedSSHSession`'s SSH-arg builder** by extracting it into a shared helper. The existing code already handles port/identity/jump/IPv4-IPv6/agent-forwarding/compression/extra options correctly.
6. **No automatic reconnect**. Failed/dropped connections require explicit user action, matching cmux's "explicit-action" UX.
7. **Polling is visibility-gated** — hidden remote sections do not poll. Concurrent poll cap of 4.
8. **Password-only hosts** delegate to OpenSSH's `SSH_ASKPASS` mechanism. No custom prompt UI in v1.

## New code structure

```
Sources/
└── Tmux/
    ├── TmuxSessionInfo.swift          # (existing — reused unchanged)
    ├── TmuxService.swift              # (existing — refactored to use Transport)
    ├── TmuxTransport.swift            # NEW — protocol + LocalTmuxTransport
    ├── TmuxSidebarState.swift         # (existing — extended for grouped state)
    ├── TmuxSidebarView.swift          # (existing — extended for grouped sections)
    └── Remote/
        ├── SSHConnectionOptions.swift # NEW — extracted from DetectedSSHSession
        ├── SSHCommandBuilder.swift    # NEW — shared SSH arg builder
        ├── RemoteHost.swift           # NEW — host entity
        ├── RemoteConnection.swift     # NEW — live master connection
        ├── RemoteHostManager.swift    # NEW — singleton owning hosts/connections
        ├── HostRegistry.swift         # NEW — JSON persistence
        ├── SSHConfigParser.swift      # NEW — read ~/.ssh/config Host entries
        ├── RemoteTmuxTransport.swift  # NEW — TmuxTransport over a connection
        └── RemoteHostSidebarUI.swift  # NEW — host-add picker, status indicators
```

## Modified files (small surgical edits)

- `Sources/Tmux/TmuxService.swift` — accept a `TmuxTransport` at construction; default to local
- `Sources/Tmux/TmuxSidebarState.swift` — manage a dictionary of services keyed by host (local + remote)
- `Sources/Tmux/TmuxSidebarView.swift` — render grouped sections (LOCAL + each REMOTE host)
- `Sources/TerminalSSHSessionDetector.swift` — refactor to use the extracted SSH-arg builder
- `Sources/cmuxApp.swift` — initialize `RemoteHostManager` on launch; tear down on quit
- `Sources/Workspace.swift` — extend `attachTmuxSession(named:)` to take an optional host context
- `Sources/TerminalController.swift` — new V2 methods: `host.list`, `host.add`, `host.remove`, `host.connect`, `host.disconnect`, `host.connect_or_get` (used by `cmux ssh`)
- `CLI/cmux.swift` — `cmux ssh` participates in the manager; new `cmux host-list/add/remove/connect/disconnect` commands

## Implementation approach (high level)

### Phase A — Foundation
- Extract `SSHConnectionOptions` and `SSHCommandBuilder` from `TerminalSSHSessionDetector.swift`
- Create `TmuxTransport` protocol; refactor `TmuxService` to use it
- Verify the local tmux feature still works after the refactor

### Phase B — RemoteHostManager + persistence
- `RemoteHost`, `RemoteConnection`, `RemoteHostManager`, `HostRegistry`
- Master spawn / teardown via `ssh -M ... -fnNT` and `ssh -O exit`
- Connection state machine + health check loop

### Phase C — UI: add host
- "Add remote host…" affordance in the sidebar
- Manual destination input
- "From SSH config" picker (uses new `SSHConfigParser`)
- Connection status indicators

### Phase D — UI: remote tmux sections
- Extend `TmuxSidebarView` to render per-host groups
- Wire `RemoteTmuxTransport` for each connected host
- Click-to-attach paths now route through the right transport

### Phase E — Plain remote shell
- "+ New terminal on host" affordance
- Opens a TerminalPanel running `ssh -S <sock> -t <dest> $SHELL`

### Phase F — `cmux ssh` integration
- New V2 method `host.connect_or_get`
- CLI uses it to reuse existing managed hosts when destinations match
- Transient host model

### Phase G — Persistence + cleanup
- HostRegistry load/save
- Orphan socket cleanup on launch
- Quit hook to tear down all connections

### Phase H — Polish
- Visibility-gated polling
- Concurrent poll cap
- Error message refinement
- Debug logging

## Testing strategy

- **Unit tests**: SSHConfigParser, SSHCommandBuilder, HostRegistry JSON round-trip, TmuxTransport mock
- **Integration tests** (CI only): connect to a localhost SSH server, run real list/attach
- **Manual testing**: tagged debug build against a real remote host
