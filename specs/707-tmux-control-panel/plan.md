# Implementation Plan: tmux Control Panel Integration

**Branch**: `707-tmux-control-panel` | **Date**: 2026-04-05 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/707-tmux-control-panel/spec.md`

## Summary

Add a tmux session management section to the cmux sidebar. Users can view all local tmux sessions, attach to them (opening a terminal pane running `tmux attach`), create new sessions, and perform session management (rename, kill). The implementation shells out to the tmux CLI for all operations and polls on a 3-second timer for session state updates. No Ghostty API changes required for v1.

## Technical Context

**Language/Version**: Swift 5.0, macOS 14.0+ (Sonoma)  
**Primary Dependencies**: SwiftUI, AppKit, Combine, GhosttyKit.xcframework, Bonsplit  
**Storage**: N/A (tmux manages its own state; we query it)  
**Testing**: XCTest (unit tests for parsing/model; manual testing via tagged debug builds)  
**Target Platform**: macOS 14.0+  
**Project Type**: Desktop app (macOS terminal emulator)  
**Performance Goals**: Session list visible within 2s of launch; attach within 1s of click  
**Constraints**: Polling interval <= 3s; tmux subprocess calls must not block main thread  
**Scale/Scope**: 1-50 tmux sessions (typical: 1-10)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution is an unfilled template — no project-specific gates defined. Proceeding.

**Post-Phase 1 re-check**: Design uses existing patterns (sidebar data model, terminal panel creation, socket command dispatch). No new frameworks, no new project structure. Passes by default.

## Project Structure

### Documentation (this feature)

```text
specs/707-tmux-control-panel/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: research decisions
├── data-model.md        # Phase 1: entity model
├── quickstart.md        # Phase 1: implementation guide
├── contracts/
│   └── socket-commands.md  # Phase 1: socket API contracts
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2: task breakdown (created by /speckit.tasks)
```

### Source Code (repository root)

```text
Sources/
├── Tmux/                        # NEW — tmux feature module
│   ├── TmuxService.swift        # Subprocess management, polling, CRUD
│   ├── TmuxSessionInfo.swift    # Session data model
│   ├── TmuxSidebarState.swift   # Observable state for sidebar
│   └── TmuxSidebarView.swift    # SwiftUI sidebar section view
├── ContentView.swift            # MODIFIED — add tmux section to sidebar
├── cmuxApp.swift                # MODIFIED — initialize TmuxService
├── Workspace.swift              # MODIFIED — track attached tmux panes
└── Panels/
    └── TerminalPanel.swift      # MODIFIED — support tmux attach initial command

CLI/
└── cmux.swift                   # MODIFIED — add tmux socket commands

Resources/
└── Localizable.xcstrings        # MODIFIED — tmux UI strings (EN + JA)

cmuxTests/
└── TmuxServiceTests.swift       # NEW — unit tests for parsing and model
```

**Structure Decision**: New code lives in `Sources/Tmux/` as a logical grouping. No new Xcode targets or frameworks — just source files added to the existing cmux target. This matches the pattern of other feature groupings (e.g., `Sources/Panels/`).

## Complexity Tracking

No constitution violations to justify.

## Phase Summary

### Phase 1: Core Service & Data Model (P1 foundation)
- `TmuxService` — detect tmux, parse `list-sessions -F` output, subprocess execution
- `TmuxSessionInfo` — data model with Equatable for diffing
- `TmuxSidebarState` — ObservableObject with polling timer
- Unit tests for parsing

### Phase 2: Sidebar UI (P1 — View Sessions)
- `TmuxSidebarView` — SwiftUI view with session list, empty state, loading state
- Integration into `ContentView.swift` sidebar
- Initialization in `cmuxApp.swift`
- Localized strings

### Phase 3: Attach to Sessions (P1 — Attach)
- Click handler → create TerminalPanel with `tmux attach -t <name>` initial command
- Track attached panes in `TmuxSidebarState`
- Detect process exit (detach) → close pane
- Visual indicator in sidebar for attached sessions

### Phase 4: Create Sessions (P2)
- "New tmux Session" button/action in sidebar
- Name input (inline or popover)
- `tmux new-session -d -s <name>` → immediate attach

### Phase 5: Session Management (P3)
- Context menu on session rows: Rename, Kill, Detach
- Confirmation dialog for Kill
- Inline rename editing
- `tmux rename-session`, `tmux kill-session` subprocess calls

### Phase 6: Socket/CLI Commands (P3)
- `tmux.list`, `tmux.create`, `tmux.kill`, `tmux.rename`, `tmux.attach` commands
- V2 JSON-RPC dispatch in CLI/cmux.swift

### Phase 7: Drag-and-Drop (P3)
- Drag provider on tmux session rows
- Drop target integration with Bonsplit pane layout
- Attach session in target pane position
