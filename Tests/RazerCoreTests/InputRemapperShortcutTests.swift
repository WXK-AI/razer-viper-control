import CoreGraphics
import XCTest
@testable import RazerCore

final class InputRemapperShortcutTests: XCTestCase {
    private struct PostedKey: Equatable {
        let keyCode: UInt16
        let keyDown: Bool
        let flags: UInt64
    }

    private func installKeyboardProbe(_ remapper: InputRemapper) -> () -> [PostedKey] {
        let lock = NSLock()
        var posted: [PostedKey] = []
        remapper.postKeyboardEvent = { keyCode, keyDown, flags in
            lock.lock()
            posted.append(PostedKey(keyCode: keyCode, keyDown: keyDown, flags: flags.rawValue))
            lock.unlock()
        }
        return {
            lock.lock()
            defer { lock.unlock() }
            return posted
        }
    }

    func testKeyboardShortcutPostsKeyDownThenKeyUpInOrder() {
        let remapper = InputRemapper()
        let snapshot = installKeyboardProbe(remapper)
        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: 0x0010_0000) // ⌘A

        remapper.executeOneShotAction(.keyboardShortcut(shortcut), callbacks: .init())

        let posted = snapshot()
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[0].keyCode, 0)
        XCTAssertTrue(posted[0].keyDown)
        XCTAssertEqual(posted[1].keyCode, 0)
        XCTAssertFalse(posted[1].keyDown)
    }

    func testKeyboardShortcutKeyDownCarriesModifiersKeyUpClearsFlags() {
        let remapper = InputRemapper()
        let snapshot = installKeyboardProbe(remapper)
        let modifiers: UInt64 = 0x0004_0000 | 0x0008_0000 | 0x0010_0000 // ⌃⌥⌘
        let shortcut = KeyboardShortcut(keyCode: 15, modifierFlags: modifiers)

        remapper.executeOneShotAction(.keyboardShortcut(shortcut), callbacks: .init())

        let posted = snapshot()
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[0].flags, modifiers, "Key-down must carry shortcut modifiers")
        XCTAssertEqual(posted[1].flags, 0, "Key-up must clear flags so modifiers cannot stick")
    }

    func testKeyboardShortcutSkippedEntirelyWhilePaused() {
        let remapper = InputRemapper()
        let snapshot = installKeyboardProbe(remapper)
        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: 0x0010_0000)

        remapper.pause()
        remapper.executeOneShotAction(.keyboardShortcut(shortcut), callbacks: .init())

        XCTAssertTrue(snapshot().isEmpty, "Neither key-down nor key-up may post while paused")
    }

    func testKeyboardShortcutPostsAfterResume() {
        let remapper = InputRemapper()
        let snapshot = installKeyboardProbe(remapper)
        let shortcut = KeyboardShortcut(keyCode: 2, modifierFlags: 0x0002_0000)

        remapper.pause()
        remapper.executeOneShotAction(.keyboardShortcut(shortcut), callbacks: .init())
        XCTAssertTrue(snapshot().isEmpty)

        XCTAssertTrue(remapper.resume())
        remapper.executeOneShotAction(.keyboardShortcut(shortcut), callbacks: .init())

        let posted = snapshot()
        XCTAssertEqual(posted.count, 2)
        XCTAssertTrue(posted[0].keyDown)
        XCTAssertEqual(posted[0].flags, 0x0002_0000)
        XCTAssertFalse(posted[1].keyDown)
        XCTAssertEqual(posted[1].flags, 0)
    }

    func testScrollMappedKeyboardShortcutUsesSamePostingRules() throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ) else {
            throw XCTSkip("CGEvent scroll construction unavailable in this environment")
        }

        let shortcut = KeyboardShortcut(keyCode: 7, modifierFlags: 0x0010_0000)
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .keyboardShortcut(shortcut)
        var profile = MouseProfile(name: "Shortcut Scroll", dpiStages: [800], activeStage: 1, pollingRateHz: 1000)
        profile.remapperEnabled = true
        profile.buttonMappings = mappings

        let remapper = InputRemapper()
        remapper.updateProfile(profile)
        let snapshot = installKeyboardProbe(remapper)

        XCTAssertNil(remapper.processScrollWheelEvent(event))
        let posted = snapshot()
        XCTAssertEqual(posted.count, 2)
        XCTAssertTrue(posted[0].keyDown)
        XCTAssertEqual(posted[0].flags, 0x0010_0000)
        XCTAssertFalse(posted[1].keyDown)
        XCTAssertEqual(posted[1].flags, 0)
    }
}
