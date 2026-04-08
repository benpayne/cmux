# Feature Specification: Remote Workspace Mode (SSH ControlMaster + Remote tmux)

**Feature Branch**: `708-remote-workspace-ssh`  
**Created**: 2026-04-07  
**Status**: Draft  
**Input**: GitHub issue manaflow-ai/cmux#2673 — "Remote workspace mode: SSH ControlMaster + first-class remote tmux/shell support"

## Clarifications

### Session 2026-04-07

- Q: Should hosts be auto-discovered from `~/.ssh/config`, added manually, or both? → A: Auto-import is available but hidden by default. The remote section starts empty. The user can use "+ Add remote host…" to either type a destination directly or pick from an "Add from SSH config" list populated from `~/.ssh/config` Host entries. No automatic clutter for users with large SSH configs.
- Q: When the user quits cmux, what happens to open SSH master connections? → A: Tear down immediately on cmux quit. No lingering SSH processes, no zombie sockets. Reopening cmux always re-authenticates (cost is small with ssh-agent).
- Q: When a remote SSH connection drops and open cmux panes were running over it (tmux-attached or plain shell), what happens to those panes? → A: The pane stays open showing the last buffer, with a "Disconnected — Reconnect" overlay. Clicking reconnect re-establishes the master; for tmux-attached panes, the reconnect also re-runs `tmux attach -t <name>`, restoring context (since the tmux server on the remote is still running). Plain shells get the same overlay but reconnect opens a fresh shell.
- Q: When the user adds a new host (typed destination or picked from SSH config), should cmux connect immediately or require an explicit connect action? → A: Connect immediately. Adding is a clear intent signal; auth or reachability failures should surface right away. On failure, the host stays in the list marked "failed" with the error message visible so the user can inspect and retry.
- Q: Which `~/.ssh/config` Host entries should appear in the "Add from SSH config" picker? → A: Only entries that are non-wildcard AND have at least one of `Hostname`, `User`, or `Port` configured. Filters out global defaults and skeleton entries, leaving real hosts the user has deliberately configured.
- Q: SC-004 said "within 10 seconds" for disconnect detection, but the research document proposed a 30-second probe cadence. Which wins? → A: 10 seconds when the host's sidebar section is visible (fast detection during active use, achieved via the 5-second tmux poll catching command failures); 30 seconds when the section is hidden (via the periodic `ssh -O check` probe). Both targets updated in the spec accordingly.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connect to a remote host and see its tmux sessions in the sidebar (Priority: P1)

A user has a development server called `prod-1`. They add it to cmux as a remote host. cmux establishes a single authenticated connection to the host. The sidebar now shows a new section "REMOTE: prod-1" listing the tmux sessions running on that server, with the same metadata (attached/detached status, window count) as the existing local tmux section. The user sees their remote work at a glance without typing `ssh prod-1 tmux ls` manually.

**Why this priority**: This is the foundational value of the feature. A user has remote servers where they run tmux. Showing that state in the sidebar is the single most impactful thing we can add — and it is the one thing that cannot be done with a plain terminal pane running `ssh`.

**Independent Test**: Start with a fresh cmux instance. Add `prod-1` as a remote host (via UI or `cmux ssh` CLI). Verify within a few seconds the sidebar shows a "REMOTE: prod-1" section listing any tmux sessions running on that host. Create a tmux session on the remote (from any other terminal) and verify it appears in the cmux sidebar within the poll interval.

**Acceptance Scenarios**:

1. **Given** `prod-1` is reachable over SSH with key-based auth and has two tmux sessions running, **When** the user adds `prod-1` as a remote host, **Then** cmux establishes a connection, auth happens once, and within a few seconds the sidebar shows "REMOTE: prod-1 ● connected" with both sessions listed.
2. **Given** a remote host is connected and shows two tmux sessions, **When** the user creates a new session on the remote from an external terminal, **Then** the new session appears in the sidebar within the poll interval without re-authenticating.
3. **Given** a remote host is connected, **When** the network connection drops, **Then** the sidebar updates to "REMOTE: prod-1 ○ disconnected" and stops attempting to run commands on that host until the user reconnects. Any open cmux panes on that host stay open with a "Disconnected — Reconnect" overlay preserving their last buffer.
4. **Given** a remote pane is showing the disconnected overlay after a network drop, **When** the user clicks "Reconnect", **Then** cmux re-establishes the master, the overlay disappears, and tmux-attached panes re-run `tmux attach -t <name>` to restore the session view.

---

### User Story 2 - Attach to a remote tmux session with a single click (Priority: P1)

A user sees `api-server` listed under REMOTE: prod-1 in the sidebar. They click it. cmux opens a new terminal pane attached to the remote tmux session — without opening a new SSH connection (it reuses the existing master), without re-authenticating, and with the same full-interactivity experience as attaching to a local tmux session.

**Why this priority**: Viewing remote tmux sessions is only half the value. Being able to attach to them with the same click-to-attach UX as local sessions is what closes the loop. Together with P1 US1, this is the "remote tmux just works" experience.

**Independent Test**: With a connected remote host showing at least one tmux session, click the session row. Verify a new pane opens and the tmux session content is visible and interactive (typing, scrolling, resizing all work).

**Acceptance Scenarios**:

1. **Given** a detached session `work` exists on prod-1, **When** the user clicks it in the sidebar, **Then** a new pane opens with the session attached, full keyboard/mouse interactivity, and no additional authentication prompts.
2. **Given** the user is attached to a remote session in a cmux pane, **When** they detach (tmux prefix+d or closing the pane), **Then** the pane closes and the session returns to "detached" in the sidebar. The remote master connection stays open for reuse.
3. **Given** the user attaches to a remote session that is already attached from another client, **When** they open it from cmux, **Then** the session is shared silently (standard tmux attach semantics), matching the local-session behavior.

---

### User Story 3 - Open a plain shell on a remote host without re-auth (Priority: P1)

A user has connected to prod-1 but doesn't want tmux for a quick task. They click "+ New terminal on prod-1" (or trigger it from the host's context menu). A new pane opens with a plain interactive shell on the remote, reusing the existing master connection — no password prompt, no key unlock, subsecond startup.

**Why this priority**: Not every remote task happens inside tmux. Users need a cheap way to run one-off commands on a connected host without paying auth cost or opening a new terminal themselves. This is VSCode Remote's single most used feature.

**Independent Test**: With a connected remote host, trigger "new terminal on host". Verify a new pane opens within 1 second, the shell is responsive, the prompt reflects the remote user/host, and no auth was required.

**Acceptance Scenarios**:

1. **Given** prod-1 is connected, **When** the user triggers "new terminal on prod-1", **Then** a new pane opens running an interactive shell on prod-1 via the existing master connection, within 1 second, with no auth prompts.
2. **Given** the user opens three terminals on prod-1, **When** all three are active, **Then** they all share a single underlying SSH master connection (one TCP connection, one authentication event).
3. **Given** the user closes a remote terminal pane, **When** other remote terminals on the same host are still open, **Then** the master connection remains active and those terminals continue to work.

---

### User Story 4 - Add, manage, and remove remote hosts from the UI (Priority: P1)

A user adds `prod-1`, `staging`, and `dev-box` as remote hosts — either by typing the SSH destination directly or by picking entries from their `~/.ssh/config`. They see all three in the sidebar, each with a connection status indicator. They can disconnect a host (tears down the master), reconnect a disconnected host, or remove a host entirely. Each host's list of tmux sessions and open terminals is scoped to that host.

**Why this priority**: Managing a small set of remote hosts needs to be fast and obvious. Without this, the feature only works for a single hardcoded host, which is much less useful.

**Independent Test**: Add three hosts to cmux. Verify all three show in the sidebar with distinct sections. Disconnect one — verify its section dims and stops polling. Reconnect — verify it reauthenticates and resumes polling. Remove a host — verify its section disappears and any open terminals for that host are closed.

**Acceptance Scenarios**:

1. **Given** the user has no remote hosts configured, **When** they click "Add remote host…" and enter `deploy@prod-1.example.com`, **Then** cmux immediately attempts to connect and, on success, adds a "REMOTE: prod-1" section to the sidebar. On failure, the host is still added but marked "failed" with the error visible so the user can retry.
2. **Given** the user has entries in `~/.ssh/config`, **When** they click "Add remote host… → From SSH config", **Then** cmux shows a picker listing only entries that have `Hostname`, `User`, or `Port` explicitly configured (wildcards and skeleton entries are excluded), and the user can add one with a click.
3. **Given** the user has three remote hosts, **When** they right-click one and select "Disconnect", **Then** the master connection is torn down, the section shows "disconnected", and no further commands run against that host until reconnect.
4. **Given** the user removes a remote host with two active remote terminal panes, **When** they confirm the removal, **Then** the master connection is torn down, the panes are closed, and the section disappears from the sidebar.
5. **Given** the user has connected hosts, **When** they quit cmux, **Then** all SSH master processes and control sockets created by cmux are torn down before cmux exits.

---

### User Story 5 - Remote tmux session management (create/rename/kill) (Priority: P2)

A user right-clicks a tmux session in the remote section and picks "Kill Session" (or "Rename"). The operation runs on the remote host using the existing master connection. The session list updates within the poll interval. This is the remote equivalent of the existing local tmux management from feature 707-tmux-control-panel.

**Why this priority**: Viewing and attaching are P1. Full CRUD completes the local-parity story but is a natural follow-on, not a blocker for the initial value.

**Independent Test**: With a connected remote host, right-click a remote tmux session, choose "Kill Session", confirm. Verify the session disappears from the sidebar within the poll interval, and the remote `tmux ls` confirms it is gone.

**Acceptance Scenarios**:

1. **Given** a remote tmux session, **When** the user kills it from the sidebar context menu, **Then** the remote session is destroyed and removed from the sidebar.
2. **Given** a remote tmux session, **When** the user renames it inline, **Then** the session appears under the new name after the next poll, and attempting to rename to an already-used name shows an error without corrupting state.
3. **Given** a connected host with no tmux sessions, **When** the user clicks "+ New session" in the remote section, **Then** a new tmux session is created on the remote and the user is attached to it in a new pane.

---

### User Story 6 - Remote hosts persist across cmux restarts (Priority: P2)

A user adds `prod-1` and `staging`. They quit cmux and reopen it later. Both hosts are still listed in the sidebar, showing "disconnected" initially. Clicking a host reconnects using the previously stored configuration (no need to re-enter the hostname). The master connection is established, auth happens, and the session list reappears.

**Why this priority**: Without persistence, the feature requires re-adding hosts every launch, which is tedious. But the P1 stories can ship without it for a single-session use case.

**Independent Test**: Add two hosts. Verify they show in the sidebar. Quit cmux fully. Reopen. Verify both hosts are still listed (initially disconnected). Click one. Verify it reconnects and shows sessions.

**Acceptance Scenarios**:

1. **Given** the user has added two remote hosts, **When** they quit cmux and reopen it, **Then** both hosts are still listed in the sidebar.
2. **Given** a host was connected when cmux quit, **When** cmux reopens, **Then** the host is shown as "disconnected" (not auto-reconnected) with a one-click option to reconnect.
3. **Given** the user removes a host, **When** they quit and reopen cmux, **Then** the host stays removed.

---

### User Story 7 - The `cmux ssh` CLI command participates in the remote host manager (Priority: P2)

Running `cmux ssh deploy@prod-1` from a shell still works as before, but now it participates in the remote host manager. If `prod-1` is already a known host, the existing master is reused. If not, a new host entry is created on the fly. Subsequent `cmux ssh` invocations to the same host reuse the master.

**Why this priority**: This unifies the existing CLI experience with the new managed-host model so users don't have to choose between them. But existing `cmux ssh` behavior already works, so this is refinement, not MVP.

**Independent Test**: Run `cmux ssh deploy@prod-1` from a shell. Verify cmux opens a pane on the remote. Check that the host now appears in the sidebar as a managed remote host. Run `cmux ssh deploy@prod-1` again from another shell. Verify the second invocation reuses the existing master (no second auth event).

**Acceptance Scenarios**:

1. **Given** no managed host for `prod-1`, **When** the user runs `cmux ssh deploy@prod-1`, **Then** cmux creates a managed host, opens a master connection, and opens a pane on the remote — and the host appears in the sidebar.
2. **Given** `prod-1` is already a managed host, **When** the user runs `cmux ssh deploy@prod-1` again, **Then** the command reuses the existing master (no new auth), opens a new pane on the remote, and does not duplicate the host entry.
3. **Given** the user runs `cmux ssh` against a host that fails auth, **When** the failure happens, **Then** a clear error is shown, no "broken" host entry is persisted, and the user can retry.

---

### User Story 8 - Detect listening ports on the connected remote (Priority: P3)

Similar to cmux's existing local port scanner, the remote section shows ports currently listening on the remote host, with one-click forwarding to a local port. The user starts a dev server on the remote (e.g., a web app on port 3000). It appears under the remote host's section. The user clicks it. cmux sets up an SSH port forward and opens the local URL in a browser tab.

**Why this priority**: This is a high-value convenience for remote web development, but it is not required for the core tmux/shell remote experience. Explicitly deferred from MVP scope.

**Independent Test**: With a connected remote host, start a server listening on a port on the remote. Verify it appears under the host's port list in the sidebar within a reasonable interval. Click it. Verify a local port forward is established and the URL opens.

**Acceptance Scenarios**:

1. **Given** a connected remote host, **When** a new process starts listening on a port on the remote, **Then** the port appears in the host's port list in the sidebar.
2. **Given** a forwarded port, **When** the user clicks the "open" button, **Then** the local URL `http://localhost:<forwarded-port>` opens in the user's browser.
3. **Given** a forwarded port, **When** the remote process exits, **Then** the port is removed from the list and the forward is torn down.

---

### Edge Cases

- **Master connection dies mid-session**: a network drop, sleep/wake, or remote sshd restart kills the master. The system must detect this (via periodic health check or command failure), mark the host as disconnected, notify the user, and offer a one-click reconnect. Any open cmux panes running over the dropped connection MUST stay open displaying their last buffer with a "Disconnected — Reconnect" overlay. Clicking reconnect re-establishes the master; for tmux-attached panes the reconnect also re-runs `tmux attach -t <name>` so the user returns to their session (tmux on the remote keeps running across SSH drops). Plain shell panes open a fresh shell on reconnect.
- **Host unreachable on add**: user adds a host that does not exist or is firewalled. The system must fail fast with a clear error rather than hanging indefinitely.
- **Authentication failure**: the SSH master fails to authenticate (expired key, wrong password, revoked key). The system must surface a clear error and not leave a half-open state.
- **Host key mismatch**: the remote host's SSH key has changed. The system must delegate to OpenSSH's host key verification and surface the warning without silently accepting the new key.
- **Multiple cmux windows/instances**: two cmux processes attempt to manage the same host simultaneously. Each must have its own control socket to avoid lifecycle confusion.
- **tmux not installed on remote**: host is reachable but lacks tmux. The remote section should show a "tmux not available" note, and shell-opening (US3) must still work.
- **Jump hosts / ProxyJump**: many users have hosts that are reachable only through a bastion. The system must respect the user's existing SSH config (`~/.ssh/config`) for ProxyJump, IdentityFile, Port, etc.
- **Agent forwarding**: for users who rely on SSH agent forwarding to reach further hosts, the feature should preserve the existing agent-forwarding behavior when desired.
- **Polling cost**: querying remote tmux over SSH every few seconds against many hosts is heavier than local polling. The system must cap the total rate and only poll hosts whose sidebar section is visible.
- **Password-only hosts**: hosts that require a password (not a key) need a prompt mechanism that works from a GUI app — not a terminal stdin prompt.
- **Control socket cleanup**: if cmux crashes, orphaned control sockets may be left behind. On next launch, they must be detected and reused or cleaned up, not left blocking new connections.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST allow users to define a remote host by specifying an SSH destination (`user@host[:port]` or an `~/.ssh/config` alias).
- **FR-002**: The system MUST establish a single authenticated SSH connection per remote host that is reused for all subsequent operations against that host during the session.
- **FR-003**: The system MUST NOT prompt for authentication more than once per managed host per cmux session (assuming credentials do not change).
- **FR-004**: The system MUST respect the user's existing OpenSSH configuration (`~/.ssh/config`) including host aliases, jump hosts, identity files, and port overrides.
- **FR-005**: The system MUST display a section in the sidebar for each connected remote host, showing its connection status and (if tmux is available on the remote) the list of tmux sessions on that host.
- **FR-006**: The system MUST allow users to attach to a remote tmux session with a single click, opening a new terminal pane that runs inside the remote session.
- **FR-007**: The system MUST allow users to open a plain interactive shell on a connected remote host in a new terminal pane, without re-authenticating.
- **FR-008**: The system MUST allow users to add, remove, disconnect, and reconnect remote hosts from the UI.
- **FR-009**: The system MUST detect when a remote connection fails or is dropped and mark the host as disconnected, stopping polling and command execution against it until the user reconnects.
- **FR-010**: The system MUST surface clear, actionable error messages when authentication fails, the host is unreachable, or commands exit with an error, without leaving the host in a broken state.
- **FR-011**: The system MUST allow users to create, rename, and kill tmux sessions on a remote host through the same UI affordances as local sessions.
- **FR-012**: The system MUST persist the user's list of remote hosts (host identifiers and configuration, but not credentials) across cmux restarts.
- **FR-013**: The system MUST NOT auto-reconnect hosts on startup; a user action MUST be required to establish the master connection after launch.
- **FR-014**: The system MUST handle a remote host that does not have tmux installed by hiding the remote tmux sub-section and still allowing plain shell operations.
- **FR-015**: The system MUST NOT deploy any binary, script, or daemon to the remote host; all operations must use standard SSH and tools the user has already installed on the host.
- **FR-016**: The `cmux ssh` CLI command MUST participate in the remote host manager, reusing an existing master connection for a host if one is already open.
- **FR-017**: The system MUST clean up any SSH control sockets it creates when the user removes a host, disconnects a host, or quits cmux normally.
- **FR-018**: When multiple cmux instances are running simultaneously, each MUST use its own control sockets, isolated from other instances.
- **FR-019**: The system MUST allow users to add remote hosts in two ways: (a) by typing an SSH destination directly, and (b) by selecting from a list of Host entries discovered in the user's `~/.ssh/config`. The remote section MUST start empty on first run; auto-discovered hosts are not shown until the user adds them, to avoid clutter for users with large SSH configs.
- **FR-020**: The system MUST tear down a host's master connection immediately when cmux quits. No SSH master processes or control sockets created by cmux may persist beyond cmux's lifetime under normal shutdown.
- **FR-021**: When a remote master connection drops while cmux panes are running over it, the system MUST keep the affected panes open with a "Disconnected — Reconnect" overlay. The panes MUST NOT close automatically. Clicking reconnect MUST re-establish the master and, for tmux-attached panes, re-run `tmux attach -t <name>` to restore context.
- **FR-022**: When a new host is added (via typed destination or SSH config picker), the system MUST immediately attempt to establish the master connection. If the attempt fails, the host remains in the registry in a "failed" state with the error message visible to the user.
- **FR-023**: When importing hosts from `~/.ssh/config`, the system MUST show only entries that are non-wildcard patterns AND have at least one of `Hostname`, `User`, or `Port` explicitly configured. Global defaults (`Host *`), wildcard patterns, and skeleton entries MUST be excluded from the picker.

### Key Entities

- **RemoteHost**: A user-facing identity for a remote machine. Has a display alias, an SSH destination string, a reference to the user's SSH configuration (if any), and a current connection state (disconnected, connecting, connected, failed).
- **RemoteConnection**: The live, authenticated SSH master connection to a host. Owns the control socket, tracks health, and mediates all command execution against the host.
- **RemoteTmuxSession**: Same data model as a local tmux session (name, window count, attached state), scoped to a specific RemoteHost.
- **RemoteTerminalPane**: A cmux terminal pane running a shell or tmux session on a remote host via a shared RemoteConnection.
- **HostRegistry**: The persistent list of remote hosts the user has added. Survives cmux restarts, stores host definitions but not credentials.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can add a remote host and begin seeing its tmux sessions in the sidebar in under 10 seconds (including authentication time), assuming standard key-based auth and a responsive host.
- **SC-002**: After the initial connection to a host, opening additional remote terminals or attaching to remote tmux sessions on the same host happens in under 1 second with no authentication prompts.
- **SC-003**: A user with five remote hosts configured can see all their tmux sessions across all hosts in the sidebar without switching context or manually running commands.
- **SC-004**: When a remote host's connection drops and its sidebar section is currently visible, the user sees the change reflected within 10 seconds. When the section is hidden/collapsed, the user sees it within 30 seconds after next making it visible. In both cases, the user can reconnect with a single click.
- **SC-005**: The feature works against any host reachable via `ssh <hostname>` from a plain terminal, without requiring the user to install anything new on the remote.
- **SC-006**: A user who previously did `cmux ssh deploy@prod` followed by manually running `tmux attach` can complete the same workflow with one sidebar click after adding the host.
- **SC-007**: No command run by the feature introduces latency greater than what the user would experience by running the same command via `ssh -S <sock> host <command>` directly.
- **SC-008**: Users whose workflow depends on jump hosts, non-standard ports, or non-default identity files see the feature "just work" because their existing `~/.ssh/config` is respected.

## Assumptions

- OpenSSH is available on both the local machine (macOS has it built in) and each remote host. No alternative SSH implementation is supported in v1.
- tmux is assumed to be installed on any remote host where the user expects remote tmux features. Plain shell operations work regardless of whether tmux is present.
- Users primarily authenticate with SSH keys (ed25519, rsa) and an SSH agent. Password-only authentication is a lower-priority path that MUST work but MAY require delegating to the system's SSH password prompt mechanism (e.g., `ssh-askpass` or stock OpenSSH interactive auth behaviors).
- Authentication credentials (passwords, key passphrases) are NOT stored by cmux. Any persistent auth is the user's responsibility via SSH agent or their OpenSSH configuration.
- The feature is additive to the existing `cmux ssh` CLI command, which continues to work for hosts not yet added as managed hosts.
- Polling remote tmux state is done lazily: a remote section only polls when its parent sidebar section is visible. Hidden hosts are not polled.
- The feature targets macOS (the only cmux-supported platform). Remote hosts can run any Unix-like OS that OpenSSH and tmux support (Linux, BSD, macOS).
- The feature is a follow-on to the local tmux control panel (feature 707-tmux-control-panel, issue #560). It generalizes the `TmuxService` abstraction introduced there to support SSH-prefixed command execution. The local feature MUST ship before or alongside this one.
- SSH host key verification is delegated entirely to OpenSSH (`StrictHostKeyChecking` behavior as configured by the user). cmux does not maintain its own host key database.
