import XCTest
import PrototypeSupport

final class LaunchArgumentsTests: XCTestCase {
    private let flags: Set<String> = ["--i-understand-system-audio-will-be-muted"]

    func testEqualsSyntaxAndFlag() throws {
        let parsed = try LaunchArguments([
            "--launch-method=launchservices",
            "--log-path=/private/tmp/test.log",
            "--i-understand-system-audio-will-be-muted"
        ], flags: flags)

        XCTAssertEqual(parsed["--launch-method"], "launchservices")
        XCTAssertEqual(parsed["--log-path"], "/private/tmp/test.log")
        XCTAssertTrue(parsed.contains("--i-understand-system-audio-will-be-muted"))
    }

    func testSeparatedSyntax() throws {
        let parsed = try LaunchArguments(["--launch-method", "launchservices"], flags: flags)
        XCTAssertEqual(parsed["--launch-method"], "launchservices")
    }

    func testMissingValue() {
        XCTAssertThrowsError(try LaunchArguments(["--log-path"], flags: flags)) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, .missingValue("--log-path"))
        }
    }

    func testNextOptionMeansMissingValue() {
        XCTAssertThrowsError(try LaunchArguments(["--log-path", "--launch-method=x"], flags: flags)) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, .missingValue("--log-path"))
        }
    }

    func testEmptyEqualsValue() {
        XCTAssertThrowsError(try LaunchArguments(["--log-path="], flags: flags)) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, .emptyValue("--log-path"))
        }
    }

    func testEmptySeparatedValue() {
        XCTAssertThrowsError(try LaunchArguments(["--log-path", ""], flags: flags)) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, .emptyValue("--log-path"))
        }
    }

    func testMalformedAndDuplicateArguments() {
        XCTAssertThrowsError(try LaunchArguments(["log-path=/tmp/x"], flags: flags)) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, .malformed("log-path=/tmp/x"))
        }
        XCTAssertThrowsError(try LaunchArguments(["--log-path=x", "--log-path", "y"], flags: flags)) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, .duplicate("--log-path"))
        }
    }
}
