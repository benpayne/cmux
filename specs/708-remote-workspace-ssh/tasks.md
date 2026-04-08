# Tasks: Remote Workspace Mode (SSH ControlMaster + Remote tmux)

**Input**: Design documents from `/specs/708-remote-workspace-ssh/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md
**Depends on**: Feature 707-tmux-control-panel (merged into parent branch)

**Tests**: Unit tests are explicitly requested by plan.md for SSHConfigParser, SSHCommandBuilder, HostRegistry JSON round-trip, and TmuxTransport mocks. These are included as non-optional tasks. All tests follow the project's test quality policy (behavior-focused, no AST-shape tests, no tests that launch the app).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the directory structure and stub files for the new module

- [ ] T001 Create Sources/Tmux/Remote/ directory
- [ ] T002 Register new Sources/Tmux/Remote/ files in GhosttyTabs.xcodeproj/project.pbxproj as they are created. Use tabs for whitespace (matching existing pbxproj style); follow the 4-edit pattern used for 707 (PBXBuildFile entry, PBXFileReference entry, Sources group children, PBXSourcesBuildPhase files). Validate with `plutil -lint` after each round of edits.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Phase A + Phase B from plan.md — extract shared SSH primitives and build the remote connection layer that all user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete. The refactor in T003-T006 MUST NOT change user-visible behavior of existing features.

### A. Extract SSH primitives (refactor, behavior-preserving)

- [ ] T003 [P] Create Sources/Tmux/Remote/SSHConnectionOptions.swift with a struct containing the fields currently on `DetectedSSHSession`: `port: Int?`, `identityFile: String?`, `configFile: String?`, `jumpHost: String?`, `useIPv4: Bool`, `useIPv6: Bool`, `forwardAgent: Bool`, `compressionEnabled: Bool`, `sshOptions: [String]`. Add `Equatable` and `Codable` conformance.
- [ ] T004 Create Sources/Tmux/Remote/SSHCommandBuilder.swift by extracting the private `sshArguments(command:)` method logic from Sources/TerminalSSHSessionDetector.swift (around line 174). Expose as `static func buildArguments(destination: String, command: String, options: SSHConnectionOptions, controlPath: String?, batchMode: Bool, useControlMaster: Bool) -> [String]`. Also expose a `buildSCPArguments` variant matching the existing `scpArguments` helper.
- [ ] T005 Add unit tests for SSHCommandBuilder in cmuxTests/SSHCommandBuilderTests.swift. Test: basic destination, with port, with identity file, with jump host, with extra sshOptions, with IPv4/IPv6 forcing, escaping of special characters in commands. DO NOT invoke actual ssh; only assert on the generated argument arrays.
- [ ] T006 Refactor Sources/TerminalSSHSessionDetector.swift to use `SSHConnectionOptions` and `SSHCommandBuilder`. Make `DetectedSSHSession` hold an `SSHConnectionOptions` value internally. Remove the inlined `sshArguments(command:)` and `scpArguments(localPath:remotePath:)` private methods. Verify that existing file-upload tests still pass (run cmuxTests/WindowAndDragTests.swift or any SSH-related tests via the unit target).

### B. TmuxTransport protocol + refactor

- [ ] T007 Create Sources/Tmux/TmuxTransport.swift with the `TmuxTransport` protocol (`var label: String { get }`, `func runTmux(arguments: [String]) throws -> TmuxProcessResult`, `func attachCommand(forSession name: String) -> String`) and a `struct TmuxProcessResult { let exitCode: Int32; let stdout: String; let stderr: String }`. Include a `LocalTmuxTransport` struct implementation that wraps the existing `TmuxService`'s subprocess runner.
- [ ] T008 Refactor Sources/Tmux/TmuxService.swift: change `TmuxService` from a monolithic class to accept a `TmuxTransport` at construction. The subprocess-running code moves into `LocalTmuxTransport`. `TmuxService` keeps the parsing, CRUD, and caching logic but delegates subprocess invocation to the transport. Preserve the `TmuxService.shared` singleton (it now constructs a `LocalTmuxTransport` internally).
- [ ] T009 Add unit tests for TmuxTransport abstraction in cmuxTests/TmuxTransportMockTests.swift. Create a `MockTmuxTransport` that returns canned stdout/stderr/exit codes. Verify that `TmuxService` correctly parses multi-session output, handles "no server running", returns errors for non-zero exits, and calls the transport with the right argument arrays.
- [ ] T010 Verify the 707 tmux feature still works after the refactor: run the existing `cmuxTests/TmuxServiceTests.swift` suite; all 16 tests must still pass. Run `xcodebuild ... build` for the cmux scheme to confirm no compile regressions in any dependent file.

### C. Remote connection layer

- [ ] T011 [P] Create Sources/Tmux/Remote/RemoteHost.swift with the `RemoteHost` struct per data-model.md: `id: UUID`, `alias: String`, `destination: String`, `sshOptions: SSHConnectionOptions`, `addedAt: Date`, `lastConnectedAt: Date?`, `transient: Bool`. Add `Equatable`, `Codable`, and an `Identifiable` conformance keyed on `id`.
- [ ] T012 [P] Create Sources/Tmux/Remote/ConnectionState.swift with the `ConnectionState` enum: `disconnected`, `connecting`, `connected`, `failed(reason: String)`. Add `Equatable` conformance.
- [ ] T013 Create Sources/Tmux/Remote/RemoteConnection.swift implementing the live master connection for a single host: spawn `ssh -M -S <sock> -fnNT <dest>` via `Process()`, track the running process, provide `connect()`, `disconnect()`, `isHealthy()` (runs `ssh -O check -S <sock>`), and `runCommand(_ command: String) throws -> TmuxProcessResult`. Manage the control socket path per R7 from research.md (`~/Library/Application Support/cmux/ssh/<instance-id>/<alias>.sock`). Marked `@MainActor` for state mutations but subprocess work happens on a background queue.
- [ ] T014 Create Sources/Tmux/Remote/RemoteHostManager.swift as a `@MainActor` singleton (`RemoteHostManager.shared`) owning `[UUID: RemoteHost]` and `[UUID: RemoteConnection]` dictionaries plus `@Published` state for UI binding. Methods: `addHost(destination:alias:transient:)`, `removeHost(id:)`, `connect(id:)`, `disconnect(id:)`, `findOrCreate(destination:transient:)`, `teardownAllConnections()` (called on app quit).
- [ ] T015 Add a periodic health-check loop to RemoteHostManager: every 30 seconds, for each connection in the `connected` state, run `isHealthy()`; on failure transition to `disconnected`. Implemented via a `Timer` on the main run loop; subprocess work happens off-main. Wrapped in `#if DEBUG` `dlog` events for `health.ok`, `health.failed`.
- [ ] T016 [P] Create Sources/Tmux/Remote/RemoteTmuxTransport.swift implementing `TmuxTransport`. Wraps a `RemoteConnection`; `runTmux(arguments:)` prefixes with `ssh -S <sock> <destination> tmux` and delegates to the connection's `runCommand`. `attachCommand(forSession:)` returns the full `ssh -S <sock> -t <destination> tmux attach-session -t <name>` command for use as a TerminalPanel initial command.
- [ ] T017 [P] Create Sources/Tmux/Remote/SSHConfigParser.swift that reads `~/.ssh/config` and returns `[ParsedSSHHost]` entries. Apply the filter from FR-023: non-wildcard patterns (no `*` or `?`) AND at least one of `Hostname`, `User`, or `Port` explicitly set. Handle `Include` directives by recursively reading referenced files. Return entries in declaration order.
- [ ] T018 [P] Add unit tests for SSHConfigParser in cmuxTests/SSHConfigParserTests.swift: empty file, single host with full config, host with only Hostname, host with only User, host with only wildcard (should be excluded), multiple hosts, comments and blank lines, malformed lines (should be skipped gracefully), Include directive support.

**Checkpoint**: Foundational layer complete. SSH primitives extracted. Transport abstraction in place. Local tmux feature still passes all tests. Connection manager ready. User story work can now begin.

---

## Phase 3: User Story 1 — View remote tmux sessions (Priority: P1) 🎯 MVP

**Goal**: With a connected remote host, the sidebar shows its tmux sessions in a dedicated "REMOTE: <alias>" section with the same metadata as local sessions (name, window count, attached status). Auto-refresh every 5 seconds while the section is visible.

**Independent Test**: Programmatically add a host via `RemoteHostManager.shared.addHost(destination:)`, wait for it to connect, verify the sidebar shows a "REMOTE:" section listing any tmux sessions on the host. Create a session on the remote externally (e.g., from another shell) and verify it appears in the cmux sidebar within the 5-second poll interval.

### Implementation for User Story 1

- [ ] T019 [US1] Refactor Sources/Tmux/TmuxSidebarState.swift: change `sessions: [TmuxSessionInfo]` to `serviceGroups: [TmuxSidebarGroup]` where `TmuxSidebarGroup` is a new struct containing `{ id: GroupId, title: String, service: TmuxService, host: RemoteHost? }`. `GroupId` is `enum { case local; case remote(UUID) }`. Maintain a default "local" group backed by the existing `LocalTmuxTransport`.
- [ ] T020 [US1] Add per-host polling to TmuxSidebarState: when a `RemoteConnection` transitions to `connected`, create a `TmuxService(transport: RemoteTmuxTransport(connection:))` and add it as a group. Poll each group's service at its own cadence (5s for remote, 3s for local). Pause polling for any group whose sidebar section is not visible (visibility tracked via a published `visibleGroupIds: Set<GroupId>`).
- [ ] T021 [US1] Cap concurrent poll subprocesses at 4 in TmuxSidebarState. Use a simple semaphore or dispatch work item count. Document the rationale in a code comment referencing R9 from research.md.
- [ ] T022 [US1] Refactor Sources/Tmux/TmuxSidebarView.swift: the top-level `TmuxSidebarSection` now iterates over `serviceGroups` and renders each group as its own `DisclosureGroup` with a localized header ("LOCAL SESSIONS" or "REMOTE: <alias>" with connection status indicator). Each group shows the existing session rows.
- [ ] T023 [US1] Add visibility tracking to the grouped sidebar view: use `.onAppear` / `.onDisappear` on each `DisclosureGroup` body (or `GeometryReader`-based viewport detection if onAppear isn't granular enough) to update `TmuxSidebarState.visibleGroupIds`.
- [ ] T024 [US1] Add localized strings for the new sidebar headers in Resources/Localizable.xcstrings: `tmux.sidebar.localHeader` ("LOCAL SESSIONS"), `tmux.sidebar.remoteHeader` (format "REMOTE: %@"), `tmux.sidebar.hostStatus.connected`, `tmux.sidebar.hostStatus.disconnected`, `tmux.sidebar.hostStatus.connecting`, `tmux.sidebar.hostStatus.failed`. Include EN + JA translations.
- [ ] T025 [US1] Verify manually in a tagged debug build: `./scripts/reload.sh --tag remote-ssh --launch`, then programmatically add a host (e.g., via a debug menu item added under Debug > Debug Windows, or via the CLI once Phase 10 lands) and confirm the sidebar shows the remote tmux section.

**Checkpoint**: User Story 1 complete. Remote tmux sessions visible in sidebar with visibility-gated polling.

---

## Phase 4: User Story 2 — Click to attach to remote tmux session (Priority: P1)

**Goal**: Clicking a remote tmux session in the sidebar opens a new pane attached to that session, reusing the existing SSH master. Detaching closes the pane as usual. On connection drop, the pane stays open with a "Disconnected — Reconnect" overlay (per FR-021).

**Independent Test**: With a connected host showing a detached tmux session, click the row. Verify a new pane opens with the session content and full interactivity. Drop the network (e.g., disable Wi-Fi), verify the pane stays open with an overlay. Re-enable network, click reconnect, verify the pane returns to the live tmux session.

### Implementation for User Story 2

- [ ] T026 [US2] Extend Sources/Workspace.swift `attachTmuxSession(named:)` to accept an optional `host: RemoteHost?` parameter. When a host is provided, use `RemoteTmuxTransport.attachCommand(forSession:)` (via the host's connection) as the initial command; when nil, use the existing local behavior. Pass through the connection reference so the new pane can be tracked.
- [ ] T027 [US2] Update Sources/TabManager.swift `attachTmuxSession(named:)` to accept the optional host parameter and forward it to the workspace method.
- [ ] T028 [US2] Wire the sidebar click handler in TmuxSidebarView: when a session row in a remote group is clicked, the `onAttach` closure receives the session name AND the host; it calls `tabManager.attachTmuxSession(named: name, onHost: host)`.
- [ ] T029 [US2] Add a `remoteConnection: RemoteConnection?` reference to `TerminalPanel` (in Sources/Panels/TerminalPanel.swift) so the pane knows which remote connection it belongs to. Increment `openTerminalCount` on creation and decrement on close. Unchanged for local panes (nil reference).
- [ ] T030 [US2] Implement the disconnect overlay UI in Sources/Tmux/Remote/RemoteDisconnectOverlay.swift (or extend Sources/Panels/TerminalPanelView.swift): when a pane's `remoteConnection` is non-nil and the connection is in `disconnected` or `failed` state, render a SwiftUI overlay over the pane with a "Disconnected — Reconnect" button. The overlay preserves the underlying terminal buffer (does not clear or close it).
- [ ] T031 [US2] Add reconnect logic to RemoteHostManager: `reconnect(host:)` re-establishes the master connection. For tmux-attached panes on that connection, after reconnect, re-send the `tmux attach -t <name>` command to the existing Ghostty surface (which still has the buffer). For plain shells, spawn a fresh shell in-place. Requires tracking per-pane intent (what command re-creates the session).
- [ ] T032 [US2] Add a per-pane state field to track attach intent: extend `RemoteTerminalPane` association in RemoteHostManager with `kind: .tmuxAttach(sessionName: String)` or `.shell`. Used by the reconnect flow to know which command to re-run.
- [ ] T033 [US2] Add localized strings for the disconnect overlay: `remote.overlay.disconnected` ("Disconnected"), `remote.overlay.reconnect` ("Reconnect"), `remote.overlay.reconnecting` ("Reconnecting…"), `remote.overlay.reconnectFailed` ("Reconnect failed: %@"). EN + JA.

**Checkpoint**: User Story 2 complete. Click-to-attach, detach-closes-pane, drop-with-overlay, and reconnect-in-place all working.

---

## Phase 5: User Story 3 — Open plain remote shell (Priority: P1)

**Goal**: A "+ New terminal on host" affordance opens a plain (non-tmux) interactive shell on a connected host, reusing the master connection.

**Independent Test**: With a connected host, click the "+ New terminal" button in the host's sidebar section. Verify a new pane opens within 1 second showing a remote shell prompt. Type commands and verify they execute on the remote.

### Implementation for User Story 3

- [ ] T034 [US3] Add a `newShell(onHost:)` method to Sources/Tmux/Remote/RemoteHostManager.swift that returns a full shell command string: `ssh -S <sock> -t <destination> <shell>` where shell is `$SHELL` expansion on the remote (use `$SHELL` literal; ssh will expand it).
- [ ] T035 [US3] Add `openRemoteShell(onHost:)` to Sources/Workspace.swift: creates a new split TerminalPanel with the remote shell command as the initial command, associates it with the RemoteConnection, and registers the panel ID with the connection's pane tracker.
- [ ] T036 [US3] Add `openRemoteShell(onHost:)` bridge to Sources/TabManager.swift that delegates to the selected workspace.
- [ ] T037 [US3] Add a "+ New terminal" button to each remote group header in Sources/Tmux/TmuxSidebarView.swift (positioned next to the existing "+ New session" button from 707 or as a separate action in a small menu). Clicking it calls `tabManager.openRemoteShell(onHost:)`.
- [ ] T038 [US3] Add localized string `remote.sidebar.newTerminal` ("New terminal on %@") in Resources/Localizable.xcstrings with EN + JA translations.

**Checkpoint**: User Story 3 complete. Users can open plain remote shells from the sidebar.

---

## Phase 6: User Story 4 — Add, manage, and remove remote hosts from the UI (Priority: P1)

**Goal**: Users can add hosts by typing a destination or picking from their `~/.ssh/config`, see connection status, disconnect/reconnect/remove hosts via a context menu. New hosts auto-connect immediately per FR-022.

**Independent Test**: Open the "Add remote host…" affordance. Type `user@host` and submit. Verify cmux immediately attempts to connect and either shows the host as connected or shows an inline error. Separately, open the picker, verify it shows SSH config entries matching the FR-023 filter, and can add one with a click.

### Implementation for User Story 4

- [ ] T039 [US4] Create Sources/Tmux/Remote/RemoteHostSidebarUI.swift with `AddRemoteHostSheet` — a SwiftUI modal with two modes: (a) manual entry — text field for destination, optional alias, submit button; (b) SSH config picker — list view of parsed hosts from `SSHConfigParser`, click-to-add.
- [ ] T040 [US4] Add a "+ Add remote host…" button to the top of the REMOTE section of TmuxSidebarView. Clicking it presents `AddRemoteHostSheet` as a popover or sheet. Show the button even when no remote hosts exist yet.
- [ ] T041 [US4] Implement immediate-connect on add in RemoteHostManager.addHost: after adding the host, call `connect(id:)` synchronously from the main actor and await the initial state transition. If the connect succeeds, return the host. If it fails, the host remains in the registry with `state = .failed(reason:)` and the error is surfaced to the caller.
- [ ] T042 [US4] Handle the "failed" state in the sidebar: a failed host shows its section header with a red dot and an error tooltip; clicking it offers "Retry" (calls `connect(id:)`) and "Remove".
- [ ] T043 [US4] Add a context menu to each remote group header: "Reconnect" (if disconnected/failed), "Disconnect" (if connected), "Rename host", "Remove host". "Remove host" shows a confirmation dialog if there are open panes on the host (same pattern as the tmux kill confirmation from 707).
- [ ] T044 [US4] Add inline rename for host aliases: same pattern as the tmux session rename from 707. A `TmuxRenameSessionRow`-style view, just wired to `RemoteHostManager.renameHost(id:newAlias:)` which must check for duplicate aliases before committing.
- [ ] T045 [US4] Add localized strings for the add-host sheet, context menu, confirmations, and error messages in Resources/Localizable.xcstrings: `remote.sidebar.addHost`, `remote.sidebar.addHost.manual`, `remote.sidebar.addHost.fromConfig`, `remote.sidebar.addHost.destinationLabel`, `remote.sidebar.addHost.aliasLabel`, `remote.sidebar.addHost.submitButton`, `remote.menu.reconnect`, `remote.menu.disconnect`, `remote.menu.rename`, `remote.menu.remove`, `remote.confirm.removeWithPanes.title`, `remote.confirm.removeWithPanes.message`, `remote.error.connectFailed`, `remote.error.duplicateAlias`, `remote.picker.noMatches`. EN + JA.

**Checkpoint**: User Story 4 complete. Full host management from the UI.

---

## Phase 7: User Story 5 — Remote tmux session management (Priority: P2)

**Goal**: Right-clicking a remote tmux session in the sidebar offers the same Rename/Kill actions as local sessions. Uses the existing context menu from feature 707 unchanged; only the underlying `TmuxService` differs (remote vs local transport).

**Independent Test**: Right-click a remote tmux session, choose "Kill Session", confirm. Verify the session disappears from the sidebar and `tmux ls` on the remote confirms it's gone. Verify rename works with duplicate-name error handling.

### Implementation for User Story 5

- [ ] T046 [US5] Verify the existing TmuxSidebarView context menu wiring from feature 707 works unchanged for remote sessions. The context menu calls `state.killSession(name:)` and `state.renameSession(oldName:newName:)` on the group's `TmuxService`, which now has a remote transport for remote groups. No new UI code needed; verify via tagged debug build.
- [ ] T047 [US5] Verify the "+ New session" affordance (from 707) routes through the remote transport for remote groups. Since `TmuxService.createSession` already uses the injected transport, this should Just Work. Add an acceptance test by creating a new session from the sidebar and confirming it appears on the remote.
- [ ] T048 [US5] Add a manual smoke-test script (documented in quickstart.md or a new TESTING.md for the feature): a sequence of user-visible steps to verify create/rename/kill work on a real remote host. This is a documentation task, not a code change.

**Checkpoint**: User Story 5 complete. Remote tmux session management working via the existing 707 UI.

---

## Phase 8: User Story 6 — Persist remote hosts across cmux restarts (Priority: P2)

**Goal**: The user's list of saved hosts survives cmux quit. On launch, hosts appear in the sidebar as disconnected. Clicking a host reconnects it (no auto-reconnect).

**Independent Test**: Add two hosts. Quit cmux. Reopen. Verify both hosts appear in the sidebar, both in disconnected state. Click one, verify it reconnects.

### Implementation for User Story 6

- [ ] T049 [US6] Create Sources/Tmux/Remote/HostRegistry.swift implementing JSON persistence per data-model.md: `{ version: 1, hosts: [RemoteHost] }`. Methods: `load() throws -> [RemoteHost]`, `save(_ hosts: [RemoteHost]) throws`. Writes atomically via temp-file + rename. File path: `~/Library/Application Support/cmux/remote-hosts.json`. Only persists saved (non-transient) hosts.
- [ ] T050 [US6] Add unit tests in cmuxTests/HostRegistryTests.swift: empty registry round-trip, single host, multiple hosts, schema version preserved, malformed JSON returns error, atomic write (write-fail doesn't corrupt existing file). Use a temporary directory for test files.
- [ ] T051 [US6] Integrate HostRegistry into RemoteHostManager: load from disk on `init()`; save on `addHost` (if not transient), `removeHost`, `renameHost`. Transient hosts are never written. After load, all hosts start in the `disconnected` state regardless of their lastConnectedAt.
- [ ] T052 [US6] Add a concurrent-write guard to HostRegistry: coalesce rapid successive saves by debouncing to 500ms. Prevents thrashing the JSON file on bulk operations.
- [ ] T053 [US6] Verify FR-013 (no auto-reconnect on startup): hosts loaded from disk MUST NOT automatically connect. This is already the default behavior of the `connect()` method being explicitly triggered; add an XCTAssertion that creating a `RemoteHostManager` with a seeded registry file does not spawn any SSH processes.

**Checkpoint**: User Story 6 complete. Host list persists across restarts.

---

## Phase 9: User Story 7 — `cmux ssh` CLI participates in the remote host manager (Priority: P2)

**Goal**: Running `cmux ssh user@host` from a shell reuses an existing managed host's master connection if one is already open for the same destination, or creates a new transient host on the fly. Transient hosts are auto-removed when their last pane closes.

**Independent Test**: Run `cmux ssh deploy@prod-1` from a shell. Verify a pane opens on the remote. Check that `prod-1` now appears in the sidebar. Run `cmux ssh deploy@prod-1` again from another shell. Verify the second invocation does NOT trigger a second authentication prompt (no second master process).

### Implementation for User Story 7

- [ ] T054 [US7] Add a `findOrCreate(destination:transient:)` method to RemoteHostManager that: (a) looks for an existing host whose `destination` matches; (b) if found, returns it (reusing the existing connection); (c) if not, creates a new host with `transient: true` by default and connects it.
- [ ] T055 [US7] Add a transient-host cleanup rule: when a transient host's `openTerminalCount` drops to zero, automatically remove the host (and its connection) from the manager. Saved hosts are NOT removed even when their pane count is zero.
- [ ] T056 [US7] Add the `host.connect_or_get` V2 method to Sources/TerminalController.swift per contracts/socket-commands.md. Parameters: `destination` (required), `save` (default false), `open_terminal` (default false). Behavior: calls `findOrCreate(destination:transient:!save)`; if `open_terminal` is true, also opens a new remote shell on the host. Returns host info and optionally surface_id/workspace_id.
- [ ] T057 [US7] Modify the existing `cmux ssh` CLI command in CLI/cmux.swift to route through `host.connect_or_get` with `open_terminal=true`. The existing argument parsing stays the same; only the dispatch changes. Preserve the existing error messages for auth/unreachable failures so users don't notice a behavior change other than the reuse.

**Checkpoint**: User Story 7 complete. `cmux ssh` reuses managed connections.

---

## Phase 10: CLI and V2 methods for host management (Cross-cutting for US4 scripting)

**Purpose**: Expose host operations over the V2 socket and as CLI commands for scripting and automation

- [ ] T058 Add V2 method `host.list` handler in Sources/TerminalController.swift per contracts/socket-commands.md. Returns all hosts (saved + transient) with their connection state.
- [ ] T059 [P] Add V2 method `host.add` handler. Parameters: `destination`, `alias?`, `ssh_options?`, `save?`. Calls `RemoteHostManager.addHost` and returns the created host.
- [ ] T060 [P] Add V2 method `host.remove` handler. Parameter: `id`. Calls `removeHost` after tearing down any open panes on the host.
- [ ] T061 [P] Add V2 method `host.connect` handler. Parameter: `id`. Idempotent — no-op if already connected.
- [ ] T062 [P] Add V2 method `host.disconnect` handler. Parameter: `id`. Tears down master and closes remote panes on that host.
- [ ] T063 [P] Add V2 method `host.shell.open` handler. Parameters: `id`, `workspace_id?`. Calls the workspace's `openRemoteShell`.
- [ ] T064 [P] Add V2 method `host.tmux.list` handler. Parameter: `id`. Returns the host's current `TmuxSessionInfo` list.
- [ ] T065 [P] Add V2 method `host.tmux.attach` handler. Parameters: `id`, `name`, `workspace_id?`. Opens a new remote-tmux-attached pane.
- [ ] T066 Add CLI commands in CLI/cmux.swift: `host-list`, `host-add <dest> [--alias <name>] [--save|--transient]`, `host-remove <id-or-alias>`, `host-connect <id-or-alias>`, `host-disconnect <id-or-alias>`, `host-shell <id-or-alias>`, `host-tmux-list <id-or-alias>`, `host-tmux-attach <id-or-alias> <session-name>`. Each command uses `normalizeHostHandle` to accept either an id or an alias. Add a new `normalizeHostHandle` helper matching the pattern of `normalizeWorkspaceHandle` (accepts UUID, ref, or 1-based position in the host list).
- [ ] T067 Add help/usage text for the new `host-*` commands in the CLI's printHelp output.

**Checkpoint**: CLI and V2 surface complete. Scripting/automation fully supported.

---

## Phase 11: Polish & cross-cutting concerns

**Purpose**: Production-readiness: error messages, cleanup, logging, quit hooks, concurrent poll cap

- [ ] T068 Initialize RemoteHostManager in Sources/cmuxApp.swift on app launch: `@StateObject private var remoteHostManager = RemoteHostManager.shared`. Call `remoteHostManager.loadFromRegistry()` in the existing `.onAppear` block. Pass it into the environment via `.environmentObject(remoteHostManager)`.
- [ ] T069 Add app-quit teardown hook in Sources/cmuxApp.swift (or Sources/AppDelegate.swift) that calls `RemoteHostManager.shared.teardownAllConnections()` before NSApp terminates. Ensures no orphaned `ssh -M` processes or control sockets survive cmux quit. Verify via `ps aux | grep 'ssh -M'` after quit that no cmux-spawned SSH processes remain.
- [ ] T070 Add orphan socket cleanup on launch: on RemoteHostManager init, scan `~/Library/Application Support/cmux/ssh/*/` directories, remove any instance directories whose owning process no longer exists (check via PID file or directory-age heuristic). Document the cleanup logic in a code comment.
- [ ] T071 Add `#if DEBUG` `dlog` events for key RemoteHostManager operations: `host.add`, `host.remove`, `host.connect.start`, `host.connect.ok`, `host.connect.failed`, `host.disconnect`, `host.reconnect`, `host.pane.added`, `host.pane.closed`, `host.health.ok`, `host.health.failed`. Use `dlog` from Bonsplit (requires `import Bonsplit`).
- [ ] T072 Refine error messages for common SSH failure modes. Map OpenSSH stderr patterns to user-friendly messages: "Permission denied" → "Authentication failed. Check your SSH key or agent.", "Could not resolve hostname" → "Host not found: <hostname>", "Connection refused" → "Connection refused. Is sshd running?", "Host key verification failed" → "The remote host's key has changed. Check with your administrator before reconnecting." Log the raw stderr to the debug log for troubleshooting.
- [ ] T073 Enforce the concurrent-poll cap (4) from R9 in TmuxSidebarState. Use a `DispatchSemaphore(value: 4)` around poll subprocess launches. Verify no more than 4 concurrent `ssh ... tmux list-sessions` processes exist during a stress test with 10 connected hosts.
- [ ] T074 Add a Debug Menu entry (DEBUG builds only) under Debug > Debug Windows: "Remote Host Inspector" that opens a small window showing the current RemoteHostManager state (host list, connection states, open pane counts, control socket paths, last health check times). Follows the pattern documented in CLAUDE.md for debug windows.
- [ ] T075 Verify tagged debug build end-to-end against a real remote host: `./scripts/reload.sh --tag remote-ssh --launch`. Scenarios: add a host manually, confirm auto-connect and sidebar render; create a tmux session on the remote externally and verify it appears; click to attach; detach via prefix+d (pane closes); drop the Wi-Fi; verify the pane shows the disconnect overlay; reconnect; verify the pane re-attaches; kill the remote session from the context menu; remove the host.
- [ ] T076 Update docs/SPEC.md or the main README with a brief section on remote workspace mode — how to add a host, how it interacts with `~/.ssh/config`, how to use `cmux ssh` to benefit from reuse. Screenshots optional.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Depends on Setup. **BLOCKS all user stories.** The SSH primitive refactor (T003–T010) must be behavior-preserving; the remote connection layer (T011–T018) must compile and be unit-tested before any UI work begins.
- **User Stories (Phases 3–9)**:
  - **US1 (Phase 3)** depends on Foundational only
  - **US2 (Phase 4)** depends on US1 (needs the grouped sidebar view)
  - **US3 (Phase 5)** depends on US2 (shares the `RemoteConnection.openTerminalCount` tracking and overlay infrastructure)
  - **US4 (Phase 6)** depends on US1 (needs the sidebar grouping) + Foundational (needs RemoteHostManager for add/remove operations)
  - **US5 (Phase 7)** depends on US1 (needs the remote sidebar group; reuses 707's context menu)
  - **US6 (Phase 8)** depends on US4 (needs the add/remove flow to have actual behavior to persist)
  - **US7 (Phase 9)** depends on Foundational + US3 (needs `openRemoteShell`)
- **Phase 10 (CLI/V2)** depends on US4, US6, US7 (exposes their operations)
- **Phase 11 (Polish)**: Depends on all desired user stories being complete

### User Story Dependencies (quick reference)

```
Foundational (Phase 2)
├── US1 (Phase 3) ─┬── US2 (Phase 4) ─── US3 (Phase 5)
│                  └── US5 (Phase 7)
├── US4 (Phase 6) ─── US6 (Phase 8)
└── US7 (Phase 9)
```

### Within Each User Story

- Models/services before UI
- UI integration after data layer
- Localization strings grouped with the UI phase that needs them
- Manual verification at the end of each story's checkpoint

### Parallel Opportunities

- **Phase 2**: T003 + T011 + T012 + T016 + T017 + T018 can run in parallel (different files, isolated concerns)
- **Phase 10**: T059 + T060 + T061 + T062 + T063 + T064 + T065 can run in parallel (all separate V2 methods in the same file, but each is a self-contained block; in practice they'll land in one commit)
- **Phase 11**: T071 + T072 can run in parallel (logging and error messages are independent)
- **Whole phases**: Once Foundational is done, US1–US4 can theoretically be worked on by different developers if they coordinate on the shared `TmuxSidebarView` / `TmuxSidebarState` files

---

## Parallel Example: Phase 2 foundational parallel tasks

```bash
# Launch these together (different files, no interdependencies):
Task: "Create Sources/Tmux/Remote/SSHConnectionOptions.swift" (T003)
Task: "Create Sources/Tmux/Remote/RemoteHost.swift" (T011)
Task: "Create Sources/Tmux/Remote/ConnectionState.swift" (T012)
Task: "Create Sources/Tmux/Remote/RemoteTmuxTransport.swift" (T016 — depends on T007 only)
Task: "Create Sources/Tmux/Remote/SSHConfigParser.swift" (T017)
Task: "Add SSHConfigParser tests" (T018 — depends on T017)
```

---

## Implementation Strategy

### MVP First (US1 + US2 + US3 + US4)

1. Complete Phase 1 (Setup)
2. Complete Phase 2 (Foundational — this is the bulk of the work; plan for it to take as long as the rest combined)
3. Complete Phase 3 (US1 — see remote tmux sessions)
4. Complete Phase 4 (US2 — click to attach, with disconnect overlay)
5. Complete Phase 5 (US3 — plain remote shell)
6. Complete Phase 6 (US4 — add/manage hosts UI)
7. **STOP and VALIDATE**: Tagged debug build, real remote host, run through the manual test scenarios in T075.
8. Ship the MVP.

### Incremental Delivery

1. Foundational + US1 → can see remote tmux in sidebar (programmatically added hosts) — alpha
2. + US2 → can attach (still no host-add UI, but MVP of the tmux experience)
3. + US4 → can add hosts via UI — beta
4. + US3 → can open plain remote shells — v1 feature-complete
5. + US5 → can manage remote tmux sessions — parity with local
6. + US6 → hosts persist across restarts
7. + US7 → `cmux ssh` integration
8. + Phase 10 CLI commands
9. + Phase 11 polish
10. GA

### Parallel Team Strategy (2–3 developers)

After Foundational completes:

- **Developer A**: US1 → US2 → US3 (sidebar / terminal integration track)
- **Developer B**: US4 → US6 (host management / persistence track)
- **Developer C**: Phase 10 CLI + V2 methods (can start as soon as RemoteHostManager interface is stable)

Coordinate on TmuxSidebarView.swift and TmuxSidebarState.swift to avoid merge conflicts.

---

## Notes

- This feature depends on **707-tmux-control-panel** being in place. The current branch is based on `707-tmux-control-panel` to satisfy the dependency until that feature is merged upstream.
- The Foundational phase contains a **behavior-preserving refactor** (T003–T010) that touches `TerminalSSHSessionDetector.swift`. Run the full cmux unit test suite (including any SSH-related tests) after each refactor task to catch regressions early.
- **Do not launch untagged debug builds** per CLAUDE.md. Always use `./scripts/reload.sh --tag remote-ssh` for manual testing.
- **Do not commit orphaned `ssh -M` processes** — T069 (quit hook teardown) must be tested before merge.
- The `dlog` function used in debug logging requires `import Bonsplit` and must be wrapped in `#if DEBUG` / `#endif`.
- All user-facing strings MUST be localized per CLAUDE.md policy. Include both EN and JA translations for every new string.
- The refactor in Phase 2 is the riskiest part of this work — it changes code that's currently exercised by file-upload features. Prioritize strong test coverage before making the changes.
- Phase 10 CLI command integer handling should use the 1-based convention established by feature 707's fix to `normalizeWorkspaceHandle`. Add a `normalizeHostHandle` helper that follows the same pattern.
