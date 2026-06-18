import AppKit
import CoreGraphics
import Foundation

public final class InputRemapper: @unchecked Sendable {
    public struct Callbacks {
        public var onNextDPIStage: (() -> Void)?
        public var onPreviousDPIStage: (() -> Void)?
        public var onNextProfile: (() -> Void)?
        public var onPreviousProfile: (() -> Void)?
        public var onEmergencyPause: (() -> Void)?

        public init() {}
    }

    public private(set) var isRunning = false
    public private(set) var isPaused = false
    public var callbacks = Callbacks()

    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var profile = MouseProfile(
        name: "Default",
        dpiStages: [800],
        activeStage: 1,
        pollingRateHz: 1000
    )

    public init() {}

    deinit {
        stop()
    }

    public func updateProfile(_ profile: MouseProfile) {
        lock.lock()
        self.profile = profile
        lock.unlock()
    }

    public func pause() {
        lock.lock()
        isPaused = true
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        isPaused = false
        lock.unlock()
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
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
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

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let remapper = Unmanaged<InputRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
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

        if paused || !currentProfile.remapperEnabled {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            guard let control = physicalControl(for: type, event: event) else {
                return Unmanaged.passUnretained(event)
            }
            return handleButtonEvent(control: control, type: type, event: event, profile: currentProfile, callbacks: callbacks)

        case .scrollWheel:
            return handleScrollEvent(event: event, profile: currentProfile, callbacks: callbacks)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleButtonEvent(
        control: PhysicalControl,
        type: CGEventType,
        event: CGEvent,
        profile: MouseProfile,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        let action = profile.buttonMappings[control] ?? .passthrough
        switch action {
        case .passthrough:
            return Unmanaged.passUnretained(event)
        case .disabled:
            return nil
        case let .mouseButton(target):
            guard isMouseDown(type) else { return nil }
            postMouseButton(target, down: true)
            postMouseButton(target, down: false)
            return nil
        case let .keyboardShortcut(shortcut):
            guard isMouseDown(type) else { return nil }
            postKeyboardShortcut(shortcut, keyDown: true)
            postKeyboardShortcut(shortcut, keyDown: false)
            return nil
        case .nextDPIStage:
            guard isMouseDown(type) else { return nil }
            callbacks.onNextDPIStage?()
            return nil
        case .previousDPIStage:
            guard isMouseDown(type) else { return nil }
            callbacks.onPreviousDPIStage?()
            return nil
        case .nextProfile:
            guard isMouseDown(type) else { return nil }
            callbacks.onNextProfile?()
            return nil
        case .previousProfile:
            guard isMouseDown(type) else { return nil }
            callbacks.onPreviousProfile?()
            return nil
        case let .openApp(path):
            guard isMouseDown(type) else { return nil }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return nil
        case let .openURL(urlString):
            guard isMouseDown(type) else { return nil }
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    private func handleScrollEvent(
        event: CGEvent,
        profile: MouseProfile,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        let rawDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard rawDelta != 0 else { return Unmanaged.passUnretained(event) }

        let software = profile.wheelSettings.software
        let wheelUp = rawDelta > 0
        let wheelControl: PhysicalControl = wheelUp ? .wheelUp : .wheelDown

        let mappingAction = profile.buttonMappings[wheelControl] ?? .passthrough
        let softwareAction = wheelUp ? software.wheelUpAction : software.wheelDownAction
        let action = softwareAction ?? mappingAction

        if case .passthrough = action {
            let modified = event
            var delta = Double(rawDelta) * software.verticalSpeedMultiplier
            if software.scrollDirection == .inverted {
                delta *= -1
            }

            if software.horizontalScrollModifier == .shift,
               event.flags.contains(.maskShift) {
                modified.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
                modified.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(delta))
            } else {
                modified.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(delta))
            }
            return Unmanaged.passUnretained(modified)
        }

        return executeScrollAction(action, callbacks: callbacks)
    }

    private func executeScrollAction(_ action: ButtonAction, callbacks: Callbacks) -> Unmanaged<CGEvent>? {
        switch action {
        case .passthrough:
            return nil
        case .disabled:
            return nil
        case let .mouseButton(target):
            postMouseButton(target, down: true)
            postMouseButton(target, down: false)
            return nil
        case let .keyboardShortcut(shortcut):
            postKeyboardShortcut(shortcut, keyDown: true)
            postKeyboardShortcut(shortcut, keyDown: false)
            return nil
        case .nextDPIStage:
            callbacks.onNextDPIStage?()
            return nil
        case .previousDPIStage:
            callbacks.onPreviousDPIStage?()
            return nil
        case .nextProfile:
            callbacks.onNextProfile?()
            return nil
        case .previousProfile:
            callbacks.onPreviousProfile?()
            return nil
        case let .openApp(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return nil
        case let .openURL(urlString):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    private func physicalControl(for type: CGEventType, event: CGEvent) -> PhysicalControl? {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return .leftClick
        case .rightMouseDown, .rightMouseUp:
            return .rightClick
        case .otherMouseDown, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            switch button {
            case 2: return .middleClick
            case 3: return .sideButton1
            case 4: return .sideButton2
            case 5: return .dpiButton
            default: return nil
            }
        default:
            return nil
        }
    }

    private func isMouseDown(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private func matchesEmergencyPause(_ event: CGEvent) -> Bool {
        let shortcut = KeyboardShortcut.emergencyPause
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue & 0x001F_FFFF
        return keyCode == shortcut.keyCode && flags == shortcut.modifierFlags
    }

    private func postMouseButton(_ target: MouseButtonTarget, down: Bool) {
        let (type, button): (CGEventType, CGMouseButton) = switch target {
        case .left: down ? (.leftMouseDown, .left) : (.leftMouseUp, .left)
        case .right: down ? (.rightMouseDown, .right) : (.rightMouseUp, .right)
        case .middle: down ? (.otherMouseDown, .center) : (.otherMouseUp, .center)
        case .side1: down ? (.otherMouseDown, CGMouseButton(rawValue: 3)!) : (.otherMouseUp, CGMouseButton(rawValue: 3)!)
        case .side2: down ? (.otherMouseDown, CGMouseButton(rawValue: 4)!) : (.otherMouseUp, CGMouseButton(rawValue: 4)!)
        }

        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: NSEvent.mouseLocation, mouseButton: button) else {
            return
        }
        if target == .side1 {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        } else if target == .side2 {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    private func postKeyboardShortcut(_ shortcut: KeyboardShortcut, keyDown: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let flags = CGEventFlags(rawValue: shortcut.modifierFlags)
        if keyDown {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        } else {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
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
