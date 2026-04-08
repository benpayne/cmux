// RemoteHost.swift
// User-facing identity for a remote machine managed by cmux.
//
// Part of feature 708-remote-workspace-ssh. A `RemoteHost` lives in the
// `HostRegistry` (saved) or as a transient entry created on the fly by
// `cmux ssh`. It does not own a connection — the live master is tracked
// separately by `RemoteConnection` inside `RemoteHostManager`.

import Foundation

/// A user-managed remote host. Persistence layer reads/writes instances
/// of this struct as JSON; credentials are NEVER stored.
struct RemoteHost: Equatable, Hashable, Codable, Identifiable {
    /// Stable unique identifier across renames and reconnects.
    var id: UUID

    /// Display name in the sidebar. User-editable. Must be unique across
    /// saved hosts (not enforced here — enforced at the manager layer).
    var alias: String

    /// SSH destination string (`user@host`, `host`, or an `~/.ssh/config`
    /// alias). Passed verbatim to ssh.
    var destination: String

    /// Additional SSH tunables. Defaults to `.default` if the user wants
    /// vanilla ssh/ssh_config behavior.
    var sshOptions: SSHConnectionOptions

    /// When the user first added this host.
    var addedAt: Date

    /// Last successful master-connect timestamp. nil if never connected.
    var lastConnectedAt: Date?

    /// True for hosts added implicitly via `cmux ssh` (not explicitly
    /// saved). Transient hosts are excluded from persistence and are
    /// auto-removed when their last remote pane closes.
    var transient: Bool

    init(
        id: UUID = UUID(),
        alias: String,
        destination: String,
        sshOptions: SSHConnectionOptions = .default,
        addedAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        transient: Bool = false
    ) {
        self.id = id
        self.alias = alias
        self.destination = destination
        self.sshOptions = sshOptions
        self.addedAt = addedAt
        self.lastConnectedAt = lastConnectedAt
        self.transient = transient
    }

    /// Conservative default alias derived from a destination string.
    /// "deploy@prod-1.example.com:2222" → "prod-1".
    /// Used by `cmux ssh` transient hosts and as the initial suggestion
    /// in the add-host sheet.
    static func defaultAlias(forDestination destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "host" }

        // Strip user@ prefix.
        var remainder = trimmed
        if let atIndex = remainder.firstIndex(of: "@") {
            remainder = String(remainder[remainder.index(after: atIndex)...])
        }
        // Strip :port suffix.
        if let colonIndex = remainder.firstIndex(of: ":") {
            remainder = String(remainder[..<colonIndex])
        }
        // Keep only the first DNS label for a friendly default.
        if let dotIndex = remainder.firstIndex(of: ".") {
            remainder = String(remainder[..<dotIndex])
        }
        let clean = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "host" : clean
    }
}
