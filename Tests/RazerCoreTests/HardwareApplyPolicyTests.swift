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
        var tokens = [UInt64](repeating: 0, count: iterations)

        for index in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                tokens[index] = gate.issue()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let unique = Set(tokens)
        XCTAssertEqual(unique.count, iterations)
        let latest = tokens.max()!
        XCTAssertTrue(gate.isCurrent(latest))
        for token in unique where token != latest {
            XCTAssertFalse(gate.isCurrent(token))
        }
    }
}
