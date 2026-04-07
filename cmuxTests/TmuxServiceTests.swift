import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for `TmuxService` parsing and `TmuxSessionInfo` model.
///
/// These tests intentionally avoid invoking the real `tmux` binary so they
/// can run hermetically in CI and on developer machines.
final class TmuxSessionInfoParsingTests: XCTestCase {

    // MARK: - Single line parsing

    func testParseValidLine_attached() {
        let line = "dev|3|1700000000|1|2"
        let session = TmuxSessionInfo.parse(line: line)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.name, "dev")
        XCTAssertEqual(session?.windowCount, 3)
        XCTAssertEqual(session?.createdAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(session?.isAttached, true)
        XCTAssertEqual(session?.clientCount, 2)
    }

    func testParseValidLine_detached() {
        let line = "prod|1|1699999000|0|0"
        let session = TmuxSessionInfo.parse(line: line)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.name, "prod")
        XCTAssertEqual(session?.isAttached, false)
        XCTAssertEqual(session?.clientCount, 0)
    }

    func testParseLine_emptyName_returnsNil() {
        let line = "|3|1700000000|1|2"
        XCTAssertNil(TmuxSessionInfo.parse(line: line))
    }

    func testParseLine_wrongFieldCount_returnsNil() {
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev|3|1700000000"))
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev"))
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev|3|1700000000|1|2|extra"))
    }

    func testParseLine_nonNumericFields_returnsNil() {
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev|three|1700000000|1|2"))
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev|3|notanumber|1|2"))
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev|3|1700000000|maybe|2"))
        XCTAssertNil(TmuxSessionInfo.parse(line: "dev|3|1700000000|1|nope"))
    }

    func testParseLine_emptyOrWhitespace_returnsNil() {
        XCTAssertNil(TmuxSessionInfo.parse(line: ""))
        XCTAssertNil(TmuxSessionInfo.parse(line: "   "))
        XCTAssertNil(TmuxSessionInfo.parse(line: "\n"))
    }

    func testParseLine_trimsWhitespace() {
        let session = TmuxSessionInfo.parse(line: "  dev|3|1700000000|1|2  \n")
        XCTAssertEqual(session?.name, "dev")
    }

    // MARK: - Multi-line output parsing

    func testParseOutput_multipleSessions() {
        let output = """
        dev|3|1700000000|1|1
        prod|1|1699999000|0|0
        scratch|2|1699998000|0|0
        """
        let sessions = TmuxSessionInfo.parse(output: output)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.map { $0.name }, ["dev", "prod", "scratch"])
    }

    func testParseOutput_emptyString_returnsEmptyArray() {
        XCTAssertEqual(TmuxSessionInfo.parse(output: "").count, 0)
    }

    func testParseOutput_skipsMalformedLines() {
        let output = """
        dev|3|1700000000|1|1
        garbage line that does not parse
        prod|1|1699999000|0|0
        """
        let sessions = TmuxSessionInfo.parse(output: output)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map { $0.name }, ["dev", "prod"])
    }

    func testParseOutput_handlesTrailingNewline() {
        let output = "dev|3|1700000000|1|1\n"
        let sessions = TmuxSessionInfo.parse(output: output)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.name, "dev")
    }

    // MARK: - Equatable / Identifiable

    func testEquatable() {
        let a = TmuxSessionInfo(name: "dev", windowCount: 3,
                                createdAt: Date(timeIntervalSince1970: 100),
                                isAttached: true, clientCount: 1)
        let b = TmuxSessionInfo(name: "dev", windowCount: 3,
                                createdAt: Date(timeIntervalSince1970: 100),
                                isAttached: true, clientCount: 1)
        let c = TmuxSessionInfo(name: "prod", windowCount: 3,
                                createdAt: Date(timeIntervalSince1970: 100),
                                isAttached: true, clientCount: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testIdentifiable_idIsName() {
        let session = TmuxSessionInfo(name: "dev", windowCount: 1,
                                      createdAt: Date(), isAttached: false, clientCount: 0)
        XCTAssertEqual(session.id, "dev")
    }
}

/// Tests for `TmuxService` operations that don't require a live tmux server.
final class TmuxServiceTests: XCTestCase {

    func testAttachCommand_quotesSimpleName() {
        let service = TmuxService()
        let cmd = service.attachCommand(for: "dev")
        XCTAssertTrue(cmd.contains("attach-session"))
        XCTAssertTrue(cmd.contains("'dev'"))
    }

    func testAttachCommand_escapesEmbeddedQuote() {
        let service = TmuxService()
        let cmd = service.attachCommand(for: "weird'name")
        // Embedded single quote must be escaped via the standard
        // close-quote / escaped-quote / reopen-quote idiom.
        XCTAssertTrue(cmd.contains("'weird'\\''name'"))
    }

    func testAttachCommand_handlesSpaces() {
        let service = TmuxService()
        let cmd = service.attachCommand(for: "my session")
        XCTAssertTrue(cmd.contains("'my session'"))
    }
}
