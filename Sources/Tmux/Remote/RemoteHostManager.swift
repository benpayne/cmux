// RemoteHostManager.swift
// @MainActor singleton that owns all managed remote hosts and their
// live connections. Central coordination point for the remote
// workspace feature (708-remote-workspace-ssh).
//
// Responsibilities:
//   - Maintain the host registry (saved + transient)
//   - Spawn and tear down RemoteConnection instances
//   - Assign per-cmux-instance control socket paths
//   - Run a periodic health check loop for connected hosts
//   - Clean up on cmux quit

import Combine
import Foundation

@MainActor
final class RemoteHostManager: ObservableObject {
    static let shared = RemoteHostManager()

    // MARK: - Published state

    /// All managed hosts keyed by id. Iteration order is insertion
    /// order (UUID keys are stable; the UI derives display order from
    /// `addedAt`).
    @Published private(set) var hosts: [UUID: RemoteHost] = [:]

    /// Live connections keyed by host id. Absent when the host is
    /// disconnected.
    @Published private(set) var connections: [UUID: RemoteConnection] = [:]

    /// Convenience: hosts sorted by addedAt for display.
    var hostsInDisplayOrder: [RemoteHost] {
        hosts.values.sorted { $0.addedAt < $1.addedAt }
    }

    // MARK: - Private state

    /// Per-instance directory for control sockets.
    /// `~/Library/Application Support/cmux/ssh/<instance-id>/`
    let controlSocketDirectory: URL

    /// Per-instance identifier, used to isolate sockets between
    /// concurrent cmux processes.
    private let instanceId: String

    /// Health check timer. Fires every 30 seconds and probes all
    /// connected hosts via `ssh -O check`.
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 30.0

    // MARK: - Init

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let cmuxDir = supportDir.appendingPathComponent("cmux", isDirectory: true)
        let sshDir = cmuxDir.appendingPathComponent("ssh", isDirectory: true)
        self.instanceId = UUID().uuidString.prefix(8).lowercased()
        self.controlSocketDirectory = sshDir.appendingPathComponent(instanceId, isDirectory: true)

        try? FileManager.default.createDirectory(
            at: controlSocketDirectory,
            withIntermediateDirectories: true
        )

        startHealthCheckTimer()
    }

    // MARK: - Lifecycle

    private func startHealthCheckTimer() {
        stopHealthCheckTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runHealthChecks()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    private func stopHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func runHealthChecks() {
        for (_, connection) in connections {
            guard case .connected = connection.state else { continue }
            connection.isHealthy { [weak connection] healthy in
                guard !healthy, let connection else { return }
                // Mark as failed; UI observers will see the transition.
                if case .connected = connection.state {
                    connection.disconnect(completion: {})
                }
            }
        }
    }

    // MARK: - Host CRUD

    /// Add a host to the registry. If a host with a matching
    /// destination already exists, returns the existing one.
    /// - Parameter transient: true for hosts added implicitly by
    ///   `cmux ssh` that should be auto-removed when their last pane
    ///   closes.
    /// - Returns: the newly-added host, or the pre-existing match.
    @discardableResult
    func addHost(
        destination: String,
        alias: String? = nil,
        sshOptions: SSHConnectionOptions = .default,
        transient: Bool = false
    ) -> RemoteHost {
        let trimmedDest = destination.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for existing host with a matching destination (logical
        // dedup for the findOrCreate case used by `cmux ssh`).
        if let existing = hosts.values.first(where: { $0.destination == trimmedDest }) {
            return existing
        }

        let computedAlias: String
        if let alias, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            computedAlias = ensureUniqueAlias(base: alias)
        } else {
            computedAlias = ensureUniqueAlias(base: RemoteHost.defaultAlias(forDestination: trimmedDest))
        }

        let host = RemoteHost(
            alias: computedAlias,
            destination: trimmedDest,
            sshOptions: sshOptions,
            transient: transient
        )
        hosts[host.id] = host
        return host
    }

    /// Remove a host and tear down any active connection.
    func removeHost(id: UUID, completion: @escaping () -> Void = {}) {
        if let connection = connections[id] {
            connection.disconnect { [weak self] in
                self?.connections.removeValue(forKey: id)
                self?.hosts.removeValue(forKey: id)
                completion()
            }
        } else {
            hosts.removeValue(forKey: id)
            completion()
        }
    }

    /// Rename a host's display alias. Throws if the new alias is
    /// already taken by another host.
    func renameHost(id: UUID, newAlias: String) throws {
        let trimmed = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteHostManagerError.invalidAlias("Alias cannot be empty")
        }
        if hosts.values.contains(where: { $0.id != id && $0.alias == trimmed }) {
            throw RemoteHostManagerError.duplicateAlias(trimmed)
        }
        hosts[id]?.alias = trimmed
    }

    // MARK: - Connection

    /// Open the SSH master for a host. If already connected, no-op.
    /// Completion fires when the connect attempt finishes (success or
    /// failure). Matches FR-022: immediate connect on add.
    func connect(id: UUID, completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard let host = hosts[id] else {
            completion(.failure(RemoteHostManagerError.unknownHost(id)))
            return
        }

        // Reuse existing connection if present.
        if let existing = connections[id] {
            if case .connected = existing.state {
                completion(.success(()))
                return
            }
            existing.connect(completion: completion)
            return
        }

        let socketPath = controlSocketDirectory
            .appendingPathComponent("\(host.alias).sock")
            .path

        let connection = RemoteConnection(host: host, controlSocketPath: socketPath)
        connection.onStateChange = { [weak self] newState in
            // Trigger objectWillChange so SwiftUI observers see
            // connection-state changes.
            self?.objectWillChange.send()
        }
        connections[id] = connection

        connection.connect { [weak self] result in
            if case .success = result {
                var updatedHost = host
                updatedHost.lastConnectedAt = Date()
                self?.hosts[id] = updatedHost
            }
            self?.objectWillChange.send()
            completion(result)
        }
    }

    /// Tear down the master for a host. Closes any open terminals on
    /// the host first (caller is responsible for UI-side pane removal;
    /// this just drops the connection).
    func disconnect(id: UUID, completion: @escaping () -> Void = {}) {
        guard let connection = connections[id] else {
            completion()
            return
        }
        connection.disconnect { [weak self] in
            self?.connections.removeValue(forKey: id)
            self?.objectWillChange.send()
            completion()
        }
    }

    /// Look up or create a host matching a destination. Used by the
    /// `cmux ssh` CLI integration (FR-016). If no match exists, creates
    /// a transient host unless `save: true` is passed.
    @discardableResult
    func findOrCreate(destination: String, save: Bool = false) -> RemoteHost {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = hosts.values.first(where: { $0.destination == trimmed }) {
            return existing
        }
        return addHost(destination: trimmed, transient: !save)
    }

    // MARK: - Quit

    /// Synchronously tear down every open connection. Called from the
    /// cmux quit hook (FR-020) so no orphaned ssh processes survive
    /// cmux exit.
    func teardownAllConnections() {
        stopHealthCheckTimer()
        let allConnections = Array(connections.values)
        for connection in allConnections {
            connection.disconnect(completion: {})
        }
        // Best-effort socket directory cleanup.
        try? FileManager.default.removeItem(at: controlSocketDirectory)
    }

    // MARK: - Helpers

    /// Generate a unique alias by appending a numeric suffix if needed.
    private func ensureUniqueAlias(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "host" }
        if !hosts.values.contains(where: { $0.alias == trimmed }) {
            return trimmed
        }
        var suffix = 2
        while hosts.values.contains(where: { $0.alias == "\(trimmed)-\(suffix)" }) {
            suffix += 1
        }
        return "\(trimmed)-\(suffix)"
    }
}

enum RemoteHostManagerError: Error, LocalizedError {
    case unknownHost(UUID)
    case invalidAlias(String)
    case duplicateAlias(String)

    var errorDescription: String? {
        switch self {
        case .unknownHost(let id): return "Unknown host: \(id.uuidString)"
        case .invalidAlias(let msg): return msg
        case .duplicateAlias(let alias): return "Alias already in use: \(alias)"
        }
    }
}
