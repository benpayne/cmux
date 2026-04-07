# Data Model: tmux Control Panel Integration

**Date**: 2026-04-05  
**Feature**: 707-tmux-control-panel

## Entities

### TmuxSessionInfo

Represents metadata for a single tmux session as reported by `tmux list-sessions`.

| Attribute      | Type     | Description                                      |
|----------------|----------|--------------------------------------------------|
| name           | String   | Session name (unique identifier for tmux)        |
| windowCount    | Int      | Number of windows in the session                 |
| createdAt      | Date     | Session creation timestamp                       |
| isAttached     | Bool     | Whether any client is currently attached         |
| clientCount    | Int      | Number of clients attached to this session       |

**Identity & uniqueness**: Session name is the unique key (tmux enforces this).

**Lifecycle/state transitions**:
```
[not exists] → Created → Detached ↔ Attached → Killed → [not exists]
```

- **Created**: `tmux new-session -d -s <name>` — starts in Detached state
- **Attached**: A client attaches (`tmux attach -t <name>`) — `isAttached` becomes true
- **Detached**: All clients detach — `isAttached` becomes false
- **Killed**: `tmux kill-session -t <name>` — session ceases to exist

### TmuxSidebarState

Observable state for the sidebar section, owned by the app (not per-workspace).

| Attribute         | Type                | Description                                          |
|-------------------|---------------------|------------------------------------------------------|
| isAvailable       | Bool                | Whether tmux binary was found on the system          |
| sessions          | [TmuxSessionInfo]   | Current list of sessions, ordered by name            |
| isLoading         | Bool                | Whether a refresh is in progress                     |
| lastError         | String?             | Last error message from tmux command, if any         |
| pollTimer         | Timer?              | Reference to the 3-second polling timer              |

**Ownership**: Singleton — tmux sessions are system-wide, not per-workspace. The sidebar section reads from this shared state regardless of which workspace is active.

### AttachedTmuxPane (logical association, not a stored entity)

When a user attaches to a tmux session, a TerminalPanel is created with `tmux attach -t <name>` as its initial command. The association between the pane and the tmux session is tracked so that:
- The sidebar can show which session is "open" in a pane
- Detach detection can close the correct pane

| Attribute      | Type     | Description                                          |
|----------------|----------|------------------------------------------------------|
| sessionName    | String   | The tmux session this pane is attached to            |
| panelId        | UUID     | The cmux panel UUID hosting the tmux attach process  |
| workspaceId    | UUID     | The workspace containing the panel                   |

## Relationships

```
TmuxSidebarState (1) ──has many──> TmuxSessionInfo (N)
TmuxSidebarState (1) ──has many──> AttachedTmuxPane (0..N)
AttachedTmuxPane (1) ──references──> TmuxSessionInfo (1) via sessionName
AttachedTmuxPane (1) ──references──> TerminalPanel (1) via panelId
```

## Validation Rules

- Session names must be non-empty strings (enforced by tmux itself)
- Duplicate session names are rejected at creation time (enforced by tmux; UI shows error)
- `windowCount` and `clientCount` are always >= 0
- `createdAt` is set once at creation and never changes

## Data Volume Assumptions

- Typical user: 1-10 tmux sessions
- Upper bound: ~50 sessions (power users with many project sessions)
- Polling produces a full snapshot each cycle; no incremental diffing needed at this scale
