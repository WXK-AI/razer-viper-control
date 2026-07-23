import AppKit
import CoreGraphics
import Foundation

public enum HeldOutputRecoveryReason: String, Equatable, Sendable {
    case pause
    case stop
    case tapDisable
    case tapDisableCircuitOpen
    case profileReplacement
    case permissionLoss
}

enum DeferredWorkspaceAction: Equatable {
    case openApp(URL)
    case openURL(URL)
}

public final class InputRemapper: @unchecked Sendable {
    public struct Callbacks {
        public var onNextDPIStage: (() -> Void)?
        public var onPreviousDPIStage: (() -> Void)?
        public var onNextProfile: (() -> Void)?
        public var onPreviousProfile: (() -> Void)?
        public var onEmergencyPause: (() -> Void)?
        /// Fired after a recovery transition. Tap-disable always notifies, even with no holds.
        public var onHeldOutputsReleased: ((HeldOutputRecoveryReason) -> Void)?
        /// Optional diagnostics sink (memory-only; never blocks on I/O).
        public var onInputDiagnostic: ((PhysicalControl?, InputCaptureSession.Disposition, String) -> Void)?

        public init() {}
    }

    /// Synchronized snapshot; internal code must use `runningState` under `lock` (non-recursive).
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return runningState
    }

    /// Synchronized snapshot; internal code must use `pausedState` under `lock` (non-recursive).
    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedState
    }

    /// Synchronized snapshot; internal code must use `installedCallbacks` under `lock` (non-recursive).
    /// Callbacks are set-once before `start()`. Mutation while running is rejected.
    public var callbacks: Callbacks {
        lock.lock()
        defer { lock.unlock() }
        return installedCallbacks
    }

    var monotonicTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var scheduleWorkspaceAction: (DeferredWorkspaceAction) -> Void = { action in
        DispatchQueue.main.async {
            switch action {
            case let .openApp(url):
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            case let .openURL(url):
                NSWorkspace.shared.open(url)
            }
        }
    }
    /// Injectable keyboard-event posting seam used by production (default posts CGEvents).
    /// Tests replace this to observe order/flags without a window server.
    var postKeyboardEvent: (UInt16, Bool, CGEventFlags) -> Void = InputRemapper.defaultPostKeyboardEvent

    private let lock = NSLock()
    private var runningState = false
    private var pausedState = false
    private var installedCallbacks = Callbacks()
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
    private var verticalLineScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    private var verticalPointScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    /// Residuals for Shift-converted vertical→horizontal output.
    private var horizontalLineScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    private var horizontalPointScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    /// Residuals for native axis-2 (hardware/trackpad horizontal) output.
    private var nativeHorizontalLineScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    private var nativeHorizontalPointScrollScaler = InputRemapperEngine.ScrollDeltaScaler()
    private var scrollActionThrottle = InputRemapperEngine.ScrollActionThrottle()
    /// Last recovery transition that notified observers (including empty tap-disable).
    private var lastHeldOutputRecovery: HeldOutputRecoveryReason?
    /// Synthetic mouse-ups posted by recovery releases (observed by tests via `@testable`).
    private var syntheticMouseUpCount = 0
    /// Blocks mapped downs while profile replacement ups publish and before the new mapping is live.
    private var suppressMappedDowns = false
    private var tapDisableCircuitBreaker = TapDisableCircuitBreaker()

    public init() {}

    deinit {
        stop()
    }

    /// Installs callbacks before the remapper is running. Returns `false` if already running.
    @discardableResult
    public func setCallbacks(_ newCallbacks: Callbacks) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !runningState else { return false }
        installedCallbacks = newCallbacks
        return true
    }

    public func updateProfile(_ profile: MouseProfile) {
        let mappingsChanged: Bool
        let release: HeldOutputRelease
        lock.lock()
        let incoming = Self.sanitizedProfile(profile)
        mappingsChanged =
            self.profile.buttonMappings != incoming.buttonMappings
            || self.profile.remapperEnabled != incoming.remapperEnabled
        if mappingsChanged {
            let targets = buttonSession.releaseAllHeldOutputs()
            // Keep the old mapping readable, but reject new mapped downs until finalize.
            suppressMappedDowns = true
            release = makeReleaseLocked(
                targets: targets,
                reason: .profileReplacement,
                notifyIfEmpty: false
            )
            // Defer profile install until after ups; stash pending profile on self temporarily via finalize capture.
        } else {
            applyProfileLocked(incoming)
            release = makeReleaseLocked(
                targets: [],
                reason: .profileReplacement,
                notifyIfEmpty: false
            )
        }
        lock.unlock()

        publishHeldOutputRelease(release) {
            guard mappingsChanged else { return }
            self.applyProfileLocked(incoming)
            self.suppressMappedDowns = false
        }
    }

    public func pause() {
        let release = commitRecoveryTransition(reason: .pause, notifyIfEmpty: false) {
            let targets = buttonSession.releaseAllHeldOutputs()
            pausedState = true
            suppressMappedDowns = false
            resetScrollAccumulatorsLocked()
            return targets
        }
        publishHeldOutputRelease(release)
    }

    /// Clears pause when the circuit is closed. Returns `false` while the circuit is open
    /// (caller must keep UI paused).
    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !tapDisableCircuitBreaker.isOpen else {
            return false
        }
        pausedState = false
        return true
    }

    /// Releases any remapped mouse holds after Accessibility/Input Monitoring is lost.
    public func handlePermissionLoss() {
        let release = commitRecoveryTransition(reason: .permissionLoss, notifyIfEmpty: false) {
            let targets = buttonSession.releaseAllHeldOutputs()
            tearDownEventTapLocked()
            resetScrollAccumulatorsLocked()
            return targets
        }
        publishHeldOutputRelease(release)
    }

    public func start() throws {
        lock.lock()
        let circuitOpen = tapDisableCircuitBreaker.isOpen
        let alreadyRunning = runningState
        lock.unlock()
        guard !circuitOpen else {
            throw InputRemapperError.circuitOpen
        }
        guard !alreadyRunning else { return }
        let permissions = PermissionStatus.current()
        guard permissions.remapperReady else {
            throw InputRemapperError.missingPermissions(permissions)
        }

        // Build mask incrementally so the type checker does not time out on a
        // single huge bitwise-OR expression (seen on macos-15 CI runners).
        var mask: CGEventMask = 0
        mask |= CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.scrollWheel.rawValue
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: InputRemapper.eventCallback,
            userInfo: userInfo
        ) else {
            throw InputRemapperError.tapCreationFailed
        }

        lock.lock()
        // Re-check under the same lock before publishing running state (concurrent start/stop).
        if runningState || tapDisableCircuitBreaker.isOpen {
            let circuitOpenNow = tapDisableCircuitBreaker.isOpen
            lock.unlock()
            CGEvent.tapEnable(tap: tap, enable: false)
            if circuitOpenNow {
                throw InputRemapperError.circuitOpen
            }
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        runningState = true
        lock.unlock()
    }

    public func stop() {
        let release = commitRecoveryTransition(reason: .stop, notifyIfEmpty: false) {
            let targets = buttonSession.releaseAllHeldOutputs()
            tearDownEventTapLocked()
            resetScrollAccumulatorsLocked()
            return targets
        }
        publishHeldOutputRelease(release)
    }

    // MARK: - Test seams (`@testable` / internal)

    /// Installs a remapped hold without a live event tap.
    func seedRemappedHold(control: PhysicalControl, target: MouseButtonTarget) {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[control] = .mouseButton(target)
        lock.lock()
        _ = buttonSession.handle(control: control, kind: .down, mappings: mappings)
        lock.unlock()
    }

    func heldMouseTargets() -> [MouseButtonTarget] {
        lock.lock()
        defer { lock.unlock() }
        return buttonSession.snapshotHeldMouseTargets()
    }

    func lastRecoveryReason() -> HeldOutputRecoveryReason? {
        lock.lock()
        defer { lock.unlock() }
        return lastHeldOutputRecovery
    }

    func releasedSyntheticMouseUpCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return syntheticMouseUpCount
    }

    public var isCircuitOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tapDisableCircuitBreaker.isOpen
    }

    /// Clears a tripped circuit only after the user explicitly re-arms remapping.
    public func resetTapDisableCircuit() {
        lock.lock()
        tapDisableCircuitBreaker.reset()
        lock.unlock()
    }

    /// Atomic snapshot used to detect pause/hold transition races.
    func recoveryStateSnapshot() -> (isPaused: Bool, heldTargets: [MouseButtonTarget]) {
        lock.lock()
        defer { lock.unlock() }
        return (pausedState, buttonSession.snapshotHeldMouseTargets())
    }

    /// Mirrors the live down path (respects pause / remapperEnabled / profile-transition gate).
    @discardableResult
    func processMappedButtonDown(_ control: PhysicalControl) -> RemapButtonOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard !pausedState, !suppressMappedDowns, profile.remapperEnabled else {
            return nil
        }
        return buttonSession.handle(
            control: control,
            kind: .down,
            mappings: profile.buttonMappings
        )
    }

    func isSuppressingMappedDowns() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressMappedDowns
    }

    func activeButtonAction(for control: PhysicalControl) -> ButtonAction {
        lock.lock()
        defer { lock.unlock() }
        return InputRemapperEngine.resolvedButtonAction(for: control, in: profile.buttonMappings)
    }

    /// Shared scroll path for the event tap and tests. Snapshots pause/profile under lock,
    /// then scales axes / fires mapped wheel actions via the same internal handlers.
    func processScrollWheelEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let currentProfile = profile
        let callbacksSnapshot = installedCallbacks
        let paused = pausedState
        lock.unlock()
        guard !paused, currentProfile.remapperEnabled else {
            return Unmanaged.passUnretained(event)
        }
        return handleScrollEvent(event: event, profile: currentProfile, callbacks: callbacksSnapshot)
    }

    /// Invoked after synthetic ups are posted and before deferred finalize work
    /// (profile apply / tap re-enable). Tests use this to assert publish ordering.
    var recoveryOrderingProbe: (() -> Void)?
    /// Invoked after deferred finalize work completes.
    var recoveryFinalizeProbe: (() -> Void)?

    func recoverAfterTapDisable() {
        let release: HeldOutputRelease
        let shouldReenable: Bool
        lock.lock()
        switch tapDisableCircuitBreaker.recordDisable(at: monotonicTime()) {
        case .allowRecovery:
            // Clear holds now; re-enable the tap only after ups are published.
            release = makeReleaseLocked(
                targets: buttonSession.releaseAllHeldOutputs(),
                reason: .tapDisable,
                notifyIfEmpty: true
            )
            shouldReenable = true
        case .trip:
            let targets = buttonSession.releaseAllHeldOutputs()
            pausedState = true
            tearDownEventTapLocked()
            release = makeReleaseLocked(
                targets: targets,
                reason: .tapDisableCircuitOpen,
                notifyIfEmpty: true
            )
            shouldReenable = false
        }
        lock.unlock()
        if shouldReenable {
            publishHeldOutputRelease(release) {
                // Finalize runs under lock: only re-enable if still running with a live tap.
                guard self.runningState, let tap = self.eventTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        } else {
            publishHeldOutputRelease(release)
        }
    }

    // MARK: - Locked recovery transitions

    private struct HeldOutputRelease {
        let targets: [MouseButtonTarget]
        let reason: HeldOutputRecoveryReason
        let shouldNotify: Bool
        let callback: ((HeldOutputRecoveryReason) -> Void)?
    }

    /// Snapshot/clear holds and apply gating state in one critical section.
    /// Deferred exposure (new mappings / tap re-enable) happens in `publishHeldOutputRelease`'s finalize.
    private func commitRecoveryTransition(
        reason: HeldOutputRecoveryReason,
        notifyIfEmpty: Bool,
        mutate: () -> [MouseButtonTarget]
    ) -> HeldOutputRelease {
        lock.lock()
        let targets = mutate()
        let release = makeReleaseLocked(
            targets: targets,
            reason: reason,
            notifyIfEmpty: notifyIfEmpty
        )
        lock.unlock()
        return release
    }

    private func makeReleaseLocked(
        targets: [MouseButtonTarget],
        reason: HeldOutputRecoveryReason,
        notifyIfEmpty: Bool
    ) -> HeldOutputRelease {
        let shouldNotify = !targets.isEmpty || notifyIfEmpty
        if shouldNotify {
            lastHeldOutputRecovery = reason
        }
        return HeldOutputRelease(
            targets: targets,
            reason: reason,
            shouldNotify: shouldNotify,
            callback: installedCallbacks.onHeldOutputsReleased
        )
    }

    private func publishHeldOutputRelease(
        _ release: HeldOutputRelease,
        finalize: (() -> Void)? = nil
    ) {
        for target in release.targets {
            postMouseButton(target, down: false)
        }
        if !release.targets.isEmpty {
            lock.lock()
            syntheticMouseUpCount += release.targets.count
            lock.unlock()
        }
        // Probe sees post-up, pre-finalize state so tests can catch ordering bugs.
        recoveryOrderingProbe?()
        if let finalize {
            lock.lock()
            finalize()
            lock.unlock()
            recoveryFinalizeProbe?()
        }
        if release.shouldNotify {
            release.callback?(release.reason)
        }
    }

    private func tearDownEventTapLocked() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        runningState = false
        suppressMappedDowns = false
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
        let callbacksSnapshot = installedCallbacks
        lock.unlock()

        if type == .keyDown, matchesEmergencyPause(event) {
            pause()
            callbacksSnapshot.onEmergencyPause?()
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
                return applyButtonOutcome(
                    outcome,
                    control: control,
                    event: event,
                    callbacks: callbacksSnapshot
                )
            }

            // Re-check pause/enabled/transition gate under the same lock as hold creation.
            lock.lock()
            if pausedState || suppressMappedDowns || !profile.remapperEnabled {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let outcome = buttonSession.handle(
                control: control,
                kind: .down,
                mappings: profile.buttonMappings
            )
            lock.unlock()
            return applyButtonOutcome(
                outcome,
                control: control,
                event: event,
                callbacks: callbacksSnapshot
            )

        case .scrollWheel:
            // Re-enter through the shared scroll path so production and tests share one code path.
            return processScrollWheelEvent(event)

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func applyButtonOutcome(
        _ outcome: RemapButtonOutcome,
        control: PhysicalControl,
        event: CGEvent,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        switch outcome {
        case .passThrough:
            callbacks.onInputDiagnostic?(control, .passthrough, "button")
            return Unmanaged.passUnretained(event)
        case .consume:
            callbacks.onInputDiagnostic?(control, .consumed, "button")
            return nil
        case let .postMouse(target, down):
            callbacks.onInputDiagnostic?(
                control,
                .remapped,
                "mouse \(target) \(down ? "down" : "up")"
            )
            postMouseButton(target, down: down, mirroring: event)
            return nil
        case let .postMouseDrag(target):
            callbacks.onInputDiagnostic?(control, .remapped, "mouse \(target) drag")
            postMouseDrag(target, mirroring: event)
            return nil
        case let .fireOneShot(oneShotAction):
            callbacks.onInputDiagnostic?(control, .consumed, "one-shot \(oneShotAction)")
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

    func executeOneShotAction(_ action: ButtonAction, callbacks: Callbacks) {
        switch action {
        case let .keyboardShortcut(shortcut):
            postKeyboardShortcut(shortcut)
        case .nextDPIStage:
            callbacks.onNextDPIStage?()
        case .previousDPIStage:
            callbacks.onPreviousDPIStage?()
        case .nextProfile:
            callbacks.onNextProfile?()
        case .previousProfile:
            callbacks.onPreviousProfile?()
        case let .openApp(path):
            let url = URL(fileURLWithPath: path).standardizedFileURL
            scheduleWorkspaceAction(.openApp(url))
        case let .openURL(urlString):
            if let normalized = ButtonActionValidator.normalizedOpenURL(urlString),
               let url = URL(string: normalized) {
                scheduleWorkspaceAction(.openURL(url))
            }
        case .passthrough, .disabled, .mouseButton:
            break
        }
    }

    private func resetScrollAccumulatorsLocked() {
        verticalLineScrollScaler.reset()
        verticalPointScrollScaler.reset()
        horizontalLineScrollScaler.reset()
        horizontalPointScrollScaler.reset()
        nativeHorizontalLineScrollScaler.reset()
        nativeHorizontalPointScrollScaler.reset()
        scrollActionThrottle.reset()
    }

    private static func sanitizedProfile(_ profile: MouseProfile) -> MouseProfile {
        var sanitized = profile
        sanitized.wheelSettings.software.verticalSpeedMultiplier =
            SoftwareWheelSettings.sanitizedSpeedMultiplier(
                profile.wheelSettings.software.verticalSpeedMultiplier
            )
        return sanitized
    }

    /// Installs a sanitized profile. Resets scroll residuals / action throttle when software
    /// wheel settings change, and always resets the action throttle on profile replacement.
    private func applyProfileLocked(_ profile: MouseProfile) {
        let wheelSoftwareChanged = self.profile.wheelSettings.software != profile.wheelSettings.software
        self.profile = profile
        if wheelSoftwareChanged {
            resetScrollAccumulatorsLocked()
        } else {
            scrollActionThrottle.reset()
        }
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
        let axis2 = InputRemapperEngine.ScrollAxisValues(
            line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
        guard !axis1.isEffectivelyZero || !axis2.isEffectivelyZero else {
            return Unmanaged.passUnretained(event)
        }

        let software = profile.wheelSettings.software
        let shiftKeyHeld = event.flags.contains(.maskShift)
        let convertVerticalToHorizontal =
            software.horizontalScrollModifier == .shift && shiftKeyHeld

        // Wheel-up/down actions key off axis 1 only; axis-2-only is always software passthrough.
        if axis1.isEffectivelyZero {
            let modified = event
            applyScaledPassthrough(
                axis1: axis1,
                axis2: axis2,
                software: software,
                event: modified,
                shiftKeyHeld: shiftKeyHeld
            )
            callbacks.onInputDiagnostic?(nil, .passthrough, "scroll-axis2")
            return Unmanaged.passUnretained(modified)
        }

        let primaryDelta = InputRemapperEngine.primaryScrollDelta(for: axis1)
        let wheelUp = primaryDelta > 0
        let wheelControl: PhysicalControl = wheelUp ? .wheelUp : .wheelDown

        let mappingAction = profile.buttonMappings[wheelControl] ?? .passthrough
        let softwareAction = wheelUp ? software.wheelUpAction : software.wheelDownAction
        let action = softwareAction ?? mappingAction

        if case .passthrough = action {
            let modified = event
            applyScaledPassthrough(
                axis1: axis1,
                axis2: axis2,
                software: software,
                event: modified,
                shiftKeyHeld: shiftKeyHeld
            )
            callbacks.onInputDiagnostic?(
                wheelControl,
                .passthrough,
                convertVerticalToHorizontal ? "scroll→horizontal" : "scroll"
            )
            return Unmanaged.passUnretained(modified)
        }

        return executeScrollAction(
            action,
            wheelControl: wheelControl,
            direction: wheelUp ? 1 : -1,
            axis2: axis2,
            software: software,
            event: event,
            callbacks: callbacks
        )
    }

    /// Scales axis1/axis2 for passthrough. `shiftKeyHeld` is the raw Shift key state;
    /// conversion only happens when software also enables `.shift` as the horizontal modifier.
    private func applyScaledPassthrough(
        axis1: InputRemapperEngine.ScrollAxisValues,
        axis2: InputRemapperEngine.ScrollAxisValues,
        software: SoftwareWheelSettings,
        event: CGEvent,
        shiftKeyHeld: Bool
    ) {
        let invert = software.scrollDirection == .inverted
        let multiplier = SoftwareWheelSettings.sanitizedSpeedMultiplier(software.verticalSpeedMultiplier)
        let convertVerticalToHorizontal =
            software.horizontalScrollModifier == .shift && shiftKeyHeld

        lock.lock()
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            axis2: axis2,
            verticalLineScaler: &verticalLineScrollScaler,
            verticalPointScaler: &verticalPointScrollScaler,
            horizontalLineScaler: &horizontalLineScrollScaler,
            horizontalPointScaler: &horizontalPointScrollScaler,
            nativeHorizontalLineScaler: &nativeHorizontalLineScrollScaler,
            nativeHorizontalPointScaler: &nativeHorizontalPointScrollScaler,
            multiplier: multiplier,
            invert: invert,
            convertVerticalToHorizontal: convertVerticalToHorizontal
        )
        lock.unlock()
        applyScrollAxes(scaled, to: event)
    }

    private func applyScrollAxes(_ pair: InputRemapperEngine.ScrollAxisPair, to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: pair.axis1.line)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: pair.axis2.line)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pair.axis1.point)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pair.axis2.point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pair.axis1.fixedPt)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: pair.axis2.fixedPt)
    }

    /// Fires a mapped wheel action under the 60ms throttle. Axis 1 is always consumed by the
    /// mapping; non-zero native axis 2 is still scaled and returned as a remainder event.
    private func executeScrollAction(
        _ action: ButtonAction,
        wheelControl: PhysicalControl,
        direction: Int,
        axis2: InputRemapperEngine.ScrollAxisValues,
        software: SoftwareWheelSettings,
        event: CGEvent,
        callbacks: Callbacks
    ) -> Unmanaged<CGEvent>? {
        // Re-check pause under the same lock as throttle/consume (mirrors button-down).
        lock.lock()
        if pausedState {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        let shouldFire = scrollActionThrottle.shouldFire(direction: direction, at: monotonicTime())
        lock.unlock()

        if shouldFire {
            switch action {
            case .passthrough, .disabled:
                callbacks.onInputDiagnostic?(wheelControl, .consumed, "scroll disabled")
            case let .mouseButton(target):
                callbacks.onInputDiagnostic?(wheelControl, .remapped, "scroll→\(target)")
                postMouseButton(target, down: true)
                postMouseButton(target, down: false)
            case .keyboardShortcut, .nextDPIStage, .previousDPIStage, .nextProfile, .previousProfile, .openApp, .openURL:
                callbacks.onInputDiagnostic?(wheelControl, .consumed, "scroll one-shot")
                executeOneShotAction(action, callbacks: callbacks)
            }
        }

        // Mapped axis-1 dual-axis events must preserve scaled native axis 2 even when the
        // vertical action fires or is throttled. Axis1-only mapped ticks still return nil.
        guard !axis2.isEffectivelyZero else {
            return nil
        }
        let modified = event
        // Axis 1 was consumed by the mapping; only scale native axis 2 (no Shift conversion).
        applyScaledPassthrough(
            axis1: .zero,
            axis2: axis2,
            software: software,
            event: modified,
            shiftKeyHeld: false
        )
        return Unmanaged.passUnretained(modified)
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

    /// Posts key-down then key-up via the keyboard seam. Skips both while paused.
    /// Key-down carries shortcut modifiers; key-up clears flags so modifiers cannot stick.
    private func postKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        lock.lock()
        let paused = pausedState
        lock.unlock()
        guard !paused else { return }

        let downFlags = CGEventFlags(rawValue: shortcut.modifierFlags)
        postKeyboardEvent(shortcut.keyCode, true, downFlags)
        postKeyboardEvent(shortcut.keyCode, false, [])
    }

    private static func defaultPostKeyboardEvent(keyCode: UInt16, keyDown: Bool, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = InputRemapperEngine.syntheticMarker
        guard let source,
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(keyCode),
                  keyDown: keyDown
              ) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: InputRemapperEngine.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

public enum InputRemapperError: Error, LocalizedError {
    case missingPermissions(PermissionStatus)
    case tapCreationFailed
    case circuitOpen

    public var errorDescription: String? {
        switch self {
        case let .missingPermissions(status):
            return "Remapper permissions missing. \(status.summary)"
        case .tapCreationFailed:
            return "Failed to create the global event tap."
        case .circuitOpen:
            return "Remapper paused after repeated event-tap timeouts. Arm the remapper again to resume."
        }
    }
}
