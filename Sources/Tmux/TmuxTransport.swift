// TmuxTransport.swift
// Transport abstraction for `TmuxService` — lets tmux commands run
// either against the local tmux binary or against a remote tmux via
// an existing SSH master connection.
//
// Part of feature 708-remote-workspace-ssh. Generalizes the subprocess
// runner that used to live inside `TmuxService` so the same parser,
// polling loop, and CRUD methods work for both local and remote.

import Foundation

/// Result of running a tmux subprocess invocation.
struct TmuxProcessResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Errors surfaced by transports when the subprocess cannot even be
/// launched (distinct from tmux itself exiting non-zero, which is
/// reported via `TmuxProcessResult.exitCode`).
enum TmuxTransportError: Error, Equatable {
    /// The transport cannot run commands because its underlying
    /// resource is unavailable (tmux not installed locally, or the
    /// remote SSH master is not connected).
    case unavailable(String)
    /// Failed to spawn the subprocess (e.g., executable not found,
    /// permission denied at launch time).
    case launchFailed(String)
}

/// Abstract subprocess runner for tmux invocations.
///
/// Implementations are expected to be `Sendable`-safe since the poll
/// loop in `TmuxSidebarState` dispatches work off the main actor. The
/// `runTmux` method is expected to block until the subprocess exits,
/// so callers should never invoke it from the main thread.
protocol TmuxTransport: AnyObject {
    /// Short human-readable label, used for debug logging ("local" or
    /// the remote host's alias).
    var label: String { get }

    /// Run `tmux <arguments>` and return the result. Throws
    /// `TmuxTransportError.unavailable` if the transport's backing
    /// resource is not ready.
    func runTmux(arguments: [String]) throws -> TmuxProcessResult

    /// Build the command string that a TerminalPanel's `initialCommand`
    /// should use to attach to the given tmux session via this
    /// transport. For the local transport this is just
    /// `<tmux-path> attach-session -t <name>`; for remote it is the
    /// full `ssh -S <sock> -t <destination> tmux attach-session -t <name>`.
    func attachCommand(forSession name: String) -> String
}

/// Transport that runs the local `tmux` binary directly.
///
/// Wraps the subprocess-launch logic that used to live inline inside
/// `TmuxService`. Discovery of the tmux binary path (via search paths
/// or `command -v`) is delegated to a caller-supplied closure so this
/// type stays pure and testable.
final class LocalTmuxTransport: TmuxTransport, @unchecked Sendable {
    let label: String = "local"

    /// Returns the absolute path to the local `tmux` binary, or nil
    /// if tmux is not installed. Called lazily on each invocation.
    private let binaryResolver: () -> String?

    init(binaryResolver: @escaping () -> String?) {
        self.binaryResolver = binaryResolver
    }

    func runTmux(arguments: [String]) throws -> TmuxProcessResult {
        guard let binary = binaryResolver() else {
            throw TmuxTransportError.unavailable("tmux not found on PATH")
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

    func attachCommand(forSession name: String) -> String {
        let binary = binaryResolver() ?? "tmux"
        return "\(Self.shellQuote(binary)) attach-session -t \(Self.shellQuote(name))"
    }

    /// Single-quote-escape a value for safe inclusion in a shell
    /// command. Matches `TmuxService.shellEscape` behavior so the two
    /// produce identical attach commands.
    static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
