import Foundation
import IOKit.hid

public enum RazerCommandError: Error, LocalizedError {
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

public final class RazerCommandClient {
    private let device: IOHIDDevice
    private let reportID: CFIndex = 0

    public init(device: IOHIDDevice) {
        self.device = device
    }

    public func open(nonSeizing: Bool = true) throws {
        let options = nonSeizing
            ? IOOptionBits(kIOHIDOptionsTypeNone)
            : IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        let result = IOHIDDeviceOpen(device, options)
        guard result == kIOReturnSuccess else {
            throw mapOpenError(result)
        }
    }

    public func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    @discardableResult
    public func send(_ request: RazerReport) throws -> RazerReport {
        var lastError: Error?

        for attempt in 1...DeviceDescriptor.maxCommandRetries {
            do {
                return try performRoundTrip(request)
            } catch RazerCommandError.deviceBusy {
                lastError = RazerCommandError.deviceBusy
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt))
            } catch {
                throw error
            }
        }

        throw lastError ?? RazerCommandError.deviceBusy
    }

    public func readState() throws -> DeviceState {
        let battery = try send(.getBatteryLevel())
        let charging = try send(.getChargingStatus())
        let dpi = try send(.getDPI())
        let stages = try send(.getDPIStages())
        let polling = try send(.getPollingRate())

        let decodedStages = stages.decodeDPIStages()
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

    public func setDPI(_ dpi: Int) throws {
        _ = try send(try .setDPI(x: dpi, y: dpi))
    }

    public func setDPIStages(activeStage: Int, stages: [Int]) throws {
        _ = try send(try .setDPIStages(activeStage: activeStage, stages: stages))
    }

    public func setPollingRate(hz: Int) throws {
        try ProfileValidator.validatePollingRate(hz)
        _ = try send(try .setPollingRate(hz: hz))
    }

    public func sendAllowingUnsupported(_ request: RazerReport) throws -> CommandSendResult {
        var lastError: Error?

        for attempt in 1...DeviceDescriptor.maxCommandRetries {
            do {
                let report = try performRoundTripAllowingUnsupported(request)
                return report
            } catch RazerCommandError.deviceBusy {
                lastError = RazerCommandError.deviceBusy
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt))
            } catch {
                throw error
            }
        }

        throw lastError ?? RazerCommandError.deviceBusy
    }

    public func probeScrollMode() throws -> CommandSendResult {
        try sendAllowingUnsupported(.getScrollMode())
    }

    public func probeScrollAcceleration() throws -> CommandSendResult {
        try sendAllowingUnsupported(.getScrollAcceleration())
    }

    public func probeScrollSmartReel() throws -> CommandSendResult {
        try sendAllowingUnsupported(.getScrollSmartReel())
    }

    public func setScrollMode(_ mode: ScrollWheelMode) throws -> CommandSendResult {
        try sendAllowingUnsupported(.setScrollMode(mode))
    }

    public func setScrollAcceleration(_ enabled: Bool) throws -> CommandSendResult {
        try sendAllowingUnsupported(.setScrollAcceleration(enabled))
    }

    public func setScrollSmartReel(_ enabled: Bool) throws -> CommandSendResult {
        try sendAllowingUnsupported(.setScrollSmartReel(enabled))
    }

    public func readWheelHardwareState() throws -> HardwareWheelSettings {
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

    public struct WheelHardwareReadback: Equatable, Sendable {
        public var settings: HardwareWheelSettings
        public var errors: [String]

        public init(settings: HardwareWheelSettings = .init(), errors: [String] = []) {
            self.settings = settings
            self.errors = errors
        }
    }

    public func readWheelHardwareState(capability: WheelHardwareCapability) -> WheelHardwareReadback {
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

    private func performRoundTripAllowingUnsupported(_ request: RazerReport) throws -> CommandSendResult {
        let payload = request.bytes

        let setResult = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            reportID,
            payload,
            payload.count
        )

        guard setResult == kIOReturnSuccess else {
            throw mapTransportError(setResult, phase: "set")
        }

        usleep(useconds_t(DeviceDescriptor.responseWaitMilliseconds * 1000))

        var response = [UInt8](repeating: 0, count: RazerReport.length)
        var responseLength = response.count

        let getResult = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            reportID,
            &response,
            &responseLength
        )

        guard getResult == kIOReturnSuccess else {
            throw mapTransportError(getResult, phase: "get")
        }

        guard responseLength == RazerReport.length else {
            throw RazerCommandError.invalidResponse("Expected \(RazerReport.length) bytes, got \(responseLength).")
        }

        let report = try RazerReport(bytes: response)
        return try validateResponseAllowingUnsupported(report, for: request)
    }

    private func performRoundTrip(_ request: RazerReport) throws -> RazerReport {
        switch try performRoundTripAllowingUnsupported(request) {
        case let .success(report):
            return report
        case .notSupported:
            throw RazerCommandError.unsupportedCommand
        }
    }

    private func validateResponseAllowingUnsupported(_ response: RazerReport, for request: RazerReport) throws -> CommandSendResult {
        let expectedCRC = RazerReport.calculateCRC(for: response.bytes)
        guard response.crc == expectedCRC else {
            throw RazerCommandError.invalidResponse("CRC mismatch.")
        }

        switch response.responseStatus {
        case .successful:
            return .success(response)
        case .busy:
            throw RazerCommandError.deviceBusy
        case .notSupported:
            return .notSupported
        case .timeout:
            throw RazerCommandError.timeout
        case .failure:
            throw RazerCommandError.invalidResponse("Command failed.")
        case .newCommand, .none:
            if response.status == 0x00 && response.commandClass == request.commandClass {
                throw RazerCommandError.blockedDeviceAccess("status 0x00 — no acknowledgement")
            }
            throw RazerCommandError.invalidResponse("status 0x\(String(response.status, radix: 16))")
        }
    }

    private func validateResponse(_ response: RazerReport, for request: RazerReport) throws -> RazerReport {
        switch try validateResponseAllowingUnsupported(response, for: request) {
        case let .success(report):
            return report
        case .notSupported:
            throw RazerCommandError.unsupportedCommand
        }
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
