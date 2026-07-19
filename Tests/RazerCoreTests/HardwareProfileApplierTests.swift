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
        yStages: [Int]? = nil,
        polling: Int? = 1000
    ) -> DeviceState {
        DeviceState(
            dpiX: dpi,
            dpiY: dpi,
            activeDPIStage: activeStage,
            dpiStages: stages,
            dpiStagesY: yStages,
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

    func testPlanSetsPollingWhenCurrentPollingIsUnknownEvenFor1000HzTarget() {
        let plan = HardwareProfileApplier.plan(
            current: state(polling: nil),
            target: profile(polling: 1000),
            wheelCurrent: .init(),
            capability: .init()
        )

        XCTAssertTrue(plan.setPolling)
    }

    func testPlanSetsDPIStagesWhenOnlyYAxisDiffers() {
        let plan = HardwareProfileApplier.plan(
            current: state(stages: [800, 1600], yStages: [800, 3200]),
            target: profile(dpiStages: [800, 1600]),
            wheelCurrent: .init(),
            capability: .init()
        )

        XCTAssertTrue(plan.setDPIStages)
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

    func testUnknownRequestedWheelCapabilityReturnsUnverifiedForEmptyPlan() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state()

        let result = try HardwareProfileApplier.apply(
            target: profile(wheel: .init(scrollMode: .freeSpin)),
            using: mutator,
            capability: .init(scrollMode: .unknown)
        )

        XCTAssertEqual(result, .unverified(mismatches: [.scrollMode]))
        XCTAssertTrue(mutator.writtenFields.isEmpty)
    }

    func testUnknownRequestedWheelCapabilityDoesNotBlockOtherWrites() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)

        let result = try HardwareProfileApplier.apply(
            target: profile(
                polling: 500,
                wheel: .init(scrollMode: .freeSpin)
            ),
            using: mutator,
            capability: .init(scrollMode: .unknown)
        )

        XCTAssertEqual(result, .unverified(mismatches: [.scrollMode]))
        XCTAssertEqual(mutator.setPollingCalls, 1)
        XCTAssertEqual(mutator.setScrollModeCalls, 0)
    }

    func testNotSupportedRequestedWheelCapabilityIsExcludedFromVerification() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state()

        let result = try HardwareProfileApplier.apply(
            target: profile(wheel: .init(scrollMode: .freeSpin)),
            using: mutator,
            capability: .init(scrollMode: .notSupported)
        )

        XCTAssertEqual(result, .verified)
        XCTAssertTrue(mutator.writtenFields.isEmpty)
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

    func testPlanSkipsSupportedWheelWhenReadbackMissing() {
        let plan = HardwareProfileApplier.plan(
            current: state(),
            target: profile(wheel: .init(
                scrollMode: .freeSpin,
                accelerationEnabled: true,
                smartReelEnabled: true
            )),
            wheelCurrent: .init(), // supported capability but failed/unknown readback → nils
            capability: .init(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            )
        )
        XCTAssertFalse(plan.setScrollMode)
        XCTAssertFalse(plan.setAcceleration)
        XCTAssertFalse(plan.setSmartReel)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(
            HardwareProfileApplier.unresolvedRequestedWheelFields(
                target: profile(wheel: .init(
                    scrollMode: .freeSpin,
                    accelerationEnabled: true,
                    smartReelEnabled: true
                )),
                wheelCurrent: .init(),
                capability: .init(
                    scrollMode: .supported,
                    acceleration: .supported,
                    smartReel: .supported
                )
            ),
            [.scrollMode, .acceleration, .smartReel]
        )
    }

    func testSupportedWheelWithFailedReadbackProducesZeroWrites() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
        mutator.wheel = .init() // nils = failed readback
        mutator.simulateFailedWheelReadback = true
        let target = profile(
            dpiStages: [800, 1600],
            activeStage: 1,
            polling: 1000,
            wheel: .init(scrollMode: .freeSpin, accelerationEnabled: true, smartReelEnabled: true)
        )
        XCTAssertThrowsError(
            try HardwareProfileApplier.apply(
                target: target,
                using: mutator,
                capability: .init(
                    scrollMode: .supported,
                    acceleration: .supported,
                    smartReel: .supported
                )
            )
        ) { error in
            guard case let HardwareApplyError.unknownWheelReadback(fields) = error else {
                return XCTFail("Expected unknownWheelReadback, got \(error)")
            }
            XCTAssertEqual(fields, [.scrollMode, .acceleration, .smartReel])
        }
        XCTAssertEqual(mutator.setScrollModeCalls, 0)
        XCTAssertEqual(mutator.setAccelerationCalls, 0)
        XCTAssertEqual(mutator.setSmartReelCalls, 0)
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
        XCTAssertEqual(mutator.setDPICalls, 0)
        XCTAssertEqual(mutator.setPollingCalls, 0)
    }

    func testUnknownWheelReadbackFailsClosedBeforeDifferingDPIWrites() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
        mutator.simulateFailedWheelReadback = true
        let target = profile(
            dpiStages: [400, 800],
            activeStage: 2,
            polling: 500,
            wheel: .init(scrollMode: .freeSpin)
        )
        XCTAssertThrowsError(
            try HardwareProfileApplier.apply(
                target: target,
                using: mutator,
                capability: .init(scrollMode: .supported)
            )
        ) { error in
            guard case let HardwareApplyError.unknownWheelReadback(fields) = error else {
                return XCTFail("Expected unknownWheelReadback, got \(error)")
            }
            XCTAssertEqual(fields, [.scrollMode])
        }
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
        XCTAssertEqual(mutator.setDPICalls, 0)
        XCTAssertEqual(mutator.setPollingCalls, 0)
        XCTAssertEqual(mutator.setScrollModeCalls, 0)
    }

    func testApplyAbortsAfterReadbackWhenSuperseded() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
        mutator.wheel = .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false)
        mutator.onAfterReadState = {
            _ = gate.issue()
        }
        let target = profile(
            dpiStages: [800, 1600],
            activeStage: 1,
            polling: 500,
            wheel: .init(scrollMode: .freeSpin, accelerationEnabled: false, smartReelEnabled: false)
        )
        let result = try HardwareProfileApplier.apply(
            target: target,
            using: mutator,
            capability: .init(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            ),
            isStillCurrent: { gate.isCurrent(token) }
        )
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
        XCTAssertEqual(mutator.setDPICalls, 0)
        XCTAssertEqual(mutator.setPollingCalls, 0)
        XCTAssertEqual(mutator.setScrollModeCalls, 0)
        XCTAssertEqual(mutator.setAccelerationCalls, 0)
        XCTAssertEqual(mutator.setSmartReelCalls, 0)
    }

    func testApplyAbortsAfterWheelReadbackWhenSuperseded() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
        mutator.wheel = .init(scrollMode: .tactile, accelerationEnabled: false, smartReelEnabled: false)
        mutator.onAfterWheelReadback = {
            _ = gate.issue()
        }
        let target = profile(polling: 500)
        let result = try HardwareProfileApplier.apply(
            target: target,
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setPollingCalls, 0)
    }

    func testMatchingPostWriteReadbackReturnsVerifiedWithoutRetry() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init()
        )

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(mutator.setPollingCalls, 1)
        XCTAssertEqual(mutator.readStateCalls, 2)
    }

    func testSingleReadableMismatchRetriesOnlyAffectedField() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, stages: [1600], polling: 1000)
        mutator.ignoredPollingWritesRemaining = 1

        let result = try HardwareProfileApplier.apply(
            target: profile(dpiStages: [1600], polling: 500),
            using: mutator,
            capability: .init()
        )

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(mutator.setDPICalls, 1)
        XCTAssertEqual(mutator.setPollingCalls, 2)
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
    }

    func testMultipleReadableMismatchesRetryOnlyAffectedFields() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(dpi: 800, stages: [1600], polling: 1000)
        mutator.wheel = .init(scrollMode: .tactile)
        mutator.ignoredDPIWritesRemaining = 1
        mutator.ignoredPollingWritesRemaining = 1
        mutator.ignoredScrollModeWritesRemaining = 1

        let result = try HardwareProfileApplier.apply(
            target: profile(
                dpiStages: [1600],
                polling: 500,
                wheel: .init(scrollMode: .freeSpin)
            ),
            using: mutator,
            capability: .init(scrollMode: .supported)
        )

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(mutator.setDPICalls, 2)
        XCTAssertEqual(mutator.setPollingCalls, 2)
        XCTAssertEqual(mutator.setScrollModeCalls, 2)
        XCTAssertEqual(mutator.setDPIStagesCalls, 0)
    }

    func testPersistentMismatchWritesAtMostTwiceAndReturnsUnverified() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.ignoredPollingWritesRemaining = 10

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init()
        )

        XCTAssertEqual(result, .unverified(mismatches: [.pollingRate]))
        XCTAssertEqual(mutator.setPollingCalls, 2)
        XCTAssertEqual(mutator.readStateCalls, 3)
    }

    func testUnknownPollingAfterWriteIsUnverifiedWithoutBlindRetry() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: nil)
        mutator.ignoredPollingWritesRemaining = 10

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 1000),
            using: mutator,
            capability: .init()
        )

        XCTAssertEqual(result, .unverified(mismatches: [.pollingRate]))
        XCTAssertEqual(mutator.setPollingCalls, 1)
        XCTAssertEqual(mutator.readStateCalls, 2)
    }

    func testUnknownWheelPostWriteReadbackIsUnverifiedWithoutUnsafeRetry() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state()
        mutator.wheel = .init(scrollMode: .tactile)
        mutator.unknownWheelReadbackCalls = [2]

        let result = try HardwareProfileApplier.apply(
            target: profile(wheel: .init(scrollMode: .freeSpin)),
            using: mutator,
            capability: .init(scrollMode: .supported)
        )

        XCTAssertEqual(result, .unverified(mismatches: [.scrollMode]))
        XCTAssertEqual(mutator.setScrollModeCalls, 1)
        XCTAssertEqual(mutator.readWheelCalls, 2)
    }

    func testPostWriteReadbackErrorPropagates() {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.readStateErrors[2] = .timeout

        XCTAssertThrowsError(
            try HardwareProfileApplier.apply(
                target: profile(polling: 500),
                using: mutator,
                capability: .init()
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .timeout)
        }
        XCTAssertEqual(mutator.setPollingCalls, 1)
    }

    func testSelectiveRetryErrorPropagates() {
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.ignoredPollingWritesRemaining = 1
        mutator.pollingWriteErrors[2] = .deviceBusy

        XCTAssertThrowsError(
            try HardwareProfileApplier.apply(
                target: profile(polling: 500),
                using: mutator,
                capability: .init()
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .deviceBusy)
        }
        XCTAssertEqual(mutator.setPollingCalls, 2)
    }

    func testStaleInitialReadErrorReturnsSuperseded() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.readStateErrors[1] = .timeout
        mutator.onAfterReadState = { _ = gate.issue() }

        let result = try HardwareProfileApplier.apply(
            target: profile(),
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )

        XCTAssertEqual(result, .superseded)
    }

    func testStaleVerificationReadErrorReturnsSuperseded() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.readStateErrors[2] = .timeout
        mutator.onAfterReadState = {
            if mutator.readStateCalls == 2 { _ = gate.issue() }
        }

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setPollingCalls, 1)
    }

    func testStaleWriteErrorReturnsSuperseded() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.pollingWriteErrors[1] = .timeout
        mutator.onAfterWrite = { field, call in
            if field == .pollingRate, call == 1 { _ = gate.issue() }
        }

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setPollingCalls, 1)
    }

    func testStaleRetryWriteErrorReturnsSuperseded() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.ignoredPollingWritesRemaining = 1
        mutator.pollingWriteErrors[2] = .timeout
        mutator.onAfterWrite = { field, call in
            if field == .pollingRate, call == 2 { _ = gate.issue() }
        }

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setPollingCalls, 2)
    }

    func testSupersessionAfterEveryCompleteCommandSkipsAllLaterCommands() throws {
        let commandOrder: [HardwareApplyField] = [
            .dpiStages, .dpi, .pollingRate, .scrollMode, .acceleration, .smartReel
        ]

        for supersededField in commandOrder {
            let gate = LatestHardwareApplyGate()
            let token = gate.issue()
            let mutator = RecordingHardwareMutator()
            mutator.state = state(dpi: 800, activeStage: 1, stages: [800, 1600], polling: 1000)
            mutator.wheel = .init(
                scrollMode: .tactile,
                accelerationEnabled: false,
                smartReelEnabled: false
            )
            mutator.onAfterWrite = { field, _ in
                if field == supersededField {
                    _ = gate.issue()
                }
            }

            let result = try HardwareProfileApplier.apply(
                target: profile(
                    dpiStages: [400, 1600],
                    activeStage: 2,
                    polling: 500,
                    wheel: .init(
                        scrollMode: .freeSpin,
                        accelerationEnabled: true,
                        smartReelEnabled: true
                    )
                ),
                using: mutator,
                capability: .init(
                    scrollMode: .supported,
                    acceleration: .supported,
                    smartReel: .supported
                ),
                isStillCurrent: { gate.isCurrent(token) }
            )

            XCTAssertEqual(result, .superseded, "field \(supersededField)")
            let completedCount = commandOrder.firstIndex(of: supersededField)! + 1
            XCTAssertEqual(
                mutator.writtenFields,
                Array(commandOrder.prefix(completedCount)),
                "field \(supersededField)"
            )
            XCTAssertEqual(mutator.readStateCalls, 1, "field \(supersededField)")
        }
    }

    func testSupersessionAfterFinalCommandStopsBeforeVerification() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.onAfterWrite = { field, _ in
            if field == .pollingRate {
                _ = gate.issue()
            }
        }

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setPollingCalls, 1)
        XCTAssertEqual(mutator.readStateCalls, 1)
    }

    func testSupersessionDuringRetryStopsBeforeFinalReadback() throws {
        let gate = LatestHardwareApplyGate()
        let token = gate.issue()
        let mutator = RecordingHardwareMutator()
        mutator.state = state(polling: 1000)
        mutator.ignoredPollingWritesRemaining = 1
        mutator.onAfterWrite = { field, call in
            if field == .pollingRate, call == 2 {
                _ = gate.issue()
            }
        }

        let result = try HardwareProfileApplier.apply(
            target: profile(polling: 500),
            using: mutator,
            capability: .init(),
            isStillCurrent: { gate.isCurrent(token) }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(mutator.setPollingCalls, 2)
        XCTAssertEqual(mutator.readStateCalls, 2)
    }

    func testEmptyPlanRechecksGenerationBeforeReportingVerified() throws {
        let mutator = RecordingHardwareMutator()
        mutator.state = state()
        var checkCount = 0

        let result = try HardwareProfileApplier.apply(
            target: profile(),
            using: mutator,
            capability: .init(),
            isStillCurrent: {
                checkCount += 1
                return checkCount < 4
            }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(mutator.writtenFields.isEmpty)
    }
}

private final class RecordingHardwareMutator: HardwareProfileApplying {
    var state = DeviceState(pollingRateHz: 1000)
    var wheel = HardwareWheelSettings()
    var simulateFailedWheelReadback = false
    var onAfterReadState: (() -> Void)?
    var onAfterWheelReadback: (() -> Void)?
    var onAfterWrite: ((HardwareApplyField, Int) -> Void)?
    var readStateErrors: [Int: RazerCommandError] = [:]
    var pollingWriteErrors: [Int: RazerCommandError] = [:]
    var unknownWheelReadbackCalls: Set<Int> = []
    var ignoredDPIWritesRemaining = 0
    var ignoredPollingWritesRemaining = 0
    var ignoredScrollModeWritesRemaining = 0
    var readStateCalls = 0
    var readWheelCalls = 0
    var writtenFields: [HardwareApplyField] = []
    var setDPIStagesCalls = 0
    var setDPICalls = 0
    var setPollingCalls = 0
    var setScrollModeCalls = 0
    var setAccelerationCalls = 0
    var setSmartReelCalls = 0

    func readState() throws -> DeviceState {
        readStateCalls += 1
        defer { onAfterReadState?() }
        if let error = readStateErrors[readStateCalls] {
            throw error
        }
        return state
    }

    func readWheelHardwareState(capability: WheelHardwareCapability) -> HardwareWheelSettings {
        readWheelCalls += 1
        defer { onAfterWheelReadback?() }
        if simulateFailedWheelReadback || unknownWheelReadbackCalls.contains(readWheelCalls) {
            return HardwareWheelSettings()
        }
        var settings = HardwareWheelSettings()
        if capability.scrollMode == .supported { settings.scrollMode = wheel.scrollMode }
        if capability.acceleration == .supported { settings.accelerationEnabled = wheel.accelerationEnabled }
        if capability.smartReel == .supported { settings.smartReelEnabled = wheel.smartReelEnabled }
        return settings
    }

    func setDPIStages(activeStage: Int, stages: [Int]) throws {
        setDPIStagesCalls += 1
        writtenFields.append(.dpiStages)
        state.activeDPIStage = activeStage
        state.dpiStages = stages
        state.dpiStagesY = stages
        onAfterWrite?(.dpiStages, setDPIStagesCalls)
    }

    func setDPI(_ dpi: Int) throws {
        setDPICalls += 1
        writtenFields.append(.dpi)
        if ignoredDPIWritesRemaining > 0 {
            ignoredDPIWritesRemaining -= 1
        } else {
            state.dpiX = dpi
            state.dpiY = dpi
        }
        onAfterWrite?(.dpi, setDPICalls)
    }

    func setPollingRate(hz: Int) throws {
        setPollingCalls += 1
        writtenFields.append(.pollingRate)
        defer { onAfterWrite?(.pollingRate, setPollingCalls) }
        if let error = pollingWriteErrors[setPollingCalls] {
            throw error
        }
        if ignoredPollingWritesRemaining > 0 {
            ignoredPollingWritesRemaining -= 1
        } else {
            state.pollingRateHz = hz
        }
    }

    func setScrollMode(_ mode: ScrollWheelMode) throws {
        setScrollModeCalls += 1
        writtenFields.append(.scrollMode)
        if ignoredScrollModeWritesRemaining > 0 {
            ignoredScrollModeWritesRemaining -= 1
        } else {
            wheel.scrollMode = mode
        }
        onAfterWrite?(.scrollMode, setScrollModeCalls)
    }

    func setScrollAcceleration(_ enabled: Bool) throws {
        setAccelerationCalls += 1
        writtenFields.append(.acceleration)
        wheel.accelerationEnabled = enabled
        onAfterWrite?(.acceleration, setAccelerationCalls)
    }

    func setScrollSmartReel(_ enabled: Bool) throws {
        setSmartReelCalls += 1
        writtenFields.append(.smartReel)
        wheel.smartReelEnabled = enabled
        onAfterWrite?(.smartReel, setSmartReelCalls)
    }
}
