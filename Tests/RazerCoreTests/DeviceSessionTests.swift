import XCTest
@testable import RazerCore

final class DeviceSessionTests: XCTestCase {
    func testInvalidateWaitsForCompleteCommandBoundaryBeforeClosing() throws {
        let request = RazerReport.getBatteryLevel()
        let transport = BlockingCommandTransport(response: successfulResponse(for: request).bytes)
        let sequence = SequencedDeviceSessionHarness(deviceIDs: [1], transports: [transport])
        let session = sequence.makeSession()
        let client = try session.connect()
        let commandFinished = expectation(description: "command finished")
        let invalidationFinished = expectation(description: "invalidation finished")

        DispatchQueue.global(qos: .userInitiated).async {
            defer { commandFinished.fulfill() }
            do {
                _ = try client.send(request)
            } catch {
                XCTFail("command failed: \(error)")
            }
        }
        XCTAssertEqual(transport.getStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            session.invalidate()
            invalidationFinished.fulfill()
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [transport.closeEntered], timeout: 0.05),
            .timedOut,
            "close must not enter the transport while a report round trip is active"
        )
        transport.allowGetToFinish.signal()
        wait(for: [commandFinished, invalidationFinished], timeout: 1)

        XCTAssertEqual(transport.events, [.open, .set, .getStarted, .getFinished, .close])
    }

    func testRemovalWaitsForCompleteCommandBoundaryBeforeClosingAndNotifying() throws {
        let request = RazerReport.getBatteryLevel()
        let transport = BlockingCommandTransport(response: successfulResponse(for: request).bytes)
        let sequence = SequencedDeviceSessionHarness(deviceIDs: [1], transports: [transport])
        let session = sequence.makeSession()
        let client = try session.connect()
        let commandFinished = expectation(description: "command finished")
        let removalFinished = expectation(description: "removal finished")
        let notificationsAfterClose = LockedCounter()
        session.onDeviceRemoved = {
            if transport.events.last == .close {
                notificationsAfterClose.increment()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { commandFinished.fulfill() }
            do {
                _ = try client.send(request)
            } catch {
                XCTFail("command failed: \(error)")
            }
        }
        XCTAssertEqual(transport.getStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            sequence.removalMonitor.emitRemoval(deviceID: 1)
            removalFinished.fulfill()
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [transport.closeEntered], timeout: 0.05),
            .timedOut,
            "removal must not close the transport during a report round trip"
        )
        transport.allowGetToFinish.signal()
        wait(for: [commandFinished, removalFinished], timeout: 1)

        XCTAssertEqual(notificationsAfterClose.value, 1)
        XCTAssertEqual(transport.events, [.open, .set, .getStarted, .getFinished, .close])
    }

    func testReconnectOpensOnlyAfterRetiredClientFinishesClosing() throws {
        let events = LockedLifecycleEvents()
        let oldTransport = BlockingCloseTransport(events: events)
        let newTransport = SignalingOpenTransport(events: events)
        let sequence = SequencedDeviceSessionHarness(
            deviceIDs: [1, 2],
            transports: [oldTransport, newTransport]
        )
        let session = sequence.makeSession()
        _ = try session.connect()
        let invalidationFinished = expectation(description: "invalidation finished")
        let reconnectFinished = expectation(description: "reconnect finished")

        DispatchQueue.global(qos: .userInitiated).async {
            session.invalidate()
            invalidationFinished.fulfill()
        }
        XCTAssertEqual(oldTransport.closeStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { reconnectFinished.fulfill() }
            do {
                _ = try session.connect()
            } catch {
                XCTFail("reconnect failed: \(error)")
            }
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [newTransport.openEntered], timeout: 0.05),
            .timedOut,
            "a replacement client must not open before old-client close is ordered"
        )
        oldTransport.allowCloseToFinish.signal()
        wait(for: [invalidationFinished, reconnectFinished], timeout: 1)

        XCTAssertEqual(events.values, [.oldOpen, .oldCloseStarted, .oldCloseFinished, .newOpen])
    }

    func testConnectReusesCachedClient() throws {
        let harness = DeviceSessionHarness(deviceIDs: [1])
        let session = harness.makeSession()

        let first = try session.connect()
        let second = try session.connect()

        XCTAssertTrue(first === second)
        XCTAssertEqual(harness.discoveryCount, 1)
        XCTAssertEqual(harness.clientCreationCount, 1)
        XCTAssertEqual(harness.transports[0].openCount, 1)
    }

    func testInvalidateDropsCachedClientAndNextConnectRediscovers() throws {
        let harness = DeviceSessionHarness(deviceIDs: [1, 2])
        let session = harness.makeSession()
        let first = try session.connect()

        session.invalidate()
        let second = try session.connect()

        XCTAssertFalse(first === second)
        XCTAssertEqual(harness.discoveryCount, 2)
        XCTAssertEqual(harness.clientCreationCount, 2)
        XCTAssertEqual(harness.transports[0].closeCount, 1)
        XCTAssertEqual(harness.transports[1].openCount, 1)
    }

    func testCachedDeviceRemovalInvalidatesBeforeNotifying() throws {
        let harness = DeviceSessionHarness(deviceIDs: [1])
        let session = harness.makeSession()
        _ = try session.connect()
        var wasConnectedWhenNotified: Bool?
        session.onDeviceRemoved = { [weak session] in
            wasConnectedWhenNotified = session?.isConnected
        }

        harness.removalMonitor.emitRemoval(deviceID: 1)

        XCTAssertEqual(wasConnectedWhenNotified, false)
        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(harness.transports[0].closeCount, 1)
    }

    func testUnrelatedDeviceRemovalDoesNotInvalidateOrNotify() throws {
        let harness = DeviceSessionHarness(deviceIDs: [1])
        let session = harness.makeSession()
        let first = try session.connect()
        var notificationCount = 0
        session.onDeviceRemoved = { notificationCount += 1 }

        harness.removalMonitor.emitRemoval(deviceID: 99)
        let second = try session.connect()

        XCTAssertTrue(first === second)
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertEqual(harness.discoveryCount, 1)
        XCTAssertEqual(harness.transports[0].closeCount, 0)
    }

    func testConnectionWithoutStableRegistryIDUsesPollingAndIgnoresRemovalCorrelation() throws {
        let transport = CountingRazerTransport()
        let removalMonitor = FakeDeviceRemovalMonitor()
        let session = DeviceSession(
            discoverDevice: {
                DeviceSessionDiscoveredDevice(identity: nil, handle: FakeDeviceSessionHandle())
            },
            makeClient: { _ in RazerCommandClient(transport: transport) },
            removalMonitor: removalMonitor
        )
        var notificationCount = 0
        session.onDeviceRemoved = { notificationCount += 1 }

        _ = try session.connect()
        removalMonitor.emitRemoval(deviceID: 1)

        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.removalMonitoringStatus, .degradedNoStableIdentity)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertEqual(transport.closeCount, 0)
    }

    func testConcurrentDuplicateRemovalNotificationsAreIdempotent() throws {
        let harness = DeviceSessionHarness(deviceIDs: [1])
        let session = harness.makeSession()
        _ = try session.connect()
        let notificationCount = LockedCounter()
        session.onDeviceRemoved = { notificationCount.increment() }

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            harness.removalMonitor.emitRemoval(deviceID: 1)
        }

        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(notificationCount.value, 1)
        XCTAssertEqual(harness.transports[0].closeCount, 1)
    }
}

private func successfulResponse(for request: RazerReport) -> RazerReport {
    var response = request
    response.status = RazerReportStatus.successful.rawValue
    response.refreshCRC()
    return response
}

private final class SequencedDeviceSessionHarness {
    let removalMonitor = FakeDeviceRemovalMonitor()

    private let lock = NSLock()
    private var deviceIDs: [UInt64]
    private var transports: [any RazerReportTransport]

    init(deviceIDs: [UInt64], transports: [any RazerReportTransport]) {
        self.deviceIDs = deviceIDs
        self.transports = transports
    }

    func makeSession() -> DeviceSession {
        DeviceSession(
            discoverDevice: { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard !deviceIDs.isEmpty else { return nil }
                let deviceID = deviceIDs.removeFirst()
                return DeviceSessionDiscoveredDevice(
                    identity: DeviceSessionDeviceIdentity(registryEntryID: deviceID),
                    handle: FakeDeviceSessionHandle()
                )
            },
            makeClient: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                precondition(!transports.isEmpty)
                return RazerCommandClient(transport: transports.removeFirst())
            },
            removalMonitor: removalMonitor
        )
    }
}

private enum BlockingCommandEvent: Equatable {
    case open
    case set
    case getStarted
    case getFinished
    case close
}

private final class BlockingCommandTransport: RazerReportTransport, @unchecked Sendable {
    let getStarted = DispatchSemaphore(value: 0)
    let allowGetToFinish = DispatchSemaphore(value: 0)
    let closeEntered = XCTestExpectation(description: "transport close entered")

    private let response: [UInt8]
    private let lock = NSLock()
    private var recordedEvents: [BlockingCommandEvent] = []

    init(response: [UInt8]) {
        self.response = response
    }

    var events: [BlockingCommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func open(nonSeizing: Bool) throws {
        record(.open)
    }

    func close() {
        record(.close)
        closeEntered.fulfill()
    }

    func setFeatureReport(_ report: [UInt8]) throws {
        record(.set)
    }

    func getFeatureReport(length: Int) throws -> [UInt8] {
        record(.getStarted)
        getStarted.signal()
        guard allowGetToFinish.wait(timeout: .now() + 1) == .success else {
            throw RazerCommandError.timeout
        }
        record(.getFinished)
        return response
    }

    func sleep(milliseconds: UInt64) {}

    private func record(_ event: BlockingCommandEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private enum SessionLifecycleEvent: Equatable {
    case oldOpen
    case oldCloseStarted
    case oldCloseFinished
    case newOpen
}

private final class LockedLifecycleEvents {
    private let lock = NSLock()
    private var events: [SessionLifecycleEvent] = []

    var values: [SessionLifecycleEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: SessionLifecycleEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class BlockingCloseTransport: RazerReportTransport, @unchecked Sendable {
    let closeStarted = DispatchSemaphore(value: 0)
    let allowCloseToFinish = DispatchSemaphore(value: 0)

    private let events: LockedLifecycleEvents

    init(events: LockedLifecycleEvents) {
        self.events = events
    }

    func open(nonSeizing: Bool) throws {
        events.append(.oldOpen)
    }

    func close() {
        events.append(.oldCloseStarted)
        closeStarted.signal()
        _ = allowCloseToFinish.wait(timeout: .now() + 1)
        events.append(.oldCloseFinished)
    }

    func setFeatureReport(_ report: [UInt8]) throws {}

    func getFeatureReport(length: Int) throws -> [UInt8] { [] }

    func sleep(milliseconds: UInt64) {}
}

private final class SignalingOpenTransport: RazerReportTransport, @unchecked Sendable {
    let openEntered = XCTestExpectation(description: "new transport open entered")

    private let events: LockedLifecycleEvents

    init(events: LockedLifecycleEvents) {
        self.events = events
    }

    func open(nonSeizing: Bool) throws {
        events.append(.newOpen)
        openEntered.fulfill()
    }

    func close() {}

    func setFeatureReport(_ report: [UInt8]) throws {}

    func getFeatureReport(length: Int) throws -> [UInt8] { [] }

    func sleep(milliseconds: UInt64) {}
}

private final class DeviceSessionHarness {
    let removalMonitor = FakeDeviceRemovalMonitor()

    private let lock = NSLock()
    private var deviceIDs: [UInt64]
    private var _discoveryCount = 0
    private var _clientCreationCount = 0
    private var _transports: [CountingRazerTransport] = []

    init(deviceIDs: [UInt64]) {
        self.deviceIDs = deviceIDs
    }

    var discoveryCount: Int {
        withLock { _discoveryCount }
    }

    var clientCreationCount: Int {
        withLock { _clientCreationCount }
    }

    var transports: [CountingRazerTransport] {
        withLock { _transports }
    }

    func makeSession() -> DeviceSession {
        DeviceSession(
            discoverDevice: { [self] in
                withLock {
                    let index = _discoveryCount
                    _discoveryCount += 1
                    guard index < deviceIDs.count else { return nil }
                    return DeviceSessionDiscoveredDevice(
                        identity: DeviceSessionDeviceIdentity(registryEntryID: deviceIDs[index]),
                        handle: FakeDeviceSessionHandle()
                    )
                }
            },
            makeClient: { [self] _ in
                withLock {
                    _clientCreationCount += 1
                    let transport = CountingRazerTransport()
                    _transports.append(transport)
                    return RazerCommandClient(transport: transport)
                }
            },
            removalMonitor: removalMonitor
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeDeviceSessionHandle: DeviceSessionDeviceHandle {}

private final class FakeDeviceRemovalMonitor: DeviceRemovalMonitoring {
    let status: DeviceRemovalMonitoringStatus = .active

    private let lock = NSLock()
    private var handler: ((DeviceSessionDeviceIdentity) -> Void)?

    func setRemovalHandler(_ handler: @escaping (DeviceSessionDeviceIdentity) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func emitRemoval(deviceID: UInt64) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(DeviceSessionDeviceIdentity(registryEntryID: deviceID))
    }
}

private final class CountingRazerTransport: RazerReportTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _openCount = 0
    private var _closeCount = 0

    var openCount: Int {
        withLock { _openCount }
    }

    var closeCount: Int {
        withLock { _closeCount }
    }

    func open(nonSeizing: Bool) throws {
        withLock { _openCount += 1 }
    }

    func close() {
        withLock { _closeCount += 1 }
    }

    func setFeatureReport(_ report: [UInt8]) throws {
        XCTFail("DeviceSession lifecycle tests must not issue feature reports.")
    }

    func getFeatureReport(length: Int) throws -> [UInt8] {
        XCTFail("DeviceSession lifecycle tests must not issue feature reports.")
        return []
    }

    func sleep(milliseconds: UInt64) {
        XCTFail("DeviceSession lifecycle tests must not sleep.")
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
