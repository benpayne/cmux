# Tasks: tmux Control Panel Integration

**Input**: Design documents from `/specs/707-tmux-control-panel/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in the feature specification. Included only for TmuxService parsing (unit-testable without app launch, per project testing policy).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the Tmux module directory and shared data model files

- [X] T001 Create Sources/Tmux/ directory and add TmuxSessionInfo model struct (name, windowCount, createdAt, isAttached, clientCount) with Equatable/Codable conformance in Sources/Tmux/TmuxSessionInfo.swift
- [X] T002 [P] Create TmuxService class with tmux binary detection (`command -v tmux`), async subprocess execution helper, and `listSessions()` method that parses `tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_created}|#{session_attached}|#{session_clients}'` output into [TmuxSessionInfo] in Sources/Tmux/TmuxService.swift
- [X] T003 [P] Create TmuxSidebarState ObservableObject class with @Published sessions, isAvailable, isLoading, lastError properties and a 3-second polling timer that calls TmuxService.listSessions() off main thread in Sources/Tmux/TmuxSidebarState.swift

**Checkpoint**: Core service layer ready — can detect tmux, parse session list, and expose observable state

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Unit tests for the parsing layer and app initialization hookup

**CRITICAL**: No user story UI work can begin until this phase is complete

- [X] T004 Add unit tests for TmuxService.listSessions() parsing: valid output with multiple sessions, empty output (no sessions), malformed lines, tmux-not-found error in cmuxTests/TmuxServiceTests.swift
- [X] T005 Initialize TmuxSidebarState singleton in Sources/cmuxApp.swift — call availability check on app launch, start polling timer when tmux is available, stop timer when sidebar is hidden

**Checkpoint**: Foundation ready — TmuxService is tested, TmuxSidebarState is initialized at app launch

---

## Phase 3: User Story 1 — View Existing tmux Sessions (Priority: P1) MVP

**Goal**: Display all local tmux sessions in a dedicated sidebar section with name, window count, and attached/detached status. Auto-refresh every 3 seconds.

**Independent Test**: Launch cmux with tmux sessions running in the background. Verify they appear in the sidebar with correct metadata. Create/destroy a session externally and verify the list updates within 5 seconds.

### Implementation for User Story 1

- [X] T006 [US1] Create TmuxSidebarView SwiftUI view in Sources/Tmux/TmuxSidebarView.swift — collapsible section header "tmux Sessions", ForEach over TmuxSidebarState.sessions rendering each as a row with session name, window count badge, and attached/detached indicator icon
- [X] T007 [US1] Add empty state view to TmuxSidebarView — shown when isAvailable is true but sessions is empty, displays "No tmux sessions" message with a "New Session" prompt
- [X] T008 [US1] Add hidden state handling to TmuxSidebarView — when isAvailable is false, hide the entire tmux section from the sidebar (do not render the section header)
- [X] T009 [US1] Integrate TmuxSidebarView into the sidebar in Sources/ContentView.swift — add the tmux section below the workspace/tab list, reading from the shared TmuxSidebarState singleton
- [X] T010 [US1] Add localized strings for tmux sidebar UI (section header, empty state, status labels) in Resources/Localizable.xcstrings — English and Japanese translations

**Checkpoint**: User Story 1 fully functional — tmux sessions visible in sidebar with auto-refresh

---

## Phase 4: User Story 2 — Attach to Existing tmux Session (Priority: P1)

**Goal**: Click a session in the sidebar to open it in a new terminal pane running `tmux attach-session -t <name>`. Pane closes on detach. Shared attachment when session is already attached elsewhere.

**Independent Test**: Create a detached tmux session externally. Click it in the sidebar. Verify a new pane opens with the session content and full interactivity. Press prefix+d to detach — verify the pane closes and the session shows as detached in the sidebar.

### Implementation for User Story 2

- [X] T011 [US2] ~~Add AttachedTmuxPane tracking struct~~ — Replaced with simpler approach: attach state is reflected by `session.isAttached` from `tmux list-sessions` polling, no separate tracking needed
- [X] T012 [US2] Implement attachTmuxSession(named:) on Workspace + TabManager that creates a new horizontal split with initialCommand `tmux attach-session -t <name>` (via extended Workspace.newTerminalSplit signature). Wired through to TmuxSidebarSection's onAttach callback in Sources/ContentView.swift
- [X] T013 [US2] Pane closes automatically on tmux detach because the `tmux attach` subprocess exits with code 0 — handled by existing terminal pane lifecycle (no extra plumbing needed)
- [X] T014 [US2] Click handler on session rows wired in Sources/Tmux/TmuxSidebarView.swift
- [X] T015 [US2] Attached visual indicator (green filled circle vs. hollow circle) on session rows in Sources/Tmux/TmuxSidebarView.swift

**Checkpoint**: User Stories 1 AND 2 fully functional — view sessions and attach with click, pane auto-closes on detach

---

## Phase 5: User Story 3 — Create New tmux Session (Priority: P2)

**Goal**: Create a new named tmux session from the sidebar and immediately attach to it in a new pane.

**Independent Test**: Click "New tmux Session" in the sidebar. Enter a name. Verify the session appears in `tmux ls` and a pane opens attached to it. Try creating a duplicate name — verify error message.

### Implementation for User Story 3

- [X] T016 [US3] Add createSession(name:) method to TmuxService in Sources/Tmux/TmuxService.swift
- [X] T017 [US3] Add "New tmux Session" "+" button to TmuxSidebarView — shows inline text field for session name input, calls createSession then attachSession on success in Sources/Tmux/TmuxSidebarView.swift
- [X] T018 [US3] Handle unnamed session creation — if user submits empty name, call `tmux new-session -d` without `-s` flag in Sources/Tmux/TmuxService.swift
- [X] T019 [US3] Add error display for duplicate session name — inline error message in the create row in Sources/Tmux/TmuxSidebarView.swift
- [X] T020 [US3] Add localized strings for create session UI in Resources/Localizable.xcstrings

**Checkpoint**: User Stories 1, 2, AND 3 functional — view, attach, and create sessions

---

## Phase 6: User Story 4 — Manage Sessions from Sidebar (Priority: P3)

**Goal**: Right-click context menu on session rows for rename, kill (with confirmation), and detach actions.

**Independent Test**: Right-click a session in the sidebar. Select "Kill Session" — confirm dialog appears, session is destroyed after confirmation. Right-click another session, select "Rename" — edit name inline, verify change in `tmux ls`.

### Implementation for User Story 4

- [X] T021 [US4] Add killSession(name:) method to TmuxService in Sources/Tmux/TmuxService.swift
- [X] T022 [P] [US4] Add renameSession(oldName:newName:) method to TmuxService in Sources/Tmux/TmuxService.swift
- [X] T023 [US4] Context menu on session rows in TmuxSidebarView with "Rename" and "Kill Session" options. (Detach action deferred — user can detach via tmux prefix+d which closes the pane automatically)
- [X] T024 [US4] Implement kill confirmation dialog using SwiftUI .alert in Sources/Tmux/TmuxSidebarView.swift
- [X] T025 [US4] Implement inline rename editing using TmuxRenameSessionRow in Sources/Tmux/TmuxSidebarView.swift
- [~] T026 [US4] Detach action — implicitly handled by tmux prefix+d → process exit → pane close. Explicit context menu detach deferred (low value when prefix+d works).
- [X] T027 [US4] Add localized strings for context menu and kill confirmation in Resources/Localizable.xcstrings

**Checkpoint**: User Stories 1-4 functional — full session lifecycle management from sidebar

---

## Phase 7: User Story 5 — Drag tmux Session to Native Pane (Priority: P3)

**Goal**: Drag a tmux session from the sidebar to a split pane drop zone to attach it in a specific pane position.

**Independent Test**: Drag a session from the sidebar to a split drop target. Verify the session attaches in the correct pane position.

### Implementation for User Story 5

- [ ] T028 [US5] **DEFERRED** — NSItemProvider drag from session row. Cannot land independently of T029.
- [ ] T029 [US5] **DEFERRED** — Per-pane drop targets. Pane drop handlers live inside `vendor/bonsplit/` at the NSView level, not in cmux's SwiftUI layer. They accept only `com.splittabbar.tabtransfer`. Adding a new UTType would require modifying the Bonsplit submodule (separate PR + vendor coordination) or building a parallel SwiftUI drop layer over every pane (high risk of z-ordering bugs and interference with the existing tab drag system, which is already flagged as typing-latency-sensitive in CLAUDE.md). A "drop anywhere in workspace" fallback would add no incremental value over clicking — without per-pane targeting, the drop has to land in the focused pane, which is exactly what click-to-attach already does. Track separately if/when Bonsplit grows a drop-handler extensibility API, or as part of the remote workspace work (#2673) which may motivate a similar refactor.
- [ ] T030 [US5] **DEFERRED** — UTType declaration in Info.plist. Cannot land independently of T029.

**Checkpoint**: All user stories functional — complete tmux sidebar experience including drag-and-drop

---

## Phase 8: Socket/CLI Commands (Priority: P3)

**Purpose**: Expose tmux operations via the socket/CLI interface for scripting and automation

- [X] T031 Added `tmux-list` CLI command in CLI/cmux.swift. Runs TmuxService.listSessions() directly in the CLI process — works without cmux app running. Also added `tmux.list` V2 method in Sources/TerminalController.swift for in-app callers. JSON and human-readable output.
- [X] T032 Added `tmux-create` CLI command and `tmux.create` V2 method handler. Direct subprocess in CLI; V2 handler in app for in-app callers.
- [X] T033 Added `tmux-kill` CLI command and `tmux.kill` V2 method handler. Direct subprocess in CLI; V2 handler in app for in-app callers.
- [X] T034 Added `tmux-rename` CLI command and `tmux.rename` V2 method handler. Direct subprocess in CLI; V2 handler in app for in-app callers.
- [X] T035 Added `tmux-attach` CLI command and `tmux.attach` V2 method handler. CLI uses sendV2 (requires cmux app running, since attaching opens a pane). V2 handler calls TabManager.attachTmuxSession(named:) and returns surface_id/workspace_id.

**Checkpoint**: All tmux operations available via CLI (`cmux tmux-list`, `cmux tmux-create`, etc.)

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T036 All TmuxService subprocess calls run on TmuxSidebarState.workQueue (off main thread). Verified.
- [X] T037 Added dlog() for tmux.sidebar.start, tmux.sidebar.refresh (on change), tmux.sidebar.unavailable, tmux.sidebar.refresh.error, tmux.attach in Sources/Tmux/TmuxSidebarState.swift and Sources/Workspace.swift, all wrapped in #if DEBUG
- [X] T038 tmux server crash handled — "no server running" output is treated as empty session list (not an error); .notInstalled error transitions isAvailable to false and stops polling; other errors surface via lastError row in the sidebar
- [X] T039 Tagged debug build verified to compile cleanly via `xcodebuild ... -derivedDataPath /tmp/cmux-tmux-panel build`. Manual launch via `./scripts/reload.sh --tag tmux-panel --launch` confirmed working by user.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Phase 2 — MVP deliverable
- **US2 (Phase 4)**: Depends on Phase 3 (needs sidebar view to add click handlers)
- **US3 (Phase 5)**: Depends on Phase 3 (needs sidebar view) + Phase 4 (reuses attachSession)
- **US4 (Phase 6)**: Depends on Phase 3 (needs sidebar view) + Phase 4 (reuses detach logic)
- **US5 (Phase 7)**: Depends on Phase 4 (needs attachSession) + existing Bonsplit drop targets
- **Socket/CLI (Phase 8)**: Depends on Phase 2 (needs TmuxService) — can run in parallel with UI phases
- **Polish (Phase 9)**: Depends on all desired phases being complete

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational — No dependencies on other stories
- **US2 (P1)**: Depends on US1 sidebar view being in place
- **US3 (P2)**: Depends on US1 (sidebar) + US2 (attachSession method)
- **US4 (P3)**: Depends on US1 (sidebar) + US2 (detach logic)
- **US5 (P3)**: Depends on US2 (attachSession) — independent from US3/US4

### Within Each User Story

- Models/service methods before UI
- UI integration after service layer is ready
- Localization strings with each UI phase

### Parallel Opportunities

- T002 and T003 can run in parallel (different files)
- T006, T007, T008 can be implemented together (same file but independent sections)
- T021 and T022 can run in parallel (independent service methods)
- T032, T033, T034 can run in parallel (independent socket command handlers)
- Phase 8 (Socket/CLI) can run in parallel with Phases 5-7 (UI stories)

---

## Parallel Example: Phase 1

```bash
# Launch foundational service tasks together:
Task: "Create TmuxService in Sources/Tmux/TmuxService.swift"
Task: "Create TmuxSidebarState in Sources/Tmux/TmuxSidebarState.swift"
```

## Parallel Example: Phase 8

```bash
# Launch independent socket commands together:
Task: "Add tmux.create handler in CLI/cmux.swift"
Task: "Add tmux.kill handler in CLI/cmux.swift"
Task: "Add tmux.rename handler in CLI/cmux.swift"
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2)

1. Complete Phase 1: Setup (T001-T003)
2. Complete Phase 2: Foundational (T004-T005)
3. Complete Phase 3: US1 — View Sessions (T006-T010)
4. Complete Phase 4: US2 — Attach to Sessions (T011-T015)
5. **STOP and VALIDATE**: Build with `./scripts/reload.sh --tag tmux-panel --launch`
6. Test: sessions appear in sidebar, clicking attaches, detaching closes pane

### Incremental Delivery

1. Setup + Foundational → Core service ready
2. Add US1 (View) → Sessions visible in sidebar (MVP!)
3. Add US2 (Attach) → Click to attach, detach closes pane
4. Add US3 (Create) → Create new sessions from sidebar
5. Add US4 (Manage) → Rename, kill, detach from context menu
6. Add US5 (Drag) → Drag sessions to pane positions
7. Add Socket/CLI → Scriptable tmux operations
8. Polish → Debug logging, error handling, performance

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- All UI strings must use `String(localized:defaultValue:)` per CLAUDE.md
- All subprocess calls must run off main thread per socket command threading policy
- Build with tagged reload: `./scripts/reload.sh --tag tmux-panel`
