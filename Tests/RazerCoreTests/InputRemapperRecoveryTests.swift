import XCTest
@testable import RazerCore

final class InputRemapperRecoveryTests: XCTestCase {
    private func mappedProfile(
        _ pairs: [PhysicalControl: ButtonAction] = [.leftClick: .mouseButton(.right)]
    ) -> MouseProfile {
        var profile = MouseProfile(name: "Test", dpiStages: [800], activeStage: 1, pollingRateHz: 1000)
        for (control, action) in pairs {
            profile.buttonMappings[control] = action
        }
        return profile
    }

    private func seedHold(
        _ remapper: InputRemapper,
        control: PhysicalControl = .leftClick,
        target: MouseButtonTarget = .right
    ) {
        remapper.seedRemappedHold(control: control, target: target)
        XCTAssertEqual(Set(remapper.heldMouseTargets()), [target])
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
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .pause)

        remapper.pause()
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
    }

    func testStopReleasesHeldOutputsBeforeTeardown() {
        let remapper = InputRemapper()
        seedHold(remapper, control: .sideButton1, target: .left)

        remapper.stop()
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .stop)

        remapper.stop()
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
    }

    func testTapDisableReleasesHeldOutputsThenAllowsReenable() {
        let remapper = InputRemapper()
        seedHold(remapper)

        remapper.recoverAfterTapDisable()
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .tapDisable)

        remapper.recoverAfterTapDisable()
        // Second recovery still notifies, but posts no additional ups.
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .tapDisable)
    }

    func testTapDisableNotifiesEvenWhenNoButtonsAreHeld() {
        let remapper = InputRemapper()
        var notified: [HeldOutputRecoveryReason] = []
        remapper.callbacks.onHeldOutputsReleased = { notified.append($0) }

        remapper.recoverAfterTapDisable()

        XCTAssertEqual(notified, [.tapDisable])
        XCTAssertEqual(remapper.lastRecoveryReason(), .tapDisable)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 0)
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
    }

    func testProfileReplacementReleasesHeldOutputs() {
        let remapper = InputRemapper()
        seedHold(remapper)

        var next = mappedProfile([.leftClick: .mouseButton(.left)])
        next.name = "Next"
        remapper.updateProfile(next)

        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .profileReplacement)

        remapper.updateProfile(next)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
    }

    func testPermissionLossReleasesHeldOutputs() {
        let remapper = InputRemapper()
        seedHold(remapper, control: .rightClick, target: .left)

        remapper.handlePermissionLoss()
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertFalse(remapper.isRunning)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .permissionLoss)

        remapper.handlePermissionLoss()
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
    }

    func testPauseTransitionNeverLeavesHoldsWhilePaused() {
        let remapper = InputRemapper()
        remapper.updateProfile(mappedProfile())

        var observedPausedWithHolds = false
        let failureLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 400) { _ in
            remapper.resume()
            _ = remapper.processMappedButtonDown(.leftClick)
            remapper.pause()
            let snapshot = remapper.recoveryStateSnapshot()
            if snapshot.isPaused && !snapshot.heldTargets.isEmpty {
                failureLock.lock()
                observedPausedWithHolds = true
                failureLock.unlock()
            }
        }

        XCTAssertFalse(
            observedPausedWithHolds,
            "Pause must clear holds and set isPaused in one critical section"
        )
        let final = remapper.recoveryStateSnapshot()
        XCTAssertTrue(final.isPaused)
        XCTAssertTrue(final.heldTargets.isEmpty)
    }

    func testProfileReplacementClearsHoldsBeforeNewMappingTakesEffect() {
        let remapper = InputRemapper()
        remapper.updateProfile(mappedProfile([.leftClick: .mouseButton(.right)]))
        seedHold(remapper)

        var next = mappedProfile([.leftClick: .mouseButton(.left)])
        next.name = "Swapped"
        remapper.updateProfile(next)

        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        remapper.resume()
        XCTAssertEqual(
            remapper.processMappedButtonDown(.leftClick),
            .postMouse(.left, isDown: true)
        )
    }

    func testProfileReplacementPostsUpsBeforeExposingNewMapping() {
        let remapper = InputRemapper()
        remapper.updateProfile(mappedProfile([.leftClick: .mouseButton(.right)]))
        seedHold(remapper)

        var next = mappedProfile([.leftClick: .mouseButton(.left)])
        next.name = "Swapped"

        var actionAtProbe: ButtonAction?
        var upsAtProbe = 0
        remapper.recoveryOrderingProbe = {
            upsAtProbe = remapper.releasedSyntheticMouseUpCount()
            actionAtProbe = remapper.activeButtonAction(for: .leftClick)
        }

        remapper.updateProfile(next)

        XCTAssertEqual(upsAtProbe, 1, "Synthetic ups must post before the new mapping is visible")
        XCTAssertEqual(
            actionAtProbe,
            .mouseButton(.right),
            "Old mapping must remain visible until ups are published"
        )
        XCTAssertEqual(remapper.activeButtonAction(for: .leftClick), .mouseButton(.left))
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
    }

    func testProfileTransitionRejectsDownsUntilNewMappingIsLive() {
        let remapper = InputRemapper()
        remapper.updateProfile(mappedProfile([.leftClick: .mouseButton(.right)]))
        seedHold(remapper)

        var next = mappedProfile([.leftClick: .mouseButton(.left)])
        next.name = "Swapped"

        var downDuringTransition: RemapButtonOutcome?
        var suppressedDuringTransition = false
        remapper.recoveryOrderingProbe = {
            suppressedDuringTransition = remapper.isSuppressingMappedDowns()
            downDuringTransition = remapper.processMappedButtonDown(.leftClick)
            XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
            XCTAssertEqual(remapper.activeButtonAction(for: .leftClick), .mouseButton(.right))
        }

        remapper.updateProfile(next)

        XCTAssertTrue(suppressedDuringTransition)
        XCTAssertNil(
            downDuringTransition,
            "Old mapping must not accept downs while replacement ups are publishing"
        )
        XCTAssertFalse(remapper.isSuppressingMappedDowns())
        XCTAssertEqual(
            remapper.processMappedButtonDown(.leftClick),
            .postMouse(.left, isDown: true)
        )
    }

    func testTapDisablePostsUpsBeforeReenablingTap() {
        let remapper = InputRemapper()
        seedHold(remapper)

        var order: [String] = []
        remapper.recoveryOrderingProbe = {
            order.append("afterUps")
            XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
            XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        }
        remapper.recoveryFinalizeProbe = {
            order.append("afterReenable")
        }

        remapper.recoverAfterTapDisable()

        XCTAssertEqual(order, ["afterUps", "afterReenable"])
        XCTAssertEqual(remapper.lastRecoveryReason(), .tapDisable)
    }
}
