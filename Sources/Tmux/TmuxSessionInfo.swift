// TmuxSessionInfo.swift
// Data model for a single tmux session as reported by `tmux list-sessions`.
//
// Part of feature 707-tmux-control-panel.

import Foundation

/// Metadata for a single tmux session.
///
/// Populated from `tmux list-sessions -F` output. Identity is by `name`
/// (tmux enforces session-name uniqueness on the local server).
struct TmuxSessionInfo: Equatable, Hashable, Codable, Identifiable {
    /// Session name. Unique on the local tmux server.
    let name: String

    /// Number of windows in the session.
    let windowCount: Int

    /// Session creation timestamp.
    let createdAt: Date

    /// True if at least one client is currently attached.
    let isAttached: Bool

    /// Number of clients attached to this session.
    let clientCount: Int

    /// Identifier for SwiftUI ForEach. Sessions are uniquely keyed by name.
    var id: String { name }
}

extension TmuxSessionInfo {
    /// Parse a single line of `tmux list-sessions -F` output using the format string
    /// `#{session_name}|#{session_windows}|#{session_created}|#{session_attached}|#{session_activity}`.
    ///
    /// Returns nil if the line cannot be parsed (wrong field count, non-numeric fields, etc.).
    static func parse(line: String) -> TmuxSessionInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Split into exactly 5 fields (name may not contain `|` since tmux session names cannot contain it).
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else { return nil }

        let name = parts[0]
        guard !name.isEmpty else { return nil }

        guard let windowCount = Int(parts[1]) else { return nil }
        guard let createdEpoch = TimeInterval(parts[2]) else { return nil }
        guard let attachedFlag = Int(parts[3]) else { return nil }
        guard let clientCount = Int(parts[4]) else { return nil }

        return TmuxSessionInfo(
            name: name,
            windowCount: windowCount,
            createdAt: Date(timeIntervalSince1970: createdEpoch),
            isAttached: attachedFlag != 0,
            clientCount: clientCount
        )
    }

    /// Parse the full multi-line output of `tmux list-sessions -F`.
    /// Lines that fail to parse are silently skipped.
    static func parse(output: String) -> [TmuxSessionInfo] {
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Self.parse(line: String($0)) }
    }
}
