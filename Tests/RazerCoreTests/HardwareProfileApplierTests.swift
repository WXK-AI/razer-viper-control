import XCTest
@testable import RazerCore

final class HardwareProfileApplierTests: XCTestCase {
    private func profile(
        dpiStages: [Int] = [800, 1600],
        activeStage: Int = 1,
        polling: Int = 1000,
        wheel: HardwareWheelSettings = .init()
    ) -> MouseProfile {
        MouseProfile(
            name: "Test",
            dpiStages: dpiStages,
            activeStage: activeStage,
            pollingRateHz: polling,
            wheelSettings: WheelSettings(hardware: wheel, software: .default)
        )
    }

    private func state(
        dpi: Int = 800,
        activeStage: Int = 1,
        stages: [Int] = [800, 1600],
        polling: Int = 1000
    ) -> DeviceState {
        DeviceState(
            dpiX: dpi,
            dpiY: dpi,
            activeDPIStage: activeStage,
            dpiStages: stages,
            pollingRateHz: polling
        )
    }

    func testPlanSetsDPIStagesWhenStagesDiffer() {
        let plan = HardwareProfileApplier.plan(
            current: state(stages: [800, 1600]),
            target: profile(dpiStages: [400, 800, 1600]),
            wheelCurrent: .init(),
            capability: .init()
        )
        XCTAssertTrue(plan.setDPIStages)
    }

    func testPlanSetsDPIStagesWhenActiveStageDiffer() {
        let plan = HardwareProfileApplier.plan(
            current: state(activeStage: 1),
            target: profile(activeStage: 2),
            wheelCurrent: .init(),
            capability: .init()
        )
        XCTAssertTrue(plan.setDPIStages)
    }

    func testPlanSetsDPIWhenActiveDPIDiffers() {
        let plan = HardwareProfileApplier.plan(
            current: state(dpi: 800, activeStage: 1, stages: [800, 1600]),
            target: profile(dpiStages: [800, 1600], activeStage: 2),
            wheelCurrent: .init(),
            capability: .init()
        )
        XCTAssertTrue(plan.setDPI)
        XCTAssertTrue(plan.setDPIStages)
    }

    func testPlanSetsPollingWhenDiffer() {
        let plan = HardwareProfileApplier.plan(
            current: state(polling: 1000),
            target: profile(polling: 500),
            wheelCurrent: .init(),
            capability: .init()
        )
        XCTAssertTrue(plan.setPolling)
        XCTAssertFalse(plan.setDPIStages)
        XCTAssertFalse(plan.setDPI)
    }

    func testPlanSetsScrollModeWhenSupportedAndDiffer() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(scrollMode: .freeSpin)),
            wheelCurrent: .init(scrollMode: .tactile),
            capability: .init(scrollMode: .supported)
        )
        XCTAssertTrue(plan.setScrollMode)
    }

    func testPlanSetsAccelerationWhenSupportedAndDiffer() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(accelerationEnabled: true)),
            wheelCurrent: .init(accelerationEnabled: false),
            capability: .init(acceleration: .supported)
        )
        XCTAssertTrue(plan.setAcceleration)
    }

    func testPlanSetsSmartReelWhenSupportedAndDiffer() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(smartReelEnabled: true)),
            wheelCurrent: .init(smartReelEnabled: false),
            capability: .init(smartReel: .supported)
        )
        XCTAssertTrue(plan.setSmartReel)
    }

    func testPlanNeverMutatesNotSupportedWheelFields() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(
                scrollMode: .freeSpin,
                accelerationEnabled: true,
                smartReelEnabled: true
            )),
            wheelCurrent: .init(),
            capability: .init(
                scrollMode: .notSupported,
                acceleration: .notSupported,
                smartReel: .notSupported
            )
        )
        XCTAssertFalse(plan.setScrollMode)
        XCTAssertFalse(plan.setAcceleration)
        XCTAssertFalse(plan.setSmartReel)
    }

    func testPlanNeverMutatesUnknownWheelFields() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(
                scrollMode: .freeSpin,
                accelerationEnabled: true,
                smartReelEnabled: true
            )),
            wheelCurrent: .init(),
            capability: .init(
                scrollMode: .unknown,
                acceleration: .unknown,
                smartReel: .unknown
            )
        )
        XCTAssertFalse(plan.setScrollMode)
        XCTAssertFalse(plan.setAcceleration)
        XCTAssertFalse(plan.setSmartReel)
    }

    func testPlanSkipsWheelWhenRequestedValueNil() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init()),
            wheelCurrent: .init(scrollMode: .tactile, accelerationEnabled: true, smartReelEnabled: true),
            capability: .init(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            )
        )
        XCTAssertFalse(plan.setScrollMode)
        XCTAssertFalse(plan.setAcceleration)
        XCTAssertFalse(plan.setSmartReel)
    }

    func testPlanSkipsWheelWhenValuesAlreadyMatch() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(
                scrollMode: .tactile,
                accelerationEnabled: false,
                smartReelEnabled: true
            )),
            wheelCurrent: .init(
                scrollMode: .tactile,
                accelerationEnabled: false,
                smartReelEnabled: true
            ),
            capability: .init(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            )
        )
        XCTAssertFalse(plan.setScrollMode)
        XCTAssertFalse(plan.setAcceleration)
        XCTAssertFalse(plan.setSmartReel)
    }

    func testEqualProfileProducesEmptyPlan() {
        let target = profile(
            dpiStages: [800, 1600],
            activeStage: 1,
            polling: 1000,
            wheel: .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false)
        )
        let plan = HardwareProfileApplier.plan(
            current: state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000),
            target: target,
            wheelCurrent: .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false),
            capability: .init(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            )
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testFakeMutatorPerformsZeroWritesForEqualProfile() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
        mutator.wheel = .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false)
        let target = profile(
            dpiStages: [800, 1600],
            activeStage: 1,
            polling: 1000,
            wheel: .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false)
        )
        let capability = WheelHardwareCapability(
            scrollMode: .supported,
            acceleration: .supported,
            smartReel: .supported
        )
        try HardwareProfileApplier.apply(
            target: target,
            using: mutator,
            capability: capability
        )
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
        XCTAssertEqual(mutator.setDPICalls, 0)
        XCTAssertEqual(mutator.setPollingCalls, 0)
        XCTAssertEqual(mutator.setScrollModeCalls, 0)
        XCTAssertEqual(mutator.setAccelerationCalls, 0)
        XCTAssertEqual(mutator.setSmartReelCalls, 0)
    }

    func testFakeMutatorWritesOnlyDifferingFields() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
        mutator.wheel = .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false)
        let target = profile(
            dpiStages: [800, 1600],
            activeStage: 1,
            polling: 500,
            wheel: .init(scrollMode: .freeSpin, accelerationEnabled: false, smartReelEnabled: false)
        )
        try HardwareProfileApplier.apply(
            target: target,
            using: mutator,
            capability: .init(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            )
        )
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
        XCTAssertEqual(mutator.setDPICalls, 0)
        XCTAssertEqual(mutator.setPollingCalls, 1)
        XCTAssertEqual(mutator.setScrollModeCalls, 1)
        XCTAssertEqual(mutator.setAccelerationCalls, 0)
        XCTAssertEqual(mutator.setSmartReelCalls, 0)
    }
}

private final class RecordingHardwareMutator: HardwareProfileApplying {
    var state = DeviceState()
    var wheel = HardwareWheelSettings()
    var setDPIStagesCalls = 0
    var setDPICalls = 0
    var setPollingCalls = 0
    var setScrollModeCalls = 0
    var setAccelerationCalls = 0
    var setSmartReelCalls = 0

    func readState() throws -> DeviceState { state }

    func readWheelHardwareState(capability: WheelHardwareCapability) -> HardwareWheelSettings {
        var settings = HardwareWheelSettings()
        if capability.scrollMode == .supported { settings.scrollMode = wheel.scrollMode }
        if capability.acceleration == .supported { settings.accelerationEnabled = wheel.accelerationEnabled }
        if capability.smartReel == .supported { settings.smartReelEnabled = wheel.smartReelEnabled }
        return settings
    }

    func setDPIStages(activeStage: Int, stages: [Int]) throws {
        setDPIStagesCalls += 1
        state.activeDPIStage = activeStage
        state.dpiStages = stages
    }

    func setDPI(_ dpi: Int) throws {
        setDPICalls += 1
        state.dpiX = dpi
        state.dpiY = dpi
    }

    func setPollingRate(hz: Int) throws {
        setPollingCalls += 1
        state.pollingRateHz = hz
    }

    func setScrollMode(_ mode: ScrollWheelMode) throws {
        setScrollModeCalls += 1
        wheel.scrollMode = mode
    }

    func setScrollAcceleration(_ enabled: Bool) throws {
        setAccelerationCalls += 1
        wheel.accelerationEnabled = enabled
    }

    func setScrollSmartReel(_ enabled: Bool) throws {
        setSmartReelCalls += 1
        wheel.smartReelEnabled = enabled
    }
}
