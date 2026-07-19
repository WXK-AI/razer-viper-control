import Foundation
import IOKit.hid

/// Injectable lifecycle, I/O, and timing seam for Razer feature reports.
public protocol RazerReportTransport: Sendable {
    func open(nonSeizing: Bool) throws
    func close()
    func setFeatureReport(_ report: [UInt8]) throws
    func getFeatureReport(length: Int) throws -> [UInt8]
    func sleep(milliseconds: UInt64)
}

private final class IOHIDReportTransport: RazerReportTransport, @unchecked Sendable {
    private let device: IOHIDDevice
    private let reportID: CFIndex = 0

    init(device: IOHIDDevice) {
        self.device = device
    }

    func open(nonSeizing: Bool) throws {
        let options = nonSeizing
            ? IOOptionBits(kIOHIDOptionsTypeNone)
            : IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        let result = IOHIDDeviceOpen(device, options)
        guard result == kIOReturnSuccess else {
            throw mapOpenError(result)
        }
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setFeatureReport(_ report: [UInt8]) throws {
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            reportID,
            report,
            report.count
        )
        guard result == kIOReturnSuccess else {
            throw mapTransportError(result, phase: "set")
        }
    }

    func getFeatureReport(length: Int) throws -> [UInt8] {
        var response = [UInt8](repeating: 0, count: length)
        var responseLength = response.count
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            reportID,
            &response,
            &responseLength
        )
        guard result == kIOReturnSuccess else {
            throw mapTransportError(result, phase: "get")
        }
        guard responseLength <= response.count else {
            throw RazerCommandError.invalidResponse(
                "Expected at most \(response.count) bytes, got \(responseLength)."
            )
        }
        return Array(response.prefix(responseLength))
    }

    func sleep(milliseconds: UInt64) {
        usleep(useconds_t(milliseconds * 1_000))
    }

    private func mapOpenError(_ result: IOReturn) -> RazerCommandError {
        switch result {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            return .permissionDenied("open result \(result)")
        case kIOReturnExclusiveAccess:
            return .blockedDeviceAccess("device already seized")
        default:
            return .transport("open result \(result)")
        }
    }

    private func mapTransportError(_ result: IOReturn, phase: String) -> RazerCommandError {
        switch result {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            return .permissionDenied("\(phase) result \(result)")
        case kIOReturnExclusiveAccess:
            return .blockedDeviceAccess("\(phase) result \(result)")
        default:
            return .transport("\(phase) result \(result)")
        }
    }
}

public enum RazerCommandError: Error, LocalizedError, Equatable {
    case deviceNotOpen
    case permissionDenied(String)
    case deviceBusy
    case unsupportedCommand
    case blockedDeviceAccess(String)
    case timeout
    case transport(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotOpen:
            return "The Razer device is not open."
        case let .permissionDenied(details):
            return "HID access was denied (\(details)). Open System Settings > Privacy & Security > Input Monitoring and allow this app."
        case .deviceBusy:
            return "The mouse reported BUSY. Retry in a moment."
        case .unsupportedCommand:
            return "The mouse does not support this command."
        case let .blockedDeviceAccess(details):
            return "Feature report writes appear blocked (\(details)). Another driver such as Razer Synapse or SteerMouse may have exclusive access."
        case .timeout:
            return "The mouse did not respond in time."
        case let .transport(details):
            return "HID transport error: \(details)"
        case let .invalidResponse(details):
            return "Unexpected mouse response: \(details)"
        }
    }

    public var isPermissionIssue: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    public var isConflictIssue: Bool {
        if case .blockedDeviceAccess = self { return true }
        return false
    }

    /// Errors that usually mean the cached IOHIDDevice handle is dead or wedged
    /// (sleep/wake, dongle re-enumeration, timeout). Clear and reopen the session.
    public var shouldInvalidateSession: Bool {
        switch self {
        case .timeout, .transport, .deviceNotOpen, .invalidResponse, .deviceBusy:
            return true
        case .permissionDenied, .blockedDeviceAccess, .unsupportedCommand:
            return false
        }
    }
}

public enum CommandSendResult: Equatable, Sendable {
    case success(RazerReport)
    case notSupported
}

public struct DeviceState: Equatable, Sendable {
    public var batteryPercent: Int
    public var isCharging: Bool
    public var dpiX: Int
    public var dpiY: Int
    public var activeDPIStage: Int
    public var dpiStages: [Int]
    public var pollingRateHz: Int

    public init(
        batteryPercent: Int = 0,
        isCharging: Bool = false,
        dpiX: Int = 800,
        dpiY: Int = 800,
        activeDPIStage: Int = 1,
        dpiStages: [Int] = [800],
        pollingRateHz: Int = 1000
    ) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.dpiX = dpiX
        self.dpiY = dpiY
        self.activeDPIStage = activeDPIStage
        self.dpiStages = dpiStages
        self.pollingRateHz = pollingRateHz
    }
}

public final class RazerCommandClient: @unchecked Sendable {
    private let transport: any RazerReportTransport
    /// Recursive because high-level operations compose lower-level public commands.
    /// Open/close and feature-report I/O can never overlap across this boundary.
    private let lifecycleLock = NSRecursiveLock()

    public init(device: IOHIDDevice) {
        transport = IOHIDReportTransport(device: device)
    }

    public init(transport: any RazerReportTransport) {
        self.transport = transport
    }

    public func open(nonSeizing: Bool = true) throws {
        try withLifecycleBoundary {
            try transport.open(nonSeizing: nonSeizing)
        }
    }

    public func close() {
        withLifecycleBoundary {
            transport.close()
        }
    }

    @discardableResult
    public func send(_ request: RazerReport) throws -> RazerReport {
        try withLifecycleBoundary {
            var lastError: Error?

            for attempt in 1...DeviceDescriptor.maxCommandRetries {
                do {
                    return try performRoundTrip(request)
                } catch RazerCommandError.deviceBusy {
                    lastError = RazerCommandError.deviceBusy
                    if attempt < DeviceDescriptor.maxCommandRetries {
                        transport.sleep(milliseconds: UInt64(50 * attempt))
                    }
                } catch {
                    throw error
                }
            }

            throw lastError ?? RazerCommandError.deviceBusy
        }
    }

    public func readState() throws -> DeviceState {
        try withLifecycleBoundary {
            let battery = try send(.getBatteryLevel())
            let charging = try send(.getChargingStatus())
            let dpi = try send(.getDPI())
            let stages = try send(.getDPIStages())
            let polling = try send(.getPollingRate())

            let decodedStages = try stages.decodeDPIStages()
            let stageValues = decodedStages.stages.map(\.x)

            return DeviceState(
                batteryPercent: battery.decodeBatteryPercent(),
                isCharging: charging.decodeCharging(),
                dpiX: dpi.decodeDPI().x,
                dpiY: dpi.decodeDPI().y,
                activeDPIStage: decodedStages.activeStage,
                dpiStages: stageValues.isEmpty ? [dpi.decodeDPI().x] : stageValues,
                pollingRateHz: polling.decodePollingRateHz() ?? 1000
            )
        }
    }

    public func setDPI(_ dpi: Int) throws {
        try withLifecycleBoundary {
            try setDPI(x: dpi, y: dpi)
        }
    }

    public func setDPI(x: Int, y: Int) throws {
        try withLifecycleBoundary {
            _ = try send(try .setDPI(x: x, y: y))
        }
    }

    public func setDPIStages(activeStage: Int, stages: [Int]) throws {
        try withLifecycleBoundary {
            _ = try send(try .setDPIStages(activeStage: activeStage, stages: stages))
        }
    }

    public func setPollingRate(hz: Int) throws {
        try withLifecycleBoundary {
            try ProfileValidator.validatePollingRate(hz)
            _ = try send(try .setPollingRate(hz: hz))
        }
    }

    public func sendAllowingUnsupported(_ request: RazerReport) throws -> CommandSendResult {
        try withLifecycleBoundary {
            var lastError: Error?

            for attempt in 1...DeviceDescriptor.maxCommandRetries {
                do {
                    let report = try performRoundTripAllowingUnsupported(request)
                    return report
                } catch RazerCommandError.deviceBusy {
                    lastError = RazerCommandError.deviceBusy
                    if attempt < DeviceDescriptor.maxCommandRetries {
                        transport.sleep(milliseconds: UInt64(50 * attempt))
                    }
                } catch {
                    throw error
                }
            }

            throw lastError ?? RazerCommandError.deviceBusy
        }
    }

    public func probeScrollMode() throws -> CommandSendResult {
        try withLifecycleBoundary {
            try sendAllowingUnsupported(.getScrollMode())
        }
    }

    public func probeScrollAcceleration() throws -> CommandSendResult {
        try withLifecycleBoundary {
            try sendAllowingUnsupported(.getScrollAcceleration())
        }
    }

    public func probeScrollSmartReel() throws -> CommandSendResult {
        try withLifecycleBoundary {
            try sendAllowingUnsupported(.getScrollSmartReel())
        }
    }

    public func setScrollMode(_ mode: ScrollWheelMode) throws -> CommandSendResult {
        try withLifecycleBoundary {
            try sendAllowingUnsupported(.setScrollMode(mode))
        }
    }

    public func setScrollAcceleration(_ enabled: Bool) throws -> CommandSendResult {
        try withLifecycleBoundary {
            try sendAllowingUnsupported(.setScrollAcceleration(enabled))
        }
    }

    public func setScrollSmartReel(_ enabled: Bool) throws -> CommandSendResult {
        try withLifecycleBoundary {
            try sendAllowingUnsupported(.setScrollSmartReel(enabled))
        }
    }

    public func readWheelHardwareState() throws -> HardwareWheelSettings {
        try withLifecycleBoundary {
            var settings = HardwareWheelSettings()
            switch try probeScrollMode() {
            case let .success(report):
                settings.scrollMode = report.decodeScrollMode()
            case .notSupported:
                break
            }
            switch try probeScrollAcceleration() {
            case let .success(report):
                settings.accelerationEnabled = report.decodeBoolArgument()
            case .notSupported:
                break
            }
            switch try probeScrollSmartReel() {
            case let .success(report):
                settings.smartReelEnabled = report.decodeBoolArgument()
            case .notSupported:
                break
            }
            return settings
        }
    }

    public struct WheelHardwareReadback: Equatable, Sendable {
        public var settings: HardwareWheelSettings
        public var errors: [String]

        public init(settings: HardwareWheelSettings = .init(), errors: [String] = []) {
            self.settings = settings
            self.errors = errors
        }
    }

    public func readWheelHardwareState(capability: WheelHardwareCapability) -> WheelHardwareReadback {
        withLifecycleBoundary {
            var settings = HardwareWheelSettings()
            var errors: [String] = []

            if capability.scrollMode == .supported {
                do {
                    switch try probeScrollMode() {
                    case let .success(report):
                        settings.scrollMode = report.decodeScrollMode()
                    case .notSupported:
                        break
                    }
                } catch {
                    errors.append("scroll mode readback: \(error.localizedDescription)")
                }
            }

            if capability.acceleration == .supported {
                do {
                    switch try probeScrollAcceleration() {
                    case let .success(report):
                        settings.accelerationEnabled = report.decodeBoolArgument()
                    case .notSupported:
                        break
                    }
                } catch {
                    errors.append("acceleration readback: \(error.localizedDescription)")
                }
            }

            if capability.smartReel == .supported {
                do {
                    switch try probeScrollSmartReel() {
                    case let .success(report):
                        settings.smartReelEnabled = report.decodeBoolArgument()
                    case .notSupported:
                        break
                    }
                } catch {
                    errors.append("smart reel readback: \(error.localizedDescription)")
                }
            }

            return WheelHardwareReadback(settings: settings, errors: errors)
        }
    }

    private func performRoundTripAllowingUnsupported(_ request: RazerReport) throws -> CommandSendResult {
        let payload = request.bytes
        try transport.setFeatureReport(payload)
        let initialWait = min(
            DeviceDescriptor.responseWaitMilliseconds,
            DeviceDescriptor.responseDeadlineMilliseconds
        )
        transport.sleep(milliseconds: initialWait)
        var elapsedMilliseconds = initialWait

        while true {
            let response = try transport.getFeatureReport(length: RazerReport.length)
            guard response.count == RazerReport.length else {
                throw RazerCommandError.invalidResponse(
                    "Expected \(RazerReport.length) bytes, got \(response.count)."
                )
            }

            let report = try RazerReport(bytes: response)
            do {
                return try RazerResponseValidator.validate(
                    response: report,
                    for: request,
                    allowingUnsupported: true
                )
            } catch let RazerCommandError.blockedDeviceAccess(details) {
                guard elapsedMilliseconds < DeviceDescriptor.responseDeadlineMilliseconds else {
                    throw RazerCommandError.blockedDeviceAccess(details)
                }
                let pollWait = min(
                    DeviceDescriptor.responsePollIntervalMilliseconds,
                    DeviceDescriptor.responseDeadlineMilliseconds - elapsedMilliseconds
                )
                transport.sleep(milliseconds: pollWait)
                elapsedMilliseconds += pollWait
            }
        }
    }

    private func performRoundTrip(_ request: RazerReport) throws -> RazerReport {
        switch try performRoundTripAllowingUnsupported(request) {
        case let .success(report):
            return report
        case .notSupported:
            throw RazerCommandError.unsupportedCommand
        }
    }

    private func withLifecycleBoundary<T>(_ operation: () throws -> T) rethrows -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try operation()
    }
}
