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

public enum HardwareTransactionPhase: String, Equatable, Sendable, CaseIterable {
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
    case verifyTemporaryWheel
    case restoreWheel
    case verifyWheelRestored
}

public enum HardwareTransactionError: Error, Equatable, LocalizedError {
    case unknownOriginal(String)
    case unknownCapability(String)
    case verificationFailed(String)
    case restorationFailed(primary: String, restoration: String)
    case injectedFailure(HardwareTransactionPhase)

    public var errorDescription: String? {
        switch self {
        case let .unknownOriginal(feature):
            return "Cannot mutate \(feature) because the original value is unknown."
        case let .unknownCapability(feature):
            return "Cannot mutate \(feature) because capability probe returned unknown."
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

    /// Runs a temporary DPI/polling mutation with guaranteed independent restoration.
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
        guard let originalPollingRateHz = originalState.pollingRateHz else {
            throw HardwareTransactionError.unknownOriginal("polling rate")
        }
        try maybeFail(after: .captureOriginal, failAfter)
        let original = HardwareStateSnapshot(
            dpiX: originalState.dpiX,
            dpiY: originalState.dpiY,
            pollingRateHz: originalPollingRateHz
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

        var restorationErrors: [String] = []

        do {
            try client.setDPI(x: original.dpiX, y: original.dpiY)
            try maybeFail(after: .restoreDPI, failAfter)
        } catch {
            restorationErrors.append("DPI restore: \(error.localizedDescription)")
        }

        do {
            try client.setPollingRate(hz: original.pollingRateHz)
            try maybeFail(after: .restorePolling, failAfter)
        } catch {
            restorationErrors.append("polling restore: \(error.localizedDescription)")
        }

        let restoredState: DeviceState
        do {
            restoredState = try client.readState()
        } catch {
            restorationErrors.append("restored readback: \(error.localizedDescription)")
            throw finalizeErrors(primary: primaryError, restoration: restorationErrors)
        }

        guard let restoredPollingRateHz = restoredState.pollingRateHz else {
            restorationErrors.append("restored polling readback is unknown")
            throw finalizeErrors(primary: primaryError, restoration: restorationErrors)
        }
        let restored = HardwareStateSnapshot(
            dpiX: restoredState.dpiX,
            dpiY: restoredState.dpiY,
            pollingRateHz: restoredPollingRateHz
        )

        do {
            guard restored.dpiX == original.dpiX,
                  restored.dpiY == original.dpiY,
                  restored.pollingRateHz == original.pollingRateHz else {
                throw HardwareTransactionError.verificationFailed(
                    "restored DPI/polling mismatch (got \(restored.dpiX)x\(restored.dpiY) @ \(restored.pollingRateHz) Hz)"
                )
            }
            try maybeFail(after: .verifyRestored, failAfter)
        } catch {
            restorationErrors.append(error.localizedDescription)
        }

        if !restorationErrors.isEmpty || primaryError != nil {
            throw finalizeErrors(primary: primaryError, restoration: restorationErrors)
        }

        return IntegrationResult(
            original: original,
            temporaryDPI: (temporaryDPI, temporaryDPI),
            temporaryPollingHz: temporaryPollingHz,
            restored: restored
        )
    }

    /// Mutates supported wheel features, verifies temporary values, and restores originals independently.
    public static func runWheelProbeMutation(
        client: RazerHardwareMutating,
        capability: WheelHardwareCapability,
        failAfter: HardwareTransactionPhase? = nil
    ) throws -> HardwareWheelSettings {
        try rejectUnknownCapabilities(capability)

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

        var expectedTemporary = original
        var primaryError: Error?
        do {
            if capability.scrollMode == .supported, let mode = original.scrollMode {
                let alternate: ScrollWheelMode = mode == .tactile ? .freeSpin : .tactile
                switch try client.setScrollMode(alternate) {
                case .success:
                    expectedTemporary.scrollMode = alternate
                case .notSupported:
                    throw HardwareTransactionError.verificationFailed("set scroll mode returned notSupported")
                }
            }
            if capability.acceleration == .supported, let enabled = original.accelerationEnabled {
                let target = !enabled
                switch try client.setScrollAcceleration(target) {
                case .success:
                    expectedTemporary.accelerationEnabled = target
                case .notSupported:
                    throw HardwareTransactionError.verificationFailed("set acceleration returned notSupported")
                }
            }
            if capability.smartReel == .supported, let enabled = original.smartReelEnabled {
                let target = !enabled
                switch try client.setScrollSmartReel(target) {
                case .success:
                    expectedTemporary.smartReelEnabled = target
                case .notSupported:
                    throw HardwareTransactionError.verificationFailed("set smart reel returned notSupported")
                }
            }
            try maybeFail(after: .mutateWheel, failAfter)

            let temporary = client.readWheelHardwareState(capability: capability).settings
            if capability.scrollMode == .supported {
                guard temporary.scrollMode == expectedTemporary.scrollMode else {
                    throw HardwareTransactionError.verificationFailed("temporary scroll mode mismatch")
                }
            }
            if capability.acceleration == .supported {
                guard temporary.accelerationEnabled == expectedTemporary.accelerationEnabled else {
                    throw HardwareTransactionError.verificationFailed("temporary acceleration mismatch")
                }
            }
            if capability.smartReel == .supported {
                guard temporary.smartReelEnabled == expectedTemporary.smartReelEnabled else {
                    throw HardwareTransactionError.verificationFailed("temporary smart reel mismatch")
                }
            }
            try maybeFail(after: .verifyTemporaryWheel, failAfter)
        } catch {
            primaryError = error
        }

        var restorationErrors: [String] = []

        if let mode = original.scrollMode {
            do {
                switch try client.setScrollMode(mode) {
                case .success:
                    break
                case .notSupported:
                    throw HardwareTransactionError.verificationFailed("restore scroll mode returned notSupported")
                }
            } catch {
                restorationErrors.append("scroll mode restore: \(error.localizedDescription)")
            }
        }
        if let enabled = original.accelerationEnabled {
            do {
                switch try client.setScrollAcceleration(enabled) {
                case .success:
                    break
                case .notSupported:
                    throw HardwareTransactionError.verificationFailed("restore acceleration returned notSupported")
                }
            } catch {
                restorationErrors.append("acceleration restore: \(error.localizedDescription)")
            }
        }
        if let enabled = original.smartReelEnabled {
            do {
                switch try client.setScrollSmartReel(enabled) {
                case .success:
                    break
                case .notSupported:
                    throw HardwareTransactionError.verificationFailed("restore smart reel returned notSupported")
                }
            } catch {
                restorationErrors.append("smart reel restore: \(error.localizedDescription)")
            }
        }

        do {
            try maybeFail(after: .restoreWheel, failAfter)
        } catch {
            restorationErrors.append(error.localizedDescription)
        }

        let restored = client.readWheelHardwareState(capability: capability).settings
        do {
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
            restorationErrors.append(error.localizedDescription)
        }

        if !restorationErrors.isEmpty || primaryError != nil {
            throw finalizeErrors(primary: primaryError, restoration: restorationErrors)
        }
        return restored
    }

    public static func rejectUnknownCapabilities(_ capability: WheelHardwareCapability) throws {
        if capability.scrollMode == .unknown {
            throw HardwareTransactionError.unknownCapability("scroll mode")
        }
        if capability.acceleration == .unknown {
            throw HardwareTransactionError.unknownCapability("scroll acceleration")
        }
        if capability.smartReel == .unknown {
            throw HardwareTransactionError.unknownCapability("smart reel")
        }
    }

    private static func finalizeErrors(primary: Error?, restoration: [String]) -> Error {
        if restoration.isEmpty, let primary {
            return primary
        }
        let restorationMessage = restoration.isEmpty ? "none" : restoration.joined(separator: "; ")
        if let primary {
            return HardwareTransactionError.restorationFailed(
                primary: primary.localizedDescription,
                restoration: restorationMessage
            )
        }
        return HardwareTransactionError.verificationFailed(restorationMessage)
    }

    private static func maybeFail(after phase: HardwareTransactionPhase, _ failAfter: HardwareTransactionPhase?) throws {
        if failAfter == phase {
            throw HardwareTransactionError.injectedFailure(phase)
        }
    }
}
