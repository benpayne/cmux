import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SSHCommandBuilderTests: XCTestCase {

    // MARK: - commandExec mode

    func testCommandExec_minimalArgs() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "echo hi",
            options: .default,
            mode: .commandExec
        )
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(containsOption(args, "ConnectTimeout=6"))
        XCTAssertTrue(containsOption(args, "BatchMode=yes"))
        XCTAssertTrue(containsOption(args, "ControlMaster=no"))
        XCTAssertTrue(containsOption(args, "StrictHostKeyChecking=accept-new"))
        XCTAssertEqual(args.suffix(2), ["user@host", "echo hi"])
    }

    func testCommandExec_withPortAndIdentity() {
        let opts = SSHConnectionOptions(port: 2222, identityFile: "/tmp/id_rsa")
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        XCTAssertTrue(contains(args, "-p"))
        XCTAssertTrue(contains(args, "2222"))
        XCTAssertTrue(contains(args, "-i"))
        XCTAssertTrue(contains(args, "/tmp/id_rsa"))
    }

    func testCommandExec_withJumpHost() {
        let opts = SSHConnectionOptions(jumpHost: "bastion")
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        XCTAssertTrue(contains(args, "-J"))
        XCTAssertTrue(contains(args, "bastion"))
    }

    func testCommandExec_withConfigFile() {
        let opts = SSHConnectionOptions(configFile: "/etc/ssh_config")
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        XCTAssertTrue(contains(args, "-F"))
        XCTAssertTrue(contains(args, "/etc/ssh_config"))
    }

    func testCommandExec_ipv4Forces() {
        let opts = SSHConnectionOptions(useIPv4: true)
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        XCTAssertTrue(args.contains("-4"))
        XCTAssertFalse(args.contains("-6"))
    }

    func testCommandExec_ipv6Forces() {
        let opts = SSHConnectionOptions(useIPv6: true)
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        XCTAssertTrue(args.contains("-6"))
        XCTAssertFalse(args.contains("-4"))
    }

    func testCommandExec_forwardAgentAndCompression() {
        let opts = SSHConnectionOptions(forwardAgent: true, compressionEnabled: true)
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        XCTAssertTrue(args.contains("-A"))
        XCTAssertTrue(args.contains("-C"))
    }

    func testCommandExec_extraOptionsAppearLast() {
        let opts = SSHConnectionOptions(sshOptions: ["CustomKey=value"])
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        // Find the last "-o" flag before the destination and confirm
        // it's the custom one.
        guard let destIdx = args.firstIndex(of: "host") else {
            XCTFail("destination not in args")
            return
        }
        let before = Array(args[..<destIdx])
        XCTAssertTrue(containsOption(before, "CustomKey=value"))
    }

    func testCommandExec_userStrictHostKeyCheckingOverridesDefault() {
        let opts = SSHConnectionOptions(sshOptions: ["StrictHostKeyChecking=no"])
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "host",
            command: "ls",
            options: opts,
            mode: .commandExec
        )
        // Default accept-new should NOT appear.
        XCTAssertFalse(containsOption(args, "StrictHostKeyChecking=accept-new"))
        // User's override should.
        XCTAssertTrue(containsOption(args, "StrictHostKeyChecking=no"))
    }

    // MARK: - openMaster mode

    func testOpenMaster_hasMasterFlags() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: nil,
            options: .default,
            mode: .openMaster(controlSocketPath: "/tmp/sock")
        )
        XCTAssertTrue(args.contains("-M"))
        XCTAssertTrue(args.contains("-f"))
        XCTAssertTrue(args.contains("-n"))
        XCTAssertTrue(args.contains("-N"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(args.contains("-S"))
        XCTAssertTrue(args.contains("/tmp/sock"))
    }

    func testOpenMaster_noBatchMode() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: nil,
            options: .default,
            mode: .openMaster(controlSocketPath: "/tmp/sock")
        )
        XCTAssertFalse(containsOption(args, "BatchMode=yes"))
    }

    func testOpenMaster_controlMasterYes() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: nil,
            options: .default,
            mode: .openMaster(controlSocketPath: "/tmp/sock")
        )
        XCTAssertTrue(containsOption(args, "ControlMaster=yes"))
    }

    func testOpenMaster_longerConnectTimeout() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: nil,
            options: .default,
            mode: .openMaster(controlSocketPath: "/tmp/sock")
        )
        XCTAssertTrue(containsOption(args, "ConnectTimeout=15"))
        XCTAssertFalse(containsOption(args, "ConnectTimeout=6"))
    }

    // MARK: - useExistingMaster mode

    func testUseExistingMaster_hasSocketFlag() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "tmux ls",
            options: .default,
            mode: .useExistingMaster(controlSocketPath: "/tmp/sock")
        )
        XCTAssertTrue(args.contains("-S"))
        XCTAssertTrue(args.contains("/tmp/sock"))
        XCTAssertTrue(args.contains("-T"))
    }

    func testUseExistingMaster_keepsBatchMode() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "tmux ls",
            options: .default,
            mode: .useExistingMaster(controlSocketPath: "/tmp/sock")
        )
        XCTAssertTrue(containsOption(args, "BatchMode=yes"))
    }

    // MARK: - interactiveAttach mode

    func testInteractiveAttach_hasPTYFlag() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "tmux attach",
            options: .default,
            mode: .interactiveAttach(controlSocketPath: "/tmp/sock")
        )
        XCTAssertTrue(args.contains("-t"))
        XCTAssertTrue(args.contains("-S"))
        XCTAssertTrue(args.contains("/tmp/sock"))
        XCTAssertFalse(args.contains("-T"))
    }

    func testInteractiveAttach_noBatchMode() {
        let args = SSHCommandBuilder.buildSSHArguments(
            destination: "user@host",
            command: "tmux attach",
            options: .default,
            mode: .interactiveAttach(controlSocketPath: "/tmp/sock")
        )
        XCTAssertFalse(containsOption(args, "BatchMode=yes"))
    }

    // MARK: - SCP builder

    func testSCP_usesCapitalP() {
        let opts = SSHConnectionOptions(port: 2222)
        let args = SSHCommandBuilder.buildSCPArguments(
            localPath: "/tmp/file",
            remoteDestination: "user@host",
            remotePath: "/remote/path",
            options: opts,
            controlPath: nil
        )
        XCTAssertTrue(args.contains("-P"))
        XCTAssertTrue(args.contains("2222"))
        XCTAssertFalse(args.contains("-p"))
    }

    func testSCP_withControlPath() {
        let args = SSHCommandBuilder.buildSCPArguments(
            localPath: "/tmp/file",
            remoteDestination: "user@host",
            remotePath: "/remote/path",
            options: .default,
            controlPath: "/tmp/master.sock"
        )
        XCTAssertTrue(containsOption(args, "ControlPath=/tmp/master.sock"))
    }

    func testSCP_controlPathSkippedIfUserSetIt() {
        let opts = SSHConnectionOptions(sshOptions: ["ControlPath=/user/sock"])
        let args = SSHCommandBuilder.buildSCPArguments(
            localPath: "/tmp/file",
            remoteDestination: "user@host",
            remotePath: "/remote/path",
            options: opts,
            controlPath: "/tmp/master.sock"
        )
        // Only the user's override should appear.
        XCTAssertFalse(containsOption(args, "ControlPath=/tmp/master.sock"))
        XCTAssertTrue(containsOption(args, "ControlPath=/user/sock"))
    }

    func testSCP_endsWithLocalAndRemote() {
        let args = SSHCommandBuilder.buildSCPArguments(
            localPath: "/tmp/file",
            remoteDestination: "user@host",
            remotePath: "/remote/path",
            options: .default,
            controlPath: nil
        )
        XCTAssertEqual(args.suffix(2), ["/tmp/file", "user@host:/remote/path"])
    }

    // MARK: - Helpers

    /// Returns true if args contains `-o <value>` where the `-o` and
    /// value are adjacent.
    private func containsOption(_ args: [String], _ value: String) -> Bool {
        for (index, arg) in args.enumerated() where arg == "-o" {
            if index + 1 < args.count, args[index + 1] == value { return true }
        }
        return false
    }

    private func contains(_ args: [String], _ value: String) -> Bool {
        args.contains(value)
    }
}
