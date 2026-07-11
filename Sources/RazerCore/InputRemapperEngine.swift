import Foundation

public enum RemapButtonOutcome: Equatable, Sendable {
    case passThrough
    case consume
    case postMouse(MouseButtonTarget, isDown: Bool)
    case postMouseDrag(MouseButtonTarget)
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
            let safeMultiplier = SoftwareWheelSettings.sanitizedSpeedMultiplier(multiplier)
            var scaled = Double(rawDelta) * safeMultiplier
            if invert { scaled *= -1 }
            guard scaled.isFinite, scaled != 0 else { return 0 }
            // Drop residual from the opposite direction so reversal stays responsive.
            if accumulator != 0, (accumulator > 0) != (scaled > 0) {
                accumulator = 0
            }
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

    /// Signed primary delta used to choose wheel-up vs wheel-down actions.
    /// Prefers line, then point, then fixed-point so fixed-only events keep direction.
    public static func primaryScrollDelta(for axis: ScrollAxisValues) -> Double {
        if axis.line != 0 { return Double(axis.line) }
        if axis.point != 0 { return Double(axis.point) }
        return axis.fixedPt
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
        pointScaler: inout ScrollDeltaScaler,
        multiplier: Double,
        invert: Bool,
        moveToHorizontalAxis: Bool
    ) -> ScrollAxisPair {
        let scaledLine = lineScaler.scale(rawDelta: axis1.line, multiplier: multiplier, invert: invert)
        let scaledPoint = pointScaler.scale(rawDelta: axis1.point, multiplier: multiplier, invert: invert)
        let scaledFixed = scaleImmediateFixed(axis1.fixedPt, multiplier: multiplier, invert: invert)
        let scaled = ScrollAxisValues(line: scaledLine, point: scaledPoint, fixedPt: scaledFixed)

        if moveToHorizontalAxis {
            return ScrollAxisPair(axis1: .zero, axis2: scaled)
        }
        return ScrollAxisPair(axis1: scaled, axis2: .zero)
    }

    private static func scaleImmediateFixed(_ raw: Double, multiplier: Double, invert: Bool) -> Double {
        guard raw != 0 else { return 0 }
        let safeMultiplier = SoftwareWheelSettings.sanitizedSpeedMultiplier(multiplier)
        var scaled = raw * safeMultiplier
        if invert { scaled *= -1 }
        guard scaled.isFinite else { return 0 }
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

    public enum ButtonEventKind: Equatable, Sendable {
        case down
        case drag
        case up
    }

    /// Per-source hold record resolved once on button-down.
    public struct HeldButtonRecord: Equatable, Sendable {
        public let source: PhysicalControl
        public let consumedPhysical: Bool
        public let mouseTarget: MouseButtonTarget?
        public let oneShot: ButtonAction?

        public init(
            source: PhysicalControl,
            consumedPhysical: Bool,
            mouseTarget: MouseButtonTarget? = nil,
            oneShot: ButtonAction? = nil
        ) {
            self.source = source
            self.consumedPhysical = consumedPhysical
            self.mouseTarget = mouseTarget
            self.oneShot = oneShot
        }
    }

    /// Stateful button remapping across down / drag / up, including mid-hold profile changes.
    /// Mouse targets are reference-counted so many-to-one mappings only release on the last up.
    public struct ButtonRemapSession: Equatable, Sendable {
        private var held: [PhysicalControl: HeldButtonRecord] = [:]
        private var mouseTargetRefCounts: [MouseButtonTarget: Int] = [:]

        public init() {}

        public func isHolding(_ control: PhysicalControl) -> Bool {
            held[control] != nil
        }

        /// Unique synthetic mouse targets still held (for recovery release).
        public func snapshotHeldMouseTargets() -> [MouseButtonTarget] {
            Array(mouseTargetRefCounts.keys)
        }

        public mutating func clearAllHolds() {
            held.removeAll()
            mouseTargetRefCounts.removeAll()
        }

        /// Snapshot unique held mouse targets and clear all hold state. Idempotent.
        @discardableResult
        public mutating func releaseAllHeldOutputs() -> [MouseButtonTarget] {
            let targets = snapshotHeldMouseTargets()
            clearAllHolds()
            return targets
        }

        public mutating func handle(
            control: PhysicalControl,
            kind: ButtonEventKind,
            mappings: [PhysicalControl: ButtonAction]
        ) -> RemapButtonOutcome {
            switch kind {
            case .down:
                return handleDown(control: control, mappings: mappings)
            case .drag:
                return handleDrag(control: control)
            case .up:
                return handleUp(control: control)
            }
        }

        private mutating func handleDown(
            control: PhysicalControl,
            mappings: [PhysicalControl: ButtonAction]
        ) -> RemapButtonOutcome {
            // Duplicate downs for an already-held source must not overwrite the record or
            // inflate mouse-target refcounts (that would leak a synthetic hold past the real up).
            if let existing = held[control] {
                return existing.consumedPhysical ? .consume : .passThrough
            }

            let action = resolvedButtonAction(for: control, in: mappings)
            let outcome = buttonOutcome(action: action, isDown: true)
            switch outcome {
            case .passThrough:
                held[control] = HeldButtonRecord(source: control, consumedPhysical: false)
                return .passThrough
            case .consume:
                held[control] = HeldButtonRecord(source: control, consumedPhysical: true)
                return .consume
            case let .postMouse(target, _):
                held[control] = HeldButtonRecord(
                    source: control,
                    consumedPhysical: true,
                    mouseTarget: target
                )
                let previous = mouseTargetRefCounts[target, default: 0]
                mouseTargetRefCounts[target] = previous + 1
                // Already owned by another physical control: do not post a second down.
                return previous > 0 ? .consume : .postMouse(target, isDown: true)
            case let .fireOneShot(oneShot):
                held[control] = HeldButtonRecord(
                    source: control,
                    consumedPhysical: true,
                    oneShot: oneShot
                )
                return .fireOneShot(oneShot)
            case .postMouseDrag:
                // Down path never produces drag outcomes.
                return .consume
            }
        }

        private func handleDrag(control: PhysicalControl) -> RemapButtonOutcome {
            guard let record = held[control] else {
                return .passThrough
            }
            if let target = record.mouseTarget {
                return .postMouseDrag(target)
            }
            return record.consumedPhysical ? .consume : .passThrough
        }

        private mutating func handleUp(control: PhysicalControl) -> RemapButtonOutcome {
            guard let record = held.removeValue(forKey: control) else {
                // Unmatched ups pass through.
                return .passThrough
            }
            if let target = record.mouseTarget {
                let remaining = mouseTargetRefCounts[target, default: 1] - 1
                if remaining > 0 {
                    mouseTargetRefCounts[target] = remaining
                    // Another physical control still owns this synthetic button.
                    return .consume
                }
                mouseTargetRefCounts.removeValue(forKey: target)
                return .postMouse(target, isDown: false)
            }
            return record.consumedPhysical ? .consume : .passThrough
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
