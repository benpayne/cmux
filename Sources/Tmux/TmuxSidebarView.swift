// TmuxSidebarView.swift
// SwiftUI sidebar section listing local tmux sessions.
//
// Part of feature 707-tmux-control-panel.
//
// Design goals:
//   - Self-contained: all tmux UI lives in this file. ContentView only invokes
//     `TmuxSidebarSection()` once and passes a workspace-context-bound action
//     closure for "attach this session". This keeps ContentView's blast radius
//     to a single line.
//   - Hides itself entirely when tmux is not installed.
//   - Renders a flat list of sessions per the v1 spec (no window-level
//     expansion).
//   - Supports inline create, kill (with confirmation), rename, and detach.

import SwiftUI

// MARK: - Public entry point

/// Top-level entry point used from `ContentView` to render the tmux sidebar
/// section. Hidden entirely when tmux is unavailable.
///
/// Usage:
/// ```swift
/// TmuxSidebarSection(onAttach: { sessionName in
///     workspace.attachTmuxSession(named: sessionName)
/// })
/// ```
struct TmuxSidebarSection: View {
    @ObservedObject private var state: TmuxSidebarState = .shared
    @ObservedObject private var remoteManager: RemoteHostManager = .shared

    /// Called when the user clicks a local session row to attach to it.
    /// The host is responsible for opening a terminal pane that runs the
    /// command returned by `TmuxService.attachCommand(for:)`.
    let onAttach: (String) -> Void

    /// Called when the user clicks a remote session row. The host
    /// (ContentView) wires this to `tabManager.attachRemoteTmuxSession`.
    /// Part of feature 708-remote-workspace-ssh (Phase 4, US2).
    let onRemoteAttach: (_ hostId: UUID, _ sessionName: String) -> Void

    /// Called when the user clicks "+ New terminal" in a remote host
    /// section header. Opens a plain shell pane on the host.
    /// Feature 708-remote-workspace-ssh (Phase 5, US3).
    let onOpenRemoteShell: (_ hostId: UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Local tmux section — hidden entirely when tmux is not installed.
            if state.isAvailable {
                TmuxSidebarSectionContent(state: state, onAttach: onAttach)
            }

            // Remote tmux sections — one per managed remote host.
            // Feature 708-remote-workspace-ssh (Phases 3–6).
            ForEach(remoteManager.hostsInDisplayOrder) { host in
                if let group = remoteManager.remoteGroups[host.id] {
                    // Connected host — show the live group with sessions.
                    RemoteTmuxSidebarSectionContent(
                        group: group,
                        connectionState: remoteManager.connections[host.id]?.state ?? .disconnected,
                        onAttach: { sessionName in
                            onRemoteAttach(host.id, sessionName)
                        },
                        onNewShell: {
                            onOpenRemoteShell(host.id)
                        },
                        onDisconnect: {
                            remoteManager.disconnect(id: host.id)
                        },
                        onRemove: {
                            remoteManager.removeHost(id: host.id)
                        }
                    )
                } else {
                    // Disconnected / failed host — show a thin placeholder row.
                    DisconnectedRemoteHostRow(
                        host: host,
                        state: remoteManager.connections[host.id]?.state ?? .disconnected,
                        onReconnect: {
                            remoteManager.connect(id: host.id)
                        },
                        onRemove: {
                            remoteManager.removeHost(id: host.id)
                        }
                    )
                }
            }

            // Always-visible "+ Add remote host" button so the feature
            // is discoverable even with zero hosts configured.
            AddRemoteHostButton()
        }
    }
}

// MARK: - Section content

private struct TmuxSidebarSectionContent: View {
    @ObservedObject var state: TmuxSidebarState
    let onAttach: (String) -> Void

    @State private var isExpanded: Bool = true
    @State private var isCreatingSession: Bool = false
    @State private var newSessionName: String = ""
    @State private var createErrorMessage: String?
    @State private var renamingSessionName: String?
    @State private var killConfirmationName: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if isCreatingSession {
                    TmuxCreateSessionRow(
                        name: $newSessionName,
                        errorMessage: createErrorMessage,
                        onSubmit: handleCreateSubmit,
                        onCancel: cancelCreate
                    )
                }

                if state.sessions.isEmpty && !isCreatingSession {
                    TmuxEmptyStateRow()
                } else {
                    ForEach(state.sessions) { session in
                        if renamingSessionName == session.name {
                            TmuxRenameSessionRow(
                                originalName: session.name,
                                onSubmit: { newName in
                                    handleRenameSubmit(oldName: session.name, newName: newName)
                                },
                                onCancel: { renamingSessionName = nil }
                            )
                        } else {
                            TmuxSessionRow(session: session) {
                                onAttach(session.name)
                            }
                            .contextMenu {
                                Button(String(localized: "tmux.menu.rename",
                                              defaultValue: "Rename…")) {
                                    renamingSessionName = session.name
                                }
                                Button(String(localized: "tmux.menu.kill",
                                              defaultValue: "Kill Session…"), role: .destructive) {
                                    killConfirmationName = session.name
                                }
                            }
                        }
                    }
                }
                if let error = state.lastError {
                    TmuxErrorRow(message: error)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(String(localized: "tmux.sidebar.sectionTitle",
                            defaultValue: "tmux Sessions"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if state.isLoading {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                }
                Button(action: beginCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "tmux.menu.newSession",
                             defaultValue: "New tmux Session"))
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .alert(
            String(localized: "tmux.kill.confirmTitle",
                   defaultValue: "Kill tmux session?"),
            isPresented: Binding(
                get: { killConfirmationName != nil },
                set: { if !$0 { killConfirmationName = nil } }
            ),
            presenting: killConfirmationName
        ) { name in
            Button(String(localized: "tmux.kill.confirm",
                          defaultValue: "Kill"), role: .destructive) {
                handleKill(name: name)
            }
            Button(String(localized: "common.cancel",
                          defaultValue: "Cancel"), role: .cancel) {}
        } message: { name in
            Text(String(
                format: String(localized: "tmux.kill.confirmMessage",
                               defaultValue: "Session \"%@\" and all of its windows will be destroyed."),
                name
            ))
        }
    }

    // MARK: - Create handling

    private func beginCreate() {
        newSessionName = ""
        createErrorMessage = nil
        isCreatingSession = true
        if !isExpanded { isExpanded = true }
    }

    private func cancelCreate() {
        isCreatingSession = false
        newSessionName = ""
        createErrorMessage = nil
    }

    private func handleCreateSubmit() {
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        createErrorMessage = nil
        state.createSession(name: trimmed.isEmpty ? nil : trimmed) { outcome in
            switch outcome {
            case .success(let info):
                isCreatingSession = false
                newSessionName = ""
                onAttach(info.name)
            case .duplicate:
                createErrorMessage = String(localized: "tmux.error.duplicateName",
                                            defaultValue: "A session with that name already exists.")
            case .failure(let message):
                createErrorMessage = message
            }
        }
    }

    // MARK: - Rename handling

    private func handleRenameSubmit(oldName: String, newName: String) {
        state.renameSession(oldName: oldName, newName: newName) { outcome in
            switch outcome {
            case .success:
                renamingSessionName = nil
            case .duplicate:
                state.objectWillChange.send()
                // Keep edit row open; show error in status row
            case .failure:
                renamingSessionName = nil
            }
        }
    }

    // MARK: - Kill handling

    private func handleKill(name: String) {
        killConfirmationName = nil
        state.killSession(name: name) { _ in }
    }
}

// MARK: - Session row

private struct TmuxSessionRow: View {
    let session: TmuxSessionInfo
    let onAttach: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onAttach) {
            HStack(spacing: 6) {
                Image(systemName: session.isAttached ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundColor(session.isAttached ? .green : .secondary)
                    .frame(width: 10)

                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(windowCountLabel(session.windowCount))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.secondary.opacity(0.12) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltipText)
    }

    private func windowCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "tmux.sidebar.windowCount.one",
                          defaultValue: "1 window")
        }
        return String(
            format: String(localized: "tmux.sidebar.windowCount.many",
                           defaultValue: "%d windows"),
            count
        )
    }

    private var tooltipText: String {
        if session.isAttached {
            return String(
                format: String(localized: "tmux.sidebar.tooltip.attached",
                               defaultValue: "%@ — attached (%d clients)"),
                session.name, session.clientCount
            )
        }
        return String(
            format: String(localized: "tmux.sidebar.tooltip.detached",
                           defaultValue: "%@ — detached"),
            session.name
        )
    }
}

// MARK: - Inline create row

private struct TmuxCreateSessionRow: View {
    @Binding var name: String
    let errorMessage: String?
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                TextField(
                    String(localized: "tmux.create.placeholder",
                           defaultValue: "Session name (optional)"),
                    text: $name
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit(onSubmit)
                .onAppear { isFocused = true }
                .onExitCommand(perform: onCancel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 3)
            }
        }
    }
}

// MARK: - Inline rename row

private struct TmuxRenameSessionRow: View {
    let originalName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var draftName: String
    @FocusState private var isFocused: Bool

    init(originalName: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.originalName = originalName
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._draftName = State(initialValue: originalName)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 10)
            TextField("", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit { onSubmit(draftName) }
                .onAppear { isFocused = true }
                .onExitCommand(perform: onCancel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

// MARK: - Empty / error states

private struct TmuxEmptyStateRow: View {
    var body: some View {
        Text(String(localized: "tmux.sidebar.empty",
                    defaultValue: "No tmux sessions"))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }
}

private struct TmuxErrorRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

// MARK: - Remote tmux section
// Feature 708-remote-workspace-ssh (Phase 3, US1). Renders one section
// per connected remote host. Structurally mirrors the local
// TmuxSidebarSectionContent above but binds to a RemoteTmuxSidebarGroup
// (which owns a TmuxService with a RemoteTmuxTransport).

private struct RemoteTmuxSidebarSectionContent: View {
    @ObservedObject var group: RemoteTmuxSidebarGroup
    let connectionState: ConnectionState
    let onAttach: (String) -> Void
    let onNewShell: () -> Void
    let onDisconnect: () -> Void
    let onRemove: () -> Void

    @State private var isExpanded: Bool = true
    @State private var showingRemoveConfirmation: Bool = false
    @State private var renamingSessionName: String?
    @State private var killConfirmationName: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if !group.remoteTmuxAvailable {
                    Text(String(localized: "tmux.remote.sidebar.tmuxUnavailable",
                                defaultValue: "tmux is not installed on this host"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                } else if group.sessions.isEmpty {
                    Text(String(localized: "tmux.remote.sidebar.empty",
                                defaultValue: "No sessions on this host"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                } else {
                    ForEach(group.sessions) { session in
                        if renamingSessionName == session.name {
                            TmuxRenameSessionRow(
                                originalName: session.name,
                                onSubmit: { newName in
                                    handleRenameSubmit(oldName: session.name, newName: newName)
                                },
                                onCancel: { renamingSessionName = nil }
                            )
                        } else {
                            RemoteTmuxSessionRow(session: session) {
                                onAttach(session.name)
                            }
                            .contextMenu {
                                Button(String(localized: "tmux.menu.rename",
                                              defaultValue: "Rename…")) {
                                    renamingSessionName = session.name
                                }
                                Button(String(localized: "tmux.menu.kill",
                                              defaultValue: "Kill Session…"),
                                       role: .destructive) {
                                    killConfirmationName = session.name
                                }
                            }
                        }
                    }
                }
                if let error = group.lastError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                RemoteConnectionStatusIndicator(state: connectionState)
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(String(
                    format: String(localized: "tmux.remote.sidebar.header",
                                   defaultValue: "REMOTE: %@"),
                    group.alias
                ))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer()
                if group.isLoading {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                }
                Button(action: onNewShell) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(
                    format: String(localized: "tmux.remote.sidebar.newTerminal",
                                   defaultValue: "New terminal on %@"),
                    group.alias
                ))
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(String(localized: "remote.menu.disconnect",
                              defaultValue: "Disconnect"), action: onDisconnect)
                Divider()
                Button(String(localized: "remote.menu.remove",
                              defaultValue: "Remove host…"), role: .destructive) {
                    showingRemoveConfirmation = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .alert(
            String(localized: "remote.confirm.removeTitle",
                   defaultValue: "Remove remote host?"),
            isPresented: $showingRemoveConfirmation
        ) {
            Button(String(localized: "remote.confirm.remove",
                          defaultValue: "Remove"), role: .destructive, action: onRemove)
            Button(String(localized: "common.cancel",
                          defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "remote.confirm.removeMessage",
                               defaultValue: "This will disconnect \"%@\" and close any open terminals on it."),
                group.alias
            ))
        }
        .alert(
            String(localized: "tmux.kill.confirmTitle",
                   defaultValue: "Kill tmux session?"),
            isPresented: Binding(
                get: { killConfirmationName != nil },
                set: { if !$0 { killConfirmationName = nil } }
            ),
            presenting: killConfirmationName
        ) { name in
            Button(String(localized: "tmux.kill.confirm",
                          defaultValue: "Kill"), role: .destructive) {
                group.killSession(name: name) { _ in }
                killConfirmationName = nil
            }
            Button(String(localized: "common.cancel",
                          defaultValue: "Cancel"), role: .cancel) {}
        } message: { name in
            Text(String(
                format: String(localized: "tmux.kill.confirmMessage",
                               defaultValue: "Session \"%@\" and all of its windows will be destroyed."),
                name
            ))
        }
    }

    private func handleRenameSubmit(oldName: String, newName: String) {
        group.renameSession(oldName: oldName, newName: newName) { outcome in
            switch outcome {
            case .success:
                renamingSessionName = nil
            case .duplicate:
                // Keep the edit row open; the group's lastError surfaces inline
                break
            case .failure:
                renamingSessionName = nil
            }
        }
    }
}

/// Thin placeholder row shown for hosts that are disconnected or
/// failed. Clicking attempts to reconnect; context menu offers remove.
/// Feature 708-remote-workspace-ssh (Phase 6, US4).
private struct DisconnectedRemoteHostRow: View {
    let host: RemoteHost
    let state: ConnectionState
    let onReconnect: () -> Void
    let onRemove: () -> Void

    @State private var showingRemoveConfirmation = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onReconnect) {
            HStack(spacing: 6) {
                RemoteConnectionStatusIndicator(state: state)
                Text(String(
                    format: String(localized: "tmux.remote.sidebar.header",
                                   defaultValue: "REMOTE: %@"),
                    host.alias
                ))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer()
                if case .failed(let reason) = state {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(reason)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHovered ? Color.secondary.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(String(localized: "remote.menu.reconnect",
                     defaultValue: "Reconnect"))
        .contextMenu {
            Button(String(localized: "remote.menu.reconnect",
                          defaultValue: "Reconnect"), action: onReconnect)
            Divider()
            Button(String(localized: "remote.menu.remove",
                          defaultValue: "Remove host…"), role: .destructive) {
                showingRemoveConfirmation = true
            }
        }
        .alert(
            String(localized: "remote.confirm.removeTitle",
                   defaultValue: "Remove remote host?"),
            isPresented: $showingRemoveConfirmation
        ) {
            Button(String(localized: "remote.confirm.remove",
                          defaultValue: "Remove"), role: .destructive, action: onRemove)
            Button(String(localized: "common.cancel",
                          defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "remote.confirm.removeMessage",
                               defaultValue: "This will disconnect \"%@\" and close any open terminals on it."),
                host.alias
            ))
        }
    }
}

private struct RemoteTmuxSessionRow: View {
    let session: TmuxSessionInfo
    let onAttach: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onAttach) {
            HStack(spacing: 6) {
                Image(systemName: session.isAttached ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundColor(session.isAttached ? .green : .secondary)
                    .frame(width: 10)

                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(windowCountLabel(session.windowCount))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.secondary.opacity(0.12) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }

    private func windowCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "tmux.sidebar.windowCount.one",
                          defaultValue: "1 window")
        }
        return String(
            format: String(localized: "tmux.sidebar.windowCount.many",
                           defaultValue: "%d windows"),
            count
        )
    }
}
