// RemoteTmuxTransport.swift
// TmuxTransport implementation that wraps a `RemoteConnection` and
// runs tmux commands on the remote host via the existing SSH master.
//
// Part of feature 708-remote-workspace-ssh. Each connected remote host
// gets its own `TmuxService` instance built with one of these as its
// transport; the rest of the TmuxService parsing/polling logic is
// reused unchanged.

import Foundation

final class RemoteTmuxTransport: TmuxTransport, @unchecked Sendable {
    let label: String

    /// Strong reference to the owning connection. The transport
    /// outlives individual poll calls but should not outlive the
    /// connection — `RemoteHostManager` is responsible for tearing
    /// down transports when a host is removed.
    private let connection: RemoteConnection

    /// Cached copies of the bits we need to build command strings
    /// without touching the main actor. Captured at init time; these
    /// are immutable on `RemoteHost` anyway.
    private let destination: String
    private let controlSocketPath: String

    @MainActor
    init(connection: RemoteConnection) {
        self.connection = connection
        self.destination = connection.host.destination
        self.controlSocketPath = connection.controlSocketPath
        self.label = "remote:\(connection.host.alias)"
    }

    func runTmux(arguments: [String]) throws -> TmuxProcessResult {
        // Build the remote command as a single shell-quoted string.
        // ssh will exec it on the remote via the login shell.
        let remoteCommand = "tmux " + arguments
            .map { Self.shellQuote($0) }
            .joined(separator: " ")
        do {
            return try connection.runCommand(remoteCommand)
        } catch let error as TmuxTransportError {
            throw error
        } catch {
            throw TmuxTransportError.launchFailed(error.localizedDescription)
        }
    }

    func attachCommand(forSession name: String) -> String {
        // Full ssh invocation used as a TerminalPanel `initialCommand`.
        // interactiveAttach mode emits `-t -S <sock>` and no BatchMode.
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: destination,
            command: "tmux attach-session -t \(Self.shellQuote(name))",
            options: defaultOptionsForAttach(),
            mode: .interactiveAttach(controlSocketPath: controlSocketPath)
        )
        // Join into a single shell command line suitable for the
        // TerminalPanel initialCommand. Each arg is shell-quoted.
        return (["/usr/bin/ssh"] + args)
            .map { Self.shellQuote($0) }
            .joined(separator: " ")
    }

    /// The attach command is run from inside a TerminalPanel's shell,
    /// so we don't have the host's SSHConnectionOptions cached locally.
    /// The host's options were already applied when the master was
    /// opened, so the attach over the existing master only needs the
    /// `-S <sock>` flag (which interactiveAttach mode provides). We
    /// pass a default options bag to avoid reaching back to the main
    /// actor for the full options.
    private func defaultOptionsForAttach() -> SSHConnectionOptions {
        return .default
    }

    /// Shell-quote for POSIX single-quoted strings. Matches the helper
    /// used elsewhere in the codebase.
    static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
