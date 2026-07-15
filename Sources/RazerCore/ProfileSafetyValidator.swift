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
    case supportDirectorySymlink
    case supportDirectoryNotDirectory
    case supportDirectoryWrongOwner(expected: UInt32, actual: UInt32)
    case supportDirectoryPermissionFailure(String)

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
            return "Profile application path must be a standardized absolute application bundle (.app)."
        case let .appPathTooLong(actual):
            return "Profile application path is \(actual) UTF-8 bytes; maximum is \(ProfileSafetyLimits.maximumAppPathUTF8Bytes)."
        case .supportDirectorySymlink:
            return "Profile support directory must not be a symbolic link."
        case .supportDirectoryNotDirectory:
            return "Profile support path must be a directory."
        case let .supportDirectoryWrongOwner(expected, actual):
            return "Profile support directory owner \(actual) does not match current user \(expected)."
        case let .supportDirectoryPermissionFailure(details):
            return "Profile support directory could not be hardened to owner-only permissions: \(details)"
        }
    }
}

public enum ProfileSafetyValidator {
    public static let ownerOnlyDirectoryMode: mode_t = 0o700

    /// Creates (if needed) and hardens a profile support directory to owner-only mode.
    /// Opens with `O_NOFOLLOW | O_DIRECTORY` and hardens via `fchmod` on that inode so a
    /// pathname swap to a symlink cannot mutate the replacement target.
    public static func prepareSupportDirectory(
        at url: URL,
        fileManager: FileManager = .default,
        currentUID: () -> uid_t = { getuid() },
        openDirectory: (String) throws -> Int32 = { path in
            try openSupportDirectoryFileDescriptor(atPath: path)
        },
        fchmodDirectory: (Int32, mode_t) throws -> Void = { fd, mode in
            if fchmod(fd, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
    ) throws {
        let fd = try openPreparedSupportDirectory(
            at: url,
            fileManager: fileManager,
            currentUID: currentUID,
            openDirectory: openDirectory,
            fchmodDirectory: fchmodDirectory
        )
        close(fd)
    }

    /// Same hardening as `prepareSupportDirectory`, but returns the open directory FD.
    /// Caller must `close` it. Mutations must use this FD (`openat`/`renameat`/`unlinkat`)
    /// so a pathname swap after validation cannot redirect writes.
    public static func openPreparedSupportDirectory(
        at url: URL,
        fileManager: FileManager = .default,
        currentUID: () -> uid_t = { getuid() },
        openDirectory: (String) throws -> Int32 = { path in
            try openSupportDirectoryFileDescriptor(atPath: path)
        },
        fchmodDirectory: (Int32, mode_t) throws -> Void = { fd, mode in
            if fchmod(fd, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
    ) throws -> Int32 {
        let path = url.path
        var status = stat()
        let exists = lstat(path, &status) == 0

        if exists {
            // Fast-fail obvious pathname problems before open; open is still authoritative.
            if (status.st_mode & S_IFMT) == S_IFLNK {
                throw ProfileSafetyValidationError.supportDirectorySymlink
            }
            if (status.st_mode & S_IFMT) != S_IFDIR {
                throw ProfileSafetyValidationError.supportDirectoryNotDirectory
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: Int(ownerOnlyDirectoryMode)]
                )
            } catch {
                throw ProfileSafetyValidationError.supportDirectoryPermissionFailure(error.localizedDescription)
            }
        }

        let fd: Int32
        do {
            fd = try openDirectory(path)
        } catch let error as ProfileSafetyValidationError {
            throw error
        } catch {
            throw ProfileSafetyValidationError.supportDirectoryPermissionFailure(error.localizedDescription)
        }

        do {
            guard fstat(fd, &status) == 0 else {
                throw ProfileSafetyValidationError.supportDirectoryPermissionFailure("fstat failed after open")
            }
            try validateOpenedSupportDirectoryStatus(status, currentUID: currentUID())

            do {
                try fchmodDirectory(fd, ownerOnlyDirectoryMode)
            } catch {
                throw ProfileSafetyValidationError.supportDirectoryPermissionFailure(error.localizedDescription)
            }

            guard fstat(fd, &status) == 0 else {
                throw ProfileSafetyValidationError.supportDirectoryPermissionFailure("fstat failed after fchmod")
            }
            try validateOpenedSupportDirectoryStatus(status, currentUID: currentUID())
            let mode = status.st_mode & 0o777
            guard mode == ownerOnlyDirectoryMode else {
                throw ProfileSafetyValidationError.supportDirectoryPermissionFailure(
                    "expected mode \(String(ownerOnlyDirectoryMode, radix: 8)), got \(String(mode, radix: 8))"
                )
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func openSupportDirectoryFileDescriptor(atPath path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let openErrno = errno
            // Darwin may report ENOTDIR (instead of ELOOP) when O_NOFOLLOW refuses a symlink.
            if openErrno == ELOOP || openErrno == EMLINK || pathIsSymlink(path) {
                throw ProfileSafetyValidationError.supportDirectorySymlink
            }
            if openErrno == ENOTDIR {
                throw ProfileSafetyValidationError.supportDirectoryNotDirectory
            }
            throw POSIXError(POSIXErrorCode(rawValue: openErrno) ?? .EIO)
        }
        return fd
    }

    private static func pathIsSymlink(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFLNK
    }

    private static func validateOpenedSupportDirectoryStatus(
        _ status: stat,
        currentUID: uid_t
    ) throws {
        // After O_DIRECTORY open, the inode is a directory; still verify owner/mode family.
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw ProfileSafetyValidationError.supportDirectoryNotDirectory
        }
        guard status.st_uid == currentUID else {
            throw ProfileSafetyValidationError.supportDirectoryWrongOwner(
                expected: currentUID,
                actual: status.st_uid
            )
        }
    }

    /// Intentional deviation from the plan's "invalid selection → quarantine" wording:
    /// dangling `selectedProfileID` values are repaired to the first profile instead of
    /// quarantining an otherwise valid file. Empty profile lists still fail closed.
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

    /// Opens the path with `O_NOFOLLOW`, validates the opened inode, and reads that inode.
    /// Avoids TOCTOU where a pathname is replaced between inspect and `Data(contentsOf:)`.
    public static func readValidatedSourceFile(at url: URL) throws -> Data {
        let path = url.path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw ProfileSafetyValidationError.sourceSymlink
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        return try readValidatedRegularFile(fromFileDescriptor: fd)
    }

    /// Reads a profile file relative to an already-validated support-directory FD.
    public static func readValidatedSourceFile(directoryFD: Int32, fileName: String) throws -> Data {
        let fd = fileName.withCString { name in
            openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw ProfileSafetyValidationError.sourceSymlink
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        return try readValidatedRegularFile(fromFileDescriptor: fd)
    }

    /// Atomically writes `data` as an owner-only regular file via `openat`/`renameat` on `directoryFD`.
    public static func writeOwnerOnlyRegularFile(
        directoryFD: Int32,
        fileName: String,
        data: Data,
        temporaryFileName: String,
        fchmodFile: (Int32, mode_t) throws -> Void = { fd, mode in
            if fchmod(fd, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
    ) throws {
        let tempFD = temporaryFileName.withCString { name in
            openat(directoryFD, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard tempFD >= 0 else {
            if errno == ELOOP {
                throw ProfileSafetyValidationError.sourceSymlink
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try data.withUnsafeBytes { buffer in
                var written = 0
                let total = buffer.count
                guard let base = buffer.baseAddress else {
                    if total == 0 { return }
                    throw POSIXError(.EIO)
                }
                while written < total {
                    let chunk = write(tempFD, base.advanced(by: written), total - written)
                    if chunk < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += chunk
                }
            }
            try fchmodFile(tempFD, 0o600)
        } catch {
            close(tempFD)
            _ = temporaryFileName.withCString { unlinkat(directoryFD, $0, 0) }
            throw error
        }
        close(tempFD)

        let renamed = temporaryFileName.withCString { tempName in
            fileName.withCString { finalName in
                renameat(directoryFD, tempName, directoryFD, finalName)
            }
        }
        guard renamed == 0 else {
            _ = temporaryFileName.withCString { unlinkat(directoryFD, $0, 0) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func entryExists(directoryFD: Int32, fileName: String) -> Bool {
        var status = stat()
        let result = fileName.withCString { name in
            fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0
    }

    public static func unlinkEntry(directoryFD: Int32, fileName: String) throws {
        let result = fileName.withCString { name in
            unlinkat(directoryFD, name, 0)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func renameEntry(directoryFD: Int32, from: String, to: String) throws {
        let result = from.withCString { fromName in
            to.withCString { toName in
                renameat(directoryFD, fromName, directoryFD, toName)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readValidatedRegularFile(fromFileDescriptor fd: Int32) throws -> Data {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

        let size = Int(status.st_size)
        guard size >= 0 else {
            throw ProfileSafetyValidationError.sourceTooLarge(actual: status.st_size)
        }
        if size == 0 {
            return Data()
        }

        var data = Data(count: size)
        let bytesRead: Int = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            var total = 0
            while total < size {
                let chunk = read(fd, base.advanced(by: total), size - total)
                if chunk == 0 { break }
                if chunk < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                total += chunk
            }
            return total
        }
        guard bytesRead == size else {
            throw POSIXError(.EIO)
        }
        return data
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
        // Intentional deviation: repair dangling selection instead of quarantining.
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
            let appURL = URL(fileURLWithPath: standardizedPath, isDirectory: true)
            guard Self.isActualApplicationBundle(at: appURL, fileManager: fileManager) else {
                throw ProfileSafetyValidationError.invalidAppPath
            }
        case .passthrough, .disabled, .mouseButton, .nextDPIStage, .previousDPIStage, .nextProfile, .previousProfile:
            break
        }
    }

    /// Requires a real application bundle, not merely a directory whose name ends in `.app`.
    private static func isActualApplicationBundle(at appURL: URL, fileManager: FileManager) -> Bool {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard fileManager.fileExists(atPath: infoPlistURL.path),
              let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
              let packageType = info["CFBundlePackageType"] as? String,
              packageType == "APPL" else {
            return false
        }
        let resourceValues = try? appURL.resourceValues(forKeys: [.isApplicationKey])
        return resourceValues?.isApplication == true
    }
}
