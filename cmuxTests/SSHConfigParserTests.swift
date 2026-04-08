import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SSHConfigParserTests: XCTestCase {

    // MARK: - Empty / trivial

    func testParseEmptyString() {
        let hosts = SSHConfigParser.parse(source: "", includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0)
    }

    func testParseOnlyComments() {
        let config = """
        # a comment
        # another comment
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0)
    }

    func testParseBlankLines() {
        let config = "\n\n\n"
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0)
    }

    // MARK: - Single host parsing

    func testParseSingleHostWithHostname() {
        let config = """
        Host prod-1
            Hostname prod-1.example.com
            User deploy
            Port 22
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        let host = hosts[0]
        XCTAssertEqual(host.pattern, "prod-1")
        XCTAssertEqual(host.hostname, "prod-1.example.com")
        XCTAssertEqual(host.user, "deploy")
        XCTAssertEqual(host.port, 22)
    }

    func testParseHostWithOnlyHostname() {
        let config = """
        Host shortname
            Hostname longname.example.com
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "longname.example.com")
        XCTAssertNil(hosts[0].user)
        XCTAssertNil(hosts[0].port)
    }

    func testParseHostWithOnlyUser() {
        let config = """
        Host example
            User deploy
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].user, "deploy")
    }

    func testParseHostWithOnlyPort() {
        let config = """
        Host example
            Port 2222
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].port, 2222)
    }

    func testParseHostWithIdentityFile() {
        let config = """
        Host example
            Hostname example.com
            IdentityFile ~/.ssh/special_key
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].identityFile, "~/.ssh/special_key")
    }

    func testParseHostWithProxyJump() {
        let config = """
        Host internal
            Hostname internal.corp
            ProxyJump bastion
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].proxyJump, "bastion")
    }

    // MARK: - Filter behavior (FR-023)

    func testWildcardHostExcluded() {
        let config = """
        Host *
            User deploy
            IdentityFile ~/.ssh/id_rsa
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0, "Wildcard-only Host entries must be filtered out")
    }

    func testQuestionMarkWildcardExcluded() {
        let config = """
        Host host?
            Hostname foo.com
            User deploy
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0)
    }

    func testEntryWithoutRequiredDirectivesExcluded() {
        // No Hostname, no User, no Port — should be filtered out.
        let config = """
        Host no-config
            IdentityFile ~/.ssh/id_rsa
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0,
                       "Entries lacking Hostname/User/Port should be filtered out")
    }

    func testBareHostEntryExcluded() {
        // Declaration with no directives at all.
        let config = "Host bare"
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 0)
    }

    // MARK: - Multiple hosts

    func testParseMultipleHosts() {
        let config = """
        Host prod-1
            Hostname prod-1.example.com
            User deploy

        Host staging
            Hostname staging.example.com
            User deploy
            Port 2222

        Host *
            IdentityFile ~/.ssh/id_rsa
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts[0].pattern, "prod-1")
        XCTAssertEqual(hosts[1].pattern, "staging")
        XCTAssertEqual(hosts[1].port, 2222)
    }

    func testDeclarationOrderPreserved() {
        let config = """
        Host alpha
            Hostname a.com
        Host beta
            Hostname b.com
        Host gamma
            Hostname c.com
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.map { $0.pattern }, ["alpha", "beta", "gamma"])
    }

    // MARK: - Parsing edge cases

    func testIgnoresInlineComments() {
        let config = """
        Host prod-1  # this is a comment
            Hostname prod-1.example.com  # another
            User deploy
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].pattern, "prod-1")
        XCTAssertEqual(hosts[0].hostname, "prod-1.example.com")
    }

    func testCaseInsensitiveDirectives() {
        let config = """
        Host example
            HOSTNAME example.com
            user deploy
            PORT 22
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, 22)
    }

    func testEqualsSyntax() {
        // ssh_config allows `Keyword=value` in addition to `Keyword value`.
        let config = """
        Host example
            Hostname=example.com
            User=deploy
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
    }

    func testMalformedPortIgnored() {
        let config = """
        Host example
            Hostname example.com
            User deploy
            Port notanumber
        """
        let hosts = SSHConfigParser.parse(source: config, includeBasePath: "/tmp")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertNil(hosts[0].port)  // malformed → nil, but host stays because User is set
    }

    // MARK: - suggestedDestination

    func testSuggestedDestinationUsesPattern() {
        let host = ParsedSSHHost(
            pattern: "prod-1",
            hostname: "prod-1.example.com",
            user: "deploy",
            port: nil,
            identityFile: nil,
            proxyJump: nil
        )
        XCTAssertEqual(host.suggestedDestination, "prod-1")
    }
}
