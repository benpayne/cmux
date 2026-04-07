// TmuxSidebarState.swift
// Observable state for the tmux sidebar section.
//
// Part of feature 707-tmux-control-panel.
//
// `TmuxSidebarState` is a singleton because tmux sessions are system-wide,
// not per-workspace. The sidebar UI binds to the shared instance regardless
// of which workspace is currently selected.

import Bonsplit
import Combine
import Foundation

/// Observable state backing the tmux sidebar section.
///
/// Owns a 3-second polling timer that refreshes `sessions` from the local
/// tmux server. All subprocess work happens on a background queue; only the
/// final state mutation is dispatched to the main actor.
@MainActor
final class TmuxSidebarState: ObservableObject {
    /// Shared instance used by the sidebar view.
    static let shared = TmuxSidebarState()

    // MARK: - Published state

    /// Whether the tmux binary was found on the system.
    @Published private(set) var isAvailable: Bool = false

    /// Most recently observed list of tmux sessions, ordered by name.
    @Published private(set) var sessions: [TmuxSessionInfo] = []

    /// True while a refresh is in progress.
    @Published private(set) var isLoading: Bool = false

    /// Last error message from a tmux command, or nil if the most recent
    /// refresh succeeded.
    @Published private(set) var lastError: String?

    // MARK: - Private state

    private let service: TmuxService
    private let workQueue = DispatchQueue(label: "com.cmux.tmux.sidebar", qos: .userInitiated)
    private var pollTimer: Timer?
    /// 3-second poll interval — meets the spec's 5s freshness target with
    /// headroom for variability.
    private let pollInterval: TimeInterval = 3.0

    // MARK: - Init

    init(service: TmuxService = .shared) {
        self.service = service
    }

    // MARK: - Lifecycle

    /// Initialize availability state and (if tmux is present) start polling.
    /// Safe to call multiple times — subsequent calls reset the timer.
    func start() {
        // Detect availability synchronously; this only does a few file
        // existence checks, no subprocess unless the absolute paths miss.
        isAvailable = service.isAvailable
#if DEBUG
        dlog("tmux.sidebar.start available=\(isAvailable)")
#endif
        guard isAvailable else {
            sessions = []
            stopPolling()
            return
        }
        refreshNow()
        startPolling()
    }

    /// Stop the polling timer. Sessions are retained.
    func stop() {
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        // Run on the common run loop so the timer fires while menus/modal
        // sheets are visible.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Refresh

    /// Trigger an immediate refresh. Coalesces with any in-flight refresh by
    /// short-circuiting if `isLoading` is already true.
    func refreshNow() {
        guard isAvailable else { return }
        if isLoading { return }
        isLoading = true

        let service = self.service
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
#if DEBUG
                    if changed {
                        dlog("tmux.sidebar.refresh count=\(sessions.count)")
                    }
#endif
                case .failure(let error):
                    if case TmuxServiceError.notInstalled = error {
#if DEBUG
                        dlog("tmux.sidebar.unavailable")
#endif
                        self.isAvailable = false
                        self.sessions = []
                        self.stopPolling()
                    } else {
#if DEBUG
                        dlog("tmux.sidebar.refresh.error \(error.localizedDescription)")
#endif
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - Re-detection

    /// Re-probe for the tmux binary (e.g. after the user installs it at
    /// runtime). Restarts polling if tmux is now available.
    func recheckAvailability() {
        service.resetDetectionCache()
        start()
    }

    // MARK: - Mutating operations

    /// Result of a session creation attempt, surfaced to the UI for inline
    /// error display and follow-up actions.
    enum CreateOutcome: Equatable {
        case success(TmuxSessionInfo)
        case duplicate
        case failure(String)
    }

    /// Create a new tmux session in the background, refresh the session
    /// list, and return the outcome on the main actor. The completion
    /// callback runs on the main actor.
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

    /// Kill a tmux session in the background and refresh the list.
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

    /// Rename a tmux session in the background and refresh the list.
    /// Returns success or duplicate-name failure on the completion callback.
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
                    // Synthesize a placeholder TmuxSessionInfo with the new name;
                    // the next poll will replace it with real metadata.
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
