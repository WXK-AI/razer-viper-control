import XCTest
@testable import RazerCore

final class InputRemapperRecoveryTests: XCTestCase {
    private func seedHold(_ remapper: InputRemapper, control: PhysicalControl = .leftClick, target: MouseButtonTarget = .right) {
        remapper.seedRemappedHoldForTesting(control: control, target: target)
        XCTAssertEqual(Set(remapper.heldMouseTargetsForTesting()), [target])
    }

    func testReleaseAllHeldOutputsIsIdempotentAndUnique() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = PhysicalControl.defaultButtonMappings().merging([
            .leftClick: .mouseButton(.right),
            .sideButton1: .mouseButton(.left),
            .sideButton2: .mouseButton(.left)
        ]) { _, new in new }

        _ = session.handle(control: .leftClick, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton1, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton2, kind: .down, mappings: map)

        let first = session.releaseAllHeldOutputs()
        XCTAssertEqual(Set(first), Set([MouseButtonTarget.right, .left]))
        XCTAssertTrue(session.snapshotHeldMouseTargets().isEmpty)
        XCTAssertFalse(session.isHolding(.leftClick))

        let second = session.releaseAllHeldOutputs()
        XCTAssertTrue(second.isEmpty)
    }

    func testPauseReleasesHeldOutputsIdempotently() {
        let remapper = InputRemapper()
        seedHold(remapper)

        remapper.pause()
        XCTAssertTrue(remapper.heldMouseTargetsForTesting().isEmpty)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
        XCTAssertEqual(remapper.lastHeldOutputRecovery, .pause)

        remapper.pause()
        XCTAssertTrue(remapper.heldMouseTargetsForTesting().isEmpty)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
    }

    func testStopReleasesHeldOutputsBeforeTeardown() {
        let remapper = InputRemapper()
        seedHold(remapper, control: .sideButton1, target: .left)

        remapper.stop()
        XCTAssertTrue(remapper.heldMouseTargetsForTesting().isEmpty)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
        XCTAssertEqual(remapper.lastHeldOutputRecovery, .stop)

        remapper.stop()
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
    }

    func testTapDisableReleasesHeldOutputsThenAllowsReenable() {
        let remapper = InputRemapper()
        seedHold(remapper)

        remapper.recoverAfterTapDisableForTesting()
        XCTAssertTrue(remapper.heldMouseTargetsForTesting().isEmpty)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
        XCTAssertEqual(remapper.lastHeldOutputRecovery, .tapDisable)

        remapper.recoverAfterTapDisableForTesting()
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
    }

    func testProfileReplacementReleasesHeldOutputs() {
        let remapper = InputRemapper()
        seedHold(remapper)

        var next = MouseProfile(name: "Next", dpiStages: [800], activeStage: 1, pollingRateHz: 1000)
        next.buttonMappings[.leftClick] = .mouseButton(.left)
        remapper.updateProfile(next)

        XCTAssertTrue(remapper.heldMouseTargetsForTesting().isEmpty)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
        XCTAssertEqual(remapper.lastHeldOutputRecovery, .profileReplacement)

        remapper.updateProfile(next)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
    }

    func testPermissionLossReleasesHeldOutputs() {
        let remapper = InputRemapper()
        seedHold(remapper, control: .rightClick, target: .left)

        remapper.handlePermissionLoss()
        XCTAssertTrue(remapper.heldMouseTargetsForTesting().isEmpty)
        XCTAssertFalse(remapper.isRunning)
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
        XCTAssertEqual(remapper.lastHeldOutputRecovery, .permissionLoss)

        remapper.handlePermissionLoss()
        XCTAssertEqual(remapper.testingSyntheticMouseUpCount, 1)
    }
}
