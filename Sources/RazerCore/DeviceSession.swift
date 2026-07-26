import Foundation
import IOKit.hid

// MARK: - Session / client seams (refresh tests + production)

/// Minimal command surface used by refresh/reconnect and auto-apply.
/// Production uses `RazerCommandClient`; tests inject deterministic fakes.
/// `Sendable` so clients can cross the MainActor → HID-queue boundary safely
/// (production `RazerCommandClient` is `@unchecked Sendable`).
public protocol DeviceCommandClient: AnyObject, Sendable {
    /// The device this client is bound to. Carrying it here rather than passing it
    /// alongside makes a client/model mismatch structurally impossible.
    var model: MouseModel { get }

    func readState() throws -> DeviceState
    func probeWheelCapability() -> WheelCapabilityProbe.ProbeReport
    /// Diagnostics line for a probe report (production may append live readback).
    func wheelProbeSummary(for report: WheelCapabilityProbe.ProbeReport) -> String
}

extension DeviceCommandClient {
    public func wheelProbeSummary(for report: WheelCapabilityProbe.ProbeReport) -> String {
        report.summary
    }
}

/// Session lifecycle used by AppModel and `DeviceRefreshCoordinator`.
///
/// Refresh witnesses (`connectForRefresh` / `reconnectForRefresh` / `applyForRefresh`)
/// keep production `connect()` / `reconnect()` / `apply(to: RazerCommandClient, …)`
/// signatures and nonescaping closure semantics intact for concrete callers.
///
/// Refines `Sendable` so `any DeviceSessionProtocol` can be captured by `hidQueue`
/// without erasing production `DeviceSession: @unchecked Sendable`.
public protocol DeviceSessionProtocol: AnyObject, Sendable {
    var onDeviceRemoved: (() -> Void)? { get set }
    var isConnected: Bool { get }
    var removalMonitoringStatus: DeviceRemovalMonitoringStatus { get }

    func connectForRefresh() throws -> any DeviceCommandClient
    func reconnectForRefresh() throws -> any DeviceCommandClient
    func invalidate()
    func disconnect()

    @discardableResult
    func retainIfLifecycleCurrent(
        _ gate: DeviceLifecycleGate,
        token: DeviceLifecycleGate.Token
    ) -> Bool

    func applyForRefresh(
        profile: MouseProfile,
        to client: any DeviceCommandClient,
        wheelCapability: WheelHardwareCapability?,
        isStillCurrent: @escaping () -> Bool
    ) throws -> HardwareApplyResult
}

/// A registry entry identifies the exact HID interface for the lifetime of the
/// current I/O Registry. Product, serial, and location properties are not used
/// because they are absent or non-unique on some receiver/device combinations.
struct DeviceSessionDeviceIdentity: Equatable, Hashable, Sendable {
    let registryEntryID: UInt64

    init(registryEntryID: UInt64) {
        self.registryEntryID = registryEntryID
    }

    init?(device: IOHIDDevice) {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }

        var registryEntryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS else {
            return nil
        }
        self.registryEntryID = registryEntryID
    }
}

/// An opaque discovery handle keeps DeviceSession independent of IOKit object
/// construction and lets alternate discovery/client factories share the cache.
protocol DeviceSessionDeviceHandle: AnyObject {}

struct DeviceSessionDiscoveredDevice {
    let identity: DeviceSessionDeviceIdentity?
    let handle: any DeviceSessionDeviceHandle
    let model: MouseModel

    init(
        identity: DeviceSessionDeviceIdentity?,
        handle: any DeviceSessionDeviceHandle,
        model: MouseModel
    ) {
        self.identity = identity
        self.handle = handle
        self.model = model
    }
}

private final class IOHIDDeviceSessionHandle: DeviceSessionDeviceHandle {
    let device: IOHIDDevice

    init(device: IOHIDDevice) {
        self.device = device
    }
}

public enum DeviceRemovalMonitoringStatus: Equatable, Sendable {
    case active
    case degradedNoStableIdentity
    case unavailable(String)
}

/// Removal delivery may arrive concurrently with `connect()` or `invalidate()`.
/// `DeviceSession` protects all cache state with its lock.
protocol DeviceRemovalMonitoring: AnyObject {
    var status: DeviceRemovalMonitoringStatus { get }
    func setRemovalHandler(_ handler: @escaping (DeviceSessionDeviceIdentity) -> Void)
    func stop()
}

protocol DeviceRemovalMonitorBackend: AnyObject {
    func start(removalHandler: @escaping (DeviceSessionDeviceIdentity) -> Void) -> IOReturn
    func stop()
}

/// Keeps handler lifetime and backend startup state separate from IOKit. Clearing
/// the relay is a drained callback boundary: it waits for a callback already in
/// its handler and prevents callbacks captured by the backend from delivering.
final class ManagedDeviceRemovalMonitor: DeviceRemovalMonitoring {
    let status: DeviceRemovalMonitoringStatus

    private let backend: any DeviceRemovalMonitorBackend
    private let callbackRelay = DeviceRemovalCallbackRelay()

    init(backend: any DeviceRemovalMonitorBackend) {
        self.backend = backend
        let result = backend.start { [callbackRelay] identity in
            callbackRelay.deliver(identity)
        }
        if result == kIOReturnSuccess {
            status = .active
        } else {
            status = .unavailable("IOHIDManagerOpen result \(result)")
            callbackRelay.deactivate()
            backend.stop()
        }
    }

    deinit {
        stop()
    }

    func setRemovalHandler(_ handler: @escaping (DeviceSessionDeviceIdentity) -> Void) {
        callbackRelay.setHandler(handler)
    }

    func stop() {
        guard callbackRelay.deactivate() else { return }
        backend.stop()
    }
}

private final class DeviceRemovalCallbackRelay: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var handler: ((DeviceSessionDeviceIdentity) -> Void)?
    private var active = true

    func setHandler(_ handler: @escaping (DeviceSessionDeviceIdentity) -> Void) {
        lock.lock()
        if active {
            self.handler = handler
        }
        lock.unlock()
    }

    @discardableResult
    func deactivate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        active = false
        handler = nil
        return true
    }

    func deliver(_ identity: DeviceSessionDeviceIdentity) {
        lock.lock()
        if active {
            handler?(identity)
        }
        lock.unlock()
    }

}

/// Owns the callback context until IOKit has cancelled the dispatch source and
/// drained its serial delivery queue.
private final class DeviceRemovalCancellation: @unchecked Sendable {
    let manager: IOHIDManager
    let callbackContextPointer: UnsafeMutableRawPointer

    private let condition = NSCondition()
    private var completed = false

    init(manager: IOHIDManager, callbackContext: DeviceRemovalCallbackContext) {
        self.manager = manager
        callbackContextPointer = Unmanaged.passRetained(callbackContext).toOpaque()
    }

    func complete() {
        Unmanaged<DeviceRemovalCallbackContext>
            .fromOpaque(callbackContextPointer)
            .release()
        condition.lock()
        completed = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilCompleted() {
        condition.lock()
        while !completed {
            condition.wait()
        }
        condition.unlock()
    }
}

/// Owns one long-lived manager so removal callbacks remain active between polls.
/// IOKit callbacks and cancellation are serialized on a dedicated queue.
private final class IOHIDDeviceRemovalMonitorBackend: DeviceRemovalMonitorBackend {
    private enum State {
        case idle
        case active(DeviceRemovalCallbackContext, DeviceRemovalCancellation)
        case stopping
        case stopped
    }

    private let manager: IOHIDManager
    private let deliveryQueue = DispatchQueue(label: "com.razer-viper-control.device-removal")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var state: State = .idle
    /// Every supported model, not the connected one: this starts before the first
    /// discovery pass, so the connected device is not yet known.
    private let models: [MouseModel]

    init(models: [MouseModel]) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        deliveryQueue.setSpecific(key: queueKey, value: 1)
        self.models = models
    }

    func start(removalHandler: @escaping (DeviceSessionDeviceIdentity) -> Void) -> IOReturn {
        let callbackContext = DeviceRemovalCallbackContext(handler: removalHandler)
        let cancellation = DeviceRemovalCancellation(
            manager: manager,
            callbackContext: callbackContext
        )

        let matching: [[String: Any]] = models.map { model in
            [
                kIOHIDVendorIDKey: model.vendorID,
                kIOHIDProductIDKey: model.productID,
                kIOHIDDeviceUsagePageKey: model.primaryUsagePage,
                kIOHIDDeviceUsageKey: model.primaryUsage
            ]
        }
        if matching.count == 1 {
            // Byte-identical to the pre-registry single-dictionary call.
            IOHIDManagerSetDeviceMatching(manager, matching[0] as CFDictionary)
        } else {
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        }
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            deviceSessionRemovalCallback,
            cancellation.callbackContextPointer
        )
        IOHIDManagerSetDispatchQueue(manager, deliveryQueue)
        IOHIDManagerSetCancelHandler(manager) { [cancellation] in
            cancellation.complete()
        }

        lock.lock()
        state = .active(callbackContext, cancellation)
        lock.unlock()

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
        if result != kIOReturnSuccess {
            stop()
        }
        return result
    }

    func stop() {
        lock.lock()
        guard case let .active(callbackContext, cancellation) = state else {
            lock.unlock()
            return
        }
        state = .stopping
        lock.unlock()

        callbackContext.clearHandler()
        _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerCancel(manager)

        if DispatchQueue.getSpecific(key: queueKey) == nil {
            cancellation.waitUntilCompleted()
        }

        lock.lock()
        state = .stopped
        lock.unlock()
    }
}

private final class DeviceRemovalCallbackContext {
    private let callbackRelay = DeviceRemovalCallbackRelay()

    init(handler: @escaping (DeviceSessionDeviceIdentity) -> Void) {
        callbackRelay.setHandler(handler)
    }

    func clearHandler() {
        callbackRelay.deactivate()
    }

    func deviceWasRemoved(_ device: IOHIDDevice) {
        guard let identity = DeviceSessionDeviceIdentity(device: device) else { return }
        callbackRelay.deliver(identity)
    }
}

private let deviceSessionRemovalCallback: IOHIDDeviceCallback = {
    context,
    _,
    _,
    device in
    guard let context else { return }
    let callbackContext = Unmanaged<DeviceRemovalCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    callbackContext.deviceWasRemoved(device)
}

public final class DeviceSession: @unchecked Sendable {
    private typealias DiscoverDevice = () throws -> DeviceSessionDiscoveredDevice?
    private typealias MakeClient = (DeviceSessionDiscoveredDevice) -> RazerCommandClient

    private let discoverDevice: DiscoverDevice
    private let makeClient: MakeClient
    private let removalMonitor: any DeviceRemovalMonitoring
    private let lock = NSLock()
    private var cachedDeviceIdentity: DeviceSessionDeviceIdentity?
    private var client: RazerCommandClient?
    private var removalHandler: (() -> Void)?

    public convenience init(registry: DeviceRegistry) {
        let discovery = HIDDeviceDiscovery(registry: registry)
        let removalMonitor = ManagedDeviceRemovalMonitor(
            backend: IOHIDDeviceRemovalMonitorBackend(models: registry.models)
        )
        self.init(
            discoverDevice: {
                guard let resolved = try discovery.findControlDevice() else { return nil }
                return DeviceSessionDiscoveredDevice(
                    identity: DeviceSessionDeviceIdentity(device: resolved.device),
                    handle: IOHIDDeviceSessionHandle(device: resolved.device),
                    model: resolved.model
                )
            },
            makeClient: { discoveredDevice in
                guard let handle = discoveredDevice.handle as? IOHIDDeviceSessionHandle else {
                    preconditionFailure("Production discovery must return an IOHIDDevice.")
                }
                return RazerCommandClient(device: handle.device, model: discoveredDevice.model)
            },
            removalMonitor: removalMonitor
        )
    }

    init(
        discoverDevice: @escaping () throws -> DeviceSessionDiscoveredDevice?,
        makeClient: @escaping (DeviceSessionDiscoveredDevice) -> RazerCommandClient,
        removalMonitor: any DeviceRemovalMonitoring
    ) {
        self.discoverDevice = discoverDevice
        self.makeClient = makeClient
        self.removalMonitor = removalMonitor
        removalMonitor.setRemovalHandler { [weak self] identity in
            self?.handleRemoval(of: identity)
        }
    }

    deinit {
        removalMonitor.stop()
        retireCachedClient()
    }

    /// Called on the removal monitor's serial delivery queue after the matching
    /// cached client has been invalidated and fully closed.
    public var onDeviceRemoved: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return removalHandler
        }
        set {
            lock.lock()
            removalHandler = newValue
            lock.unlock()
        }
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client != nil
    }

    /// Missing registry identity degrades immediate removal correlation only;
    /// connection and the existing polling heartbeat remain available.
    public var removalMonitoringStatus: DeviceRemovalMonitoringStatus {
        lock.lock()
        defer { lock.unlock() }
        if client != nil, cachedDeviceIdentity == nil, removalMonitor.status == .active {
            return .degradedNoStableIdentity
        }
        return removalMonitor.status
    }

    /// Discovery and client creation are serialized with invalidation. The app's
    /// serial HID queue owns operation ordering; the client lock is the final
    /// lifecycle boundary against concurrent removal callbacks.
    public func connect() throws -> RazerCommandClient {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }

        guard let discoveredDevice = try discoverDevice() else {
            throw RazerCommandError.deviceNotOpen
        }

        let client = makeClient(discoveredDevice)
        do {
            try client.open(nonSeizing: true)
        } catch {
            client.close()
            throw error
        }

        cachedDeviceIdentity = discoveredDevice.identity
        self.client = client
        return client
    }

    /// Cache removal and close form one ordered retirement boundary. `connect()`
    /// cannot open a replacement until the retired client has fully closed.
    public func invalidate() {
        retireCachedClient()
    }

    public func disconnect() {
        invalidate()
    }

    /// After `connect()` / `reconnect()`, drop the cache when `token` is no longer
    /// current and awake so sleep/removal cannot leave a connected session while
    /// UI is forced disconnected. Returns whether work may continue.
    @discardableResult
    public func retainIfLifecycleCurrent(
        _ gate: DeviceLifecycleGate,
        token: DeviceLifecycleGate.Token
    ) -> Bool {
        guard gate.isCurrentAndAwake(token) else {
            disconnect()
            return false
        }
        return true
    }

    public func reconnect() throws -> RazerCommandClient {
        invalidate()
        return try connect()
    }

    /// Protocol witness for refresh/coordinator paths (existential-friendly).
    public func connectForRefresh() throws -> any DeviceCommandClient {
        try connect()
    }

    /// Protocol witness for refresh/coordinator paths (existential-friendly).
    public func reconnectForRefresh() throws -> any DeviceCommandClient {
        try reconnect()
    }

    /// Concrete production apply API — preserves nonescaping `isStillCurrent`.
    public func apply(
        profile: MouseProfile,
        to client: RazerCommandClient,
        wheelCapability: WheelHardwareCapability? = nil,
        isStillCurrent: () -> Bool = { true }
    ) throws -> HardwareApplyResult {
        let capability = wheelCapability ?? WheelHardwareCapability()
        return try HardwareProfileApplier.apply(
            target: profile,
            using: RazerCommandClientHardwareApplier(client: client),
            capability: capability,
            isStillCurrent: isStillCurrent
        )
    }

    /// Protocol witness for refresh/coordinator apply against `any DeviceCommandClient`.
    public func applyForRefresh(
        profile: MouseProfile,
        to client: any DeviceCommandClient,
        wheelCapability: WheelHardwareCapability? = nil,
        isStillCurrent: @escaping () -> Bool = { true }
    ) throws -> HardwareApplyResult {
        if let razer = client as? RazerCommandClient {
            return try apply(
                profile: profile,
                to: razer,
                wheelCapability: wheelCapability,
                isStillCurrent: isStillCurrent
            )
        }
        guard let hardwareClient = client as? HardwareProfileApplying else {
            throw RazerCommandError.unsupportedCommand
        }
        let capability = wheelCapability ?? WheelHardwareCapability()
        return try HardwareProfileApplier.apply(
            target: profile,
            using: hardwareClient,
            capability: capability,
            isStillCurrent: isStillCurrent
        )
    }

    public func applyWheelSettings(
        _ settings: HardwareWheelSettings,
        to client: RazerCommandClient,
        capability: WheelHardwareCapability? = nil
    ) throws {
        let resolved = capability ?? WheelHardwareCapability()
        if let mode = settings.scrollMode, resolved.scrollMode == .supported {
            _ = try client.setScrollMode(mode)
        }
        if let enabled = settings.accelerationEnabled, resolved.acceleration == .supported {
            _ = try client.setScrollAcceleration(enabled)
        }
        if let enabled = settings.smartReelEnabled, resolved.smartReel == .supported {
            _ = try client.setScrollSmartReel(enabled)
        }
    }

    private func retireCachedClient() {
        lock.lock()
        let cachedClient = client
        client = nil
        cachedDeviceIdentity = nil
        cachedClient?.close()
        lock.unlock()
    }

    private func handleRemoval(of identity: DeviceSessionDeviceIdentity) {
        lock.lock()
        guard cachedDeviceIdentity == identity else {
            lock.unlock()
            return
        }
        let removedClient = client
        client = nil
        cachedDeviceIdentity = nil
        let removalHandler = removalHandler
        removedClient?.close()
        lock.unlock()

        removalHandler?()
    }
}

extension DeviceSession: DeviceSessionProtocol {}

/// Adapts `RazerCommandClient` to the apply planner without colliding on return types.
final class RazerCommandClientHardwareApplier: HardwareProfileApplying {
    private let client: RazerCommandClient

    init(client: RazerCommandClient) {
        self.client = client
    }

    func readState() throws -> DeviceState {
        try client.readState()
    }

    func readWheelHardwareState(capability: WheelHardwareCapability) -> HardwareWheelSettings {
        client.readWheelHardwareState(capability: capability).settings
    }

    func setDPIStages(activeStage: Int, stages: [Int]) throws {
        try client.setDPIStages(activeStage: activeStage, stages: stages)
    }

    func setDPI(_ dpi: Int) throws {
        try client.setDPI(dpi)
    }

    func setPollingRate(hz: Int) throws {
        try client.setPollingRate(hz: hz)
    }

    func setScrollMode(_ mode: ScrollWheelMode) throws {
        _ = try client.setScrollMode(mode)
    }

    func setScrollAcceleration(_ enabled: Bool) throws {
        _ = try client.setScrollAcceleration(enabled)
    }

    func setScrollSmartReel(_ enabled: Bool) throws {
        _ = try client.setScrollSmartReel(enabled)
    }
}
