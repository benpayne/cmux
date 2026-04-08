// ConnectionState.swift
// State machine for a single `RemoteConnection` (SSH master) lifetime.
//
// Part of feature 708-remote-workspace-ssh.
//
// Valid transitions:
//     disconnected → connecting → connected → disconnected
//                 ↘          ↘ failed ← /
//     connected → failed (drop / health check failure)

import Foundation

/// Current lifecycle state of a `RemoteConnection`.
enum ConnectionState: Equatable, Hashable {
    /// No master process. The default resting state.
    case disconnected

    /// `ssh -M -fnNT ...` has been spawned but has not yet completed
    /// authentication / socket setup.
    case connecting

    /// Master is authenticated, control socket is live, and commands
    /// can be dispatched via `ssh -S <sock>`.
    case connected

    /// The master either failed to start, failed authentication, or
    /// dropped mid-session. Carries a short reason suitable for display.
    case failed(reason: String)

    /// True while the state is live enough to run commands against.
    var isLive: Bool {
        if case .connected = self { return true }
        return false
    }

    /// True for "the user probably wants to act on this" — failed or
    /// disconnected states that offer a reconnect affordance.
    var isActionable: Bool {
        switch self {
        case .disconnected, .failed:
            return true
        case .connecting, .connected:
            return false
        }
    }

    /// Short label for display purposes.
    var shortLabel: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    /// Validation for the state-machine diagram above. Returns true if
    /// the transition from `self` to `next` is allowed. Implementations
    /// should treat disallowed transitions as no-ops with a debug log.
    func canTransition(to next: ConnectionState) -> Bool {
        switch (self, next) {
        case (.disconnected, .connecting),
             (.connecting, .connected),
             (.connecting, .failed),
             (.connected, .disconnected),
             (.connected, .failed),
             (.failed, .connecting),
             (.failed, .disconnected),
             (.disconnected, .disconnected),
             (.failed, .failed):
            return true
        default:
            return false
        }
    }
}
