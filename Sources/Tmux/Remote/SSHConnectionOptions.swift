// SSHConnectionOptions.swift
// Shared SSH connection configuration used by both DetectedSSHSession
// (Sources/TerminalSSHSessionDetector.swift) and the new RemoteHost
// (feature 708-remote-workspace-ssh).
//
// Encapsulates every tunable that cmux passes to ssh/scp so call sites
// can build command-line invocations consistently via SSHCommandBuilder.

import Foundation

/// Connection options for an SSH invocation.
///
/// All fields are optional overrides of ssh's default / the user's ssh_config.
/// When nil or false, ssh uses its own defaults. `sshOptions` is an escape
/// hatch for any `-o key=value` flags that don't have dedicated fields.
struct SSHConnectionOptions: Equatable, Hashable, Codable {
    /// TCP port. nil = ssh default (22 or ssh_config).
    var port: Int?

    /// Absolute path to a private key file for `-i`.
    var identityFile: String?

    /// Alternate `~/.ssh/config` path for `-F`.
    var configFile: String?

    /// Jump host spec for `-J` (e.g. `user@bastion`).
    var jumpHost: String?

    /// Force IPv4 via `-4`. Mutually exclusive with `useIPv6`.
    var useIPv4: Bool

    /// Force IPv6 via `-6`. Mutually exclusive with `useIPv4`.
    var useIPv6: Bool

    /// Forward the SSH agent via `-A`.
    var forwardAgent: Bool

    /// Enable compression via `-C`.
    var compressionEnabled: Bool

    /// Additional `-o key=value` overrides. Each entry is passed as a
    /// standalone `-o` argument. Entries take precedence over the dedicated
    /// fields above when there is a conflict.
    var sshOptions: [String]

    init(
        port: Int? = nil,
        identityFile: String? = nil,
        configFile: String? = nil,
        jumpHost: String? = nil,
        useIPv4: Bool = false,
        useIPv6: Bool = false,
        forwardAgent: Bool = false,
        compressionEnabled: Bool = false,
        sshOptions: [String] = []
    ) {
        self.port = port
        self.identityFile = identityFile
        self.configFile = configFile
        self.jumpHost = jumpHost
        self.useIPv4 = useIPv4
        self.useIPv6 = useIPv6
        self.forwardAgent = forwardAgent
        self.compressionEnabled = compressionEnabled
        self.sshOptions = sshOptions
    }

    /// Default empty options — uses ssh/ssh_config defaults entirely.
    static let `default` = SSHConnectionOptions()

    /// True if the `-o key=...` option list already contains an override
    /// for `key` (case-insensitive). Used by SSHCommandBuilder to avoid
    /// emitting duplicate flags when the caller has set their own.
    func hasOption(key: String) -> Bool {
        let needle = key.lowercased() + "="
        for entry in sshOptions {
            let trimmed = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix(needle) { return true }
        }
        return false
    }
}
