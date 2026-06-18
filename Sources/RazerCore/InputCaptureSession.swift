import AppKit
import CoreGraphics
import Foundation

public final class InputCaptureSession: @unchecked Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let summary: String
        public let control: PhysicalControl?

        public init(timestamp: Date = Date(), summary: String, control: PhysicalControl?) {
            self.id = UUID()
            self.timestamp = timestamp
            self.summary = summary
            self.control = control
        }
    }

    public private(set) var isRunning = false
    public private(set) var entries: [Entry] = []

    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let maxEntries = 250

    public init() {}

    deinit {
        stop()
    }

    public func start() throws {
        guard !isRunning else { return }
        let permissions = PermissionStatus.current()
        guard permissions.inputMonitoringGranted else {
            throw InputCaptureError.missingInputMonitoring
        }

        let mask = (
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        )

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: InputCaptureSession.eventCallback,
            userInfo: userInfo
        ) else {
            throw InputCaptureError.tapCreationFailed
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

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = Unmanaged<InputCaptureSession>.fromOpaque(userInfo).takeUnretainedValue().eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let session = Unmanaged<InputCaptureSession>.fromOpaque(userInfo).takeUnretainedValue()
        session.record(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func record(type: CGEventType, event: CGEvent) {
        let control = Self.detectControl(type: type, event: event)
        let summary = Self.describe(type: type, event: event, control: control)
        let entry = Entry(summary: summary, control: control)

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
    }

    private static func detectControl(type: CGEventType, event: CGEvent) -> PhysicalControl? {
        switch type {
        case .leftMouseDown:
            return .leftClick
        case .rightMouseDown:
            return .rightClick
        case .otherMouseDown:
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: return .middleClick
            case 3: return .sideButton1
            case 4: return .sideButton2
            case 5: return .dpiButton
            default: return nil
            }
        case .scrollWheel:
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if delta > 0 { return .wheelUp }
            if delta < 0 { return .wheelDown }
            return nil
        default:
            return nil
        }
    }

    private static func describe(type: CGEventType, event: CGEvent, control: PhysicalControl?) -> String {
        let typeName: String = switch type {
        case .leftMouseDown: "leftMouseDown"
        case .rightMouseDown: "rightMouseDown"
        case .otherMouseDown: "otherMouseDown(button=\(event.getIntegerValueField(.mouseEventButtonNumber)))"
        case .scrollWheel: "scrollWheel(delta=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)))"
        default: "event(\(type.rawValue))"
        }
        if let control {
            return "\(typeName) → \(control.displayName)"
        }
        return typeName
    }
}

public enum InputCaptureError: Error, LocalizedError {
    case missingInputMonitoring
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .missingInputMonitoring:
            return "Input Monitoring permission is required for capture."
        case .tapCreationFailed:
            return "Failed to create the capture event tap."
        }
    }
}
