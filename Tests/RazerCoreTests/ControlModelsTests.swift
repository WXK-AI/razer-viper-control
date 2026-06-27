import XCTest
@testable import RazerCore

final class ControlModelsTests: XCTestCase {
    func testShortcutDisplayNamesUseMacOSModifierFlags() {
        let commandA = KeyboardShortcut(keyCode: 0, modifierFlags: 0x0010_0000)
        XCTAssertEqual(commandA.displayName, "⌘A")

        let shiftA = KeyboardShortcut(keyCode: 0, modifierFlags: 0x0002_0000)
        XCTAssertEqual(shiftA.displayName, "⇧A")

        let complex = KeyboardShortcut(keyCode: 15, modifierFlags: 0x0004_0000 | 0x0008_0000 | 0x0010_0000)
        XCTAssertEqual(complex.displayName, "⌃⌥⌘R")
    }

    func testOpenURLValidation() {
        XCTAssertNil(ButtonActionValidator.validateOpenURL("https://example.com"))
        XCTAssertEqual(ButtonActionValidator.normalizedOpenURL("  https://example.com/path  "), "https://example.com/path")

        XCTAssertEqual(ButtonActionValidator.validateOpenURL(""), .empty)
        XCTAssertEqual(ButtonActionValidator.validateOpenURL("   "), .empty)
        XCTAssertEqual(ButtonActionValidator.validateOpenURL("ftp://example.com"), .invalidScheme)
        XCTAssertEqual(ButtonActionValidator.validateOpenURL("https://"), .missingHost)
        XCTAssertNil(ButtonActionValidator.normalizedOpenURL("not-a-url"))
    }
}
