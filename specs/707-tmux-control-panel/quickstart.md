# Quickstart: tmux Control Panel Integration

**Date**: 2026-04-05  
**Feature**: 707-tmux-control-panel

## Overview

This feature adds a tmux session management section to the cmux sidebar. Users can view, create, attach to, rename, and kill tmux sessions without leaving cmux.

## Architecture

```
┌─────────────────────────────────────────────┐
│  cmux App                                   │
│                                             │
│  ┌─────────────┐    ┌────────────────────┐  │
│  │  Sidebar     │    │  Terminal Panes    │  │
│  │             │    │                    │  │
│  │ [tmux       │    │  ┌──────────────┐  │  │
│  │  Sessions]  │───>│  │ tmux attach  │  │  │
│  │  - dev  ●   │    │  │ -t dev       │  │  │
│  │  - prod ○   │    │  └──────────────┘  │  │
│  │  + New...   │    │                    │  │
│  └─────────────┘    └────────────────────┘  │
│         │                                   │
│         ▼                                   │
│  ┌─────────────┐                            │
│  │ TmuxService │ ── polls every 3s ──>  tmux CLI  │
│  └─────────────┘                            │
└─────────────────────────────────────────────┘
```

## Key Design Decisions

1. **CLI-based, not control mode**: We shell out to `tmux list-sessions -F`, `tmux new-session`, `tmux kill-session`, etc. rather than using Ghostty's tmux `-CC` control mode. This keeps v1 simple and decoupled from Ghostty internals.

2. **Polling, not event-driven**: A 3-second timer polls for session changes. tmux doesn't expose a lightweight notification mechanism suitable for sidebar metadata.

3. **Attach via TerminalPanel**: Clicking a session opens a new terminal pane running `tmux attach-session -t <name>`. Full terminal interactivity comes for free from the existing Ghostty surface.

4. **Singleton state**: tmux sessions are system-wide, so `TmuxSidebarState` is a singleton, not per-workspace.

5. **Pane closes on detach**: When the user detaches (prefix+d), the `tmux attach` process exits, and the pane closes automatically. The session stays in the sidebar.

## Implementation Approach

### New Files
- `Sources/Tmux/TmuxService.swift` — Subprocess management, polling, session CRUD
- `Sources/Tmux/TmuxSessionInfo.swift` — Data model for session metadata
- `Sources/Tmux/TmuxSidebarState.swift` — Observable state for sidebar binding
- `Sources/Tmux/TmuxSidebarView.swift` — SwiftUI view for the sidebar section

### Modified Files
- `Sources/ContentView.swift` — Add tmux section to sidebar rendering
- `Sources/cmuxApp.swift` — Initialize TmuxService and start polling
- `CLI/cmux.swift` — Add `tmux-list`, `tmux-create`, `tmux-kill`, `tmux-rename` socket commands
- `Resources/Localizable.xcstrings` — Localized strings for tmux UI

### Key Patterns to Follow
- Sidebar data: Follow `sidebarStatusEntriesInDisplayOrder()` pattern in Workspace.swift
- Panel creation: Follow `newTerminalSplit()` in Workspace.swift with `initialCommand` parameter
- Socket commands: Follow existing V2 command dispatch pattern in CLI/cmux.swift
- Localization: Use `String(localized:defaultValue:)` for all UI strings

## Testing Strategy

- Unit tests for `TmuxService` parsing of `tmux list-sessions -F` output
- Unit tests for `TmuxSessionInfo` model (state transitions, validation)
- Socket command tests for `tmux-list`, `tmux-create`, etc.
- Manual testing via tagged debug build: `./scripts/reload.sh --tag tmux-panel --launch`
