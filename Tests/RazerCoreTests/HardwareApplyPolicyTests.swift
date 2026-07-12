import XCTest
@testable import RazerCore

final class HardwareApplyPolicyTests: XCTestCase {
    private func baseProfile() -> MouseProfile {
        MouseProfile(
            name: "Base",
            dpiStages: [800, 1600, 3200],
            activeStage: 2,
            pollingRateHz: 1000,
            autoReapplyEnabled: true,
            buttonMappings: PhysicalControl.defaultButtonMappings(),
            wheelSettings: WheelSettings(
                hardware: HardwareWheelSettings(
                    scrollMode: .tactile,
                    accelerationEnabled: false,
                    smartReelEnabled: false
                ),
                software: .default
            ),
            remapperEnabled: true
        )
    }

    func testNameChangeLeavesHardwareSettingsEqual() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.name = "Renamed"
        XCTAssertEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testButtonMappingChangeLeavesHardwareSettingsEqual() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.buttonMappings[.sideButton1] = .nextDPIStage
        XCTAssertEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testSoftwareWheelChangeLeavesHardwareSettingsEqual() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.wheelSettings.software.verticalSpeedMultiplier = 2.5
        profile.wheelSettings.software.scrollDirection = .inverted
        profile.wheelSettings.software.wheelUpAction = .disabled
        XCTAssertEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testAutoReapplyToggleLeavesHardwareSettingsEqual() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.autoReapplyEnabled.toggle()
        XCTAssertEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testRemapperToggleLeavesHardwareSettingsEqual() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.remapperEnabled.toggle()
        XCTAssertEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testDPIStagesChangeAltersHardwareSettings() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.dpiStages = [400, 800, 1600]
        XCTAssertNotEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testActiveStageChangeAltersHardwareSettings() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.activeStage = 1
        XCTAssertNotEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testPollingChangeAltersHardwareSettings() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.pollingRateHz = 500
        XCTAssertNotEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testHardwareWheelChangeAltersHardwareSettings() {
        var profile = baseProfile()
        let before = HardwareProfileSettings(profile: profile)
        profile.wheelSettings.hardware.scrollMode = .freeSpin
        XCTAssertNotEqual(before, HardwareProfileSettings(profile: profile))
    }

    func testLatestHardwareApplyGateOnlyLatestTokenIsCurrent() {
        let gate = LatestHardwareApplyGate()
        let first = gate.issue()
        let second = gate.issue()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testLatestHardwareApplyGateIsThreadSafeUnderContention() {
        let gate = LatestHardwareApplyGate()
        let iterations = 1_000
        let group = DispatchGroup()
        let lock = NSLock()
        var tokens = [UInt64]()
        tokens.reserveCapacity(iterations)

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let token = gate.issue()
                lock.lock()
                tokens.append(token)
                lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        lock.lock()
        let snapshot = tokens
        lock.unlock()

        let unique = Set(snapshot)
        XCTAssertEqual(unique.count, iterations)
        let latest = snapshot.max()!
        XCTAssertTrue(gate.isCurrent(latest))
        for token in unique where token != latest {
            XCTAssertFalse(gate.isCurrent(token))
        }
    }

    func testReconnectObservationDoesNotSupersedeNewerExplicitApply() {
        let gate = LatestHardwareApplyGate()
        let generationAtSchedule = gate.currentGeneration()
        let explicitToken = gate.issue()
        XCTAssertFalse(
            gate.isCurrent(generationAtSchedule),
            "Reconnect must skip after a newer Apply claims the gate"
        )
        XCTAssertTrue(gate.isCurrent(explicitToken))
    }

    func testReconnectProceedsWhenNoNewerApplyIssued() {
        let gate = LatestHardwareApplyGate()
        _ = gate.issue()
        let generationAtSchedule = gate.currentGeneration()
        XCTAssertTrue(gate.isCurrent(generationAtSchedule))
        XCTAssertEqual(generationAtSchedule, gate.currentGeneration())
    }

    func testBaselineTracksExactAppliedSnapshotNotLaterSelection() {
        var appliedProfile = baseProfile()
        appliedProfile.pollingRateHz = 1000
        let recorded = HardwareProfileSettings(profile: appliedProfile)

        var laterSelected = appliedProfile
        laterSelected.pollingRateHz = 500
        laterSelected.name = "Edited after apply"

        XCTAssertEqual(recorded.pollingRateHz, 1000)
        XCTAssertTrue(
            HardwarePendingDetector.hasPendingChanges(profile: laterSelected, lastApplied: recorded)
        )
        XCTAssertFalse(
            HardwarePendingDetector.hasPendingChanges(profile: appliedProfile, lastApplied: recorded)
        )
    }

    func testIncompleteApplyDoesNotRecordBaseline() {
        let candidate = HardwareProfileSettings(profile: baseProfile())
        XCTAssertNil(
            HardwareApplyBaseline.settingsToRecord(didComplete: false, applied: candidate)
        )
        XCTAssertNil(
            HardwareApplyBaseline.settingsToRecord(didComplete: true, applied: nil)
        )
        XCTAssertEqual(
            HardwareApplyBaseline.settingsToRecord(didComplete: true, applied: candidate),
            candidate
        )
    }

    func testUnknownWheelReadbackDoesNotRecordBaseline() {
        let candidate = HardwareProfileSettings(profile: baseProfile())
        // AppModel only records through settingsToRecord after a completed apply;
        // thrown unknownWheelReadback never reaches didComplete: true.
        let didComplete = false
        XCTAssertNil(
            HardwareApplyBaseline.settingsToRecord(didComplete: didComplete, applied: candidate)
        )
    }

    func testHardwareChangesPendingWhenLastAppliedDiffers() {
        let profile = baseProfile()
        let applied = HardwareProfileSettings(profile: profile)
        var edited = profile
        edited.pollingRateHz = 500
        XCTAssertTrue(
            HardwarePendingDetector.hasPendingChanges(profile: edited, lastApplied: applied)
        )
    }

    func testHardwareChangesNotPendingWhenEqualToLastApplied() {
        let profile = baseProfile()
        let applied = HardwareProfileSettings(profile: profile)
        XCTAssertFalse(
            HardwarePendingDetector.hasPendingChanges(profile: profile, lastApplied: applied)
        )
    }

    func testHardwareChangesNotPendingWithoutProfileOrBaseline() {
        XCTAssertFalse(HardwarePendingDetector.hasPendingChanges(profile: nil, lastApplied: nil))
        XCTAssertFalse(
            HardwarePendingDetector.hasPendingChanges(profile: baseProfile(), lastApplied: nil)
        )
    }

    func testHardwareApplyReasonsAreDistinct() {
        let reasons: [HardwareApplyReason] = [
            .explicitApply, .profileSelection, .dpiCycle, .reconnect
        ]
        XCTAssertEqual(Set(reasons.map(\.rawValue)).count, 4)
    }
}
