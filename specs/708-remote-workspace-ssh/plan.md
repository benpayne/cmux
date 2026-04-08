# Implementation Plan: Remote Workspace Mode (SSH ControlMaster + Remote tmux)

**Branch**: `708-remote-workspace-ssh` | **Date**: 2026-04-07 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/708-remote-workspace-ssh/spec.md`

## Summary

Add a first-class remote workspace concept to cmux. Users add remote hosts; cmux opens a single authenticated SSH master connection per host (via standard OpenSSH `ssh -M -S <sock>`); all subsequent operations against that host (list/attach/create tmux sessions, open new shells) reuse the master with no re-auth and subsecond startup. Generalizes the local tmux feature (707) by introducing a `TmuxTransport` protocol with local + remote implementations. No agent or daemon deployed to the remote — pure OpenSSH + tmux.

This feature **depends on feature 707-tmux-control-panel** (already implemented on the parent branch) and is built directly on top of its `TmuxService`/`TmuxSidebarState`/`TmuxSidebarView` abstractions.

## Technical Context

**Language/Version**: Swift 5.0, macOS 14.0+ (Sonoma)  
**Primary Dependencies**: SwiftUI, AppKit, Combine, GhosttyKit.xcframework, Bonsplit, OpenSSH (system), tmux (on remote, optional)  
**Storage**: JSON file at `~/Library/Application Support/cmux/remote-hosts.json` for the host registry. SSH control sockets in `~/Library/Application Support/cmux/ssh/<instance-id>/`. Credentials NEVER persisted.  
**Testing**: XCTest unit tests for SSH config parsing, command builder, host registry JSON round-trip, transport protocol mocks. Manual testing via tagged debug build against a real remote host.  
**Target Platform**: macOS 14.0+ (cmux client). Remote hosts run any Unix-like OS supporting OpenSSH and tmux.  
**Project Type**: Desktop app (macOS terminal emulator) with embedded CLI.  
**Performance Goals**:  
- First connect (with key auth + agent): < 10 seconds  
- Subsequent operations on same host: < 1 second  
- Sidebar state freshness: < 10 seconds after a remote change  
- Connection drop detection: < 30 seconds  
**Constraints**:  
- No binary/daemon deployed to remote.  
- Must respect user's `~/.ssh/config` (jump hosts, identity, port, etc.).  
- Master connection lifetime ≤ cmux process lifetime (tear down on quit).  
- Visibility-gated polling; max 4 concurrent poll subprocesses.  
**Scale/Scope**: 0–50 managed hosts; ~5 connected concurrently in typical use.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution is the unfilled template — no project-specific gates defined. Proceeding.

**Post-Phase 1 re-check**: Design uses existing patterns (subprocess wrapping, observable state, SwiftUI sidebar sections, V2 method dispatch) and reuses code from feature 707. No new frameworks, no new project structure. Passes by default.

## Project Structure

### Documentation (this feature)

```text
specs/708-remote-workspace-ssh/
├── plan.md              # This file
├── spec.md              # Feature specification (with clarifications resolved)
├── research.md          # Phase 0: 12 design decisions with rationale
├── data-model.md        # Phase 1: entity model
├── quickstart.md        # Phase 1: implementation guide + architecture diagram
├── contracts/
│   └── socket-commands.md  # Phase 1: V2 socket method contracts
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
Sources/
├── Tmux/
│   ├── TmuxSessionInfo.swift          # (existing — unchanged)
│   ├── TmuxService.swift              # MODIFIED — accepts TmuxTransport
│   ├── TmuxTransport.swift            # NEW — protocol + LocalTmuxTransport
│   ├── TmuxSidebarState.swift         # MODIFIED — manages dict of services
│   ├── TmuxSidebarView.swift          # MODIFIED — grouped sections
│   └── Remote/                        # NEW subdirectory
│       ├── SSHConnectionOptions.swift # NEW
│       ├── SSHCommandBuilder.swift    # NEW (extracted from TerminalSSHSessionDetector)
│       ├── SSHConfigParser.swift      # NEW
│       ├── RemoteHost.swift           # NEW
│       ├── RemoteConnection.swift     # NEW
│       ├── RemoteHostManager.swift    # NEW (singleton)
│       ├── HostRegistry.swift         # NEW (JSON persistence)
│       ├── RemoteTmuxTransport.swift  # NEW
│       └── RemoteHostSidebarUI.swift  # NEW (add picker, status indicators)
├── TerminalSSHSessionDetector.swift   # MODIFIED — uses extracted SSHCommandBuilder
├── ContentView.swift                  # MODIFIED — TmuxSidebarSection still 1 line
├── cmuxApp.swift                      # MODIFIED — initialize/teardown RemoteHostManager
├── Workspace.swift                    # MODIFIED — extend attach for host context
├── TabManager.swift                   # MODIFIED — bridge methods for host actions
└── TerminalController.swift           # MODIFIED — V2 host.* methods

CLI/
└── cmux.swift                         # MODIFIED — host-* commands; cmux ssh integration

Resources/
└── Localizable.xcstrings              # MODIFIED — strings for new UI

cmuxTests/
├── SSHConfigParserTests.swift         # NEW
├── SSHCommandBuilderTests.swift       # NEW
├── HostRegistryTests.swift            # NEW
└── TmuxTransportMockTests.swift       # NEW
```

**Structure Decision**: All new code lives under `Sources/Tmux/Remote/` to keep the feature module self-contained, mirroring how `Sources/Tmux/` was organized in feature 707. The integration footprint in the existing big files (ContentView, cmuxApp, Workspace, TabManager, TerminalController, CLI/cmux) stays small and surgical — same modular approach as 707.

## Complexity Tracking

No constitution violations to justify.

## Phase Summary

### Phase A — Foundation (refactor without behavior change)
Goal: Extract reusable SSH primitives without changing user-visible behavior.
- Extract `SSHConnectionOptions` struct from `DetectedSSHSession`
- Extract `SSHCommandBuilder` (the existing private `sshArguments(command:)` method) into a shared utility
- Refactor `TerminalSSHSessionDetector` to use the extracted builder
- Verify file upload (SSH-using path of cmux) still works
- Introduce `TmuxTransport` protocol; provide `LocalTmuxTransport` implementation
- Refactor `TmuxService` to accept a transport at construction; keep `TmuxService.shared` using the local transport
- Verify the local tmux feature (707) still works after the refactor

### Phase B — Remote connection layer
Goal: Spawn, track, and tear down SSH master connections.
- `RemoteHost` entity
- `RemoteConnection` with state machine (`disconnected → connecting → connected → disconnected/failed`)
- `RemoteHostManager` singleton:
  - `addHost(destination:)` / `removeHost(id:)`
  - `connect(id:)` — spawns `ssh -M -S <sock> -fnNT <dest>` background process
  - `disconnect(id:)` — runs `ssh -O exit -S <sock>`
  - Health check loop (`ssh -O check`) every 30 seconds for connected hosts
  - Per-cmux-instance socket directory; cleanup on quit
- `RemoteTmuxTransport` — wraps a `RemoteConnection`; runs `ssh -S <sock> <dest> tmux <args>`
- Unit tests with a mock transport for state-machine and command-failure paths

### Phase C — UI: add and manage hosts (P1: US4)
Goal: User can add, see, connect, disconnect, and remove hosts.
- "Add remote host…" sidebar affordance
- Manual destination input form
- `SSHConfigParser` — read `~/.ssh/config` Host entries
- "From SSH config" picker
- Host status indicators (●/○) and per-host context menu (Connect, Disconnect, Remove)
- New localized strings

### Phase D — Remote tmux sections in sidebar (P1: US1, US2)
Goal: View remote tmux sessions and attach with one click.
- Extend `TmuxSidebarState` to manage a dict of services keyed by host (local + remote)
- Refactor `TmuxSidebarView` to render grouped sections
- Wire `RemoteTmuxTransport` for each connected host
- Click-to-attach routes through the right transport and uses the existing `Workspace.attachTmuxSession` flow with the SSH attach command
- Visibility-gated polling

### Phase E — Plain remote shell (P1: US3)
Goal: Open a non-tmux shell on a connected host.
- "+ New terminal on host" button in each remote section
- Creates a TerminalPanel with `initialCommand: ssh -S <sock> -t <dest> $SHELL`
- Track the pane in `RemoteConnection.openTerminalCount`

### Phase F — Persistence (P2: US6)
Goal: Host list survives cmux restarts.
- `HostRegistry` JSON load/save at `~/Library/Application Support/cmux/remote-hosts.json`
- Atomic write (temp + rename)
- Load on app launch (hosts shown as disconnected initially)
- Save on add/edit/remove
- Schema version field for future migrations

### Phase G — Remote tmux session management (P2: US5)
Goal: Create, rename, kill remote tmux sessions from the sidebar.
- Reuse the local tmux context-menu UI from feature 707
- The actions just call methods on the per-host `TmuxService` (which uses the remote transport)
- No new UI required — the existing context menu works as-is once the transport is plumbed

### Phase H — `cmux ssh` CLI integration (P2: US7)
Goal: `cmux ssh user@host` reuses managed master connections.
- New V2 method `host.connect_or_get` in `TerminalController`
- `RemoteHostManager.findOrCreate(destination:transient:)`
- Modify the existing `cmux ssh` CLI command to call `host.connect_or_get` with `open_terminal=true`
- Transient hosts auto-removed when their last terminal closes

### Phase I — Host CLI commands (P2)
Goal: Scripting/automation interface for host management.
- New CLI commands: `host-list`, `host-add`, `host-remove`, `host-connect`, `host-disconnect`, `host-tmux-list`, `host-tmux-attach`, `host-shell`
- All forward to V2 methods

### Phase J — Cleanup, error handling, polish
- Orphan socket cleanup on launch (scan instance dirs, remove dead ones)
- Quit hook in `cmuxApp.swift` to tear down all connections
- Error message refinement for common failure modes (auth, unreachable, host key mismatch)
- Debug logging via `dlog` in `#if DEBUG` blocks
- Concurrent poll cap (4)
- Verify tagged debug build against real remote

### Phase K (deferred to v2) — Remote port detection (P3: US8)
Out of MVP scope. Track separately.

## Dependencies and risks

### Dependencies
- **Hard**: Feature 707-tmux-control-panel must be merged first (or this branch must include it). The current branch is built on top of 707 to satisfy this.
- **Soft**: macOS file system layout — uses `~/Library/Application Support/cmux/` which is the standard location.

### Risks
- **OpenSSH version differences**: very old OpenSSH may not support `-O exit` or `-fnNT`. Mitigation: target OpenSSH 6.7+ (released 2014); macOS ships much newer.
- **Network behavior under sleep/wake**: TCP connections often die silently. Health check loop mitigates.
- **`SSH_ASKPASS` environment**: cmux must explicitly set this when spawning the master if the user has configured one. We don't override their `~/.ssh/config`.
- **Refactor risk in Phase A**: extracting the SSH-args builder touches `TerminalSSHSessionDetector.swift`, which is exercised by file-upload features. Strong unit test coverage required before refactor.
- **SwiftUI redraw complexity in Phase D**: extending `TmuxSidebarView` to grouped sections risks state-management bugs. Mitigation: keep the per-group `TmuxService` instances stable across renders.
