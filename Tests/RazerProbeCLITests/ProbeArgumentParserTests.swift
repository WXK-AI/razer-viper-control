import XCTest
@testable import RazerCore

final class ProbeArgumentParserTests: XCTestCase {
    func testHelpWhenNoArgs() throws {
        let options = try ProbeArgumentParser.parse(["RazerProbeCLI"])
        XCTAssertEqual(options.command, .help)
    }

    func testUnknownCommandThrows() {
        XCTAssertThrowsError(try ProbeArgumentParser.parse(["cli", "nope"])) { error in
            XCTAssertEqual(error as? ProbeParseError, .unknownCommand("nope"))
        }
    }

    func testExtraParameterRejected() {
        XCTAssertThrowsError(try ProbeArgumentParser.parse(["cli", "battery", "x"])) { error in
            XCTAssertEqual(error as? ProbeParseError, .extraParameter("x"))
        }
    }

    func testIntegrationParsesIntegers() throws {
        let options = try ProbeArgumentParser.parse(["cli", "integration", "1800", "125"])
        XCTAssertEqual(options.command, .integration)
        XCTAssertEqual(options.temporaryDPI, 1800)
        XCTAssertEqual(options.temporaryPollingHz, 125)
    }

    func testInvalidIntegerRejected() {
        XCTAssertThrowsError(try ProbeArgumentParser.parse(["cli", "integration", "abc"])) { error in
            XCTAssertEqual(error as? ProbeParseError, .invalidInteger("abc"))
        }
    }

    func testNonPositiveCaptureDurationRejected() {
        XCTAssertThrowsError(try ProbeArgumentParser.parse(["cli", "input-capture", "0"])) { error in
            XCTAssertEqual(error as? ProbeParseError, .nonPositiveDuration(0))
        }
    }

    func testInputCaptureParsesSeconds() throws {
        let options = try ProbeArgumentParser.parse(["cli", "input-capture", "7"])
        XCTAssertEqual(options.captureSeconds, 7)
    }
}
