import Foundation

public protocol RazerHardwareMutating: AnyObject {
    func readState() throws -> DeviceState
    func setDPI(x: Int, y: Int) throws
    func setPollingRate(hz: Int) throws
    func send(_ request: RazerReport) throws -> RazerReport
    func readWheelHardwareState(capability: WheelHardwareCapability) -> RazerCommandClient.WheelHardwareReadback
    func setScrollMode(_ mode: ScrollWheelMode) throws -> CommandSendResult
    func setScrollAcceleration(_ enabled: Bool) throws -> CommandSendResult
    func setScrollSmartReel(_ enabled: Bool) throws -> CommandSendResult
}

extension RazerCommandClient: RazerHardwareMutating {}

public enum HardwareTransactionPhase: String, Equatable, Sendable {
    case captureOriginal
    case setTemporaryDPI
    case verifyTemporaryDPI
    case setTemporaryPolling
    case verifyTemporaryPolling
    case restoreDPI
    case restorePolling
    case verifyRestored
    case captureWheelOriginal
    case mutateWheel
    case restoreWheel
    case verifyWheelRestored
}

public enum HardwareTransactionError: Error, Equatable, LocalizedError {
    case unknownOriginal(String)
    case verificationFailed(String)
    case restorationFailed(primary: String, restoration: String)
    case injectedFailure(HardwareTransactionPhase)

    public var errorDescription: String? {
        switch self {
        case let .unknownOriginal(feature):
            return "Cannot mutate \(feature) because the original value is unknown."
        case let .verificationFailed(details):
            return "Hardware verification failed: \(details)"
        case let .restorationFailed(primary, restoration):
            return "\(primary) Restoration also failed: \(restoration)"
        case let .injectedFailure(phase):
            return "Injected failure after \(phase.rawValue)."
        }
    }
}

public struct HardwareStateSnapshot: Equatable, Sendable {
    public var dpiX: Int
    public var dpiY: Int
    public var pollingRateHz: Int
    public var wheel: HardwareWheelSettings

    public init(
        dpiX: Int,
        dpiY: Int,
        pollingRateHz: Int,
        wheel: HardwareWheelSettings = .init()
    ) {
        self.dpiX = dpiX
        self.dpiY = dpiY
        self.pollingRateHz = pollingRateHz
        self.wheel = wheel
    }
}

public enum HardwareStateTransaction {
    public struct IntegrationResult: Equatable, Sendable {
        public var original: HardwareStateSnapshot
        public var temporaryDPI: (x: Int, y: Int)
        public var temporaryPollingHz: Int
        public var restored: HardwareStateSnapshot

        public static func == (lhs: IntegrationResult, rhs: IntegrationResult) -> Bool {
            lhs.original == rhs.original
                && lhs.temporaryDPI.x == rhs.temporaryDPI.x
                && lhs.temporaryDPI.y == rhs.temporaryDPI.y
                && lhs.temporaryPollingHz == rhs.temporaryPollingHz
                && lhs.restored == rhs.restored
        }
    }

    /// Runs a temporary DPI/polling mutation with guaranteed restoration.
    /// `failAfter` injects a failure after the named phase completes (for tests).
    public static func runIntegration(
        client: RazerHardwareMutating,
        temporaryDPI: Int,
        temporaryPollingHz: Int,
        failAfter: HardwareTransactionPhase? = nil
    ) throws -> IntegrationResult {
        try ProfileValidator.validatePollingRate(temporaryPollingHz)
        guard (DeviceDescriptor.minDPI...DeviceDescriptor.maxDPI).contains(temporaryDPI) else {
            throw RazerValidationError.invalidDPI(temporaryDPI)
        }

        let originalState = try client.readState()
        try maybeFail(after: .captureOriginal, failAfter)
        let original = HardwareStateSnapshot(
            dpiX: originalState.dpiX,
            dpiY: originalState.dpiY,
            pollingRateHz: originalState.pollingRateHz
        )

        var primaryError: Error?
        do {
            try client.setDPI(x: temporaryDPI, y: temporaryDPI)
            try maybeFail(after: .setTemporaryDPI, failAfter)

            let readDPI = try client.send(.getDPI()).decodeDPI()
            guard readDPI.x == temporaryDPI, readDPI.y == temporaryDPI else {
                throw HardwareTransactionError.verificationFailed(
                    "temporary DPI expected \(temporaryDPI)x\(temporaryDPI), got \(readDPI.x)x\(readDPI.y)"
                )
            }
            try maybeFail(after: .verifyTemporaryDPI, failAfter)

            try client.setPollingRate(hz: temporaryPollingHz)
            try maybeFail(after: .setTemporaryPolling, failAfter)

            let readPolling = try client.send(.getPollingRate()).decodePollingRateHz()
            guard let readPolling, readPolling == temporaryPollingHz else {
                throw HardwareTransactionError.verificationFailed(
                    "temporary polling expected \(temporaryPollingHz), got \(readPolling.map(String.init) ?? "unknown")"
                )
            }
            try maybeFail(after: .verifyTemporaryPolling, failAfter)
        } catch {
            primaryError = error
        }

        let restored: HardwareStateSnapshot
        do {
            try client.setDPI(x: original.dpiX, y: original.dpiY)
            try maybeFail(after: .restoreDPI, failAfter)
            try client.setPollingRate(hz: original.pollingRateHz)
            try maybeFail(after: .restorePolling, failAfter)

            let restoredState = try client.readState()
            restored = HardwareStateSnapshot(
                dpiX: restoredState.dpiX,
                dpiY: restoredState.dpiY,
                pollingRateHz: restoredState.pollingRateHz
            )
            guard restored.dpiX == original.dpiX,
                  restored.dpiY == original.dpiY,
                  restored.pollingRateHz == original.pollingRateHz else {
                throw HardwareTransactionError.verificationFailed(
                    "restored DPI/polling mismatch (got \(restored.dpiX)x\(restored.dpiY) @ \(restored.pollingRateHz) Hz)"
                )
            }
            try maybeFail(after: .verifyRestored, failAfter)
        } catch {
            if let primaryError {
                throw HardwareTransactionError.restorationFailed(
                    primary: primaryError.localizedDescription,
                    restoration: error.localizedDescription
                )
            }
            throw error
        }

        if let primaryError {
            throw primaryError
        }

        return IntegrationResult(
            original: original,
            temporaryDPI: (temporaryDPI, temporaryDPI),
            temporaryPollingHz: temporaryPollingHz,
            restored: restored
        )
    }

    /// Mutates supported wheel features and restores exact originals. Skips any feature whose original is unknown.
    public static func runWheelProbeMutation(
        client: RazerHardwareMutating,
        capability: WheelHardwareCapability,
        failAfter: HardwareTransactionPhase? = nil
    ) throws -> HardwareWheelSettings {
        let originalReadback = client.readWheelHardwareState(capability: capability)
        try maybeFail(after: .captureWheelOriginal, failAfter)
        let original = originalReadback.settings

        if capability.scrollMode == .supported, original.scrollMode == nil {
            throw HardwareTransactionError.unknownOriginal("scroll mode")
        }
        if capability.acceleration == .supported, original.accelerationEnabled == nil {
            throw HardwareTransactionError.unknownOriginal("scroll acceleration")
        }
        if capability.smartReel == .supported, original.smartReelEnabled == nil {
            throw HardwareTransactionError.unknownOriginal("smart reel")
        }

        var primaryError: Error?
        do {
            if capability.scrollMode == .supported, let mode = original.scrollMode {
                let alternate: ScrollWheelMode = mode == .tactile ? .freeSpin : .tactile
                _ = try client.setScrollMode(alternate)
            }
            if capability.acceleration == .supported, let enabled = original.accelerationEnabled {
                _ = try client.setScrollAcceleration(!enabled)
            }
            if capability.smartReel == .supported, let enabled = original.smartReelEnabled {
                _ = try client.setScrollSmartReel(!enabled)
            }
            try maybeFail(after: .mutateWheel, failAfter)
        } catch {
            primaryError = error
        }

        let restored: HardwareWheelSettings
        do {
            if let mode = original.scrollMode {
                _ = try client.setScrollMode(mode)
            }
            if let enabled = original.accelerationEnabled {
                _ = try client.setScrollAcceleration(enabled)
            }
            if let enabled = original.smartReelEnabled {
                _ = try client.setScrollSmartReel(enabled)
            }
            try maybeFail(after: .restoreWheel, failAfter)

            restored = client.readWheelHardwareState(capability: capability).settings
            if capability.scrollMode == .supported {
                guard restored.scrollMode == original.scrollMode else {
                    throw HardwareTransactionError.verificationFailed("scroll mode not restored")
                }
            }
            if capability.acceleration == .supported {
                guard restored.accelerationEnabled == original.accelerationEnabled else {
                    throw HardwareTransactionError.verificationFailed("acceleration not restored")
                }
            }
            if capability.smartReel == .supported {
                guard restored.smartReelEnabled == original.smartReelEnabled else {
                    throw HardwareTransactionError.verificationFailed("smart reel not restored")
                }
            }
            try maybeFail(after: .verifyWheelRestored, failAfter)
        } catch {
            if let primaryError {
                throw HardwareTransactionError.restorationFailed(
                    primary: primaryError.localizedDescription,
                    restoration: error.localizedDescription
                )
            }
            throw error
        }

        if let primaryError {
            throw primaryError
        }
        return restored
    }

    private static func maybeFail(after phase: HardwareTransactionPhase, _ failAfter: HardwareTransactionPhase?) throws {
        if failAfter == phase {
            throw HardwareTransactionError.injectedFailure(phase)
        }
    }
}
