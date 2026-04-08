// HostRegistry.swift
// JSON-based persistence for saved remote hosts.
//
// Part of feature 708-remote-workspace-ssh (Phase 8, US6).
// Stores at ~/Library/Application Support/cmux/remote-hosts.json.
// Credentials (passwords, key passphrases) are NEVER persisted —
// those live in the user's ssh-agent / keychain outside cmux.
//
// Atomic writes via temp-file + rename. Reads are tolerant of missing
// or malformed files (return empty array).

import Foundation

/// Persistent collection of saved `RemoteHost` records.
struct HostRegistry: Codable, Equatable {
    /// Schema version for future migrations.
    var version: Int
    /// Saved hosts (transient ones are excluded at write time).
    var hosts: [RemoteHost]

    static let currentVersion: Int = 1

    init(version: Int = Self.currentVersion, hosts: [RemoteHost] = []) {
        self.version = version
        self.hosts = hosts
    }
}

/// Errors surfaced by the persistence layer.
enum HostRegistryError: Error, LocalizedError {
    case ioFailed(String)
    case corruptData(String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .ioFailed(let msg): return "I/O failed: \(msg)"
        case .corruptData(let msg): return "Registry file is corrupt: \(msg)"
        case .unsupportedVersion(let v): return "Unsupported registry version: \(v)"
        }
    }
}

/// Reads and writes the saved host registry.
struct HostRegistryStore {
    /// Absolute path to the registry file.
    let fileURL: URL

    /// Default store at `~/Library/Application Support/cmux/remote-hosts.json`.
    static var `default`: HostRegistryStore {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let cmuxDir = supportDir.appendingPathComponent("cmux", isDirectory: true)
        return HostRegistryStore(fileURL: cmuxDir.appendingPathComponent("remote-hosts.json"))
    }

    /// Initialize with an explicit file path — used by tests with a
    /// temporary directory.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Load

    /// Load the registry from disk. Returns an empty registry if the
    /// file does not exist. Throws on corrupt JSON or unsupported
    /// version.
    func load() throws -> HostRegistry {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HostRegistry()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HostRegistryError.ioFailed(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let registry: HostRegistry
        do {
            registry = try decoder.decode(HostRegistry.self, from: data)
        } catch {
            throw HostRegistryError.corruptData(error.localizedDescription)
        }
        if registry.version > HostRegistry.currentVersion {
            throw HostRegistryError.unsupportedVersion(registry.version)
        }
        return registry
    }

    /// Load with tolerance — returns an empty registry on any failure.
    /// Used by the manager's init path where startup MUST succeed
    /// even if the saved file is corrupt (we log the error in a real
    /// implementation; here we just silently fall back).
    func loadTolerant() -> HostRegistry {
        (try? load()) ?? HostRegistry()
    }

    // MARK: - Save

    /// Save the given hosts list to disk atomically. Filters out any
    /// `transient: true` hosts automatically so callers can pass the
    /// manager's full host list without pre-filtering.
    ///
    /// Writes to a temporary sibling file, then renames into place —
    /// if the process is interrupted mid-write the previous file is
    /// untouched.
    func save(hosts: [RemoteHost]) throws {
        let saved = hosts.filter { !$0.transient }
        let registry = HostRegistry(hosts: saved)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(registry)
        } catch {
            throw HostRegistryError.corruptData(error.localizedDescription)
        }

        // Ensure parent directory exists.
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tempURL = parent.appendingPathComponent(".remote-hosts.json.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw HostRegistryError.ioFailed("write temp: \(error.localizedDescription)")
        }

        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            // Fallback path if replaceItemAt fails (target doesn't exist yet, etc.).
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw HostRegistryError.ioFailed("rename: \(error.localizedDescription)")
            }
        }
    }
}
