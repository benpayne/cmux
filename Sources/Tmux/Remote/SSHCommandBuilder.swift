// SSHCommandBuilder.swift
// Shared builder for ssh/scp command-line argument arrays.
//
// Extracted from Sources/TerminalSSHSessionDetector.swift's private
// sshArguments/scpArguments helpers so the existing file-upload code
// path and the new RemoteHostManager / RemoteTmuxTransport can share
// the same battle-tested logic.
//
// Part of feature 708-remote-workspace-ssh.

import Foundation

/// High-level intent for an SSH invocation. Controls which of the
/// several "flavors" of ssh flags are emitted.
enum SSHInvocationMode: Equatable {
    /// Normal command execution. Matches DetectedSSHSession behavior:
    /// `-T`, BatchMode=yes, ControlMaster=no, short ConnectTimeout.
    /// Used for file upload (scp cleanup), existing cmux paths.
    case commandExec

    /// Open a new SSH master as a detached background process:
    /// `-M -f -n -N -T -S <socket>`. Allows interactive auth (no
    /// BatchMode). Uses a longer ConnectTimeout.
    case openMaster(controlSocketPath: String)

    /// Run a command through an already-open master socket. Uses
    /// `-S <socket>` and short timeouts. BatchMode=yes (the master
    /// already authenticated; failures should fail fast).
    case useExistingMaster(controlSocketPath: String)

    /// Interactive attach over an existing master. `-S <socket> -t`
    /// to allocate a real PTY. No BatchMode (interactive session).
    case interactiveAttach(controlSocketPath: String)
}

enum SSHCommandBuilder {
    /// Build the argument array for an `/usr/bin/ssh` invocation.
    ///
    /// - Parameters:
    ///   - destination: the SSH destination (`user@host`, or alias)
    ///   - command: the remote command to run, or nil for master-only
    ///              invocations (openMaster mode implies nil command)
    ///   - options: user-provided SSH connection options
    ///   - mode: which flavor of invocation to build
    static func buildSSHArguments(
        destination: String,
        command: String?,
        options: SSHConnectionOptions,
        mode: SSHInvocationMode
    ) -> [String] {
        var args: [String] = []

        // Base per-mode flags. `-T` disables PTY allocation; `-t` forces
        // one. openMaster wants `-MfnNT` to background after auth.
        switch mode {
        case .commandExec:
            args += ["-T"]
        case .openMaster(let socket):
            args += ["-M", "-f", "-n", "-N", "-T", "-S", socket]
        case .useExistingMaster(let socket):
            args += ["-T", "-S", socket]
        case .interactiveAttach(let socket):
            args += ["-t", "-S", socket]
        }

        // Connection timeouts. Longer for openMaster so interactive auth
        // has time to complete.
        let connectTimeout: Int
        switch mode {
        case .openMaster: connectTimeout = 15
        default: connectTimeout = 6
        }
        args += ["-o", "ConnectTimeout=\(connectTimeout)"]
        args += ["-o", "ServerAliveInterval=20"]
        args += ["-o", "ServerAliveCountMax=2"]

        // BatchMode: suppress interactive prompts for every mode EXCEPT
        // openMaster (which needs to accept password/passphrase/key
        // prompts) and interactiveAttach (which is itself interactive).
        switch mode {
        case .openMaster, .interactiveAttach:
            break
        default:
            args += ["-o", "BatchMode=yes"]
        }

        // ControlMaster handling. commandExec forces `no` (legacy
        // behavior). openMaster forces `yes` (we're creating one).
        // Master-attached modes don't touch it (the `-S` flag is what
        // matters). Skip emitting anything if the user already set it.
        if !options.hasOption(key: "ControlMaster") {
            switch mode {
            case .commandExec:
                args += ["-o", "ControlMaster=no"]
            case .openMaster:
                args += ["-o", "ControlMaster=yes"]
            default:
                break
            }
        }

        // Common option flags from SSHConnectionOptions.
        if options.useIPv4 {
            args.append("-4")
        } else if options.useIPv6 {
            args.append("-6")
        }
        if options.forwardAgent {
            args.append("-A")
        }
        if options.compressionEnabled {
            args.append("-C")
        }
        if let configFile = options.configFile,
           !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost = options.jumpHost,
           !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port = options.port {
            args += ["-p", String(port)]
        }
        if let identityFile = options.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }

        // Host key verification default (only when user hasn't set it).
        if !options.hasOption(key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }

        // Caller-supplied extra -o options, always last so they can
        // override anything above.
        for option in options.sshOptions {
            args += ["-o", option]
        }

        // Destination and remote command.
        args.append(destination)
        if let command = command, !command.isEmpty {
            args.append(command)
        }
        return args
    }

    /// Build the argument array for an `/usr/bin/scp` invocation
    /// matching the existing `DetectedSSHSession.scpArguments` behavior.
    /// Used by the file-upload path in `TerminalSSHSessionDetector`.
    ///
    /// - Parameters:
    ///   - localPath: source file path on the local machine
    ///   - remoteDestination: destination host part (e.g. `user@host` or
    ///                        `[host]` for bracketed IPv6)
    ///   - remotePath: target path on the remote host
    ///   - options: SSH connection options
    ///   - controlPath: optional control socket path (reuses existing
    ///                  master if present)
    static func buildSCPArguments(
        localPath: String,
        remoteDestination: String,
        remotePath: String,
        options: SSHConnectionOptions,
        controlPath: String?
    ) -> [String] {
        var args: [String] = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if options.useIPv4 {
            args.append("-4")
        } else if options.useIPv6 {
            args.append("-6")
        }
        if options.forwardAgent {
            args.append("-A")
        }
        if options.compressionEnabled {
            args.append("-C")
        }
        if let configFile = options.configFile,
           !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost = options.jumpHost,
           !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port = options.port {
            args += ["-P", String(port)] // scp uses -P (capital), unlike ssh's -p
        }
        if let identityFile = options.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath = controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !options.hasOption(key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !options.hasOption(key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in options.sshOptions {
            args += ["-o", option]
        }
        args += [localPath, "\(remoteDestination):\(remotePath)"]
        return args
    }
}
