import AppKit
import Foundation
import RazerCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var isConnected = false
    @Published var batteryPercent = 0
    @Published var isCharging = false
    @Published var profileName = "—"
    @Published var activeDPI = 0
    @Published var pollingRateHz: Int?
    @Published var statusMessage = "Waiting for mouse…"
    @Published var warningMessage: String?
    @Published var persistenceWarning: String?
    @Published var quarantinedProfileURL: URL?
    /// This device's quarantine artifacts for Diagnostics restore/reveal (newest first).
    @Published var quarantinedArtifacts: [URL] = []
    @Published var persistenceStatus: PersistenceStatus = .clean
    @Published var profileDraft: ProfileDraft?
    @Published var pendingQuitAfterSaveFailure = false
    @Published var confirmDiscardCorruptFile = false
    @Published var mappingWarning: String?

    var writesBlockedForCorruptSource: Bool {
        profileStore.writesBlockedForCorruptSource
    }

    var areWritesBlocked: Bool {
        profileStore.areWritesBlocked
    }

    /// Quarantine/discard actions are only for preserved corrupt profile files.
    var allowsCorruptSourceRecoveryActions: Bool {
        profileStore.allowsCorruptSourceRecoveryActions
    }
    @Published var bundle: ProfileBundle
    @Published var launchAtLogin = false
    @Published var showSettings = false
    @Published var remapperPaused = false
    @Published var remapperRunning = false
    @Published var remapperRecovering = false
    @Published var remapperCircuitOpen = false
    @Published var remapperStartError: String?
    @Published var driverActivationState: DriverActivationState = .unknown
    @Published var driverStatusMessage = "Driver status has not been queried yet."
    @Published var driverLastError: String?
    @Published var wheelCapability = WheelHardwareCapability()
    @Published var permissions = PermissionStatus.current()
    @Published var captureSession = InputCaptureSession()
    @Published var captureEntries: [InputCaptureSession.Entry] = []
    @Published var diagnosticsCaptureEnabled = false
    @Published var wheelProbeSummary = "Not probed yet"
    @Published var shortcutCaptureControl: PhysicalControl?

    var remapperStatus: RemapperRuntimeStatus {
        RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: selectedProfile?.remapperEnabled ?? false,
            remapperArmed: remapperArmed,
            permissions: permissions,
            isRunning: remapperRunning,
            isPaused: remapperPaused,
            isRecovering: remapperRecovering,
            lastError: remapperStartError,
            circuitOpen: remapperCircuitOpen
        )
    }

    /// Pure menu presentation — views render this instead of raw error dumps.
    var menuStatus: MenuStatusPresentation {
        let remapper = remapperStatus
        let showRemapper = selectedProfile?.remapperEnabled == true
            || remapperRunning
            || remapperArmed
            || remapperCircuitOpen
        return MenuStatusModel.make(
            inputs: MenuStatusInputs(
                isConnected: isConnected,
                batteryPercent: batteryPercent,
                isCharging: isCharging,
                isLowBattery: lowBatteryLatched,
                commandError: lastCommandError,
                connectionStatusLine: statusMessage,
                remapperStatus: remapper,
                showRemapperSection: showRemapper,
                persistenceWarning: persistenceWarning,
                reconnectFeedback: reconnectFeedback
            )
        )
    }

    var hardwareChangesPending: Bool {
        HardwarePendingDetector.hasPendingChanges(
            profile: selectedProfile,
            lastApplied: lastAppliedHardwareSettings
        )
    }

    typealias DelayedActionScheduler = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> Void

    private let session: any DeviceSessionProtocol
    private let profileStore: ProfileStore
    private let workspaceNotificationCenter: NotificationCenter
    private let scheduleDelayedAction: DelayedActionScheduler
    private let remapper = InputRemapper()
    private let systemExtensionManager = SystemExtensionManager()
    private let hidQueue = DispatchQueue(label: "com.razermenubar.hid", qos: .utility)
    private let hardwareApplyGate = LatestHardwareApplyGate()
    private let deviceLifecycleGate = DeviceLifecycleGate()
    private var lastAppliedHardwareSettings: HardwareProfileSettings?
    private var hardwareVerificationWarning: String?
    /// Event-tap-safe diagnostic bridge; avoids per-event MainActor `Task` hops.
    private let remapDiagnosticSink = InputCaptureDiagnosticSink()
    private var monitorTimer: Timer?
    private var wasConnected = false
    private var isSleeping = false
    private var isRefreshInFlight = false
    private var deviceRefreshRequested = false
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var autoApplyState = AutoApplyCoordinator.State()
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.4
    /// Low-battery hysteresis latch (enter ≤15%, clear ≥20%).
    private var lowBatteryLatched = false
    /// Last device command error used for friendly menu mapping.
    private var lastCommandError: RazerCommandError?
    /// Transient reconnect result line for the menu.
    @Published private(set) var reconnectFeedback: MenuReconnectFeedback?
    private var reconnectFeedbackGeneration: UInt64 = 0
    /// True after any successful link this process; first connect must not say "Reconnected".
    private var hadPriorSuccessfulConnection = false

    private var draftsByProfileID: [UUID: ProfileDraft] = [:]

    /// Session-only consent to run the remapper; never persisted. Resets on every launch.
    @Published var remapperArmed = false
    @Published var confirmArmRemapper = false
    private var pendingRemapperEnableDraft: ProfileDraft?

    init(
        profileStore: ProfileStore = ProfileStore(),
        session: any DeviceSessionProtocol = DeviceSession(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scheduleDelayedAction: @escaping DelayedActionScheduler = { delay, action in
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    ) {
        self.profileStore = profileStore
        self.session = session
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.scheduleDelayedAction = scheduleDelayedAction
        let outcome = profileStore.loadOutcome()
        bundle = outcome.bundle

        switch outcome {
        case .loaded:
            if let warning = outcome.persistenceWarning {
                persistenceStatus = .failed(warning)
                persistenceWarning = "Profiles loaded in memory, but repairing/saving them failed: \(warning)"
            }
        case .firstRun:
            if let warning = outcome.persistenceWarning {
                persistenceStatus = .failed(warning)
                persistenceWarning = "Could not create initial profile storage: \(warning)"
            }
        case let .recovered(_, quarantinedURL, reason, persistenceWarning):
            quarantinedProfileURL = quarantinedURL
            if let persistenceWarning {
                persistenceStatus = .failed(persistenceWarning)
                self.persistenceWarning = "Corrupt profiles were quarantined, but saving defaults failed: \(persistenceWarning). \(reason)"
            } else {
                self.persistenceWarning = "Saved profiles were unreadable and were reset to defaults. \(reason)"
            }
        case let .corruptPreserved(_, sourceURL, reason):
            quarantinedProfileURL = sourceURL
            persistenceStatus = .failed(ProfileStoreError.writeBlockedCorruptSource(sourceURL.path).localizedDescription)
            persistenceWarning = "Saved profiles are corrupt and could not be quarantined. Edits stay in memory until you quarantine or discard the corrupt file. \(reason)"
        }

        if bundle.profiles.isEmpty {
            bundle = profileStore.defaultBundle()
            if !profileStore.areWritesBlocked {
                do {
                    try profileStore.save(bundle)
                } catch {
                    persistenceStatus = .failed(error.localizedDescription)
                    persistenceWarning = "Could not save empty-profile recovery defaults: \(error.localizedDescription)"
                }
            }
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = LaunchAtLoginManager.isEnabled
        }
        configureRemapperCallbacks()
        configureCaptureSession()
        bindSystemExtensionManager()
        configureDeviceLifecycleMonitoring()
        refreshProfileSummary()
        refreshMappingWarning()
        reloadDraftFromSelectedProfile()
        refreshQuarantineList()
        startMonitoring()
        syncRemapper()
    }

    private func bindSystemExtensionManager() {
        systemExtensionManager.onStateChange = { [weak self] in
            self?.syncDriverStatusFromManager()
        }
        syncDriverStatusFromManager()
    }

    private func syncDriverStatusFromManager() {
        driverActivationState = systemExtensionManager.state
        driverStatusMessage = systemExtensionManager.statusMessage
        driverLastError = systemExtensionManager.lastErrorDescription
    }

    func activateDriverExtension() {
        systemExtensionManager.activate()
        syncDriverStatusFromManager()
    }

    func deactivateDriverExtension() {
        systemExtensionManager.deactivate()
        syncDriverStatusFromManager()
    }

    func dismissPersistenceWarning() {
        // Dismissing the banner must not clear a durable corrupt-source write block.
        if profileStore.allowsCorruptSourceRecoveryActions {
            return
        }
        persistenceWarning = nil
    }

    /// Retries quarantine, then persists the in-memory defaults/bundle.
    func retryQuarantineCorruptProfiles() {
        guard profileStore.allowsCorruptSourceRecoveryActions else {
            persistenceWarning = profileStore.areWritesBlocked
                ? (persistenceWarning ?? "Profile storage is blocked.")
                : persistenceWarning
            return
        }
        do {
            let url = try profileStore.retryQuarantineCorruptSource()
            quarantinedProfileURL = url
            try profileStore.save(bundle)
            persistenceStatus = .clean
            persistenceWarning = "Corrupt profiles were quarantined and defaults were saved."
            refreshQuarantineList()
        } catch {
            persistenceStatus = .failed(error.localizedDescription)
            persistenceWarning = error.localizedDescription
        }
    }

    /// Explicitly discards the corrupt primary file and starts fresh with the in-memory bundle.
    func discardCorruptFileAndStartFresh() {
        guard profileStore.allowsCorruptSourceRecoveryActions else {
            confirmDiscardCorruptFile = false
            return
        }
        do {
            try profileStore.discardCorruptSourceAndAllowWrites()
            try profileStore.save(bundle)
            persistenceStatus = .clean
            persistenceWarning = nil
            quarantinedProfileURL = nil
            confirmDiscardCorruptFile = false
            refreshQuarantineList()
        } catch {
            persistenceStatus = .failed(error.localizedDescription)
            persistenceWarning = error.localizedDescription
        }
    }

    /// Refreshes the Diagnostics quarantine list (newest first for this device).
    func refreshQuarantineList() {
        do {
            quarantinedArtifacts = try profileStore.listQuarantineArtifacts()
        } catch {
            quarantinedArtifacts = []
        }
    }

    /// Restores a validated quarantine artifact into the primary store. On failure, in-memory state is unchanged.
    func restoreQuarantinedProfile(from url: URL) {
        do {
            let restored = try profileStore.attemptRestore(from: url)
            bundle = restored
            draftsByProfileID.removeAll()
            reloadDraftFromSelectedProfile()
            refreshProfileSummary()
            refreshMappingWarning()
            persistenceStatus = .clean
            persistenceWarning = nil
            // Banner "reveal last quarantine" may still point at a useful file; keep if present.
            refreshQuarantineList()
            syncRemapper()
        } catch {
            persistenceStatus = .failed(error.localizedDescription)
            persistenceWarning = "Could not restore quarantined profiles: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reloadDraftFromSelectedProfile() {
        guard let profile = selectedProfile else {
            profileDraft = nil
            return
        }
        if let existing = draftsByProfileID[profile.id] {
            profileDraft = existing
        } else {
            let draft = ProfileDraft(profile: profile)
            draftsByProfileID[profile.id] = draft
            profileDraft = draft
        }
    }

    deinit {
        monitorTimer?.invalidate()
        saveWorkItem?.cancel()
        session.onDeviceRemoved = nil
        workspaceObserverTokens.forEach(workspaceNotificationCenter.removeObserver)
        remapper.stop()
    }

    var selectedProfile: MouseProfile? {
        bundle.selectedProfile
    }

    func startMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDeviceState()
            }
        }
        refreshDeviceState()
        refreshPermissions()
    }

    /// Session cache mutation is lock-protected in `DeviceSession`. All UI and
    /// workspace lifecycle reactions explicitly hop to this model's main actor.
    private func configureDeviceLifecycleMonitoring() {
        // Gates are thread-safe; bump them on the removal delivery path before any
        // MainActor hop so in-flight HID work cannot treat a removed device as current.
        let lifecycleGate = deviceLifecycleGate
        let applyGate = hardwareApplyGate
        session.onDeviceRemoved = { [weak self] in
            lifecycleGate.invalidateForRemoval()
            _ = applyGate.issue()
            Task { @MainActor in
                self?.handleCachedDeviceRemoval()
            }
        }

        guard workspaceObserverTokens.isEmpty else { return }
        let willSleepToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillSleep()
            }
        }
        let didWakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleWakeRefresh()
            }
        }
        workspaceObserverTokens = [willSleepToken, didWakeToken]
    }

    private func handleCachedDeviceRemoval() {
        // Generations were already advanced in `onDeviceRemoved`; do not bump again.
        deviceRefreshRequested = false
        applyDisconnectedState(commandError: nil)
        syncRemapper()
        // DeviceSession retires the matched client before this handler runs, but a
        // raced reconnect on hidQueue can re-cache; retire behind in-flight HID work.
        hidQueue.async { [session] in
            session.invalidate()
        }
    }

    private func handleWillSleep() {
        isSleeping = true
        deviceLifecycleGate.transitionToSleep()
        _ = hardwareApplyGate.issue()
        deviceRefreshRequested = false
        applyDisconnectedState(commandError: nil)
        syncRemapper()

        // Queue retirement behind any in-flight HID operation. DeviceSession's
        // own lock also orders close before a later replacement open.
        hidQueue.async { [session] in
            session.invalidate()
        }
    }

    private func scheduleWakeRefresh() {
        isSleeping = false
        let lifecycleToken = deviceLifecycleGate.transitionToWake()
        scheduleDelayedAction(2) { [weak self] in
            Task { @MainActor in
                guard let self,
                      !self.isSleeping,
                      self.deviceLifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                    return
                }
                self.refreshDeviceState()
            }
        }
    }

    func refreshPermissions() {
        let wasReady = permissions.remapperReady
        permissions = PermissionStatus.current()
        if wasReady && !permissions.remapperReady {
            // Permission loss clears session arming; restoration alone must not restart.
            remapperArmed = false
            remapperCircuitOpen = false
        }
        if wasReady != permissions.remapperReady {
            syncRemapper()
        }
    }

    func refreshDeviceState() {
        guard !isSleeping,
              let lifecycleToken = deviceLifecycleGate.currentAwakeToken() else {
            deviceRefreshRequested = false
            return
        }
        refreshPermissions()
        guard !isRefreshInFlight else {
            deviceRefreshRequested = true
            return
        }
        isRefreshInFlight = true
        deviceRefreshRequested = false

        let wasConnectedBefore = wasConnected
        let selectedProfile = selectedProfile
        let shouldAutoApply = selectedProfile?.autoReapplyEnabled ?? false
        let autoApplySnapshot = autoApplyState
        let cachedWheelCapability = wheelCapability
        let applyGate = hardwareApplyGate
        let lifecycleGate = deviceLifecycleGate
        // Observe only — never issue() here, or reconnect would supersede a newer Apply.
        let generationAtSchedule = applyGate.currentGeneration()

        hidQueue.async { [weak self] in
            guard let self else { return }

            let request = DeviceRefreshRequest(
                wasConnectedBefore: wasConnectedBefore,
                selectedProfile: selectedProfile,
                shouldAutoApply: shouldAutoApply,
                autoApplySnapshot: autoApplySnapshot,
                cachedWheelCapability: cachedWheelCapability,
                generationAtSchedule: generationAtSchedule,
                lifecycleToken: lifecycleToken
            )
            let snapshot = DeviceRefreshCoordinator.performRefresh(
                session: self.session,
                request: request,
                applyGate: applyGate,
                lifecycleGate: lifecycleGate
            )

            Task { @MainActor in
                self.isRefreshInFlight = false
                if let snapshot,
                   !self.isSleeping,
                   lifecycleGate.isCurrentAndAwake(lifecycleToken) {
                    self.applyRefreshSnapshot(snapshot, shouldAutoApply: shouldAutoApply)
                }
                if self.deviceRefreshRequested,
                   !self.isSleeping,
                   lifecycleGate.currentAwakeToken() != nil {
                    self.refreshDeviceState()
                } else {
                    self.deviceRefreshRequested = false
                }
            }
        }
    }

    private func applyRefreshSnapshot(_ snapshot: DeviceRefreshSnapshot, shouldAutoApply: Bool) {
        if snapshot.disconnected {
            // Coordinator already applied onDisconnect into autoApplyState (authoritative).
            adoptAutoApplyState(from: snapshot, shouldAutoApply: shouldAutoApply, acceptsApplyResult: false)
            applyDisconnectedState(commandError: snapshot.commandError, adoptAutoApplyFromSnapshot: false)
        } else if let state = snapshot.state {
            let acceptsApplyResult = snapshot.applyGeneration.map(hardwareApplyGate.isCurrent) ?? false
            adoptAutoApplyState(
                from: snapshot,
                shouldAutoApply: shouldAutoApply,
                acceptsApplyResult: acceptsApplyResult
            )
            if acceptsApplyResult && snapshot.profileAppliedSuccessfully {
                hardwareVerificationWarning = nil
                if let recorded = HardwareApplyBaseline.settingsToRecord(
                    result: .verified,
                    applied: snapshot.appliedHardwareSettings
                ) {
                    lastAppliedHardwareSettings = recorded
                }
            } else if acceptsApplyResult, let applyWarning = snapshot.applyWarning {
                hardwareVerificationWarning = "Auto-apply not verified: \(applyWarning)"
            }

            wasConnected = true
            isConnected = true
            lastCommandError = nil
            batteryPercent = state.batteryPercent
            isCharging = state.isCharging
            lowBatteryLatched = MenuStatusModel.isLowBattery(
                percent: state.batteryPercent,
                wasLow: lowBatteryLatched
            )
            activeDPI = state.dpiX
            pollingRateHz = state.pollingRateHz
            let monitoringWarning: String?
            let monitoringStatus: String
            switch session.removalMonitoringStatus {
            case .active:
                monitoringWarning = nil
                monitoringStatus = "Connected"
            case .degradedNoStableIdentity:
                monitoringWarning = "Immediate device-removal detection is unavailable; using 5-second polling."
                monitoringStatus = "Connected (5-second disconnect polling)"
            case let .unavailable(reason):
                monitoringWarning = "Device-removal monitoring is unavailable; using 5-second polling. \(reason)"
                monitoringStatus = "Connected (5-second disconnect polling)"
            }
            warningMessage = [monitoringWarning, hardwareVerificationWarning]
                .compactMap { $0 }
                .joined(separator: "\n")
            if warningMessage?.isEmpty == true {
                warningMessage = nil
            }
            statusMessage = hardwareVerificationWarning == nil
                ? monitoringStatus
                : "Connected (profile not verified)"
            if snapshot.becameConnected {
                if let feedback = MenuReconnectFeedbackPolicy.feedback(
                    becameConnected: true,
                    hadPriorSuccessfulConnection: hadPriorSuccessfulConnection,
                    profileApplied: acceptsApplyResult && snapshot.profileAppliedSuccessfully
                ) {
                    publishReconnectFeedback(feedback)
                }
                hadPriorSuccessfulConnection = true
            }
            if let probeReport = snapshot.probeReport {
                wheelCapability = probeReport.capability
                wheelProbeSummary = probeReport.summary
            }
            if acceptsApplyResult && snapshot.profileAppliedSuccessfully {
                refreshProfileSummary()
            }
        }
        syncRemapper()
    }

    /// Adopts coordinator-owned auto-apply transitions when the apply generation is publishable.
    /// Does not re-run success/failure accounting in AppModel.
    private func adoptAutoApplyState(
        from snapshot: DeviceRefreshSnapshot,
        shouldAutoApply: Bool,
        acceptsApplyResult: Bool
    ) {
        if snapshot.disconnected {
            autoApplyState = snapshot.autoApplyState
            return
        }
        if snapshot.applyOutcomeCommitted {
            if acceptsApplyResult {
                autoApplyState = snapshot.autoApplyState
            } else if snapshot.becameConnected {
                // HID committed an apply outcome under a generation that is no longer
                // publishable — drop success/failure, keep only connect re-arm.
                AutoApplyCoordinator.onConnect(
                    autoReapplyEnabled: shouldAutoApply,
                    state: &autoApplyState
                )
            }
            return
        }
        // Superseded-before-write or no attempt: safe to adopt (may include onConnect only).
        autoApplyState = snapshot.autoApplyState
    }

    private func applyDisconnectedState(
        commandError: RazerCommandError?,
        adoptAutoApplyFromSnapshot: Bool = true
    ) {
        if adoptAutoApplyFromSnapshot {
            // Non-coordinator disconnect paths (sleep/removal) still reset here.
            AutoApplyCoordinator.onDisconnect(&autoApplyState)
        }
        hardwareVerificationWarning = nil
        wasConnected = false
        isConnected = false
        // Clear battery so status item never flashes a stale percentage.
        batteryPercent = 0
        isCharging = false
        lowBatteryLatched = false
        clearReconnectFeedback()
        lastCommandError = commandError
        if let error = commandError {
            statusMessage = MenuStatusModel.friendlyMessage(for: error)
        } else {
            statusMessage = "Disconnected"
        }
        // Permission/conflict keep a banner; other errors clear unrelated stale warnings.
        warningMessage = MenuStatusModel.disconnectWarningMessage(for: commandError)
    }

    private func publishReconnectFeedback(_ feedback: MenuReconnectFeedback) {
        reconnectFeedbackGeneration += 1
        let generation = reconnectFeedbackGeneration
        reconnectFeedback = feedback
        scheduleDelayedAction(5) { [weak self] in
            guard let self, self.reconnectFeedbackGeneration == generation else { return }
            self.reconnectFeedback = nil
        }
    }

    private func clearReconnectFeedback() {
        reconnectFeedbackGeneration += 1
        reconnectFeedback = nil
    }

    func applySelectedProfile(reason: HardwareApplyReason = .explicitApply) {
        _ = reason
        guard !isSleeping,
              let profile = selectedProfile,
              let lifecycleToken = deviceLifecycleGate.currentAwakeToken() else {
            return
        }
        let capability = wheelCapability
        let token = hardwareApplyGate.issue()
        let gate = hardwareApplyGate
        let lifecycleGate = deviceLifecycleGate
        let settings = HardwareProfileSettings(profile: profile)
        hidQueue.async { [weak self] in
            guard let self else { return }
            guard gate.isCurrent(token),
                  lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                return
            }
            do {
                let client = try self.session.connectForRefresh()
                // Lifecycle stale after connect must retire; apply-generation-only
                // stale keeps the session for a newer explicit apply on hidQueue.
                guard self.session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                    return
                }
                guard gate.isCurrent(token) else { return }
                let result = try self.session.applyForRefresh(
                    profile: profile,
                    to: client,
                    wheelCapability: capability,
                    isStillCurrent: {
                        gate.isCurrent(token)
                            && lifecycleGate.isCurrentAndAwake(lifecycleToken)
                    }
                )
                guard self.session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                    return
                }
                guard gate.isCurrent(token) else { return }
                guard let recorded = HardwareApplyBaseline.settingsToRecord(
                    result: result,
                    applied: settings
                ) else {
                    guard let warning = result.verificationWarning else { return }
                    Task { @MainActor in
                        guard !self.isSleeping,
                              gate.isCurrent(token),
                              lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                            return
                        }
                        // Drop stale command errors so connectedDetailLine shows verification.
                        let status = MenuStatusModel.deviceStatusAfterUnverifiedApply(
                            verificationWarning: warning
                        )
                        self.lastCommandError = status.lastCommandError
                        self.hardwareVerificationWarning = status.hardwareVerificationWarning
                        self.warningMessage = status.warningMessage
                        self.statusMessage = status.statusMessage
                        self.syncRemapper()
                    }
                    return
                }
                Task { @MainActor in
                    guard !self.isSleeping,
                          gate.isCurrent(token),
                          lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                        return
                    }
                    self.lastAppliedHardwareSettings = recorded
                    self.activeDPI = profile.activeDPI
                    self.pollingRateHz = profile.pollingRateHz
                    let cleared = MenuStatusModel.deviceStatusAfterSuccessfulApply(
                        profileName: profile.name
                    )
                    self.lastCommandError = cleared.lastCommandError
                    self.hardwareVerificationWarning = cleared.hardwareVerificationWarning
                    self.warningMessage = cleared.warningMessage
                    self.statusMessage = cleared.statusMessage
                    AutoApplyCoordinator.onApplySuccess(&self.autoApplyState)
                    self.syncRemapper()
                }
            } catch {
                guard self.session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                    return
                }
                guard gate.isCurrent(token) else { return }
                if HardwareApplyFailurePolicy.shouldInvalidate(error: error) {
                    self.session.disconnect()
                }
                Task { @MainActor in
                    guard !self.isSleeping,
                          gate.isCurrent(token),
                          lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                        return
                    }
                    if let commandError = error as? RazerCommandError {
                        self.lastCommandError = commandError
                        let friendly = MenuStatusModel.friendlyMessage(for: commandError)
                        self.statusMessage = friendly
                        // New failure supersedes a stale verification banner.
                        self.hardwareVerificationWarning = nil
                        if commandError.isPermissionIssue || commandError.isConflictIssue {
                            self.warningMessage = friendly
                        } else {
                            self.warningMessage = nil
                        }
                    } else if let applyError = error as? HardwareApplyError {
                        self.lastCommandError = nil
                        self.statusMessage = "Profile apply failed"
                        // Keep technical detail in Settings only; menu uses statusMessage.
                        self.hardwareVerificationWarning = applyError.localizedDescription
                        self.warningMessage = applyError.localizedDescription
                    } else {
                        let status = MenuStatusModel.deviceStatusAfterGenericApplyFailure()
                        self.lastCommandError = status.lastCommandError
                        self.hardwareVerificationWarning = status.hardwareVerificationWarning
                        self.warningMessage = status.warningMessage
                        self.statusMessage = status.statusMessage
                    }
                    self.syncRemapper()
                }
            }
        }
    }

    func selectProfile(_ profile: MouseProfile) {
        if let currentID = selectedProfile?.id, let draft = profileDraft {
            draftsByProfileID[currentID] = draft
        }
        bundle.selectedProfileID = profile.id
        reloadDraftFromSelectedProfile()
        // Required flush fails while the newly selected (or previous retained) draft is invalid.
        _ = flushPendingSave()
        refreshProfileSummary()
        applySelectedProfile(reason: .profileSelection)
        syncRemapper()
    }

    func updateProfile(_ profile: MouseProfile) {
        guard let index = bundle.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let existingInvalidDraft = draftsByProfileID[profile.id].map { !$0.isValid } ?? false
        bundle.profiles[index] = profile
        if existingInvalidDraft {
            // Keep the invalid DPI draft; button/wheel edits must not discard it.
            if selectedProfile?.id == profile.id {
                profileDraft = draftsByProfileID[profile.id]
            }
        } else {
            let draft = ProfileDraft(profile: profile)
            draftsByProfileID[profile.id] = draft
            if selectedProfile?.id == profile.id {
                profileDraft = draft
            }
        }
        persistenceStatus = .dirty
        scheduleSaveBundle()
        refreshProfileSummary()
        refreshMappingWarning()
        if bundle.selectedProfileID == profile.id {
            syncRemapper()
        }
    }

    /// Updates the editable draft. Canonical profile hardware fields change only while the draft is valid.
    func updateDraft(_ draft: ProfileDraft) {
        guard let profileID = selectedProfile?.id else { return }
        profileDraft = draft
        draftsByProfileID[profileID] = draft
        persistenceStatus = .dirty
        guard draft.isValid,
              var profile = selectedProfile,
              let committed = try? draft.applying(to: profile) else {
            return
        }
        profile = committed
        guard let index = bundle.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        bundle.profiles[index] = profile
        scheduleSaveBundle()
        refreshProfileSummary()
        refreshMappingWarning()
        if bundle.selectedProfileID == profile.id {
            syncRemapper()
        }
    }

    func addProfile() {
        if let currentID = selectedProfile?.id, let draft = profileDraft {
            draftsByProfileID[currentID] = draft
        }
        let profile = MouseProfile(
            name: "Profile \(bundle.profiles.count + 1)",
            dpiStages: [800, 1600],
            activeStage: 1,
            pollingRateHz: 1000,
            autoReapplyEnabled: true
        )
        bundle.profiles.append(profile)
        bundle.selectedProfileID = profile.id
        let draft = ProfileDraft(profile: profile)
        draftsByProfileID[profile.id] = draft
        profileDraft = draft
        _ = flushPendingSave()
        refreshProfileSummary()
        syncRemapper()
    }

    func deleteSelectedProfile() {
        guard bundle.profiles.count > 1, let selected = selectedProfile else { return }
        draftsByProfileID.removeValue(forKey: selected.id)
        bundle.profiles.removeAll { $0.id == selected.id }
        bundle.selectedProfileID = bundle.profiles.first?.id
        reloadDraftFromSelectedProfile()
        _ = flushPendingSave()
        refreshProfileSummary()
        syncRemapper()
    }

    func resetSelectedProfileControls() {
        guard var profile = selectedProfile else { return }
        profile.resetControlsToDefaults()
        updateProfile(profile)
        statusMessage = "Reset controls to defaults"
    }

    func setRemapperPaused(_ paused: Bool) {
        if paused {
            remapperPaused = true
            remapper.pause()
            return
        }
        // Keep UI paused when resume is blocked (e.g. open circuit breaker).
        let resumeSucceeded = remapper.resume()
        remapperPaused = RemapperPausePolicy.uiPaused(afterResumeSucceeded: resumeSucceeded)
        if resumeSucceeded {
            remapperRecovering = false
        }
    }

    func toggleRemapperPause() {
        setRemapperPaused(!remapperPaused)
    }

    func performRemapperRecoveryAction(_ action: RemapperRecoveryAction) {
        switch action {
        case .openInputMonitoring:
            openInputMonitoringSettings()
        case .openAccessibility:
            openAccessibilitySettings()
        case .openPrivacySettings:
            // One Privacy & Security pane — opening both deep links races and stacks two windows.
            openPrivacyAndSecuritySettings()
        case .armRemapper, .rearmRemapper:
            armRemapperForSession()
        case .resume:
            setRemapperPaused(false)
        case .acknowledgeRecovery:
            remapperRecovering = false
        case .retryStart:
            remapperStartError = nil
            warningMessage = nil
            syncRemapper()
        }
    }

    /// Rejects enabling software remapping when required permissions are missing.
    /// Enabling requires an explicit confirmation that arms this process only.
    @discardableResult
    func setRemapperEnabled(_ enabled: Bool, on draft: ProfileDraft) -> Bool {
        if enabled {
            if !permissions.remapperReady {
                warningMessage = "Grant Input Monitoring and Accessibility before enabling the software remapper. \(permissions.summary)"
                return false
            }
            pendingRemapperEnableDraft = draft
            confirmArmRemapper = true
            return false
        }
        remapperArmed = false
        var updated = draft
        updated.remapperEnabled = false
        updateDraft(updated)
        return true
    }

    /// Arms the remapper for this process after explicit consent.
    func armRemapperForSession() {
        if !permissions.remapperReady {
            warningMessage = "Grant Input Monitoring and Accessibility before arming the software remapper. \(permissions.summary)"
            return
        }
        if let draft = pendingRemapperEnableDraft {
            var updated = draft
            updated.remapperEnabled = true
            updateDraft(updated)
            pendingRemapperEnableDraft = nil
        }
        remapper.resetTapDisableCircuit()
        remapperCircuitOpen = false
        remapperArmed = true
        remapperPaused = false
        confirmArmRemapper = false
        syncRemapper()
    }

    func cancelArmRemapperConfirmation() {
        pendingRemapperEnableDraft = nil
        confirmArmRemapper = false
    }

    func setDiagnosticsCaptureEnabled(_ enabled: Bool) {
        diagnosticsCaptureEnabled = enabled
        if enabled {
            remapDiagnosticSink.clear()
            captureEntries = []
            do {
                try captureSession.start()
                remapDiagnosticSink.update(enabled: true, session: captureSession)
            } catch {
                diagnosticsCaptureEnabled = false
                remapDiagnosticSink.disableAndClear()
                warningMessage = error.localizedDescription
            }
        } else {
            remapDiagnosticSink.disableAndClear()
            captureSession.stop()
            captureEntries = []
        }
    }

    func clearDiagnosticsCapture() {
        remapDiagnosticSink.clear()
        captureEntries = []
    }

    func probeWheelHardware() {
        guard !isSleeping,
              let lifecycleToken = deviceLifecycleGate.currentAwakeToken() else {
            return
        }
        let lifecycleGate = deviceLifecycleGate
        hidQueue.async { [weak self] in
            guard let self else { return }
            guard lifecycleGate.isCurrentAndAwake(lifecycleToken) else { return }
            do {
                let client = try self.session.connectForRefresh()
                guard self.session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                    return
                }
                let probeReport = client.probeWheelCapability()
                let summary = client.wheelProbeSummary(for: probeReport)
                Task { @MainActor in
                    guard !self.isSleeping,
                          lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                        return
                    }
                    self.wheelCapability = probeReport.capability
                    self.wheelProbeSummary = summary
                }
            } catch {
                Task { @MainActor in
                    guard !self.isSleeping,
                          lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                        return
                    }
                    self.wheelProbeSummary = error.localizedDescription
                }
            }
        }
    }

    private func configureCaptureSession() {
        remapDiagnosticSink.update(enabled: false, session: captureSession)
        captureSession.onEntriesChanged = { [weak self] entries in
            Task { @MainActor in
                self?.captureEntries = entries
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginManager.isEnabled
        } catch {
            warningMessage = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    func openInputMonitoringSettings() {
        openPrivacySettings("Privacy_ListenEvent")
    }

    func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    func openPrivacyAndSecuritySettings() {
        openPrivacySettings("Privacy")
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func configureRemapperCallbacks() {
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { [weak self] in
            Task { @MainActor in self?.advanceDPIStage(by: 1) }
        }
        callbacks.onPreviousDPIStage = { [weak self] in
            Task { @MainActor in self?.advanceDPIStage(by: -1) }
        }
        callbacks.onNextProfile = { [weak self] in
            Task { @MainActor in self?.advanceProfile(by: 1) }
        }
        callbacks.onPreviousProfile = { [weak self] in
            Task { @MainActor in self?.advanceProfile(by: -1) }
        }
        callbacks.onEmergencyPause = { [weak self] in
            Task { @MainActor in
                self?.setRemapperPaused(true)
                self?.statusMessage = "Remapper paused (⌃⌥⌘R)"
            }
        }
        callbacks.onHeldOutputsReleased = { [weak self] reason in
            Task { @MainActor in
                switch reason {
                case .pause:
                    break
                case .stop:
                    break
                case .tapDisable:
                    self?.remapperRecovering = true
                    self?.statusMessage = "Remapper recovered after tap disable; held buttons released"
                case .tapDisableCircuitOpen:
                    self?.remapperArmed = false
                    self?.remapperPaused = true
                    self?.remapperRunning = false
                    self?.remapperRecovering = false
                    self?.remapperCircuitOpen = true
                    self?.warningMessage = "Remapper paused after repeated event-tap timeouts."
                    self?.statusMessage = "Remapper paused after repeated event-tap timeouts."
                case .profileReplacement:
                    break
                case .permissionLoss:
                    self?.statusMessage = "Remapper stopped; held buttons released (permissions lost)"
                    self?.remapperRunning = false
                    self?.remapperRecovering = false
                }
            }
        }
        callbacks.onInputDiagnostic = { [remapDiagnosticSink] control, disposition, detail in
            // Hot path: record directly on the capture session. Do not spawn a Task per event.
            remapDiagnosticSink.record(control: control, disposition: disposition, detail: detail)
        }
        remapper.setCallbacks(callbacks)
    }

    private func advanceDPIStage(by delta: Int) {
        guard var profile = selectedProfile else { return }
        let next = min(max(profile.activeStage + delta, 1), profile.dpiStages.count)
        guard next != profile.activeStage else { return }
        profile.activeStage = next
        updateProfile(profile)
        applySelectedProfile(reason: .dpiCycle)
    }

    private func advanceProfile(by delta: Int) {
        guard !bundle.profiles.isEmpty, let current = selectedProfile,
              let index = bundle.profiles.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIndex = (index + delta + bundle.profiles.count) % bundle.profiles.count
        selectProfile(bundle.profiles[nextIndex])
    }

    private func syncRemapper() {
        guard let profile = selectedProfile, profile.remapperEnabled, remapperArmed else {
            remapper.stop()
            remapperRunning = false
            remapperRecovering = false
            remapperStartError = nil
            return
        }
        guard permissions.remapperReady else {
            // Fail closed: losing permissions also clears session consent.
            remapperArmed = false
            remapper.handlePermissionLoss()
            remapperRunning = false
            remapperRecovering = false
            remapperStartError = nil
            remapperCircuitOpen = remapper.isCircuitOpen
            return
        }

        remapper.updateProfile(profile)
        if remapperPaused {
            remapper.pause()
        } else {
            let resumeSucceeded = remapper.resume()
            remapperPaused = RemapperPausePolicy.uiPaused(afterResumeSucceeded: resumeSucceeded)
        }

        if remapper.isRunning {
            remapperRunning = true
            remapperStartError = nil
            return
        }

        do {
            try remapper.start()
            remapperRunning = true
            remapperStartError = nil
        } catch {
            remapperRunning = false
            remapperStartError = error.localizedDescription
            warningMessage = error.localizedDescription
        }
    }

    @discardableResult
    func flushPendingSave() -> Bool {
        flushSaveBundle()
    }

    func discardUnsavedChangesAndMarkClean() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if let profile = selectedProfile {
            let draft = ProfileDraft(profile: profile)
            draftsByProfileID[profile.id] = draft
            profileDraft = draft
        } else {
            profileDraft = nil
        }
        persistenceStatus = .clean
        pendingQuitAfterSaveFailure = false
    }

    private func scheduleSaveBundle() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            _ = self?.flushSaveBundle()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    @discardableResult
    private func flushSaveBundle() -> Bool {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        if let profileID = selectedProfile?.id, let draft = profileDraft {
            draftsByProfileID[profileID] = draft
        }

        if let reason = ProfileDraft.requiredFlushBlockReason(drafts: Array(draftsByProfileID.values)) {
            persistenceStatus = .failed(reason)
            return false
        }

        if let draft = profileDraft, draft.isValid, var profile = selectedProfile {
            if let committed = try? draft.applying(to: profile) {
                profile = committed
                if let index = bundle.profiles.firstIndex(where: { $0.id == profile.id }) {
                    bundle.profiles[index] = profile
                }
                draftsByProfileID[profile.id] = draft
            }
        }

        do {
            try profileStore.save(bundle)
            persistenceStatus = .clean
            return true
        } catch {
            persistenceStatus = .failed(error.localizedDescription)
            return false
        }
    }

    private func refreshProfileSummary() {
        profileName = selectedProfile?.name ?? "No profile"
        if let profile = selectedProfile {
            activeDPI = profile.activeDPI
            pollingRateHz = profile.pollingRateHz
        }
    }

    private func refreshMappingWarning() {
        guard let profile = selectedProfile else {
            mappingWarning = nil
            return
        }
        mappingWarning = ProfileMappingValidator.warnings(for: profile).first?.message
    }
}

import AppKit
