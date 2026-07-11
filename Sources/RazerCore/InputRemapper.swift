import AppKit
import CoreGraphics
import Foundation

public enum HeldOutputRecoveryReason: String, Equatable, Sendable {
    case pause
    case stop
    case tapDisable
    case profileReplacement
    case permissionLoss
}

public final class InputRemapper: @unchecked Sendable {
    public struct Callbacks {
        public var onNextDPIStage: (() -> Void)?
        public var onPreviousDPIStage: (() -> Void)?
        public var onNextProfile: (() -> Void)?
        public var onPreviousProfile: (() -> Void)?
        public var onEmergencyPause: (() -> Void)?
        public var onHeldOutputsReleased: ((HeldOutputRecoveryReason) -> Void)?

        public init() {}
    }

    public private(set) var isRunning = false
    public private(set) var isPaused = false
    public private(set) var lastHeldOutputRecovery: HeldOutputRecoveryReason?
    /// Counts synthetic mouse-ups posted by `releaseAllHeldOutputs` (test observation).
    public private(set) var testingSyntheticMouseUpCount = 0
    public var callbacks = Callbacks()

    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private lazy var syntheticEventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = InputRemapperEngine.syntheticMarker
        return source
    }()
    private var profile = MouseProfile(
        name: "Default",
        dpiStages: [800],
        activeStage: 1,
        pollingRateHz: 1000
    )
    private var buttonSession = InputRemapperEngine.ButtonRemapSession()
    private var verticalScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    private var horizontalScrollScaler = InputRemapperEngine.ScrollDeltaScaler()

    public init() {}

    deinit {
        stop()
    }

    public func updateProfile(_ profile: MouseProfile) {
        lock.lock()
        let mappingsChanged =
            self.profile.buttonMappings != profile.buttonMappings
            || self.profile.remapperEnabled != profile.remapperEnabled
        lock.unlock()
        if mappingsChanged {
            releaseAllHeldOutputs(reason: .profileReplacement)
        }
        lock.lock()
        self.profile = profile
        resetScrollAccumulatorsLocked()
        lock.unlock()
    }

    public func pause() {
        releaseAllHeldOutputs(reason: .pause)
        lock.lock()
        isPaused = true
        resetScrollAccumulatorsLocked()
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        isPaused = false
        lock.unlock()
    }

    /// Releases any remapped mouse holds after Accessibility/Input Monitoring is lost.
    public func handlePermissionLoss() {
        releaseAllHeldOutputs(reason: .permissionLoss)
        tearDownEventTap()
    }

    /// Test seam: recovers after a system tap-disable notification.
    public func recoverAfterTapDisableForTesting() {
        recoverAfterTapDisable()
    }

    /// Test seam: installs a remapped hold without requiring a live event tap.
    public func seedRemappedHoldForTesting(control: PhysicalControl, target: MouseButtonTarget) {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[control] = .mouseButton(target)
        lock.lock()
        _ = buttonSession.handle(control: control, kind: .down, mappings: mappings)
        lock.unlock()
    }

    /// Test seam: unique synthetic mouse targets still held.
    public func heldMouseTargetsForTesting() -> [MouseButtonTarget] {
        lock.lock()
        defer { lock.unlock() }
        return buttonSession.snapshotHeldMouseTargets()
    }

    /// Snapshot, clear, and post synthetic ups for every held remapped mouse target.
    /// Idempotent: a second call with no new holds posts nothing.
    @discardableResult
    public func releaseAllHeldOutputs(reason: HeldOutputRecoveryReason) -> [MouseButtonTarget] {
        lock.lock()
        let targets = buttonSession.releaseAllHeldOutputs()
        let callback = callbacks.onHeldOutputsReleased
        if !targets.isEmpty {
            lastHeldOutputRecovery = reason
        }
        lock.unlock()

        for target in targets {
            postMouseButton(target, down: false)
            testingSyntheticMouseUpCount += 1
        }
        if !targets.isEmpty {
            callback?(reason)
        }
        return targets
    }

    private func recoverAfterTapDisable() {
        releaseAllHeldOutputs(reason: .tapDisable)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func tearDownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    public func start() throws {
        guard !isRunning else { return }
        let permissions = PermissionStatus.current()
        guard permissions.remapperReady else {
            throw InputRemapperError.missingPermissions(permissions)
        }

        let mask = (
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        )

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: InputRemapper.eventCallback,
            userInfo: userInfo
        ) else {
            throw InputRemapperError.tapCreationFailed
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    public func stop() {
        releaseAllHeldOutputs(reason: .stop)
        tearDownEventTap()
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let remapper = Unmanaged<InputRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverAfterTapDisable()
            return Unmanaged.passUnretained(event)
        }

        if isSyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let currentProfile = profile
        let paused = isPaused
        let callbacks = callbacks
        lock.unlock()

        if type == .keyDown, matchesEmergencyPause(event) {
            pause()
            callbacks.onEmergencyPause?()
            return nil
        }

        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            guard let control = physicalControl(for: type, event: event) else {
                break
            }

            let kind = buttonEventKind(for: type)
            if kind != .down {
                // Finish holds even when paused/disabled so synthetic buttons cannot stick.
                lock.lock()
                let outcome = buttonSession.handle(
                    control: control,
                    kind: kind,
                    mappings: currentProfile.buttonMappings
                )
                lock.unlock()
                return applyButtonOutcome(outcome, event: event, callbacks: callbacks)
            }

            if paused || !currentProfile.remapperEnabled {
                return Unmanaged.passUnretained(event)
            }

            return handleButtonEvent(
                control: control,
                kind: kind,
                event: event,
                profile: currentProfile,
                callbacks: callbacks
            )

        case .scrollWheel:
            if paused || !currentProfile.remapperEnabled {
                return Unmanaged.passUnretained(event)
            }
            return handleScrollEvent(event: event, profile: currentProfile, callbacks: callbacks)

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleButtonEvent(
        control: PhysicalControl,
        kind: InputRemapperEngine.ButtonEventKind,
        event: CGEvent,
        profile: MouseProfile,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        lock.lock()
        let outcome = buttonSession.handle(
            control: control,
            kind: kind,
            mappings: profile.buttonMappings
        )
        lock.unlock()
        return applyButtonOutcome(outcome, event: event, callbacks: callbacks)
    }

    private func applyButtonOutcome(
        _ outcome: RemapButtonOutcome,
        event: CGEvent,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        switch outcome {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case let .postMouse(target, down):
            postMouseButton(target, down: down, mirroring: event)
            return nil
        case let .postMouseDrag(target):
            postMouseDrag(target, mirroring: event)
            return nil
        case let .fireOneShot(oneShotAction):
            executeOneShotAction(oneShotAction, callbacks: callbacks)
            return nil
        }
    }

    private func buttonEventKind(for type: CGEventType) -> InputRemapperEngine.ButtonEventKind {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .down
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .drag
        default:
            return .up
        }
    }

    private func executeOneShotAction(_ action: ButtonAction, callbacks: Callbacks) {
        switch action {
        case let .keyboardShortcut(shortcut):
            postKeyboardShortcut(shortcut, keyDown: true)
            postKeyboardShortcut(shortcut, keyDown: false)
        case .nextDPIStage:
            callbacks.onNextDPIStage?()
        case .previousDPIStage:
            callbacks.onPreviousDPIStage?()
        case .nextProfile:
            callbacks.onNextProfile?()
        case .previousProfile:
            callbacks.onPreviousProfile?()
        case let .openApp(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        case let .openURL(urlString):
            if let normalized = ButtonActionValidator.normalizedOpenURL(urlString),
               let url = URL(string: normalized) {
                NSWorkspace.shared.open(url)
            }
        case .passthrough, .disabled, .mouseButton:
            break
        }
    }

    private func resetScrollAccumulatorsLocked() {
        verticalScrollScaler.reset()
        horizontalScrollScaler.reset()
    }

    private func handleScrollEvent(
        event: CGEvent,
        profile: MouseProfile,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        let axis1 = InputRemapperEngine.ScrollAxisValues(
            line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            fixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        )
        guard !axis1.isEffectivelyZero else { return Unmanaged.passUnretained(event) }

        let primaryDelta = axis1.line != 0 ? axis1.line : axis1.point
        let software = profile.wheelSettings.software
        let wheelUp = primaryDelta > 0
        let wheelControl: PhysicalControl = wheelUp ? .wheelUp : .wheelDown

        let mappingAction = profile.buttonMappings[wheelControl] ?? .passthrough
        let softwareAction = wheelUp ? software.wheelUpAction : software.wheelDownAction
        let action = softwareAction ?? mappingAction

        if case .passthrough = action {
            let modified = event
            let invert = software.scrollDirection == .inverted
            let multiplier = software.verticalSpeedMultiplier
            let moveHorizontal = software.horizontalScrollModifier == .shift && event.flags.contains(.maskShift)

            lock.lock()
            let scaled: InputRemapperEngine.ScrollAxisPair
            if moveHorizontal {
                scaled = InputRemapperEngine.scalePassthroughScroll(
                    axis1: axis1,
                    lineScaler: &horizontalScrollScaler,
                    multiplier: multiplier,
                    invert: invert,
                    moveToHorizontalAxis: true
                )
            } else {
                scaled = InputRemapperEngine.scalePassthroughScroll(
                    axis1: axis1,
                    lineScaler: &verticalScrollScaler,
                    multiplier: multiplier,
                    invert: invert,
                    moveToHorizontalAxis: false
                )
            }
            lock.unlock()

            applyScrollAxes(scaled, to: modified)
            return Unmanaged.passUnretained(modified)
        }

        return executeScrollAction(action, callbacks: callbacks)
    }

    private func applyScrollAxes(_ pair: InputRemapperEngine.ScrollAxisPair, to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: pair.axis1.line)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: pair.axis2.line)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pair.axis1.point)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pair.axis2.point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pair.axis1.fixedPt)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: pair.axis2.fixedPt)
    }

    private func executeScrollAction(_ action: ButtonAction, callbacks: Callbacks) -> Unmanaged<CGEvent>? {
        switch action {
        case .passthrough, .disabled:
            return nil
        case let .mouseButton(target):
            postMouseButton(target, down: true)
            postMouseButton(target, down: false)
            return nil
        case .keyboardShortcut, .nextDPIStage, .previousDPIStage, .nextProfile, .previousProfile, .openApp, .openURL:
            executeOneShotAction(action, callbacks: callbacks)
            return nil
        }
    }

    private func isSyntheticEvent(_ event: CGEvent) -> Bool {
        InputRemapperEngine.shouldIgnoreSynthetic(sourceUserData: event.getIntegerValueField(.eventSourceUserData))
    }

    private func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: InputRemapperEngine.syntheticMarker)
    }

    private func matchesEmergencyPause(_ event: CGEvent) -> Bool {
        let shortcut = KeyboardShortcut.emergencyPause
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        return InputRemapperEngine.matchesShortcut(shortcut, keyCode: keyCode, modifierFlags: flags)
    }

    private func physicalControl(for type: CGEventType, event: CGEvent) -> PhysicalControl? {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return .leftClick
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return .rightClick
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            switch button {
            case 2: return .wheelClick
            case 3: return .sideButton1
            case 4: return .sideButton2
            case 5: return .dpiButton
            default: return nil
            }
        default:
            return nil
        }
    }

    private func postMouseButton(_ target: MouseButtonTarget, down: Bool, mirroring sourceEvent: CGEvent? = nil) {
        let (type, button): (CGEventType, CGMouseButton) = switch target {
        case .left: down ? (.leftMouseDown, .left) : (.leftMouseUp, .left)
        case .right: down ? (.rightMouseDown, .right) : (.rightMouseUp, .right)
        case .middle: down ? (.otherMouseDown, .center) : (.otherMouseUp, .center)
        case .side1: down ? (.otherMouseDown, CGMouseButton(rawValue: 3)!) : (.otherMouseUp, CGMouseButton(rawValue: 3)!)
        case .side2: down ? (.otherMouseDown, CGMouseButton(rawValue: 4)!) : (.otherMouseUp, CGMouseButton(rawValue: 4)!)
        }

        let position = sourceEvent?.location ?? NSEvent.mouseLocation
        guard let cgEvent = CGEvent(
            mouseEventSource: syntheticEventSource,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: button
        ) else {
            return
        }
        applyMirroredMouseMetadata(to: cgEvent, from: sourceEvent, target: target)
        markSynthetic(cgEvent)
        cgEvent.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(_ target: MouseButtonTarget, mirroring sourceEvent: CGEvent) {
        let (type, button): (CGEventType, CGMouseButton) = switch target {
        case .left: (.leftMouseDragged, .left)
        case .right: (.rightMouseDragged, .right)
        case .middle: (.otherMouseDragged, .center)
        case .side1: (.otherMouseDragged, CGMouseButton(rawValue: 3)!)
        case .side2: (.otherMouseDragged, CGMouseButton(rawValue: 4)!)
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: syntheticEventSource,
            mouseType: type,
            mouseCursorPosition: sourceEvent.location,
            mouseButton: button
        ) else {
            return
        }
        applyMirroredMouseMetadata(to: cgEvent, from: sourceEvent, target: target)
        markSynthetic(cgEvent)
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Copies location-independent click/modifier metadata from the source event onto synthetics.
    private func applyMirroredMouseMetadata(
        to cgEvent: CGEvent,
        from sourceEvent: CGEvent?,
        target: MouseButtonTarget
    ) {
        if let sourceEvent {
            cgEvent.flags = sourceEvent.flags
            cgEvent.setIntegerValueField(
                .mouseEventClickState,
                value: sourceEvent.getIntegerValueField(.mouseEventClickState)
            )
        }
        if target == .side1 {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        } else if target == .side2 {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        }
    }

    private func postKeyboardShortcut(_ shortcut: KeyboardShortcut, keyDown: Bool) {
        let source = syntheticEventSource ?? CGEventSource(stateID: .hidSystemState)
        guard let source else { return }
        source.userData = InputRemapperEngine.syntheticMarker
        let flags = CGEventFlags(rawValue: shortcut.modifierFlags)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: keyDown) else {
            return
        }
        event.flags = flags
        markSynthetic(event)
        event.post(tap: .cghidEventTap)
    }
}

public enum InputRemapperError: Error, LocalizedError {
    case missingPermissions(PermissionStatus)
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case let .missingPermissions(status):
            return "Remapper permissions missing. \(status.summary)"
        case .tapCreationFailed:
            return "Failed to create the global event tap."
        }
    }
}
