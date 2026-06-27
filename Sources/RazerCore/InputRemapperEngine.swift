import Foundation

public enum RemapButtonOutcome: Equatable, Sendable {
    case passThrough
    case consume
    case postMouse(MouseButtonTarget, isDown: Bool)
    case fireOneShot(ButtonAction)
}

public enum InputRemapperEngine {
    public static let syntheticMarker: Int64 = 0x525A_524D_5045

    public static func shouldIgnoreSynthetic(sourceUserData: Int64) -> Bool {
        sourceUserData == syntheticMarker
    }

    public static func matchesShortcut(_ shortcut: KeyboardShortcut, keyCode: UInt16, modifierFlags: UInt64) -> Bool {
        guard keyCode == shortcut.keyCode else { return false }
        let masked = modifierFlags & 0x001F_FFFF
        let required = shortcut.modifierFlags & 0x001F_FFFF
        return (masked & required) == required
    }

    public static func resolvedButtonAction(
        for control: PhysicalControl,
        in mappings: [PhysicalControl: ButtonAction]
    ) -> ButtonAction {
        let direct = mappings[control] ?? .passthrough
        if direct != .passthrough {
            return direct
        }
        switch control {
        case .wheelClick:
            return mappings[.middleClick] ?? .passthrough
        case .middleClick:
            return mappings[.wheelClick] ?? .passthrough
        default:
            return .passthrough
        }
    }

    public struct ScrollDeltaScaler: Sendable {
        private var accumulator: Double

        public init(accumulator: Double = 0) {
            self.accumulator = accumulator
        }

        public mutating func reset() {
            accumulator = 0
        }

        public mutating func scale(rawDelta: Int64, multiplier: Double, invert: Bool = false) -> Int64 {
            guard rawDelta != 0 else { return 0 }
            var scaled = Double(rawDelta) * multiplier
            if invert { scaled *= -1 }
            accumulator += scaled
            let emitted = Int64(accumulator.rounded(.towardZero))
            if emitted != 0 {
                accumulator -= Double(emitted)
            }
            return emitted
        }
    }

    public struct ScrollAxisValues: Equatable, Sendable {
        public var line: Int64
        public var point: Int64
        public var fixedPt: Double

        public init(line: Int64 = 0, point: Int64 = 0, fixedPt: Double = 0) {
            self.line = line
            self.point = point
            self.fixedPt = fixedPt
        }

        public var isEffectivelyZero: Bool {
            line == 0 && point == 0 && fixedPt == 0
        }

        public static let zero = ScrollAxisValues()
    }

    public struct ScrollAxisPair: Equatable, Sendable {
        public var axis1: ScrollAxisValues
        public var axis2: ScrollAxisValues

        public init(axis1: ScrollAxisValues = .zero, axis2: ScrollAxisValues = .zero) {
            self.axis1 = axis1
            self.axis2 = axis2
        }
    }

    public static func scalePassthroughScroll(
        axis1: ScrollAxisValues,
        lineScaler: inout ScrollDeltaScaler,
        multiplier: Double,
        invert: Bool,
        moveToHorizontalAxis: Bool
    ) -> ScrollAxisPair {
        let scaledLine = lineScaler.scale(rawDelta: axis1.line, multiplier: multiplier, invert: invert)
        let scaledPoint = scaleImmediateDelta(axis1.point, multiplier: multiplier, invert: invert)
        let scaledFixed = scaleImmediateFixed(axis1.fixedPt, multiplier: multiplier, invert: invert)
        let scaled = ScrollAxisValues(line: scaledLine, point: scaledPoint, fixedPt: scaledFixed)

        if moveToHorizontalAxis {
            return ScrollAxisPair(axis1: .zero, axis2: scaled)
        }
        return ScrollAxisPair(axis1: scaled, axis2: .zero)
    }

    private static func scaleImmediateDelta(_ raw: Int64, multiplier: Double, invert: Bool) -> Int64 {
        guard raw != 0 else { return 0 }
        var scaled = Double(raw) * multiplier
        if invert { scaled *= -1 }
        return Int64(scaled.rounded(.towardZero))
    }

    private static func scaleImmediateFixed(_ raw: Double, multiplier: Double, invert: Bool) -> Double {
        guard raw != 0 else { return 0 }
        var scaled = raw * multiplier
        if invert { scaled *= -1 }
        return scaled
    }

    public static func scaledScrollDelta(rawDelta: Int64, multiplier: Double) -> Int64 {
        Int64((Double(rawDelta) * multiplier).rounded(.towardZero))
    }

    public static func buttonOutcome(action: ButtonAction, isDown: Bool) -> RemapButtonOutcome {
        switch action {
        case .passthrough:
            return .passThrough
        case .disabled:
            return .consume
        case let .mouseButton(target):
            return .postMouse(target, isDown: isDown)
        case .keyboardShortcut, .nextDPIStage, .previousDPIStage, .nextProfile, .previousProfile, .openApp, .openURL:
            return isDown ? .fireOneShot(action) : .consume
        }
    }
}

public enum ButtonActionValidator {
    public enum ValidationError: Equatable, Sendable {
        case empty
        case invalidScheme
        case missingHost
    }

    public static func validateOpenURL(_ urlString: String) -> ValidationError? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .invalidScheme
        }
        guard let host = url.host, !host.isEmpty else { return .missingHost }
        return nil
    }

    public static func normalizedOpenURL(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validateOpenURL(trimmed) == nil else { return nil }
        return trimmed
    }
}
