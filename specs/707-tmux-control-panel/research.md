# Research: tmux Control Panel Integration

**Date**: 2026-04-05  
**Feature**: 707-tmux-control-panel

## R1: tmux CLI Interface for Session Enumeration

**Decision**: Use `tmux list-sessions -F` with format strings to enumerate sessions, rather than Ghostty's built-in tmux control mode.

**Rationale**: The Ghostty tmux control mode (`tmux -CC`) is designed for a fundamentally different use case — it replaces tmux's own rendering with the host terminal's rendering. Our feature needs to list and manage sessions at the session level, not take over pane rendering. Shelling out to `tmux list-sessions -F '#{session_name}:#{session_windows}:#{session_created}:#{session_attached}'` is simple, reliable, and decoupled from Ghostty internals. It also works regardless of whether the user is currently inside a tmux session.

**Alternatives considered**:
- Ghostty tmux control mode (`tmux -CC`): Too invasive for v1 — designed for full pane rendering takeover, not sidebar metadata. Could be revisited in v2 for window/pane-level integration.
- tmux command mode (`tmux command-prompt`): Interactive, not suitable for programmatic queries.
- Parsing `tmux ls` output: Fragile compared to `-F` format strings.

## R2: Session Polling vs Event-Driven Refresh

**Decision**: Use polling with `tmux list-sessions` on a 3-second timer, with an immediate refresh on user actions (create/kill/rename).

**Rationale**: tmux does not expose a file-system-level notification mechanism for session changes (no inotify/kqueue on the socket). The control mode (`tmux -CC`) provides `%session-changed` notifications but requires an active control mode connection, which is heavyweight for sidebar metadata. A 3-second poll is lightweight (single process spawn) and meets the SC-004 requirement of "within 5 seconds."

**Alternatives considered**:
- `tmux -CC` persistent connection: Would provide instant notifications but adds complexity (managing a long-lived subprocess, parsing control mode protocol). Better suited for v2 window-level integration.
- `kqueue` on tmux socket file: Only detects socket creation/deletion, not session-level changes.
- Longer polling interval (10s+): Would feel stale and not meet the 5-second success criterion.

## R3: Attaching to Sessions — Approach

**Decision**: Open a new TerminalPanel with `tmux attach-session -t <session-name>` as the initial command. Detect detach (process exit with code 0) and close the pane automatically.

**Rationale**: This leverages cmux's existing terminal pane infrastructure completely. `tmux attach` provides full interactivity (keyboard, mouse, resize) because the terminal surface handles it natively. When the user detaches (`prefix+d`), the `tmux attach` process exits cleanly, which cmux can detect to close the pane per the clarification decision. No Ghostty API changes required.

**Alternatives considered**:
- Ghostty tmux control mode rendering: Would provide tighter integration but requires Ghostty API bridge work (see issue #560 Phase 2). Overkill for v1.
- Running `tmux attach` in an existing pane: Would lose the current shell context. New pane is cleaner.

## R4: tmux Availability Detection

**Decision**: Run `which tmux` (or `command -v tmux`) at app launch and cache the result. Re-check on sidebar visibility toggle.

**Rationale**: Simple and reliable. If tmux is not found, hide the sidebar section entirely. Re-checking on sidebar toggle handles the case where the user installs tmux after launching cmux.

**Alternatives considered**:
- Continuous polling for tmux binary: Wasteful for an edge case.
- Hardcoded path (`/usr/local/bin/tmux`, `/opt/homebrew/bin/tmux`): Fragile across different installations.

## R5: Sidebar Section Placement

**Decision**: Add a "tmux Sessions" collapsible section to the existing sidebar, below the workspace/tab list. Use the existing sidebar data model pattern (computed display-order functions on Workspace, rendered in ContentView).

**Rationale**: The sidebar already has a pattern for data-driven sections (git branches, PRs, status entries, metadata blocks). tmux sessions fit naturally as another section. Placing it below workspace tabs keeps the primary navigation at the top.

**Alternatives considered**:
- Separate sidebar panel/tab: Over-engineered for a flat session list.
- Top-level menu only (no sidebar): Doesn't provide the at-a-glance visibility that is P1.

## R6: Session Management Commands

**Decision**: Use standard tmux CLI commands for all management operations:
- Create: `tmux new-session -d -s <name>` (detached, then attach via new pane)
- Kill: `tmux kill-session -t <name>`
- Rename: `tmux rename-session -t <old-name> <new-name>`

**Rationale**: These are stable, well-documented tmux commands. Running them as subprocesses is consistent with the enumeration approach (R1) and avoids any need for a persistent tmux connection.

**Alternatives considered**:
- tmux control mode commands: Requires active `-CC` session; unnecessary for simple CRUD.
