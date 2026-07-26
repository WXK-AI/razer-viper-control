import Foundation

/// Wire-protocol family. Determines which command encoder a device speaks.
public enum DeviceFamily: String, Sendable, Equatable, Hashable, CaseIterable {
    case razer
}

/// How much trust the parameters in a `MouseModel` carry.
public enum SupportTier: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Maintainer owns the hardware; wire bytes confirmed against it.
    case verified
}

/// The device-dependent bounds that profile editing, persistence, and hardware
/// writes validate against.
///
/// Deliberately narrower than `MouseModel`: `ProfileStore`, `ProfileDraft`, and
/// `ProfileSafetyValidator` must not be able to reach protocol parameters such as
/// `transactionID`.
public struct ProfileLimits: Sendable, Equatable, Hashable {
    public let dpiRange: ClosedRange<Int>
    public let maxDPIStages: Int
    public let pollingRates: [Int]

    public init(dpiRange: ClosedRange<Int>, maxDPIStages: Int, pollingRates: [Int]) {
        precondition(maxDPIStages >= 1, "ProfileLimits requires at least one DPI stage.")
        precondition(!pollingRates.isEmpty, "ProfileLimits requires at least one polling rate.")
        self.dpiRange = dpiRange
        self.maxDPIStages = maxDPIStages
        self.pollingRates = pollingRates
    }

    public struct ValidatedStages: Equatable, Sendable {
        public let stages: [Int]
        public let activeStage: Int

        public init(stages: [Int], activeStage: Int) {
            self.stages = stages
            self.activeStage = activeStage
        }
    }

    @discardableResult
    public func validateDPI(_ dpi: Int) throws -> Int {
        guard dpiRange.contains(dpi) else {
            throw RazerValidationError.invalidDPI(dpi, allowed: dpiRange)
        }
        return dpi
    }

    /// Guard order is load-bearing: empty → count → active stage → per-stage DPI.
    /// `ProfileValidatorTests` asserts each boundary independently.
    public func validateStages(_ stages: [Int], activeStage: Int) throws -> ValidatedStages {
        guard !stages.isEmpty else {
            throw RazerValidationError.emptyDPIStages
        }
        guard stages.count <= maxDPIStages else {
            throw RazerValidationError.tooManyDPIStages(stages.count, maximum: maxDPIStages)
        }
        guard activeStage >= 1, activeStage <= stages.count else {
            throw RazerValidationError.invalidActiveStage(activeStage, stageCount: stages.count)
        }
        for dpi in stages {
            try validateDPI(dpi)
        }
        return ValidatedStages(stages: stages, activeStage: activeStage)
    }

    public func validatePollingRate(_ rate: Int) throws {
        guard pollingRates.contains(rate) else {
            throw RazerValidationError.unsupportedPollingRate(rate, supported: pollingRates)
        }
    }
}

/// Per-device protocol parameters, capability limits, and HID matching data.
///
/// A value, never a global. Every encoder, validator, client, and store that used to
/// read a shared device constant now receives one of these explicitly.
///
/// `minimumFeatureReportSize` is a *discovery* threshold — the control interface must
/// advertise at least this many feature-report bytes — and is compared with `>=`.
/// `RazerReport.length` is a separate protocol constant: the Razer configuration packet
/// is exactly 90 bytes for the whole family. Both are 90 here; they must not be merged.
public struct MouseModel: Sendable, Equatable, Hashable, Identifiable {
    public let family: DeviceFamily
    public let vendorID: UInt16
    public let productID: UInt16
    public let name: String
    public let supportTier: SupportTier

    /// Byte 1 of every Razer configuration packet.
    public let transactionID: UInt8

    public let primaryUsagePage: UInt32
    public let primaryUsage: UInt32
    /// Minimum `kIOHIDMaxFeatureReportSizeKey` a control interface must report.
    public let minimumFeatureReportSize: Int

    public let responseWaitMilliseconds: UInt64
    public let responsePollIntervalMilliseconds: UInt64
    public let responseDeadlineMilliseconds: UInt64
    public let maxCommandRetries: Int

    public let dpiRange: ClosedRange<Int>
    public let maxDPIStages: Int
    public let pollingRates: [Int]

    /// Profile-file key. Rendering is frozen: existing
    /// `~/Library/Application Support/RazerMenuBarApp/profiles-1532:00B8.json` files
    /// must keep resolving. Computed so a registry entry cannot typo it out of sync
    /// with the vendor/product IDs.
    public var deviceKey: String { String(format: "%04X:%04X", vendorID, productID) }

    public var id: String { deviceKey }

    public var limits: ProfileLimits {
        ProfileLimits(dpiRange: dpiRange, maxDPIStages: maxDPIStages, pollingRates: pollingRates)
    }

    public init(
        family: DeviceFamily,
        vendorID: UInt16,
        productID: UInt16,
        name: String,
        supportTier: SupportTier,
        transactionID: UInt8,
        primaryUsagePage: UInt32,
        primaryUsage: UInt32,
        minimumFeatureReportSize: Int,
        responseWaitMilliseconds: UInt64,
        responsePollIntervalMilliseconds: UInt64,
        responseDeadlineMilliseconds: UInt64,
        maxCommandRetries: Int,
        dpiRange: ClosedRange<Int>,
        maxDPIStages: Int,
        pollingRates: [Int]
    ) {
        // Both are structurally impossible while these are compile-time constants and
        // become reachable the moment they are per-model. `1...n` traps when n < 1
        // (RazerCommandClient.send), and a zero poll interval wedges the response
        // wait loop forever because elapsed time would never advance.
        precondition(maxCommandRetries >= 1, "MouseModel.maxCommandRetries must be >= 1.")
        precondition(
            responsePollIntervalMilliseconds > 0,
            "MouseModel.responsePollIntervalMilliseconds must be > 0."
        )
        precondition(maxDPIStages >= 1, "MouseModel.maxDPIStages must be >= 1.")
        precondition(!pollingRates.isEmpty, "MouseModel.pollingRates must not be empty.")

        self.family = family
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.supportTier = supportTier
        self.transactionID = transactionID
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
        self.minimumFeatureReportSize = minimumFeatureReportSize
        self.responseWaitMilliseconds = responseWaitMilliseconds
        self.responsePollIntervalMilliseconds = responsePollIntervalMilliseconds
        self.responseDeadlineMilliseconds = responseDeadlineMilliseconds
        self.maxCommandRetries = maxCommandRetries
        self.dpiRange = dpiRange
        self.maxDPIStages = maxDPIStages
        self.pollingRates = pollingRates
    }
}

extension MouseModel {
    public static let viperV3HyperSpeed = MouseModel(
        family: .razer,
        vendorID: 0x1532,
        productID: 0x00B8,
        name: "Razer Viper V3 HyperSpeed",
        supportTier: .verified,
        transactionID: 0x1F,
        primaryUsagePage: 1,
        primaryUsage: 2,
        minimumFeatureReportSize: 90,
        responseWaitMilliseconds: 15,
        responsePollIntervalMilliseconds: 15,
        responseDeadlineMilliseconds: 200,
        maxCommandRetries: 5,
        dpiRange: 100...30_000,
        maxDPIStages: 5,
        pollingRates: [125, 500, 1000]
    )
}

extension ProfileLimits {
    public static let viperV3HyperSpeed = MouseModel.viperV3HyperSpeed.limits
}
