// TmuxService.swift
// Subprocess-based wrapper around the local tmux CLI.
//
// Part of feature 707-tmux-control-panel. All operations shell out to the
// `tmux` binary; nothing here uses Ghostty's internal tmux control mode.
//
// All methods are safe to call from any queue; subprocess execution always
// runs off the main thread.

import Foundation

/// Errors thrown by `TmuxService` operations.
enum TmuxServiceError: Error, Equatable, LocalizedError {
    /// The tmux binary was not found on PATH.
    case notInstalled
    /// `tmux` exited non-zero. Includes stderr text and exit status.
    case commandFailed(status: Int32, stderr: String)
    /// A duplicate session name was rejected by tmux.
    case duplicateName(String)
    /// A session name was not found.
    case sessionNotFound(String)
    /// Subprocess could not be launched.
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "tmux is not installed or not on PATH"
        case .commandFailed(let status, let stderr):
            return "tmux exited \(status): \(stderr)"
        case .duplicateName(let name):
            return "duplicate session name: \(name)"
        case .sessionNotFound(let name):
            return "session not found: \(name)"
        case .launchFailed(let message):
            return "failed to launch tmux: \(message)"
        }
    }
}

/// Wraps invocations of the local `tmux` CLI for session enumeration and CRUD.
///
/// `TmuxService` is stateless aside from a cached path to the tmux binary; it
/// is safe to construct multiple instances. The shared singleton
/// `TmuxService.shared` is provided for convenience.
///
/// Marked `@unchecked Sendable` because all mutable state
/// (`cachedBinaryPath`, `didDetect`) is guarded by `detectionLock`.
final class TmuxService: @unchecked Sendable {
    static let shared = TmuxService()

    /// Cached absolute path to the `tmux` binary, or nil if unavailable.
    /// Initialized lazily on first call to `detectTmux()`.
    private var cachedBinaryPath: String?
    private var didDetect = false
    private let detectionLock = NSLock()

    /// Search paths to probe in order when locating the tmux binary.
    /// We avoid relying on the launching process's PATH because GUI apps on
    /// macOS often have a stripped PATH that excludes Homebrew locations.
    private static let searchPaths: [String] = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        "/opt/local/bin/tmux",
    ]

    /// Format string used for `list-sessions -F`. Fields are pipe-separated;
    /// see `TmuxSessionInfo.parse(line:)` for the parser.
    private static let listFormat =
        "#{session_name}|#{session_windows}|#{session_created}|#{session_attached}|#{session_activity}"

    init() {}

    // MARK: - Detection

    /// Returns the cached path to tmux, detecting on first call.
    /// Returns nil if tmux is not installed.
    func detectTmux() -> String? {
        detectionLock.lock()
        defer { detectionLock.unlock() }

        if didDetect {
            return cachedBinaryPath
        }
        didDetect = true

        // Probe well-known absolute paths first.
        for path in Self.searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedBinaryPath = path
                return path
            }
        }

        // Fall back to `command -v` via /bin/sh which inherits the user's PATH.
        if let resolved = resolveViaShell() {
            cachedBinaryPath = resolved
            return resolved
        }

        return nil
    }

    /// True if tmux is installed.
    var isAvailable: Bool {
        detectTmux() != nil
    }

    /// Force re-detection (e.g. after the user installs tmux at runtime).
    func resetDetectionCache() {
        detectionLock.lock()
        defer { detectionLock.unlock() }
        cachedBinaryPath = nil
        didDetect = false
    }

    private func resolveViaShell() -> String? {
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-l", "-c", "command -v tmux"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    // MARK: - Operations

    /// Enumerate all tmux sessions on the local server.
    /// Returns an empty array if tmux is installed but no sessions exist.
    /// Throws `TmuxServiceError.notInstalled` if tmux is unavailable.
    func listSessions() throws -> [TmuxSessionInfo] {
        let result = try runTmux(arguments: ["list-sessions", "-F", Self.listFormat])
        if result.exitCode != 0 {
            // tmux exits 1 with "no server running" when there are no sessions.
            // Treat that as an empty list rather than an error.
            let stderr = result.stderr.lowercased()
            if stderr.contains("no server running") || stderr.contains("error connecting") {
                return []
            }
            throw TmuxServiceError.commandFailed(status: result.exitCode, stderr: result.stderr)
        }
        return TmuxSessionInfo.parse(output: result.stdout).sorted { $0.name < $1.name }
    }

    /// Create a new detached tmux session.
    ///
    /// - Parameter name: Optional session name. If nil, tmux assigns a default
    ///   numeric name (e.g. "0", "1", ...).
    /// - Returns: The newly created session's metadata.
    func createSession(name: String?) throws -> TmuxSessionInfo {
        var args: [String] = ["new-session", "-d"]
        if let name, !name.isEmpty {
            args.append(contentsOf: ["-s", name])
        }
        let result = try runTmux(arguments: args)
        if result.exitCode != 0 {
            let stderr = result.stderr
            if stderr.lowercased().contains("duplicate session") {
                throw TmuxServiceError.duplicateName(name ?? "")
            }
            throw TmuxServiceError.commandFailed(status: result.exitCode, stderr: stderr)
        }

        // Re-list to find the freshly created session.
        let sessions = try listSessions()
        if let name {
            if let match = sessions.first(where: { $0.name == name }) {
                return match
            }
        } else {
            // Default-named: pick the most recently created session.
            if let newest = sessions.max(by: { $0.createdAt < $1.createdAt }) {
                return newest
            }
        }
        throw TmuxServiceError.commandFailed(status: 0, stderr: "session created but not found in list")
    }

    /// Kill an existing tmux session by name.
    func killSession(name: String) throws {
        let result = try runTmux(arguments: ["kill-session", "-t", name])
        if result.exitCode != 0 {
            if result.stderr.lowercased().contains("can't find session") {
                throw TmuxServiceError.sessionNotFound(name)
            }
            throw TmuxServiceError.commandFailed(status: result.exitCode, stderr: result.stderr)
        }
    }

    /// Rename an existing tmux session.
    func renameSession(oldName: String, newName: String) throws {
        let result = try runTmux(arguments: ["rename-session", "-t", oldName, newName])
        if result.exitCode != 0 {
            let stderr = result.stderr.lowercased()
            if stderr.contains("duplicate session") {
                throw TmuxServiceError.duplicateName(newName)
            }
            if stderr.contains("can't find session") {
                throw TmuxServiceError.sessionNotFound(oldName)
            }
            throw TmuxServiceError.commandFailed(status: result.exitCode, stderr: result.stderr)
        }
    }

    /// Build the shell command needed to attach to a given session.
    /// Returned as a string suitable for use as a TerminalPanel `initialCommand`.
    func attachCommand(for sessionName: String) -> String {
        // Use absolute path when known so the launched shell finds tmux even
        // with a sparse PATH.
        let binary = detectTmux() ?? "tmux"
        let escapedName = Self.shellEscape(sessionName)
        return "\(Self.shellEscape(binary)) attach-session -t \(escapedName)"
    }

    // MARK: - Subprocess plumbing

    fileprivate struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    fileprivate func runTmux(arguments: [String]) throws -> ProcessResult {
        guard let binary = detectTmux() else {
            throw TmuxServiceError.notInstalled
        }

        let process = Process()
        process.launchPath = binary
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TmuxServiceError.launchFailed(error.localizedDescription)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Single-quote-escape a string for safe inclusion in a shell command.
    private static func shellEscape(_ value: String) -> String {
        // Wrap in single quotes; escape any embedded single quotes by closing,
        // inserting an escaped quote, and reopening: 'foo'\''bar'
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
