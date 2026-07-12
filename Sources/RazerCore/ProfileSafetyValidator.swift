import Darwin
import Foundation

public enum ProfileSafetyLimits {
    public static let maximumFileBytes = 1_048_576
    public static let maximumProfiles = 50
    public static let maximumProfileNameUTF8Bytes = 256
    public static let maximumURLUTF8Bytes = 2_048
    public static let maximumAppPathUTF8Bytes = 4_096
    public static let allowedShortcutModifierMask: UInt64 = 0x001E_0000
    public static let maximumVirtualKeyCode: UInt16 = 127
}

public enum ProfileSafetyValidationError: Error, LocalizedError, Equatable {
    case sourceSymlink
    case sourceNotRegularFile
    case sourceWrongOwner(expected: UInt32, actual: UInt32)
    case sourceTooLarge(actual: Int64)
    case invalidProfileCount(Int)
    case duplicateProfileID(UUID)
    case invalidSelection
    case invalidProfileName
    case profileNameTooLong(actual: Int)
    case invalidHardware(RazerValidationError)
    case invalidShortcut
    case invalidURL
    case urlTooLong(actual: Int)
    case invalidAppPath
    case appPathTooLong(actual: Int)

    public var errorDescription: String? {
        switch self {
        case .sourceSymlink:
            return "Profile storage must not be a symbolic link."
        case .sourceNotRegularFile:
            return "Profile storage must be a regular file."
        case let .sourceWrongOwner(expected, actual):
            return "Profile storage owner \(actual) does not match current user \(expected)."
        case let .sourceTooLarge(actual):
            return "Profile storage is \(actual) bytes; maximum is \(ProfileSafetyLimits.maximumFileBytes)."
        case let .invalidProfileCount(count):
            return "Profile storage must contain 1...\(ProfileSafetyLimits.maximumProfiles) profiles, got \(count)."
        case let .duplicateProfileID(id):
            return "Profile storage contains duplicate profile ID \(id)."
        case .invalidSelection:
            return "Profile storage has an invalid selected profile."
        case .invalidProfileName:
            return "Profile names must not be blank."
        case let .profileNameTooLong(actual):
            return "Profile name is \(actual) UTF-8 bytes; maximum is \(ProfileSafetyLimits.maximumProfileNameUTF8Bytes)."
        case let .invalidHardware(error):
            return error.localizedDescription
        case .invalidShortcut:
            return "Profile shortcut contains unsupported modifiers or key code."
        case .invalidURL:
            return "Profile URL must be an HTTP(S) URL with a host."
        case let .urlTooLong(actual):
            return "Profile URL is \(actual) UTF-8 bytes; maximum is \(ProfileSafetyLimits.maximumURLUTF8Bytes)."
        case .invalidAppPath:
            return "Profile application path must be an existing standardized absolute .app directory."
        case let .appPathTooLong(actual):
            return "Profile application path is \(actual) UTF-8 bytes; maximum is \(ProfileSafetyLimits.maximumAppPathUTF8Bytes)."
        }
    }
}

public enum ProfileSafetyValidator {
    public static func inspectSourceFile(at url: URL, fileManager: FileManager = .default) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (status.st_mode & S_IFMT) != S_IFLNK else {
            throw ProfileSafetyValidationError.sourceSymlink
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw ProfileSafetyValidationError.sourceNotRegularFile
        }

        let currentUID = getuid()
        guard status.st_uid == currentUID else {
            throw ProfileSafetyValidationError.sourceWrongOwner(expected: currentUID, actual: status.st_uid)
        }
        guard status.st_size <= Int64(ProfileSafetyLimits.maximumFileBytes) else {
            throw ProfileSafetyValidationError.sourceTooLarge(actual: status.st_size)
        }
    }

    public static func validateAndRepair(
        _ bundle: ProfileBundle,
        fileManager: FileManager = .default
    ) throws -> (bundle: ProfileBundle, repairWarnings: [String]) {
        guard (1...ProfileSafetyLimits.maximumProfiles).contains(bundle.profiles.count) else {
            throw ProfileSafetyValidationError.invalidProfileCount(bundle.profiles.count)
        }

        var repaired = bundle
        var identifiers = Set<UUID>()
        var warnings: [String] = []

        for index in repaired.profiles.indices {
            var profile = repaired.profiles[index]
            guard identifiers.insert(profile.id).inserted else {
                throw ProfileSafetyValidationError.duplicateProfileID(profile.id)
            }

            let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw ProfileSafetyValidationError.invalidProfileName
            }
            let nameBytes = trimmedName.lengthOfBytes(using: .utf8)
            guard nameBytes <= ProfileSafetyLimits.maximumProfileNameUTF8Bytes else {
                throw ProfileSafetyValidationError.profileNameTooLong(actual: nameBytes)
            }
            profile.name = trimmedName

            do {
                _ = try ProfileValidator.validateStages(profile.dpiStages, activeStage: profile.activeStage)
                try ProfileValidator.validatePollingRate(profile.pollingRateHz)
                try ProfileValidator.validateWheelSpeedMultiplier(profile.wheelSettings.software.verticalSpeedMultiplier)
            } catch let error as RazerValidationError {
                throw ProfileSafetyValidationError.invalidHardware(error)
            }

            try validateActions(in: &profile.buttonMappings, fileManager: fileManager, warnings: &warnings)
            try validateWheelActions(in: &profile.wheelSettings, fileManager: fileManager, warnings: &warnings)
            repaired.profiles[index] = profile
        }

        if let selectedID = repaired.selectedProfileID,
           repaired.profiles.contains(where: { $0.id == selectedID }) {
            return (repaired, warnings)
        }
        guard let firstID = repaired.profiles.first?.id else {
            throw ProfileSafetyValidationError.invalidSelection
        }
        repaired.selectedProfileID = firstID
        return (repaired, warnings)
    }

    private static func validateActions(
        in mappings: inout [PhysicalControl: ButtonAction],
        fileManager: FileManager,
        warnings: inout [String]
    ) throws {
        for control in mappings.keys {
            guard var action = mappings[control] else { continue }
            try validateAction(&action, fileManager: fileManager, warnings: &warnings)
            mappings[control] = action
        }
    }

    private static func validateWheelActions(
        in settings: inout WheelSettings,
        fileManager: FileManager,
        warnings: inout [String]
    ) throws {
        if var action = settings.software.wheelUpAction {
            try validateAction(&action, fileManager: fileManager, warnings: &warnings)
            settings.software.wheelUpAction = action
        }
        if var action = settings.software.wheelDownAction {
            try validateAction(&action, fileManager: fileManager, warnings: &warnings)
            settings.software.wheelDownAction = action
        }
    }

    private static func validateAction(
        _ action: ButtonAction?,
        fileManager: FileManager,
        warnings: inout [String]
    ) throws {
        guard var action else { return }
        try validateAction(&action, fileManager: fileManager, warnings: &warnings)
    }

    private static func validateAction(
        _ action: inout ButtonAction,
        fileManager: FileManager,
        warnings: inout [String]
    ) throws {
        switch action {
        case let .keyboardShortcut(shortcut):
            guard shortcut.modifierFlags & ~ProfileSafetyLimits.allowedShortcutModifierMask == 0,
                  shortcut.keyCode <= ProfileSafetyLimits.maximumVirtualKeyCode else {
                throw ProfileSafetyValidationError.invalidShortcut
            }
        case let .openURL(url):
            let bytes = url.lengthOfBytes(using: .utf8)
            guard bytes <= ProfileSafetyLimits.maximumURLUTF8Bytes else {
                throw ProfileSafetyValidationError.urlTooLong(actual: bytes)
            }
            guard ButtonActionValidator.validateOpenURL(url) == nil else {
                throw ProfileSafetyValidationError.invalidURL
            }
        case let .openApp(path):
            let bytes = path.lengthOfBytes(using: .utf8)
            guard bytes <= ProfileSafetyLimits.maximumAppPathUTF8Bytes else {
                throw ProfileSafetyValidationError.appPathTooLong(actual: bytes)
            }
            let standardizedPath = (path as NSString).standardizingPath
            guard path.hasPrefix("/"), path == standardizedPath, standardizedPath.hasSuffix(".app") else {
                throw ProfileSafetyValidationError.invalidAppPath
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory) else {
                action = .disabled
                warnings.append("Disabled Open App action because the application is missing: \(standardizedPath)")
                return
            }
            guard isDirectory.boolValue else {
                throw ProfileSafetyValidationError.invalidAppPath
            }
        case .passthrough, .disabled, .mouseButton, .nextDPIStage, .previousDPIStage, .nextProfile, .previousProfile:
            break
        }
    }
}
