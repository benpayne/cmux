# Feature Specification: tmux Control Panel Integration

**Feature Branch**: `707-tmux-control-panel`  
**Created**: 2026-04-05  
**Status**: Draft  
**Input**: User description: "Implement native tmux control panel integration - allow users to view, create, and attach to tmux sessions from the cmux sidebar. Based on GitHub issue #560."

## Clarifications

### Session 2026-04-05

- Q: When attaching to a session already attached in another terminal, should cmux share the session silently, prompt, or force-detach the other client? → A: Always attach with shared session (standard `tmux attach` behavior), no confirmation dialog.
- Q: When the user detaches from a tmux session, should the pane stay open (returning to a shell) or close entirely? → A: Close the pane entirely; the session remains visible in the sidebar for reattachment.
- Q: Should the sidebar show a flat list of sessions or an expandable tree with windows inside each session? → A: Flat session list only for v1; window-level expansion is deferred to a future iteration.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View Existing tmux Sessions (Priority: P1)

A user opens cmux and wants to see what tmux sessions are already running on their machine. The sidebar displays a "tmux Sessions" section listing all active tmux sessions with their names, number of windows, and attached/detached status. The user can see at a glance which sessions exist and their state without opening a separate terminal to run `tmux ls`.

**Why this priority**: Visibility is the foundation — users need to know what sessions exist before they can interact with them. This is the minimum viable feature that provides value on its own.

**Independent Test**: Can be fully tested by launching cmux with one or more tmux sessions running in the background and verifying they appear in the sidebar with correct metadata.

**Acceptance Scenarios**:

1. **Given** the user has three tmux sessions running (one attached, two detached), **When** they open cmux, **Then** the sidebar shows all three sessions with their names, window counts, and attached/detached status.
2. **Given** the user has no tmux sessions running, **When** they open cmux, **Then** the tmux section shows an empty state with a prompt to create a new session.
3. **Given** a tmux session is created or destroyed externally (e.g., from another terminal), **When** the sidebar is visible, **Then** the session list updates automatically within a few seconds.

---

### User Story 2 - Attach to an Existing tmux Session (Priority: P1)

A user sees a detached tmux session in the sidebar and wants to attach to it. They click on the session entry, and cmux opens the tmux session in a new pane or tab, providing full interactive terminal access to that session. The user can work inside the tmux session as if they had run `tmux attach -t <session>` manually.

**Why this priority**: Attaching to existing sessions is the core use case for tmux users who want to resume work. Combined with P1 viewing, this delivers the primary value proposition.

**Independent Test**: Can be tested by creating a tmux session externally, clicking it in the sidebar, and verifying the session content appears in a cmux pane with full interactivity.

**Acceptance Scenarios**:

1. **Given** a detached tmux session named "dev" exists, **When** the user clicks on it in the sidebar, **Then** cmux opens the session in a new pane showing the session's current content with full keyboard/mouse interactivity.
2. **Given** a tmux session is already attached in another terminal, **When** the user attaches to it from cmux, **Then** the session is shared silently — both terminals show the same content, matching standard `tmux attach` behavior.
3. **Given** the user is attached to a tmux session in cmux, **When** they detach (via tmux prefix+d or sidebar action), **Then** the pane closes entirely and the session returns to detached status in the sidebar.

---

### User Story 3 - Create a New tmux Session (Priority: P2)

A user wants to start a new tmux session from within cmux. They use a "New tmux Session" action (button or context menu) to create a named session. The new session appears in the sidebar and is immediately attached in a cmux pane.

**Why this priority**: Creating sessions completes the basic session lifecycle but is secondary to viewing and attaching, since users often have existing sessions they want to manage first.

**Independent Test**: Can be tested by clicking the create action, entering a session name, and verifying the session appears in both the sidebar and `tmux ls` output.

**Acceptance Scenarios**:

1. **Given** the user clicks "New tmux Session," **When** they provide a session name, **Then** a new tmux session is created and immediately attached in a cmux pane.
2. **Given** the user tries to create a session with a name that already exists, **When** they confirm the name, **Then** the system shows an error and prompts for a different name.
3. **Given** the user creates a session without specifying a name, **When** the session is created, **Then** tmux assigns a default name following its standard naming convention.

---

### User Story 4 - Manage tmux Sessions from Sidebar (Priority: P3)

A user wants to perform common tmux session management tasks directly from the sidebar: rename a session, kill/destroy a session, or detach from a session. Right-clicking a session in the sidebar presents these options in a context menu.

**Why this priority**: Management actions are convenience features that round out the experience but are not essential for initial value delivery.

**Independent Test**: Can be tested by right-clicking a session, selecting "Kill Session," and verifying the session no longer appears in `tmux ls`.

**Acceptance Scenarios**:

1. **Given** a tmux session exists, **When** the user right-clicks it and selects "Rename," **Then** they can edit the session name inline and the change is reflected in tmux.
2. **Given** a tmux session exists, **When** the user right-clicks it and selects "Kill Session," **Then** the system asks for confirmation, and upon confirming, the session is destroyed.
3. **Given** the user is attached to a tmux session, **When** they right-click and select "Detach," **Then** the pane closes and the session returns to detached status.

---

### User Story 5 - Drag tmux Session to Native Pane (Priority: P3)

A user wants to integrate a tmux session into their cmux workspace layout. They drag a tmux session from the sidebar into a split pane area, and the session attaches in that specific pane location — similar to how native cmux tabs can be arranged.

**Why this priority**: This is an advanced workflow integration feature that enhances power users' experience but is not required for core tmux functionality.

**Independent Test**: Can be tested by dragging a session from the sidebar to a split target and verifying the session renders in the correct pane position.

**Acceptance Scenarios**:

1. **Given** a tmux session is listed in the sidebar, **When** the user drags it to a split pane drop zone, **Then** the session attaches in that specific pane position.
2. **Given** the user drags a tmux session to an existing pane, **When** they drop it, **Then** the pane content is replaced with the tmux session (or a new split is created, depending on drop target).

---

### Edge Cases

- What happens when tmux is not installed on the system? The tmux section should be hidden or show a message indicating tmux is not available.
- What happens when the tmux server crashes or is killed while sessions are displayed? The sidebar should detect the loss and update the session list to empty, with an appropriate message.
- What happens when a session is killed externally while the user is attached in cmux? The pane should detect the disconnection and show a notification, then close or return to shell.
- What happens over SSH where tmux is on the remote host? The initial implementation focuses on local tmux sessions only; remote tmux is a separate concern.
- What happens with nested tmux sessions (tmux inside tmux)? The sidebar should show top-level sessions from the local tmux server only.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST detect whether tmux is installed and available on the local system.
- **FR-002**: System MUST enumerate all active tmux sessions with their metadata (name, number of windows, creation time, attached/detached status).
- **FR-003**: System MUST display tmux sessions in a dedicated sidebar section as a flat list (session-level only; no window-level expansion in v1) with real-time status.
- **FR-004**: System MUST allow users to attach to a tmux session by opening it in a cmux pane, using shared attachment (standard `tmux attach` behavior) when the session is already attached elsewhere.
- **FR-004a**: System MUST close the cmux pane entirely when the user detaches from a tmux session; the session remains in the sidebar for reattachment.
- **FR-005**: System MUST allow users to create new named tmux sessions from the sidebar.
- **FR-006**: System MUST allow users to kill/destroy tmux sessions from the sidebar with confirmation.
- **FR-007**: System MUST allow users to rename tmux sessions from the sidebar.
- **FR-008**: System MUST automatically refresh the session list when sessions are created, destroyed, or change state externally.
- **FR-009**: System MUST handle the case where tmux is not installed by hiding the tmux sidebar section or showing a descriptive empty state.
- **FR-010**: System MUST provide full interactive terminal access when attached to a tmux session (keyboard input, mouse events, resize handling).

### Key Entities

- **tmux Session**: Represents a running tmux session. Key attributes: name, ID, number of windows, creation timestamp, attached/detached status, client count.
- **tmux Sidebar Section**: A UI region in the cmux sidebar that lists tmux sessions and provides actions. Related to the existing sidebar panel system.
- **Attached Pane**: A cmux terminal pane that is connected to a tmux session. Represents the link between a cmux pane and a tmux session.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can see all running tmux sessions in the sidebar within 2 seconds of opening cmux.
- **SC-002**: Users can attach to an existing tmux session with a single click and begin interacting within 1 second.
- **SC-003**: Users can create a new tmux session and begin working in it within 3 seconds.
- **SC-004**: Session list reflects external changes (sessions created/destroyed outside cmux) within 5 seconds.
- **SC-005**: All standard terminal interactions (typing, scrolling, mouse selection, resize) work correctly while attached to a tmux session.
- **SC-006**: Users who currently switch between cmux and a separate terminal for tmux management can perform all common tmux session operations without leaving cmux.

## Assumptions

- tmux is expected to be installed separately by the user; cmux will not bundle or install tmux.
- The initial implementation focuses on local tmux sessions only. Remote tmux sessions over SSH are out of scope for this feature.
- The tmux control mode (`tmux -CC`) internals already present in the Ghostty codebase may or may not be leveraged; the implementation approach is left to the planning phase.
- cmux's existing sidebar infrastructure and pane system will be extended rather than replaced.
- tmux sessions are managed via the local tmux server using the default socket path; custom socket paths are out of scope for v1.
- The feature targets the macOS platform only, consistent with cmux's current platform support.
