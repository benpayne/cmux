import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class HostRegistryTests: XCTestCase {

    var tempDir: URL!
    var fileURL: URL!
    var store: HostRegistryStore!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HostRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("remote-hosts.json")
        store = HostRegistryStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        fileURL = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Load behavior

    func testLoadMissingFileReturnsEmpty() throws {
        let registry = try store.load()
        XCTAssertEqual(registry.version, HostRegistry.currentVersion)
        XCTAssertTrue(registry.hosts.isEmpty)
    }

    func testLoadTolerantReturnsEmptyOnMissing() {
        let registry = store.loadTolerant()
        XCTAssertTrue(registry.hosts.isEmpty)
    }

    func testLoadTolerantReturnsEmptyOnCorruptJSON() throws {
        try "not valid json".write(to: fileURL, atomically: true, encoding: .utf8)
        let registry = store.loadTolerant()
        XCTAssertTrue(registry.hosts.isEmpty)
    }

    func testLoadThrowsOnCorruptJSON() throws {
        try "not valid json".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load()) { error in
            guard case HostRegistryError.corruptData = error else {
                XCTFail("Expected corruptData, got \(error)")
                return
            }
        }
    }

    func testLoadThrowsOnUnsupportedVersion() throws {
        let json = """
        { "version": 999, "hosts": [] }
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load()) { error in
            guard case HostRegistryError.unsupportedVersion(let v) = error else {
                XCTFail("Expected unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, 999)
        }
    }

    // MARK: - Save / round-trip

    func testSaveEmpty() throws {
        try store.save(hosts: [])
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveSingleHostRoundTrip() throws {
        let host = RemoteHost(
            alias: "prod-1",
            destination: "deploy@prod-1.example.com",
            sshOptions: .default
        )
        try store.save(hosts: [host])
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.count, 1)
        XCTAssertEqual(loaded.hosts[0].alias, "prod-1")
        XCTAssertEqual(loaded.hosts[0].destination, "deploy@prod-1.example.com")
        XCTAssertEqual(loaded.hosts[0].id, host.id)
    }

    func testSaveMultipleHostsPreservesOrder() throws {
        let hosts = [
            RemoteHost(alias: "alpha", destination: "a@host"),
            RemoteHost(alias: "beta", destination: "b@host"),
            RemoteHost(alias: "gamma", destination: "c@host"),
        ]
        try store.save(hosts: hosts)
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.map { $0.alias }, ["alpha", "beta", "gamma"])
    }

    func testSaveFiltersOutTransientHosts() throws {
        let hosts = [
            RemoteHost(alias: "saved-1", destination: "a@host", transient: false),
            RemoteHost(alias: "tmp-1", destination: "b@host", transient: true),
            RemoteHost(alias: "saved-2", destination: "c@host", transient: false),
            RemoteHost(alias: "tmp-2", destination: "d@host", transient: true),
        ]
        try store.save(hosts: hosts)
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.count, 2)
        XCTAssertEqual(loaded.hosts.map { $0.alias }, ["saved-1", "saved-2"])
        XCTAssertTrue(loaded.hosts.allSatisfy { !$0.transient })
    }

    func testSaveOverwritesExistingFile() throws {
        let firstHosts = [
            RemoteHost(alias: "first", destination: "a@host"),
            RemoteHost(alias: "second", destination: "b@host"),
        ]
        try store.save(hosts: firstHosts)

        let secondHosts = [
            RemoteHost(alias: "only", destination: "c@host"),
        ]
        try store.save(hosts: secondHosts)

        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.count, 1)
        XCTAssertEqual(loaded.hosts[0].alias, "only")
    }

    func testSavePreservesSSHOptions() throws {
        let opts = SSHConnectionOptions(
            port: 2222,
            identityFile: "/tmp/id_rsa",
            jumpHost: "bastion",
            useIPv4: true,
            forwardAgent: true,
            sshOptions: ["LogLevel=ERROR"]
        )
        let host = RemoteHost(
            alias: "configured",
            destination: "user@host",
            sshOptions: opts
        )
        try store.save(hosts: [host])
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.count, 1)
        let loadedOpts = loaded.hosts[0].sshOptions
        XCTAssertEqual(loadedOpts.port, 2222)
        XCTAssertEqual(loadedOpts.identityFile, "/tmp/id_rsa")
        XCTAssertEqual(loadedOpts.jumpHost, "bastion")
        XCTAssertTrue(loadedOpts.useIPv4)
        XCTAssertTrue(loadedOpts.forwardAgent)
        XCTAssertEqual(loadedOpts.sshOptions, ["LogLevel=ERROR"])
    }

    func testSavePreservesTimestamps() throws {
        let addedAt = Date(timeIntervalSince1970: 1700000000)
        let connectedAt = Date(timeIntervalSince1970: 1700001000)
        let host = RemoteHost(
            alias: "timed",
            destination: "user@host",
            addedAt: addedAt,
            lastConnectedAt: connectedAt
        )
        try store.save(hosts: [host])
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.count, 1)
        XCTAssertEqual(loaded.hosts[0].addedAt.timeIntervalSince1970, 1700000000, accuracy: 0.001)
        XCTAssertEqual(loaded.hosts[0].lastConnectedAt?.timeIntervalSince1970 ?? 0, 1700001000, accuracy: 0.001)
    }

    // MARK: - Schema version

    func testSaveWritesCurrentVersion() throws {
        try store.save(hosts: [])
        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, HostRegistry.currentVersion)
    }

    // MARK: - Atomicity

    func testSaveCreatesParentDirectory() throws {
        let nestedURL = tempDir.appendingPathComponent("nested/subdir/remote-hosts.json")
        let nestedStore = HostRegistryStore(fileURL: nestedURL)
        try nestedStore.save(hosts: [RemoteHost(alias: "x", destination: "y@z")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
    }
}
