import Foundation

// MARK: - Physical controls

public enum PhysicalControl: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case leftClick
    case rightClick
    case middleClick
    case sideButton1
    case sideButton2
    case dpiButton
    case wheelUp
    case wheelDown
    case wheelClick

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .leftClick: return "Left Click"
        case .rightClick: return "Right Click"
        case .middleClick: return "Middle Click"
        case .sideButton1: return "Side Button 1"
        case .sideButton2: return "Side Button 2"
        case .dpiButton: return "DPI / Top Button"
        case .wheelUp: return "Wheel Up"
        case .wheelDown: return "Wheel Down"
        case .wheelClick: return "Wheel Click"
        }
    }

    public static func defaultButtonMappings() -> [PhysicalControl: ButtonAction] {
        Dictionary(uniqueKeysWithValues: assignableControls.map { ($0, .passthrough) })
    }

    /// Controls shown in the Buttons UI. `.middleClick` is omitted because it shares
    /// physical button 2 with `.wheelClick`; legacy `.middleClick` mappings still resolve.
    public static var assignableControls: [PhysicalControl] {
        allCases.filter { $0 != .middleClick }
    }
}

public enum MouseButtonTarget: String, Codable, CaseIterable, Sendable, Hashable {
    case left
    case right
    case middle
    case side1
    case side2

    public var displayName: String {
        switch self {
        case .left: return "Left Click"
        case .right: return "Right Click"
        case .middle: return "Middle Click"
        case .side1: return "Side Button 1"
        case .side2: return "Side Button 2"
        }
    }
}

// MARK: - Button actions

public enum ButtonAction: Codable, Equatable, Sendable, Hashable {
    case passthrough
    case disabled
    case mouseButton(MouseButtonTarget)
    case keyboardShortcut(KeyboardShortcut)
    case nextDPIStage
    case previousDPIStage
    case nextProfile
    case previousProfile
    case openApp(String)
    case openURL(String)

    public var displayName: String {
        switch self {
        case .passthrough: return "Default (passthrough)"
        case .disabled: return "Disabled"
        case let .mouseButton(target): return "Mouse: \(target.displayName)"
        case let .keyboardShortcut(shortcut): return "Shortcut: \(shortcut.displayName)"
        case .nextDPIStage: return "Next DPI Stage"
        case .previousDPIStage: return "Previous DPI Stage"
        case .nextProfile: return "Next Profile"
        case .previousProfile: return "Previous Profile"
        case let .openApp(path): return "Open App: \(URL(fileURLWithPath: path).lastPathComponent)"
        case let .openURL(url): return "Open URL: \(url)"
        }
    }
}

public struct KeyboardShortcut: Codable, Equatable, Sendable, Hashable {
    public var keyCode: UInt16
    public var modifierFlags: UInt64

    public init(keyCode: UInt16, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    public static let emergencyPause = KeyboardShortcut(
        keyCode: 15,
        modifierFlags: 0x001C_0000 // control + option + command
    )

    public var displayName: String {
        var parts: [String] = []
        if modifierFlags & 0x0004_0000 != 0 { parts.append("⌃") }
        if modifierFlags & 0x0008_0000 != 0 { parts.append("⌥") }
        if modifierFlags & 0x0002_0000 != 0 { parts.append("⇧") }
        if modifierFlags & 0x0010_0000 != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: keyCode))
        return parts.joined()
    }
}

private enum KeyCodeNames {
    static func name(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - Wheel settings

public enum ScrollDirection: String, Codable, CaseIterable, Sendable {
    case normal
    case inverted

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .inverted: return "Inverted"
        }
    }
}

public enum ScrollWheelMode: UInt8, Codable, CaseIterable, Sendable {
    case tactile = 0
    case freeSpin = 1

    public var displayName: String {
        switch self {
        case .tactile: return "Tactile"
        case .freeSpin: return "Free Spin"
        }
    }
}

public struct HardwareWheelSettings: Codable, Equatable, Sendable {
    public var scrollMode: ScrollWheelMode?
    public var accelerationEnabled: Bool?
    public var smartReelEnabled: Bool?

    public init(
        scrollMode: ScrollWheelMode? = nil,
        accelerationEnabled: Bool? = nil,
        smartReelEnabled: Bool? = nil
    ) {
        self.scrollMode = scrollMode
        self.accelerationEnabled = accelerationEnabled
        self.smartReelEnabled = smartReelEnabled
    }
}

public enum HorizontalScrollModifier: String, Codable, CaseIterable, Sendable {
    case none
    case shift

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .shift: return "Hold Shift"
        }
    }
}

public struct SoftwareWheelSettings: Codable, Equatable, Sendable {
    public var scrollDirection: ScrollDirection
    public var verticalSpeedMultiplier: Double
    public var horizontalScrollModifier: HorizontalScrollModifier
    public var wheelUpAction: ButtonAction?
    public var wheelDownAction: ButtonAction?

    public init(
        scrollDirection: ScrollDirection = .normal,
        verticalSpeedMultiplier: Double = 1.0,
        horizontalScrollModifier: HorizontalScrollModifier = .shift,
        wheelUpAction: ButtonAction? = nil,
        wheelDownAction: ButtonAction? = nil
    ) {
        self.scrollDirection = scrollDirection
        self.verticalSpeedMultiplier = verticalSpeedMultiplier
        self.horizontalScrollModifier = horizontalScrollModifier
        self.wheelUpAction = wheelUpAction
        self.wheelDownAction = wheelDownAction
    }

    public static let `default` = SoftwareWheelSettings()
}

public struct WheelSettings: Codable, Equatable, Sendable {
    public var hardware: HardwareWheelSettings
    public var software: SoftwareWheelSettings

    public init(hardware: HardwareWheelSettings = HardwareWheelSettings(), software: SoftwareWheelSettings = .default) {
        self.hardware = hardware
        self.software = software
    }

    public static let `default` = WheelSettings()
}

// MARK: - Hardware capability

public enum CapabilityResult: Equatable, Sendable {
    case supported
    case notSupported
    case unknown

    public var displayName: String {
        switch self {
        case .supported: return "Supported"
        case .notSupported: return "Not supported on this device"
        case .unknown: return "Unknown (probe error)"
        }
    }
}

public struct WheelHardwareCapability: Equatable, Sendable {
    public var scrollMode: CapabilityResult
    public var acceleration: CapabilityResult
    public var smartReel: CapabilityResult

    public init(
        scrollMode: CapabilityResult = .unknown,
        acceleration: CapabilityResult = .unknown,
        smartReel: CapabilityResult = .unknown
    ) {
        self.scrollMode = scrollMode
        self.acceleration = acceleration
        self.smartReel = smartReel
    }
}

// MARK: - Validation

public enum ButtonMappingWarning: Equatable, Sendable {
    case primaryClickUnavailable

    public var message: String {
        switch self {
        case .primaryClickUnavailable:
            return "A primary click is unavailable. Keep at least one left-click and one right-click action, or use the emergency shortcut (⌃⌥⌘R) to pause the remapper."
        }
    }
}

public enum ProfileMappingValidator {
    public static func warnings(for profile: MouseProfile) -> [ButtonMappingWarning] {
        var warnings: [ButtonMappingWarning] = []
        let mappings = profile.buttonMappings
        let hasLeftClick = PhysicalControl.allCases.contains { control in
            emits(.left, from: control, action: mappings[control] ?? .passthrough)
        }
        let hasRightClick = PhysicalControl.allCases.contains { control in
            emits(.right, from: control, action: mappings[control] ?? .passthrough)
        }
        if !hasLeftClick || !hasRightClick {
            warnings.append(.primaryClickUnavailable)
        }
        return warnings
    }

    private static func emits(_ target: MouseButtonTarget, from control: PhysicalControl, action: ButtonAction) -> Bool {
        switch action {
        case .passthrough:
            return (control == .leftClick && target == .left) || (control == .rightClick && target == .right)
        case let .mouseButton(mappedTarget):
            return mappedTarget == target
        default:
            return false
        }
    }
}
