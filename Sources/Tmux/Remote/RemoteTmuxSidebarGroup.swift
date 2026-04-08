// RemoteTmuxSidebarGroup.swift
// Per-host sidebar state for remote tmux sessions.
//
// One instance per connected remote host. Owns a 5-second poll timer
// that lists tmux sessions on the remote, plus create/kill/rename
// wrappers that delegate to the RemoteTmuxTransport-backed TmuxService.
//
// Part of feature 708-remote-workspace-ssh (Phase 3, US1).

import Bonsplit
import Combine
import Foundation

@MainActor
final class RemoteTmuxSidebarGroup: ObservableObject, Identifiable {
    // MARK: - Identity

    /// Matches the owning `RemoteHost.id` for stable SwiftUI diffing.
    let id: UUID

    /// Copy of the host at creation time. Used for display labels and
    /// to rebuild the attach command. Updated externally when the host
    /// is renamed (via `updateHost(_:)`).
    private(set) var host: RemoteHost

    /// Display alias for the section header. Updates when the user
    /// renames the host.
    var alias: String { host.alias }

    // MARK: - Published state

    /// Current tmux sessions on the remote, sorted by name.
    @Published private(set) var sessions: [TmuxSessionInfo] = []

    /// True while a list-sessions call is in flight.
    @Published private(set) var isLoading: Bool = false

    /// Last error from a tmux command, nil if the most recent refresh
    /// succeeded. Typical values: "session not found", connection
    /// errors, tmux-not-installed-on-remote.
    @Published private(set) var lastError: String?

    /// Whether the remote host is reachable at all. Set to false if
    /// the list-sessions call fails with a connection-level error.
    @Published private(set) var remoteTmuxAvailable: Bool = true

    // MARK: - Private

    private let service: TmuxService
    private let workQueue: DispatchQueue
    private var pollTimer: Timer?

    /// 5-second poll interval per R9 in the spec's research.md —
    /// slightly slower than local (3s) because remote calls incur
    /// SSH round-trip latency.
    private let pollInterval: TimeInterval = 5.0

    // MARK: - Init

    init(host: RemoteHost, service: TmuxService) {
        self.id = host.id
        self.host = host
        self.service = service
        self.workQueue = DispatchQueue(
            label: "com.cmux.tmux.remote.sidebar.\(host.id.uuidString)",
            qos: .userInitiated
        )
    }

    /// Convenience: construct a group for a remote host using a
    /// RemoteTmuxTransport over the given connection.
    static func make(for connection: RemoteConnection) -> RemoteTmuxSidebarGroup {
        let transport = RemoteTmuxTransport(connection: connection)
        let service = TmuxService(transport: transport)
        return RemoteTmuxSidebarGroup(host: connection.host, service: service)
    }

    // MARK: - Lifecycle

    /// Start polling. Safe to call multiple times — resets the timer.
    func start() {
        stopPolling()
        refreshNow()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
#if DEBUG
        dlog("tmux.remote.group.start host=\(host.alias)")
#endif
    }

    /// Stop polling. Retains the last observed sessions.
    func stop() {
        stopPolling()
#if DEBUG
        dlog("tmux.remote.group.stop host=\(host.alias)")
#endif
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Update the host reference (e.g., after a rename). Display labels
    /// will pick up the new alias on the next render.
    func updateHost(_ newHost: RemoteHost) {
        self.host = newHost
        objectWillChange.send()
    }

    // MARK: - Refresh

    /// Immediate refresh. Coalesces with an in-flight refresh.
    func refreshNow() {
        if isLoading { return }
        isLoading = true

        let service = self.service
        let alias = host.alias
        workQueue.async { [weak self] in
            let result = Result<[TmuxSessionInfo], Error> {
                try service.listSessions()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let sessions):
                    let changed = sessions != self.sessions
                    self.sessions = sessions
                    self.lastError = nil
                    self.remoteTmuxAvailable = true
#if DEBUG
                    if changed {
                        dlog("tmux.remote.group.refresh host=\(alias) count=\(sessions.count)")
                    }
#endif
                case .failure(let error):
                    // Heuristic: if the error mentions "command not
                    // found" or "tmux: not found", the remote host
                    // doesn't have tmux installed. Distinguish this
                    // from connection errors so the UI can show
                    // "tmux not available on host" instead of an
                    // error row.
                    let lowered = error.localizedDescription.lowercased()
                    if lowered.contains("not found") && lowered.contains("tmux") {
                        self.remoteTmuxAvailable = false
                        self.lastError = nil
                        self.sessions = []
                    } else {
                        self.lastError = error.localizedDescription
                    }
#if DEBUG
                    dlog("tmux.remote.group.refresh.error host=\(alias) \(error.localizedDescription)")
#endif
                }
            }
        }
    }

    // MARK: - Mutating operations
    // Mirror the same API shape as TmuxSidebarState's local methods so
    // TmuxSidebarView can render remote sections with identical UX.

    enum CreateOutcome: Equatable {
        case success(TmuxSessionInfo)
        case duplicate
        case failure(String)
    }

    func createSession(name: String?, completion: @escaping (CreateOutcome) -> Void) {
        let service = self.service
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = (trimmed?.isEmpty == false) ? trimmed : nil

        workQueue.async { [weak self] in
            let result = Result<TmuxSessionInfo, Error> {
                try service.createSession(name: normalizedName)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let info):
                    self.lastError = nil
                    self.refreshNow()
                    completion(.success(info))
                case .failure(let error):
                    if case TmuxServiceError.duplicateName = error {
                        completion(.duplicate)
                    } else {
                        self.lastError = error.localizedDescription
                        completion(.failure(error.localizedDescription))
                    }
                }
            }
        }
    }

    func killSession(name: String, completion: @escaping (Bool) -> Void) {
        let service = self.service
        workQueue.async { [weak self] in
            let success: Bool
            do {
                try service.killSession(name: name)
                success = true
            } catch {
                success = false
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !success {
                    self.lastError = String(localized: "tmux.error.killFailed",
                                            defaultValue: "Failed to kill session")
                } else {
                    self.lastError = nil
                }
                self.refreshNow()
                completion(success)
            }
        }
    }

    func renameSession(oldName: String, newName: String, completion: @escaping (CreateOutcome) -> Void) {
        let service = self.service
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else {
            completion(.failure(""))
            return
        }
        workQueue.async { [weak self] in
            let result = Result<Void, Error> {
                try service.renameSession(oldName: oldName, newName: trimmed)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.lastError = nil
                    self.refreshNow()
                    completion(.success(TmuxSessionInfo(
                        name: trimmed, windowCount: 0,
                        createdAt: Date(), isAttached: false, clientCount: 0
                    )))
                case .failure(let error):
                    if case TmuxServiceError.duplicateName = error {
                        completion(.duplicate)
                    } else {
                        self.lastError = error.localizedDescription
                        completion(.failure(error.localizedDescription))
                    }
                }
            }
        }
    }
}
