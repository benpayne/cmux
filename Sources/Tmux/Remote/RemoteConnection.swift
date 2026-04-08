// RemoteConnection.swift
// A single live SSH master connection to a remote host.
//
// Part of feature 708-remote-workspace-ssh. Owns:
//   - The control socket path on disk
//   - The background `ssh -M -fnNT ...` process (if running)
//   - The ConnectionState
//   - A count of cmux panes using this connection
//
// Thread-safety: all state mutation happens on the main actor via the
// helper methods below. Subprocess execution happens on a background
// queue, with the completion dispatched back to main for state updates.

import Foundation

@MainActor
final class RemoteConnection {
    // MARK: - Public state

    /// The host this connection is for.
    let host: RemoteHost

    /// Absolute path to the SSH ControlPath socket for this connection.
    /// Per-cmux-instance isolation is the caller's responsibility (the
    /// RemoteHostManager chooses the instance directory).
    let controlSocketPath: String

    /// Current state. Observable via the `onStateChange` callback.
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    /// Number of cmux panes currently using this connection.
    private(set) var openTerminalCount: Int = 0

    /// Callback invoked whenever `state` changes. Set by the
    /// RemoteHostManager to drive UI updates.
    var onStateChange: ((ConnectionState) -> Void)?

    // MARK: - Private

    /// The running `ssh -M ...` master process, if the state is
    /// `.connected` (or `.connecting`).
    private var masterProcess: Process?

    /// Dedicated queue for running ssh subprocesses. All blocking waits
    /// happen here so the main actor is never blocked.
    nonisolated(unsafe) private let workQueue: DispatchQueue

    // MARK: - Init

    init(host: RemoteHost, controlSocketPath: String) {
        self.host = host
        self.controlSocketPath = controlSocketPath
        self.workQueue = DispatchQueue(
            label: "com.cmux.remote.connection.\(host.id.uuidString)",
            qos: .userInitiated
        )
    }

    // MARK: - Lifecycle

    /// Spawn the `ssh -M -fnNT` background master. Completion fires on
    /// the main actor. On success, state becomes `.connected`. On
    /// failure, state becomes `.failed(reason:)`.
    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        guard state == .disconnected || state.isActionable else {
            // Already connecting or connected — no-op.
            completion(.success(()))
            return
        }
        if case .connecting = state {
            // Already in flight.
            completion(.success(()))
            return
        }
        state = .connecting

        // Ensure the parent directory for the control socket exists.
        let socketDir = (controlSocketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: socketDir,
                withIntermediateDirectories: true
            )
        } catch {
            state = .failed(reason: "Could not create socket directory: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        // Remove any stale socket file (e.g., left by a previous
        // instance that crashed).
        try? FileManager.default.removeItem(atPath: controlSocketPath)

        let args = SSHCommandBuilder.buildSSHArguments(
            destination: host.destination,
            command: nil,
            options: host.sshOptions,
            mode: .openMaster(controlSocketPath: controlSocketPath)
        )
        let destination = host.destination

        workQueue.async { [weak self] in
            let process = Process()
            process.launchPath = "/usr/bin/ssh"
            process.arguments = args

            // Capture stderr so we can surface auth/connection errors.
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe() // discard

            do {
                try process.run()
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.state = .failed(reason: "Failed to launch ssh: \(error.localizedDescription)")
                    completion(.failure(error))
                }
                return
            }

            // `-fnNT` backgrounds the master after authentication, so
            // the foreground process exits once the control socket is
            // ready. Wait for it.
            process.waitUntilExit()
            let status = process.terminationStatus
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == 0 {
                    self.state = .connected
                    // Keep a reference to the process? Once `-fnNT`
                    // backgrounds, the foreground process we spawned
                    // has already exited. The actual master is now
                    // owned by the SSH client; we interact with it via
                    // the control socket. So we do NOT keep a Process
                    // reference — teardown uses `ssh -O exit` instead.
                    self.masterProcess = nil
                    completion(.success(()))
                } else {
                    let reason = Self.friendlyFailureReason(stderr: stderr, destination: destination, exitStatus: status)
                    self.state = .failed(reason: reason)
                    completion(.failure(RemoteConnectionError.connectFailed(reason)))
                }
            }
        }
    }

    /// Gracefully tear down the master via `ssh -O exit -S <sock>`.
    /// Idempotent — safe to call from any state.
    func disconnect(completion: @escaping () -> Void = {}) {
        // Always transition to disconnected regardless of prior state;
        // the worst case is a no-op exit command against a dead socket.
        let socketPath = self.controlSocketPath
        let destination = self.host.destination
        let options = self.host.sshOptions
        state = .disconnected

        workQueue.async { [weak self] in
            let args = SSHCommandBuilder.buildSSHArguments(
                destination: destination,
                command: nil,
                options: options,
                mode: .useExistingMaster(controlSocketPath: socketPath)
            ) + ["-O", "exit"]

            let process = Process()
            process.launchPath = "/usr/bin/ssh"
            // The -O exit form uses these specific args; our builder
            // returns them minus "-O exit" which we append.
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            // Remove the socket file (ssh -O exit may leave it).
            try? FileManager.default.removeItem(atPath: socketPath)

            Task { @MainActor [weak self] in
                self?.masterProcess = nil
                completion()
            }
        }
    }

    /// Run `ssh -O check -S <sock>` to verify the master is still alive.
    /// Completion receives true if healthy, false if not. Does not
    /// mutate state; caller decides what to do with the result.
    func isHealthy(completion: @escaping (Bool) -> Void) {
        let socketPath = self.controlSocketPath
        let destination = self.host.destination
        let options = self.host.sshOptions

        workQueue.async {
            var args = SSHCommandBuilder.buildSSHArguments(
                destination: destination,
                command: nil,
                options: options,
                mode: .useExistingMaster(controlSocketPath: socketPath)
            )
            args += ["-O", "check"]
            let process = Process()
            process.launchPath = "/usr/bin/ssh"
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                Task { @MainActor in
                    completion(process.terminationStatus == 0)
                }
            } catch {
                Task { @MainActor in
                    completion(false)
                }
            }
        }
    }

    /// Run a remote command through the existing master. Blocks until
    /// completion. Must be called off the main actor (the caller should
    /// wrap in a background dispatch or Task).
    nonisolated func runCommand(_ command: String) throws -> TmuxProcessResult {
        // Snapshot the immutable bits we need.
        let socketPath = self.controlSocketPath
        // host is immutable after init so this access is safe from off
        // the main actor — we treat RemoteHost value semantics as
        // Sendable because it is a value type of Sendable fields.
        let dest = self.host.destination
        let opts = self.host.sshOptions

        let args = SSHCommandBuilder.buildSSHArguments(
            destination: dest,
            command: command,
            options: opts,
            mode: .useExistingMaster(controlSocketPath: socketPath)
        )

        let process = Process()
        process.launchPath = "/usr/bin/ssh"
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TmuxTransportError.launchFailed(error.localizedDescription)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return TmuxProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Pane tracking

    func registerOpenedPane() {
        openTerminalCount += 1
    }

    func registerClosedPane() {
        openTerminalCount = max(0, openTerminalCount - 1)
    }

    // MARK: - Error mapping

    /// Translate common OpenSSH stderr patterns into user-friendly
    /// error messages.
    static func friendlyFailureReason(stderr: String, destination: String, exitStatus: Int32) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") {
            return "Authentication failed. Check your SSH key or agent."
        }
        if lower.contains("could not resolve hostname") {
            return "Host not found: \(destination)"
        }
        if lower.contains("connection refused") {
            return "Connection refused. Is sshd running on \(destination)?"
        }
        if lower.contains("host key verification failed") {
            return "Host key verification failed. Check with your administrator before reconnecting."
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return "Connection timed out: \(destination)"
        }
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty {
            return firstLine
        }
        return "ssh exited with status \(exitStatus)"
    }
}

enum RemoteConnectionError: Error, LocalizedError {
    case connectFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectFailed(let reason): return reason
        case .notConnected: return "Not connected"
        }
    }
}
