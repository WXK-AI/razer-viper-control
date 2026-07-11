import Foundation

public enum PersistenceStatus: Equatable, Sendable {
    case clean
    case dirty
    case failed(String)
}

/// Editable hardware fields kept as draft text until every value is valid.
public struct ProfileDraft: Equatable, Sendable {
    public var name: String
    public var stageTexts: [String]
    public var activeStage: Int
    public var pollingRateHz: Int
    public var autoReapplyEnabled: Bool
    public var remapperEnabled: Bool

    public init(profile: MouseProfile) {
        name = profile.name
        stageTexts = profile.dpiStages.map(String.init)
        activeStage = profile.activeStage
        pollingRateHz = profile.pollingRateHz
        autoReapplyEnabled = profile.autoReapplyEnabled
        remapperEnabled = profile.remapperEnabled
    }

    public init(
        name: String,
        stageTexts: [String],
        activeStage: Int,
        pollingRateHz: Int,
        autoReapplyEnabled: Bool = true,
        remapperEnabled: Bool = true
    ) {
        self.name = name
        self.stageTexts = stageTexts
        self.activeStage = activeStage
        self.pollingRateHz = pollingRateHz
        self.autoReapplyEnabled = autoReapplyEnabled
        self.remapperEnabled = remapperEnabled
    }

    public var stageErrors: [String?] {
        stageTexts.map { text in
            Self.stageError(for: text)
        }
    }

    public var activeStageError: String? {
        guard let stages = try? parsedStages() else {
            return nil
        }
        guard (1...stages.count).contains(activeStage) else {
            return "Active stage must be between 1 and \(stages.count)."
        }
        return nil
    }

    public var pollingError: String? {
        guard DeviceDescriptor.supportedPollingRates.contains(pollingRateHz) else {
            return "Polling rate must be 125, 500, or 1000 Hz."
        }
        return nil
    }

    public var isValid: Bool {
        stageErrors.allSatisfy { $0 == nil }
            && activeStageError == nil
            && pollingError == nil
            && !stageTexts.isEmpty
    }

    public func parsedStages() throws -> [Int] {
        var stages: [Int] = []
        for (index, text) in stageTexts.enumerated() {
            if let error = Self.stageError(for: text) {
                throw DraftValidationError.stage(index: index, message: error)
            }
            stages.append(Int(text.trimmingCharacters(in: .whitespacesAndNewlines))!)
        }
        guard !stages.isEmpty else {
            throw DraftValidationError.emptyStages
        }
        guard stages.count <= DeviceDescriptor.maxDPIStages else {
            throw DraftValidationError.tooManyStages(stages.count)
        }
        return stages
    }

    public func validatedHardware() throws -> (stages: [Int], activeStage: Int, pollingRateHz: Int) {
        let stages = try parsedStages()
        _ = try ProfileValidator.validateStages(stages, activeStage: activeStage)
        try ProfileValidator.validatePollingRate(pollingRateHz)
        return (stages, activeStage, pollingRateHz)
    }

    public func applying(to profile: MouseProfile) throws -> MouseProfile {
        let hardware = try validatedHardware()
        var updated = profile
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? profile.name
            : name
        updated.dpiStages = hardware.stages
        updated.activeStage = hardware.activeStage
        updated.pollingRateHz = hardware.pollingRateHz
        updated.autoReapplyEnabled = autoReapplyEnabled
        updated.remapperEnabled = remapperEnabled
        return updated
    }

    public static func stageError(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a DPI value."
        }
        guard let value = Int(trimmed) else {
            return "DPI must be a whole number."
        }
        guard (DeviceDescriptor.minDPI...DeviceDescriptor.maxDPI).contains(value) else {
            return "DPI must be between \(DeviceDescriptor.minDPI) and \(DeviceDescriptor.maxDPI)."
        }
        return nil
    }

    /// Required flush (quit / explicit save) must fail while any draft is invalid.
    public static func requiredFlushBlockReason(drafts: [ProfileDraft]) -> String? {
        if drafts.contains(where: { !$0.isValid }) {
            return "Profile draft has invalid DPI values. Fix them or discard changes before saving."
        }
        return nil
    }
}

public enum DraftValidationError: Error, Equatable, LocalizedError {
    case stage(index: Int, message: String)
    case emptyStages
    case tooManyStages(Int)

    public var errorDescription: String? {
        switch self {
        case let .stage(index, message):
            return "Stage \(index + 1): \(message)"
        case .emptyStages:
            return "At least one DPI stage is required."
        case let .tooManyStages(count):
            return "Too many DPI stages (\(count)). Maximum is \(DeviceDescriptor.maxDPIStages)."
        }
    }
}
