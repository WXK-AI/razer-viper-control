import AppKit
import CoreGraphics
import Foundation

public final class InputCaptureSession: @unchecked Sendable {
    public enum Disposition: String, Equatable, Sendable {
        /// Physical input observed by the opt-in capture tap.
        case observed
        /// Event carries the remapper synthetic marker.
        case synthetic
        /// Remapper reported a remapped replacement/post.
        case remapped
        /// Remapper reported the event was consumed.
        case consumed
        /// Remapper reported passthrough.
        case passthrough

        public var displayName: String {
            switch self {
            case .observed: return "observed"
            case .synthetic: return "synthetic"
            case .remapped: return "remapped"
            case .consumed: return "consumed"
            case .passthrough: return "passthrough"
            }
        }
    }

    public struct WheelAxes: Equatable, Sendable {
        public var axis1Line: Int64
        public var axis1Point: Int64
        public var axis1FixedPt: Double
        public var axis2Line: Int64
        public var axis2Point: Int64
        public var axis2FixedPt: Double

        public init(
            axis1Line: Int64 = 0,
            axis1Point: Int64 = 0,
            axis1FixedPt: Double = 0,
            axis2Line: Int64 = 0,
            axis2Point: Int64 = 0,
            axis2FixedPt: Double = 0
        ) {
            self.axis1Line = axis1Line
            self.axis1Point = axis1Point
            self.axis1FixedPt = axis1FixedPt
            self.axis2Line = axis2Line
            self.axis2Point = axis2Point
            self.axis2FixedPt = axis2FixedPt
        }

        public var summary: String {
            "a1(line:\(axis1Line),point:\(axis1Point),fixed:\(String(format: "%.3f", axis1FixedPt))) "
                + "a2(line:\(axis2Line),point:\(axis2Point),fixed:\(String(format: "%.3f", axis2FixedPt)))"
        }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let eventType: String
        public let buttonNumber: Int64?
        public let wheelAxes: WheelAxes?
        public let control: PhysicalControl?
        public let isSynthetic: Bool
        public let disposition: Disposition
        public let summary: String

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            eventType: String,
            buttonNumber: Int64? = nil,
            wheelAxes: WheelAxes? = nil,
            control: PhysicalControl? = nil,
            isSynthetic: Bool = false,
            disposition: Disposition = .observed,
            summary: String
        ) {
            self.id = id
            self.timestamp = timestamp
            self.eventType = eventType
            self.buttonNumber = buttonNumber
            self.wheelAxes = wheelAxes
            self.control = control
            self.isSynthetic = isSynthetic
            self.disposition = disposition
            self.summary = summary
        }
    }

    public var onEntriesChanged: (([Entry]) -> Void)?

    public private(set) var isRunning = false
    public let maxEntries: Int

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// True while a main-queue publication block is outstanding or running.
    private var publicationScheduled = false
    /// Set by append/clear; consumed when a publication re-snapshots `entries`.
    private var publicationDirty = false
    /// Test seam: increments only when a main-queue publication block is enqueued.
    private(set) var publicationEnqueueCount = 0
    /// Coalesce window so continuous input cannot enqueue denser than one publish per interval.
    private static let publicationCoalesceInterval: DispatchTimeInterval = .milliseconds(16)

    public init(maxEntries: Int = 250) {
        self.maxEntries = max(1, maxEntries)
    }

    deinit {
        stop()
    }

    public func snapshotEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func start() throws {
        guard !isRunning else { return }
        let permissions = PermissionStatus.current()
        guard permissions.inputMonitoringGranted else {
            throw InputCaptureError.missingInputMonitoring
        }

        // Mouse/scroll only — no keyboard character capture in this session.
        let mask = (
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
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
        entries.removeAll(keepingCapacity: false)
        lock.unlock()
        // Prefer prompt empty UI when nothing is already outstanding.
        schedulePublication(immediate: true)
    }

    /// Records a remapper-side observation while diagnostics capture is enabled.
    public func recordRemapObservation(
        control: PhysicalControl?,
        disposition: Disposition,
        detail: String = ""
    ) {
        let summaryParts = [
            "remap",
            disposition.displayName,
            control.map(\.displayName),
            detail.isEmpty ? nil : detail
        ].compactMap { $0 }
        append(
            Entry(
                eventType: "remap",
                control: control,
                // Only true synthetic-marker events are synthetic; remapped is a remapper decision.
                isSynthetic: disposition == .synthetic,
                disposition: disposition,
                summary: summaryParts.joined(separator: " ")
            )
        )
    }

    /// Test/ remapper seam: append a fully formed diagnostic entry with cap eviction.
    public func append(_ entry: Entry) {
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
        schedulePublication(immediate: false)
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
        append(Self.makeEntry(type: type, event: event))
    }

    static func makeEntry(type: CGEventType, event: CGEvent) -> Entry {
        let isSynthetic = InputRemapperEngine.shouldIgnoreSynthetic(
            sourceUserData: event.getIntegerValueField(.eventSourceUserData)
        )
        let control = detectControl(type: type, event: event)
        let buttonNumber: Int64? = {
            switch type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return event.getIntegerValueField(.mouseEventButtonNumber)
            default:
                return nil
            }
        }()
        let wheelAxes: WheelAxes? = {
            guard type == .scrollWheel else { return nil }
            return WheelAxes(
                axis1Line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                axis1Point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                axis1FixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                axis2Line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                axis2Point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                axis2FixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            )
        }()
        let eventType = eventTypeName(type: type, buttonNumber: buttonNumber)
        let disposition: Disposition = isSynthetic ? .synthetic : .observed
        var parts = [eventType, disposition.displayName]
        if let control {
            parts.append(control.displayName)
        }
        if let buttonNumber {
            parts.append("button=\(buttonNumber)")
        }
        if let wheelAxes {
            parts.append(wheelAxes.summary)
        }
        if isSynthetic {
            parts.append("marker")
        }
        return Entry(
            eventType: eventType,
            buttonNumber: buttonNumber,
            wheelAxes: wheelAxes,
            control: control,
            isSynthetic: isSynthetic,
            disposition: disposition,
            summary: parts.joined(separator: " | ")
        )
    }

    /// At most one main-queue publication is outstanding. Further events only set a dirty flag
    /// (no per-event `DispatchWorkItem` / `async` allocation).
    private func schedulePublication(immediate: Bool) {
        lock.lock()
        publicationDirty = true
        if publicationScheduled {
            lock.unlock()
            return
        }
        publicationScheduled = true
        publicationEnqueueCount += 1
        lock.unlock()

        let deliver: () -> Void = { [weak self] in
            self?.deliverPublication()
        }
        if immediate {
            DispatchQueue.main.async(execute: deliver)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.publicationCoalesceInterval,
                execute: deliver
            )
        }
    }

    private func deliverPublication() {
        lock.lock()
        publicationDirty = false
        let snapshot = entries
        let callback = onEntriesChanged
        lock.unlock()

        callback?(snapshot)

        lock.lock()
        if publicationDirty {
            // Keep the single outstanding slot; schedule one follow-up after the coalesce window.
            publicationEnqueueCount += 1
            lock.unlock()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.publicationCoalesceInterval
            ) { [weak self] in
                self?.deliverPublication()
            }
            return
        }
        publicationScheduled = false
        if publicationDirty {
            publicationScheduled = true
            publicationEnqueueCount += 1
            lock.unlock()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.publicationCoalesceInterval
            ) { [weak self] in
                self?.deliverPublication()
            }
            return
        }
        lock.unlock()
    }

    private static func eventTypeName(type: CGEventType, buttonNumber: Int64?) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown:
            return "otherMouseDown"
        case .otherMouseUp:
            return "otherMouseUp"
        case .scrollWheel:
            return "scrollWheel"
        default:
            return "event(\(type.rawValue))"
        }
    }

    private static func detectControl(type: CGEventType, event: CGEvent) -> PhysicalControl? {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return .leftClick
        case .rightMouseDown, .rightMouseUp:
            return .rightClick
        case .otherMouseDown, .otherMouseUp:
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: return .wheelClick
            case 3: return .sideButton1
            case 4: return .sideButton2
            case 5: return .dpiButton
            default: return nil
            }
        case .scrollWheel:
            let axis = InputRemapperEngine.ScrollAxisValues(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                fixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            )
            let delta = InputRemapperEngine.primaryScrollDelta(for: axis)
            if delta > 0 { return .wheelUp }
            if delta < 0 { return .wheelDown }
            return nil
        default:
            return nil
        }
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
