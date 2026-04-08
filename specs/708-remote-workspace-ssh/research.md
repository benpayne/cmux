# Research: Remote Workspace Mode

**Date**: 2026-04-07  
**Feature**: 708-remote-workspace-ssh

## R1: SSH ControlMaster ownership model

**Decision**: cmux explicitly spawns and owns SSH master processes via `ssh -M -S <sock> -fnNT user@host`. cmux tracks the process and tears it down on quit/disconnect using `ssh -O exit -S <sock>`.

**Rationale**: The clarification decision (Q2: tear down on quit) requires cmux to own the master lifecycle. The alternative — relying on the user's `~/.ssh/config` `ControlMaster=auto` — is simpler but cmux can't deterministically tear down a master it doesn't own. Owning the process also gives us reliable connection-state tracking (process exits = disconnect) and lets us monitor health via `ssh -O check`.

**Alternatives considered**:
- **Rely on user `ControlMaster=auto`**: Simpler but the user has to configure it. Worse, cmux can't tear it down on quit because SSH owns the lifetime via `ControlPersist`. Violates our clarification.
- **Use a third-party Swift SSH library** (NIOSSH, libssh2 bindings): Reinvents what OpenSSH already does, adds dependency surface, doesn't reuse the user's existing key/config setup. Not worth it.
- **Per-command `ssh -o ControlMaster=auto`**: Equivalent to relying on user config. Same lifetime problem.

## R2: Reuse of existing SSH command-builder code

**Decision**: Generalize the SSH-args builder from `Sources/TerminalSSHSessionDetector.swift` (currently a private method `sshArguments(command:)`) into a shared helper that the new `RemoteHostManager` can also use. Keep the existing `DetectedSSHSession` as the data shape for SSH connection options (port, identityFile, configFile, jumpHost, controlPath, useIPv4/v6, forwardAgent, compressionEnabled, sshOptions).

**Rationale**: cmux already has battle-tested code that builds correct SSH command-line invocations, including handling of all the OpenSSH config nuances we need (and that we'd otherwise have to reimplement). The data fields on `DetectedSSHSession` are exactly what `RemoteHost` needs. Avoid duplication by extracting the args builder into a shared utility.

**Alternatives considered**:
- **Reimplement from scratch**: Duplicates a working, tested implementation; risks divergence in escaping, option ordering, etc.
- **Use `DetectedSSHSession` directly for managed hosts**: Wrong scope — that struct represents a *detected* session inside an existing pane. Conflates two different concepts.

## R3: Generalizing TmuxService for remote execution

**Decision**: Introduce a `TmuxTransport` protocol (local + remote impls) that `TmuxService` uses to run commands. The local transport runs `tmux` directly via `Process()`. The remote transport prefixes the command with `ssh -S <sock> <user@host>`. `TmuxService` becomes generic over the transport.

**Rationale**: The tmux feature (707) intentionally structured `TmuxService` to be the single point where tmux subprocess invocation happens. Generalizing it via a small protocol means almost zero churn to the existing parser, polling logic, and UI. The remote transport is a thin wrapper that only changes how the subprocess is launched.

**Alternatives considered**:
- **Subclass `TmuxService`**: Swift's preference is composition over inheritance, and `final class` is the existing pattern.
- **Two parallel services (`LocalTmuxService` / `RemoteTmuxService`) with shared parser code**: More code, more API surface, more places to keep in sync.
- **Function injection (closures)**: Less discoverable than a protocol; harder to mock/test.

## R4: Connection health detection

**Decision**: Two-pronged approach: (a) command-failure feedback — any subprocess that fails with an "ssh: connect" / "broken pipe" / "controlmaster" error transitions the host to disconnected; (b) periodic `ssh -O check -S <sock>` health probe every 30 seconds while the host is connected, to catch silent drops.

**Rationale**: Most disconnections will surface naturally as command failures during normal polling. The periodic check catches the case where the master is quietly dead but no commands are being run (e.g., the sidebar section is hidden so polling is paused). 30s is a reasonable balance between responsiveness and overhead.

**Alternatives considered**:
- **Health probe only, no error detection**: Slower to surface disconnects (up to 30s).
- **Error detection only, no probe**: Misses silent drops when no commands are flowing.
- **Use SSH's `ServerAliveInterval`**: Helps the master itself detect drops, but cmux still needs to know — `ssh -O check` is the explicit signal.

## R5: Persistence format and location

**Decision**: Persist the host registry as a JSON file at `~/Library/Application Support/cmux/remote-hosts.json`. Schema is a versioned array of host definitions: `{ version: 1, hosts: [{ alias, destination, sshOptions, ... }] }`. Credentials are NOT persisted.

**Rationale**: Matches macOS conventions for app user data. A JSON file is simple to read/write, human-editable for debugging, and easy to version. Not using `UserDefaults` because the data is structured and could grow beyond what `UserDefaults` is appropriate for.

**Alternatives considered**:
- **`UserDefaults`**: Possible for small lists but awkward for nested structures, and harder to debug/inspect.
- **SQLite**: Overkill for an array of <50 records.
- **Keychain**: Required for credentials (which we explicitly don't persist), not for host metadata.
- **Re-derive from `~/.ssh/config`**: We could not store anything and just re-read SSH config every launch. But then "removed" hosts come back, and the user has no way to mark a host as "added but hidden."

## R6: Host list source — manual + opt-in import from `~/.ssh/config`

**Decision** (per clarification): The remote section starts empty. Adding a host has two paths in the UI:
1. **Type a destination** — user enters `user@host[:port]` or an SSH config alias.
2. **Import from SSH config** — picker showing parsed Host entries from `~/.ssh/config`. The user selects one or more to add.

The picker reads `~/.ssh/config` lazily when opened, parses Host entries (skipping wildcards like `Host *`), and shows alias + Hostname for each. cmux does not modify the user's SSH config.

**Rationale**: Honors the clarification (no auto-clutter, easy to import). Reading `~/.ssh/config` is well-documented; OpenSSH's format is stable.

**Alternatives considered**:
- **Auto-import everything**: Rejected during clarification (clutter for users with many hosts).
- **Auto-import only `ControlMaster`-using hosts**: Too clever.

## R7: Per-cmux-instance isolation

**Decision**: Control sockets live at `~/Library/Application Support/cmux/ssh/<instance-id>/<host-alias>.sock`. The instance ID is generated per cmux process launch (UUID prefix). On cmux quit, the entire `<instance-id>` directory is removed.

**Rationale**: Two cmux instances running simultaneously each have their own socket directory; no chance of stepping on each other. Per-process directories make orphan cleanup trivial: on launch, scan for directories whose owning process no longer exists and remove them.

**Alternatives considered**:
- **Single shared socket dir**: Race conditions, unclear ownership.
- **PID-based directories**: Stale-PID issues if PIDs are reused after a crash.
- **Random per-host filenames**: Harder to introspect, no clear cleanup story.

## R8: Connection failure recovery and reconnect

**Decision**: When a connection fails or drops, transition the host to `disconnected` state and stop polling. Show a "Reconnect" affordance in the sidebar. No automatic retry — user action is required. (Aligns with FR-013: no auto-reconnect on startup; same principle for mid-session drops.)

**Rationale**: Silent auto-retry hides problems and burns auth events. Putting the user in control matches the rest of cmux's "explicit-action" UX. If the user wants persistent connections, they can rely on something like Mosh (out of scope here).

**Alternatives considered**:
- **Auto-retry with exponential backoff**: Surprises users when their host reconnects unexpectedly; can cause auth-prompt spam if creds expired.
- **Auto-retry once, then give up**: Compromise but adds complexity and edge cases.

## R9: Polling rate control

**Decision**: Poll each visible remote host's tmux state every 5 seconds (vs. 3 seconds for local). Pause polling for any host whose sidebar section is collapsed or off-screen. Cap concurrent poll subprocesses at 4 to prevent thundering-herd against many hosts.

**Rationale**: Remote tmux polling is heavier than local (round-trip latency) and the user is less likely to be actively watching multiple hosts. 5s is a reasonable freshness target. Visibility-gated polling and a concurrency cap prevent CPU/network spikes.

**Alternatives considered**:
- **Same 3s as local**: Too aggressive; user-perceptible network usage with many hosts.
- **Event-driven via `tmux -CC` control mode**: Would give push notifications but requires a long-lived control mode connection per host (heavyweight, complicates lifecycle).
- **Single global poll thread**: Simpler but a slow host blocks fast hosts.

## R10: Authentication UX for non-key auth

**Decision** (default for v1): Delegate password prompts to OpenSSH itself. cmux runs `ssh -M ...` as a child process; if the host needs a password, OpenSSH normally reads it from a TTY. Since cmux is a GUI app without a TTY, OpenSSH falls back to `SSH_ASKPASS` when set. We document that users with password-only hosts should configure an `SSH_ASKPASS` helper (macOS has `ssh-askpass` available via Homebrew).

**Rationale**: Password-only auth is the long tail of v1. Most users have key + agent. Building a custom password-prompt UI in cmux that integrates safely with OpenSSH is significant work and risks credential mishandling. Delegating to the standard mechanism is correct and lets us defer the custom UI to v2 if demand emerges.

**Alternatives considered**:
- **Custom in-app password prompt**: Significant security and UX work; out of scope for v1.
- **Reject password hosts entirely**: Worse UX; we should at least let them work via `SSH_ASKPASS`.
- **Use the user's existing terminal-based ssh prompt**: Doesn't work — cmux is a GUI app, no TTY.

## R11: cmux ssh CLI integration

**Decision**: When `cmux ssh user@host` is invoked, the CLI sends a new V2 method `host.connect_or_get` to the running cmux app with the destination string. The app:
1. Looks for an existing matching managed host.
2. If found, returns the existing connection's identity and reuses it for the new pane.
3. If not found, creates a new managed host (transient, auto-removed when last pane on it closes — unless the user explicitly "saves" it via the sidebar UI).
4. Opens a new pane on that host using the shared master.

**Rationale**: Unifies the existing CLI flow with the new manager without forcing users to pre-add hosts. Transient hosts get cleaned up automatically so casual `cmux ssh` invocations don't pollute the persistent host list.

**Alternatives considered**:
- **Always persist `cmux ssh` invocations**: Pollutes host list with one-off hosts.
- **Never persist**: Users who use `cmux ssh` regularly would have to re-add the host every time.
- **Prompt to save**: Interruptive.

## R12: SwiftUI sidebar reuse from tmux feature

**Decision**: Extend `TmuxSidebarView` (introduced in 707-tmux-control-panel) to render multiple sections — one for "LOCAL" and one for each connected remote host. Refactor the view so it accepts a list of `TmuxSidebarGroup` items rather than reading directly from `TmuxSidebarState.shared`. The grouping logic lives in a higher-level state object.

**Rationale**: Maintains the modular design property of the tmux feature. The sidebar view stays self-contained; ContentView's invocation site doesn't change at all (it still calls `TmuxSidebarSection()` once). All the new complexity is internal to the tmux module.

**Alternatives considered**:
- **Add a separate `RemoteTmuxSidebarSection` view**: Would mean two parallel sidebar sections in ContentView, increasing the integration surface in the big shared file.
- **Refactor to inject state from outside**: Same outcome but more SwiftUI boilerplate.
