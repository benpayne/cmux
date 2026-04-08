// SSHConfigParser.swift
// Parse ~/.ssh/config and return real Host entries (non-wildcard, with
// at least one of Hostname/User/Port set).
//
// Part of feature 708-remote-workspace-ssh. Implements the filter
// behavior described in FR-023.
//
// This parser intentionally implements only the subset of ssh_config
// directives cmux cares about. It does not replicate OpenSSH's full
// matching/inheritance behavior — it produces a flat list of Host
// entries that passed the filter.

import Foundation

/// A Host entry parsed from ssh_config.
struct ParsedSSHHost: Equatable, Hashable {
    /// The Host pattern (alias) as written in the config file.
    let pattern: String
    /// Explicit `Hostname` directive, if set.
    let hostname: String?
    /// Explicit `User` directive, if set.
    let user: String?
    /// Explicit `Port` directive, if set.
    let port: Int?
    /// Explicit `IdentityFile` directive, if set.
    let identityFile: String?
    /// Explicit `ProxyJump` directive, if set.
    let proxyJump: String?

    /// Convert to a cmux destination string the user would type.
    /// Prefers the pattern alias (since OpenSSH will resolve it); falls
    /// back to `user@hostname` if the pattern isn't a straightforward
    /// alias.
    var suggestedDestination: String {
        // The pattern as-written is what the user sees in their ssh_config
        // and is the most stable identity.
        return pattern
    }
}

enum SSHConfigParser {
    /// Default location of the user's ssh config.
    static var defaultPath: String {
        return (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    /// Parse the file at `path` (or the default `~/.ssh/config`) and
    /// return the filtered list of hosts. Returns an empty array if the
    /// file does not exist or cannot be read.
    static func parse(path: String? = nil) -> [ParsedSSHHost] {
        let target = path ?? defaultPath
        guard let raw = try? String(contentsOfFile: target, encoding: .utf8) else {
            return []
        }
        return parse(source: raw, includeBasePath: (target as NSString).deletingLastPathComponent)
    }

    /// Parse config text directly. `includeBasePath` is used to resolve
    /// relative `Include` directives. Returns hosts in declaration order
    /// after applying the FR-023 filter.
    static func parse(source: String, includeBasePath: String = NSHomeDirectory() + "/.ssh") -> [ParsedSSHHost] {
        var entries: [ParsedSSHHost] = []
        var current: HostBuilder?
        var visitedIncludes: Set<String> = []

        func flushCurrent() {
            if let built = current?.build() {
                entries.append(built)
            }
            current = nil
        }

        parseLines(source: source, includeBasePath: includeBasePath, visitedIncludes: &visitedIncludes) { directive, value, patterns in
            if let patterns = patterns {
                // Host directive — flush any in-progress host and start
                // fresh. Multi-pattern Host lines create one entry per
                // pattern sharing the same directives.
                flushCurrent()
                // Only keep non-wildcard patterns; drop the entry
                // entirely if every pattern is a wildcard.
                let realPatterns = patterns.filter { !$0.contains("*") && !$0.contains("?") }
                if let first = realPatterns.first {
                    current = HostBuilder(pattern: first)
                    // For secondary patterns on the same line, we'd need
                    // to emit multiple entries with identical contents.
                    // To keep this simple, we treat them as aliases of
                    // the first pattern and skip the duplicates.
                }
            } else if let directive = directive, let value = value, var builder = current {
                builder.apply(directive: directive, value: value)
                current = builder
            }
        }

        flushCurrent()

        // Apply the FR-023 filter: at least one of Hostname, User, or Port.
        return entries.filter { entry in
            entry.hostname != nil || entry.user != nil || entry.port != nil
        }
    }

    /// Low-level line walker. Handles comments, blank lines, `Host`
    /// blocks, and `Include` directives. Invokes `lineHandler` with
    /// either:
    ///   - a new Host block (directive = nil, value = nil, patterns = [...])
    ///   - an in-block directive (directive = "Hostname", value = "foo", patterns = nil)
    private static func parseLines(
        source: String,
        includeBasePath: String,
        visitedIncludes: inout Set<String>,
        lineHandler: (_ directive: String?, _ value: String?, _ patterns: [String]?) -> Void
    ) {
        for rawLine in source.components(separatedBy: .newlines) {
            // Strip comments (# to end of line) and trim whitespace.
            var line = rawLine
            if let hashIndex = line.firstIndex(of: "#") {
                line = String(line[..<hashIndex])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Split into keyword and rest-of-line.
            guard let firstSpace = line.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else {
                continue
            }
            let keyword = String(line[..<firstSpace]).lowercased()
            let rest = String(line[line.index(after: firstSpace)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))

            switch keyword {
            case "host":
                let patterns = rest
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                lineHandler(nil, nil, patterns)

            case "include":
                // Recursive include. Support `~` and relative paths.
                let resolved = expandTilde(rest, relativeTo: includeBasePath)
                if !visitedIncludes.contains(resolved) {
                    visitedIncludes.insert(resolved)
                    if let included = try? String(contentsOfFile: resolved, encoding: .utf8) {
                        parseLines(
                            source: included,
                            includeBasePath: (resolved as NSString).deletingLastPathComponent,
                            visitedIncludes: &visitedIncludes,
                            lineHandler: lineHandler
                        )
                    }
                }

            default:
                lineHandler(keyword, rest, nil)
            }
        }
    }

    private static func expandTilde(_ path: String, relativeTo basePath: String) -> String {
        if path.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        if path.hasPrefix("/") {
            return path
        }
        return (basePath as NSString).appendingPathComponent(path)
    }
}

/// Mutable builder used while parsing a single Host block.
private struct HostBuilder {
    let pattern: String
    var hostname: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?

    init(pattern: String) {
        self.pattern = pattern
    }

    mutating func apply(directive: String, value: String) {
        switch directive {
        case "hostname":
            hostname = value
        case "user":
            user = value
        case "port":
            port = Int(value)
        case "identityfile":
            identityFile = value
        case "proxyjump":
            proxyJump = value
        default:
            break
        }
    }

    func build() -> ParsedSSHHost {
        return ParsedSSHHost(
            pattern: pattern,
            hostname: hostname,
            user: user,
            port: port,
            identityFile: identityFile,
            proxyJump: proxyJump
        )
    }
}
