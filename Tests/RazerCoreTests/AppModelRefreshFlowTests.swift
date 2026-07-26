import XCTest
@testable import RazerCore

// MARK: - Fakes

private final class FakeCommandClient: DeviceCommandClient, HardwareProfileApplying, @unchecked Sendable {
    let model = MouseModel.viperV3HyperSpeed
    var state: DeviceState
    var readStateErrors: [Error] = []
    var probeReports: [WheelCapabilityProbe.ProbeReport] = []
    private(set) var readStateCount = 0
    private(set) var probeCount = 0
    private(set) var applyMutatorCalls = 0

    init(state: DeviceState = DeviceState(batteryPercent: 80, isCharging: false, dpiX: 800)) {
        self.state = state
    }

    func readState() throws -> DeviceState {
        readStateCount += 1
        if !readStateErrors.isEmpty {
            throw readStateErrors.removeFirst()
        }
        return state
    }

    func probeWheelCapability() -> WheelCapabilityProbe.ProbeReport {
        probeCount += 1
        if !probeReports.isEmpty {
            return probeReports.removeFirst()
        }
        return WheelCapabilityProbe.ProbeReport(
            capability: WheelHardwareCapability(
                scrollMode: .supported,
                acceleration: .supported,
                smartReel: .supported
            )
        )
    }

    func readWheelHardwareState(capability: WheelHardwareCapability) -> HardwareWheelSettings {
        HardwareWheelSettings()
    }

    func setDPIStages(activeStage: Int, stages: [Int]) throws {
        applyMutatorCalls += 1
    }

    func setDPI(_ dpi: Int) throws {
        applyMutatorCalls += 1
    }

    func setPollingRate(hz: Int) throws {
        applyMutatorCalls += 1
    }

    func setScrollMode(_ mode: ScrollWheelMode) throws {
        applyMutatorCalls += 1
    }

    func setScrollAcceleration(_ enabled: Bool) throws {
        applyMutatorCalls += 1
    }

    func setScrollSmartReel(_ enabled: Bool) throws {
        applyMutatorCalls += 1
    }
}

private final class FakeDeviceSession: DeviceSessionProtocol, @unchecked Sendable {
    enum Event: Equatable {
        case connect
        case reconnect
        case disconnect
        case apply
        case retainLifecycle
    }

    private(set) var events: [Event] = []
    private(set) var connectCount = 0
    private(set) var reconnectCount = 0
    private(set) var disconnectCount = 0
    private(set) var applyCount = 0

    var client = FakeCommandClient()
    var connectErrors: [Error] = []
    var reconnectErrors: [Error] = []
    var applyResults: [Result<HardwareApplyResult, Error>] = []
    var isConnectedFlag = false
    var removalMonitoringStatus: DeviceRemovalMonitoringStatus = .active
    var onDeviceRemoved: (() -> Void)?

    /// Deterministic mid-flow hooks (no sleeps).
    var afterConnect: (() -> Void)?
    var beforeApply: (() -> Void)?
    /// Issued inside `apply` after `isStillCurrent` passes, before returning a scripted success.
    var supersedeApplyGate: LatestHardwareApplyGate?

    var isConnected: Bool { isConnectedFlag }

    func connectForRefresh() throws -> any DeviceCommandClient {
        events.append(.connect)
        connectCount += 1
        if !connectErrors.isEmpty {
            throw connectErrors.removeFirst()
        }
        isConnectedFlag = true
        afterConnect?()
        return client
    }

    func reconnectForRefresh() throws -> any DeviceCommandClient {
        events.append(.reconnect)
        reconnectCount += 1
        isConnectedFlag = false
        if !reconnectErrors.isEmpty {
            throw reconnectErrors.removeFirst()
        }
        isConnectedFlag = true
        afterConnect?()
        return client
    }

    func invalidate() {
        events.append(.disconnect)
        disconnectCount += 1
        isConnectedFlag = false
    }

    func disconnect() {
        invalidate()
    }

    @discardableResult
    func retainIfLifecycleCurrent(
        _ gate: DeviceLifecycleGate,
        token: DeviceLifecycleGate.Token
    ) -> Bool {
        events.append(.retainLifecycle)
        guard gate.isCurrentAndAwake(token) else {
            disconnect()
            return false
        }
        return true
    }

    func applyForRefresh(
        profile: MouseProfile,
        to client: any DeviceCommandClient,
        wheelCapability: WheelHardwareCapability?,
        isStillCurrent: @escaping () -> Bool
    ) throws -> HardwareApplyResult {
        events.append(.apply)
        applyCount += 1
        beforeApply?()
        guard isStillCurrent() else {
            return .superseded
        }
        // Mid-apply gate bump: successful work returns, but generation is already stale for publish.
        if let gate = supersedeApplyGate {
            _ = gate.issue()
        }
        if !applyResults.isEmpty {
            return try applyResults.removeFirst().get()
        }
        if let applying = client as? HardwareProfileApplying {
            return try HardwareProfileApplier.apply(
                target: profile,
                using: applying,
                capability: wheelCapability ?? WheelHardwareCapability(),
                isStillCurrent: isStillCurrent
            )
        }
        return .verified
    }
}

// MARK: - Helpers

private func makeProfile(
    name: String = "Test",
    autoReapply: Bool = true,
    wheel: HardwareWheelSettings = HardwareWheelSettings()
) -> MouseProfile {
    var profile = MouseProfile(
        name: name,
        dpiStages: [800, 1600],
        activeStage: 1,
        pollingRateHz: 1000,
        autoReapplyEnabled: autoReapply
    )
    profile.wheelSettings = WheelSettings(hardware: wheel, software: .default)
    return profile
}

private func supportedCapability() -> WheelHardwareCapability {
    WheelHardwareCapability(
        scrollMode: .supported,
        acceleration: .supported,
        smartReel: .supported
    )
}

private func armedAutoState(attempts: Int = AutoApplyCoordinator.maxAttempts) -> AutoApplyCoordinator.State {
    AutoApplyCoordinator.State(needsAutoApply: true, attemptsRemaining: attempts)
}

// MARK: - Tests

final class AppModelRefreshFlowTests: XCTestCase {

    // MARK: Retry / reconnect

    func testStaleHandleInvalidatesAndRetriesOnceWithBecameConnected() throws {
        let session = FakeDeviceSession()
        session.client.readStateErrors = [RazerCommandError.timeout]
        session.client.state = DeviceState(batteryPercent: 55, dpiX: 1600)

        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let request = DeviceRefreshRequest(
            wasConnectedBefore: false,
            selectedProfile: makeProfile(),
            shouldAutoApply: true,
            autoApplySnapshot: armedAutoState(),
            cachedWheelCapability: supportedCapability(),
            generationAtSchedule: applyGate.currentGeneration(),
            lifecycleToken: lifecycle.currentAwakeToken()!
        )

        let result = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: request,
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertFalse(result.disconnected)
        XCTAssertTrue(result.becameConnected)
        XCTAssertEqual(result.state?.batteryPercent, 55)
        XCTAssertEqual(session.connectCount, 1)
        XCTAssertEqual(session.reconnectCount, 1)
        // Order: first connect, then disconnect (invalidate), then exactly one reconnect.
        let connectIdx = try XCTUnwrap(session.events.firstIndex(of: .connect))
        let disconnectIdx = try XCTUnwrap(session.events.firstIndex(of: .disconnect))
        let reconnectIdx = try XCTUnwrap(session.events.firstIndex(of: .reconnect))
        XCTAssertLessThan(connectIdx, disconnectIdx)
        XCTAssertLessThan(disconnectIdx, reconnectIdx)
        XCTAssertEqual(session.events.filter { $0 == .reconnect }.count, 1)
    }

    func testExactlyOneRetryWhenSecondAttemptAlsoFails() throws {
        let session = FakeDeviceSession()
        // Invalidating failures on both apply attempts.
        session.applyResults = [
            .failure(RazerCommandError.timeout),
            .failure(RazerCommandError.timeout)
        ]

        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let request = DeviceRefreshRequest(
            wasConnectedBefore: true,
            selectedProfile: makeProfile(),
            shouldAutoApply: true,
            autoApplySnapshot: armedAutoState(attempts: 1),
            cachedWheelCapability: supportedCapability(),
            generationAtSchedule: applyGate.currentGeneration(),
            lifecycleToken: lifecycle.currentAwakeToken()!
        )

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: request,
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertTrue(snapshot.disconnected)
        XCTAssertEqual(session.connectCount, 1)
        XCTAssertEqual(session.reconnectCount, 1, "exactly one retry")
        XCTAssertEqual(session.applyCount, 2)
        // connect → apply → disconnect → reconnect → apply → disconnect
        XCTAssertEqual(
            session.events.filter { [.connect, .reconnect, .apply, .disconnect].contains($0) },
            [
                .connect, .apply, .disconnect,
                .reconnect, .apply, .disconnect
            ]
        )
        // Per-episode end: onDisconnect clears need and restores max attempts for the *next*
        // connection episode (which will re-arm via onConnect — not a cross-cycle breaker).
        XCTAssertFalse(snapshot.autoApplyState.needsAutoApply)
        XCTAssertEqual(snapshot.autoApplyState.attemptsRemaining, AutoApplyCoordinator.maxAttempts)
        XCTAssertFalse(
            snapshot.applyOutcomeCommitted,
            "disconnect does not commit a verified/unverified apply outcome"
        )
    }

    func testInvalidatingApplyFailureThenSuccessfulRetry() throws {
        let session = FakeDeviceSession()
        session.applyResults = [
            .failure(RazerCommandError.timeout),
            .success(.verified)
        ]

        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let request = DeviceRefreshRequest(
            wasConnectedBefore: true,
            selectedProfile: makeProfile(),
            shouldAutoApply: true,
            autoApplySnapshot: armedAutoState(),
            cachedWheelCapability: supportedCapability(),
            generationAtSchedule: applyGate.currentGeneration(),
            lifecycleToken: lifecycle.currentAwakeToken()!
        )

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: request,
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertEqual(session.connectCount, 1)
        XCTAssertEqual(session.reconnectCount, 1)
        XCTAssertEqual(session.applyCount, 2)
        XCTAssertTrue(snapshot.becameConnected)
        XCTAssertTrue(snapshot.profileAppliedSuccessfully)
        XCTAssertTrue(snapshot.applyOutcomeCommitted)
        XCTAssertFalse(snapshot.autoApplyState.needsAutoApply)
        XCTAssertFalse(snapshot.disconnected)
    }

    // MARK: Auto-apply next-state via coordinator (not policy-only)

    func testCoordinatorUnverifiedApplyReturnsDecrementedBudget() throws {
        let session = FakeDeviceSession()
        session.applyResults = [.success(.unverified(mismatches: [.dpi]))]
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let prior = armedAutoState(attempts: 3)

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: makeProfile(),
                    shouldAutoApply: true,
                    autoApplySnapshot: prior,
                    cachedWheelCapability: supportedCapability(),
                    generationAtSchedule: applyGate.currentGeneration(),
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertTrue(snapshot.applyOutcomeCommitted)
        XCTAssertFalse(snapshot.profileAppliedSuccessfully)
        XCTAssertNotNil(snapshot.applyWarning)
        XCTAssertEqual(snapshot.autoApplyState.attemptsRemaining, 2)
        XCTAssertTrue(snapshot.autoApplyState.needsAutoApply)
        // Next attempt still allowed under returned state.
        XCTAssertTrue(
            AutoApplyCoordinator.shouldAttemptApply(
                state: snapshot.autoApplyState,
                autoReapplyEnabled: true,
                hasProfile: true
            )
        )
    }

    func testCoordinatorNonInvalidatingFailureReturnsDecrementedBudget() throws {
        let session = FakeDeviceSession()
        session.applyResults = [
            .failure(HardwareApplyError.unknownWheelReadback(fields: [.scrollMode]))
        ]
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: makeProfile(),
                    shouldAutoApply: true,
                    autoApplySnapshot: armedAutoState(attempts: 2),
                    cachedWheelCapability: supportedCapability(),
                    generationAtSchedule: applyGate.currentGeneration(),
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertFalse(snapshot.disconnected)
        XCTAssertEqual(session.disconnectCount, 0)
        XCTAssertTrue(snapshot.applyOutcomeCommitted)
        XCTAssertEqual(snapshot.autoApplyState.attemptsRemaining, 1)
        XCTAssertTrue(snapshot.autoApplyState.needsAutoApply)
    }

    func testCoordinatorVerifiedApplyClearsNeedInReturnedState() throws {
        let session = FakeDeviceSession()
        session.applyResults = [.success(.verified)]
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: makeProfile(),
                    shouldAutoApply: true,
                    autoApplySnapshot: armedAutoState(),
                    cachedWheelCapability: supportedCapability(),
                    generationAtSchedule: applyGate.currentGeneration(),
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertTrue(snapshot.applyOutcomeCommitted)
        XCTAssertTrue(snapshot.profileAppliedSuccessfully)
        XCTAssertFalse(snapshot.autoApplyState.needsAutoApply)
        XCTAssertEqual(snapshot.autoApplyState.attemptsRemaining, AutoApplyCoordinator.maxAttempts)
        XCTAssertFalse(
            AutoApplyCoordinator.shouldAttemptApply(
                state: snapshot.autoApplyState,
                autoReapplyEnabled: true,
                hasProfile: true
            )
        )
    }

    func testCoordinatorSupersededBeforeWriteConsumesNoAttempt() throws {
        let session = FakeDeviceSession()
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let genAtSchedule = applyGate.currentGeneration()
        _ = applyGate.issue()

        let prior = armedAutoState(attempts: 3)
        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: makeProfile(),
                    shouldAutoApply: true,
                    autoApplySnapshot: prior,
                    cachedWheelCapability: supportedCapability(),
                    generationAtSchedule: genAtSchedule,
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertEqual(session.applyCount, 0)
        XCTAssertEqual(session.disconnectCount, 0)
        XCTAssertTrue(session.isConnected)
        XCTAssertFalse(snapshot.applyOutcomeCommitted)
        XCTAssertEqual(snapshot.autoApplyState, prior)
        XCTAssertFalse(snapshot.profileAppliedSuccessfully)
    }

    func testCoordinatorExhaustedStatePerformsNoApply() throws {
        let session = FakeDeviceSession()
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let exhausted = AutoApplyCoordinator.State(needsAutoApply: false, attemptsRemaining: 0)

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: makeProfile(),
                    shouldAutoApply: true,
                    autoApplySnapshot: exhausted,
                    cachedWheelCapability: supportedCapability(),
                    generationAtSchedule: applyGate.currentGeneration(),
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertEqual(session.applyCount, 0)
        XCTAssertFalse(snapshot.applyOutcomeCommitted)
        XCTAssertEqual(snapshot.autoApplyState, exhausted)
        XCTAssertFalse(snapshot.profileAppliedSuccessfully)
    }

    // MARK: Gate supersession during apply

    func testGateSupersessionDuringApplyDoesNotPublishSuccess() throws {
        let session = FakeDeviceSession()
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let genAtSchedule = applyGate.currentGeneration()
        session.supersedeApplyGate = applyGate
        session.applyResults = [.success(.verified)]

        let prior = armedAutoState()
        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: makeProfile(),
                    shouldAutoApply: true,
                    autoApplySnapshot: prior,
                    cachedWheelCapability: supportedCapability(),
                    generationAtSchedule: genAtSchedule,
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertEqual(session.applyCount, 1, "apply ran")
        XCTAssertFalse(applyGate.isCurrent(genAtSchedule))
        XCTAssertFalse(snapshot.profileAppliedSuccessfully, "stale successful result not published")
        XCTAssertNil(snapshot.appliedHardwareSettings)
        XCTAssertFalse(snapshot.applyOutcomeCommitted, "success not committed when generation stale after write")
        // No success/failure budget transition.
        XCTAssertEqual(snapshot.autoApplyState.attemptsRemaining, prior.attemptsRemaining)
        XCTAssertTrue(snapshot.autoApplyState.needsAutoApply)
        XCTAssertEqual(session.disconnectCount, 0, "generation staleness alone must not disconnect")
        XCTAssertTrue(session.isConnected)
    }

    // MARK: Lifecycle retirement

    func testStaleAtEntryDoesNotConnectOrRetireCachedSession() {
        // Decision: entry-time stale token returns nil without work and without disconnect.
        // Sleep/removal paths already retire the session; a stale token here means AppModel
        // should not have scheduled work (no awake token). Retiring here would race a newer
        // generation's concurrent refresh that reconnected after removal.
        let session = FakeDeviceSession()
        session.isConnectedFlag = true
        let lifecycle = DeviceLifecycleGate()
        let staleToken = lifecycle.currentAwakeToken()!
        lifecycle.invalidateForRemoval()

        let snapshot = DeviceRefreshCoordinator.performRefresh(
            session: session,
            request: DeviceRefreshRequest(
                wasConnectedBefore: true,
                selectedProfile: makeProfile(),
                shouldAutoApply: true,
                autoApplySnapshot: armedAutoState(),
                cachedWheelCapability: supportedCapability(),
                generationAtSchedule: 0,
                lifecycleToken: staleToken
            ),
            applyGate: LatestHardwareApplyGate(),
            lifecycleGate: lifecycle
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(session.connectCount, 0)
        XCTAssertEqual(session.applyCount, 0)
        XCTAssertEqual(session.disconnectCount, 0, "stale-at-entry does not retire")
        XCTAssertTrue(session.isConnectedFlag, "cached session left for lifecycle owners")
    }

    func testMidFlowLifecycleInvalidationRetiresSession() {
        let session = FakeDeviceSession()
        let lifecycle = DeviceLifecycleGate()
        let token = lifecycle.currentAwakeToken()!
        let applyGate = LatestHardwareApplyGate()

        // After connect succeeds, invalidate lifecycle so the next retain retires the session.
        session.afterConnect = {
            lifecycle.invalidateForRemoval()
        }

        let snapshot = DeviceRefreshCoordinator.performRefresh(
            session: session,
            request: DeviceRefreshRequest(
                wasConnectedBefore: false,
                selectedProfile: makeProfile(),
                shouldAutoApply: true,
                autoApplySnapshot: armedAutoState(),
                cachedWheelCapability: supportedCapability(),
                generationAtSchedule: applyGate.currentGeneration(),
                lifecycleToken: token
            ),
            applyGate: applyGate,
            lifecycleGate: lifecycle
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(session.connectCount, 1)
        XCTAssertGreaterThanOrEqual(session.disconnectCount, 1)
        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(session.applyCount, 0, "retired before apply")
    }

    // MARK: Probe behavior

    func testBecameConnectedProbesWheelCapability() throws {
        let session = FakeDeviceSession()
        session.client.probeReports = [
            WheelCapabilityProbe.ProbeReport(
                capability: WheelHardwareCapability(
                    scrollMode: .supported,
                    acceleration: .notSupported,
                    smartReel: .unknown
                )
            )
        ]
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: false,
                    selectedProfile: makeProfile(autoReapply: false),
                    shouldAutoApply: false,
                    autoApplySnapshot: AutoApplyCoordinator.State(),
                    cachedWheelCapability: WheelHardwareCapability(),
                    generationAtSchedule: applyGate.currentGeneration(),
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertTrue(snapshot.becameConnected)
        XCTAssertEqual(session.client.probeCount, 1)
        XCTAssertEqual(snapshot.probeReport?.capability.scrollMode, .supported)
    }

    func testLaterRetryWithUnknownCachedCapabilityReprobes() throws {
        let session = FakeDeviceSession()
        session.client.probeReports = [
            WheelCapabilityProbe.ProbeReport(capability: supportedCapability())
        ]
        let lifecycle = DeviceLifecycleGate()
        let applyGate = LatestHardwareApplyGate()
        let profile = makeProfile(
            wheel: HardwareWheelSettings(
                scrollMode: .freeSpin,
                accelerationEnabled: true,
                smartReelEnabled: false
            )
        )

        let snapshot = try XCTUnwrap(
            DeviceRefreshCoordinator.performRefresh(
                session: session,
                request: DeviceRefreshRequest(
                    wasConnectedBefore: true,
                    selectedProfile: profile,
                    shouldAutoApply: true,
                    autoApplySnapshot: armedAutoState(attempts: 2),
                    cachedWheelCapability: WheelHardwareCapability(), // all unknown
                    generationAtSchedule: applyGate.currentGeneration(),
                    lifecycleToken: lifecycle.currentAwakeToken()!
                ),
                applyGate: applyGate,
                lifecycleGate: lifecycle
            )
        )

        XCTAssertFalse(snapshot.becameConnected)
        XCTAssertEqual(session.client.probeCount, 1)
        XCTAssertNotNil(snapshot.probeReport)
    }
}
