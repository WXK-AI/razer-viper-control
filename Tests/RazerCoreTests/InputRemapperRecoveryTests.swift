import XCTest
@testable import RazerCore

final class InputRemapperRecoveryTests: XCTestCase {
    private func mappedProfile(
        _ pairs: [PhysicalControl: ButtonAction] = [.leftClick: .mouseButton(.right)]
    ) -> MouseProfile {
        var profile = MouseProfile(name: "Test", dpiStages: [800], activeStage: 1, pollingRateHz: 1000)
        profile.remapperEnabled = true
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
        var callbacks = InputRemapper.Callbacks()
        callbacks.onHeldOutputsReleased = { notified.append($0) }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        remapper.recoverAfterTapDisable()

        XCTAssertEqual(notified, [.tapDisable])
        XCTAssertEqual(remapper.lastRecoveryReason(), .tapDisable)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 0)
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
    }

    func testSetCallbacksSucceedsBeforeRunningAndIsReadable() {
        let remapper = InputRemapper()
        var fired = false
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { fired = true }
        XCTAssertTrue(remapper.setCallbacks(callbacks))
        remapper.callbacks.onNextDPIStage?()
        XCTAssertTrue(fired)
    }

    func testPublicStateGettersRemainConsistentUnderConcurrentAccess() {
        let remapper = InputRemapper()
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = {}
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            if index % 3 == 0 {
                remapper.pause()
            } else if index % 3 == 1 {
                _ = remapper.resume()
            } else {
                _ = remapper.isPaused
                _ = remapper.isRunning
                _ = remapper.callbacks
            }
        }

        // Final pause must be visible through the synchronized getter.
        remapper.pause()
        XCTAssertTrue(remapper.isPaused)
        XCTAssertFalse(remapper.isRunning)
        XCTAssertNotNil(remapper.callbacks.onNextDPIStage)
    }

    func testSetCallbacksRejectedWhileRunning() throws {
        let remapper = InputRemapper()
        do {
            try remapper.start()
        } catch {
            throw XCTSkip("Cannot create event tap in this environment: \(error)")
        }
        defer { remapper.stop() }
        XCTAssertTrue(remapper.isRunning)
        XCTAssertFalse(remapper.setCallbacks(InputRemapper.Callbacks()))
    }

    func testResumeReturnsFalseWhileCircuitOpenAndLeavesPaused() {
        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.recoverAfterTapDisable()
        time = 1
        remapper.recoverAfterTapDisable()
        time = 2
        remapper.recoverAfterTapDisable()
        XCTAssertTrue(remapper.isCircuitOpen)
        XCTAssertTrue(remapper.isPaused)

        XCTAssertFalse(remapper.resume())
        XCTAssertTrue(remapper.isPaused, "Resume must leave isPaused true while the circuit is open")

        remapper.resetTapDisableCircuit()
        XCTAssertTrue(remapper.resume())
        XCTAssertFalse(remapper.isPaused)
    }

    func testResumeReturnsTrueWhenNotPausedAndCircuitClosed() {
        let remapper = InputRemapper()
        remapper.pause()
        XCTAssertTrue(remapper.isPaused)
        XCTAssertTrue(remapper.resume())
        XCTAssertFalse(remapper.isPaused)
    }

    func testScrollMappedActionSkippedWhenPaused() throws {
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

        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage
        var profile = MouseProfile(name: "Scroll Pause", dpiStages: [800], activeStage: 1, pollingRateHz: 1000)
        profile.remapperEnabled = true
        profile.buttonMappings = mappings

        let remapper = InputRemapper()
        remapper.updateProfile(profile)
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        remapper.pause()
        let result = processScroll(remapper, event)
        XCTAssertNotNil(result, "Paused scroll must passthrough, not consume")
        XCTAssertEqual(nextDPI, 0)
    }

    func testScrollMappedActionNeverFiresWhilePausedUnderRace() throws {
        let makeScrollEvent: () -> CGEvent? = {
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            )
        }
        guard makeScrollEvent() != nil else {
            throw XCTSkip("CGEvent scroll construction unavailable in this environment")
        }

        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage
        var profile = MouseProfile(name: "Scroll Race", dpiStages: [800], activeStage: 1, pollingRateHz: 1000)
        profile.remapperEnabled = true
        profile.buttonMappings = mappings

        let remapper = InputRemapper()
        remapper.updateProfile(profile)
        let dpiLock = NSLock()
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = {
            dpiLock.lock()
            nextDPI += 1
            dpiLock.unlock()
        }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        // Concurrent resume/scroll/pause stress (no sleeps). After the join, a paused
        // remapper must not fire further scroll-mapped actions.
        DispatchQueue.concurrentPerform(iterations: 400) { _ in
            _ = remapper.resume()
            if let event = makeScrollEvent() {
                _ = remapper.processScrollWheelEvent(event)
            }
            remapper.pause()
        }

        let final = remapper.recoveryStateSnapshot()
        XCTAssertTrue(final.isPaused)
        dpiLock.lock()
        let firesWhileSettling = nextDPI
        dpiLock.unlock()

        if let event = makeScrollEvent() {
            _ = remapper.processScrollWheelEvent(event)
        }
        if let event = makeScrollEvent() {
            _ = remapper.processScrollWheelEvent(event)
        }

        dpiLock.lock()
        let firesAfterPausedScrolls = nextDPI
        dpiLock.unlock()
        XCTAssertEqual(
            firesAfterPausedScrolls,
            firesWhileSettling,
            "Scroll-mapped actions must re-check pause before consuming/posting"
        )
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

    func testThirdRapidTapDisableTripsCircuitReleasesHoldsAndDoesNotReenable() {
        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }

        remapper.recoverAfterTapDisable()
        time = 1
        remapper.recoverAfterTapDisable()
        seedHold(remapper)

        var finalized = false
        remapper.recoveryFinalizeProbe = { finalized = true }
        time = 2
        remapper.recoverAfterTapDisable()

        XCTAssertTrue(remapper.isCircuitOpen)
        XCTAssertTrue(remapper.isPaused)
        XCTAssertFalse(remapper.isRunning)
        XCTAssertTrue(remapper.heldMouseTargets().isEmpty)
        XCTAssertEqual(remapper.releasedSyntheticMouseUpCount(), 1)
        XCTAssertEqual(remapper.lastRecoveryReason(), .tapDisableCircuitOpen)
        XCTAssertFalse(finalized, "A tripped circuit must not re-enable the event tap")
    }

    func testStartThrowsWhileCircuitIsOpen() {
        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.recoverAfterTapDisable()
        time = 1
        remapper.recoverAfterTapDisable()
        time = 2
        remapper.recoverAfterTapDisable()
        XCTAssertTrue(remapper.isCircuitOpen)

        XCTAssertThrowsError(try remapper.start()) { error in
            guard case InputRemapperError.circuitOpen = error else {
                return XCTFail("Expected circuitOpen, got \(error)")
            }
        }
        XCTAssertFalse(remapper.isRunning)

        remapper.resetTapDisableCircuit()
        // start may still fail for missing permissions in CI; circuit must no longer block.
        do {
            try remapper.start()
            remapper.stop()
        } catch let error as InputRemapperError {
            if case .circuitOpen = error {
                XCTFail("Circuit must not block start after reset")
            }
        } catch {
            // Other start failures (permissions/tap) are acceptable in this environment.
        }
    }

    func testOpenAppActionSchedulesWorkspaceOperation() {
        let remapper = InputRemapper()
        var scheduled: [DeferredWorkspaceAction] = []
        remapper.scheduleWorkspaceAction = { action in
            scheduled.append(action)
        }

        remapper.executeOneShotAction(.openApp("/Applications/Test.app"), callbacks: .init())

        XCTAssertEqual(
            scheduled,
            [.openApp(URL(fileURLWithPath: "/Applications/Test.app").standardizedFileURL)]
        )
    }

    /// Converts the remapper's `Unmanaged` result to a managed reference while `event`
    /// is still alive. Never hand a raw `Unmanaged` to an XCTest assertion: the
    /// assertion stringifies its value, and reflecting `Unmanaged` retains the pointer
    /// it holds — which is dangling the moment the source event is released.
    private func processScroll(_ remapper: InputRemapper, _ event: CGEvent) -> CGEvent? {
        let result = remapper.processScrollWheelEvent(event)
        return withExtendedLifetime(event) { result?.takeUnretainedValue() }
    }

}
