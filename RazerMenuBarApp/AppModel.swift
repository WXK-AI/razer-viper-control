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
    @Published var pollingRateHz = 1000
    @Published var statusMessage = "Waiting for mouse…"
    @Published var warningMessage: String?
    @Published var persistenceWarning: String?
    @Published var quarantinedProfileURL: URL?
    @Published var persistenceStatus: PersistenceStatus = .clean
    @Published var profileDraft: ProfileDraft?
    @Published var mappingWarning: String?
    @Published var pendingQuitAfterSaveFailure = false
    @Published var bundle: ProfileBundle
    @Published var launchAtLogin = false
    @Published var showSettings = false
    @Published var remapperPaused = false
    @Published var remapperRunning = false
    @Published var wheelCapability = WheelHardwareCapability()
    @Published var permissions = PermissionStatus.current()
    @Published var captureSession = InputCaptureSession()
    @Published var captureEntries: [InputCaptureSession.Entry] = []
    @Published var diagnosticsCaptureEnabled = false
    @Published var wheelProbeSummary = "Not probed yet"
    @Published var shortcutCaptureControl: PhysicalControl?

    private let session = DeviceSession()
    private let profileStore = ProfileStore()
    private let remapper = InputRemapper()
    private let hidQueue = DispatchQueue(label: "com.razermenubar.hid", qos: .utility)
    private var monitorTimer: Timer?
    private var wasConnected = false
    private var isRefreshInFlight = false
    private var autoApplyState = AutoApplyCoordinator.State()
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.4

    private var draftsByProfileID: [UUID: ProfileDraft] = [:]

    private struct DeviceRefreshSnapshot {
        let state: DeviceState?
        let probeReport: WheelCapabilityProbe.ProbeReport?
        let becameConnected: Bool
        let commandError: RazerCommandError?
        let disconnected: Bool
        let applyWarning: String?
        let profileAppliedSuccessfully: Bool
    }

    init() {
        switch profileStore.loadOutcome() {
        case let .loaded(loaded):
            bundle = loaded
        case let .firstRun(defaults):
            bundle = defaults
            try? profileStore.save(bundle)
        case let .recovered(defaults, quarantinedURL, reason):
            bundle = defaults
            quarantinedProfileURL = quarantinedURL
            persistenceWarning = "Saved profiles were unreadable and were reset to defaults. \(reason)"
            try? profileStore.save(bundle)
        case let .corruptPreserved(defaults, sourceURL, reason):
            bundle = defaults
            quarantinedProfileURL = sourceURL
            persistenceWarning = "Saved profiles are corrupt and could not be quarantined. Defaults are in use in-memory only; the original file was left untouched. \(reason)"
            // Do not save — writing would overwrite the only remaining corrupt source.
        }
        if bundle.profiles.isEmpty {
            bundle = profileStore.defaultBundle()
            try? profileStore.save(bundle)
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = LaunchAtLoginManager.isEnabled
        }
        configureRemapperCallbacks()
        configureCaptureSession()
        refreshProfileSummary()
        refreshMappingWarning()
        reloadDraftFromSelectedProfile()
        startMonitoring()
        syncRemapper()
    }

    func dismissPersistenceWarning() {
        persistenceWarning = nil
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

    func refreshPermissions() {
        permissions = PermissionStatus.current()
    }

    func refreshDeviceState() {
        refreshPermissions()
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true

        let wasConnectedBefore = wasConnected
        let selectedProfile = selectedProfile
        let shouldAutoApply = selectedProfile?.autoReapplyEnabled ?? false
        let autoApplySnapshot = autoApplyState

        hidQueue.async { [weak self] in
            guard let self else { return }

            let snapshot = self.performDeviceRefresh(
                wasConnectedBefore: wasConnectedBefore,
                selectedProfile: selectedProfile,
                shouldAutoApply: shouldAutoApply,
                autoApplySnapshot: autoApplySnapshot
            )

            Task { @MainActor in
                self.isRefreshInFlight = false
                self.applyRefreshSnapshot(snapshot, shouldAutoApply: shouldAutoApply)
            }
        }
    }

    /// Runs on `hidQueue`. On recoverable HID failures, clears the cached session
    /// and retries once with a fresh device open (sleep/wake / stale handle).
    private nonisolated func performDeviceRefresh(
        wasConnectedBefore: Bool,
        selectedProfile: MouseProfile?,
        shouldAutoApply: Bool,
        autoApplySnapshot: AutoApplyCoordinator.State
    ) -> DeviceRefreshSnapshot {
        do {
            return try readRefreshSnapshot(
                wasConnectedBefore: wasConnectedBefore,
                selectedProfile: selectedProfile,
                shouldAutoApply: shouldAutoApply,
                autoApplySnapshot: autoApplySnapshot,
                forceReconnect: false
            )
        } catch let error as RazerCommandError {
            if error.shouldInvalidateSession {
                session.disconnect()
                do {
                    return try readRefreshSnapshot(
                        wasConnectedBefore: wasConnectedBefore,
                        selectedProfile: selectedProfile,
                        shouldAutoApply: shouldAutoApply,
                        autoApplySnapshot: autoApplySnapshot,
                        forceReconnect: true
                    )
                } catch let retryError as RazerCommandError {
                    session.disconnect()
                    return DeviceRefreshSnapshot(
                        state: nil,
                        probeReport: nil,
                        becameConnected: false,
                        commandError: retryError,
                        disconnected: true,
                        applyWarning: nil,
                        profileAppliedSuccessfully: false
                    )
                } catch {
                    session.disconnect()
                    return DeviceRefreshSnapshot(
                        state: nil,
                        probeReport: nil,
                        becameConnected: false,
                        commandError: nil,
                        disconnected: true,
                        applyWarning: nil,
                        profileAppliedSuccessfully: false
                    )
                }
            }

            return DeviceRefreshSnapshot(
                state: nil,
                probeReport: nil,
                becameConnected: false,
                commandError: error,
                disconnected: true,
                applyWarning: nil,
                profileAppliedSuccessfully: false
            )
        } catch {
            session.disconnect()
            return DeviceRefreshSnapshot(
                state: nil,
                probeReport: nil,
                becameConnected: false,
                commandError: nil,
                disconnected: true,
                applyWarning: nil,
                profileAppliedSuccessfully: false
            )
        }
    }

    private nonisolated func readRefreshSnapshot(
        wasConnectedBefore: Bool,
        selectedProfile: MouseProfile?,
        shouldAutoApply: Bool,
        autoApplySnapshot: AutoApplyCoordinator.State,
        forceReconnect: Bool
    ) throws -> DeviceRefreshSnapshot {
        let client = forceReconnect ? try session.reconnect() : try session.connect()
        let state = try client.readState()
        let becameConnected = !wasConnectedBefore || forceReconnect
        let probeReport = becameConnected ? WheelCapabilityProbe.probe(client: client) : nil

        var applyState = autoApplySnapshot
        if becameConnected && shouldAutoApply {
            AutoApplyCoordinator.onConnect(autoReapplyEnabled: true, state: &applyState)
        }

        var applyWarning: String?
        var profileAppliedSuccessfully = false
        if AutoApplyCoordinator.shouldAttemptApply(
            state: applyState,
            autoReapplyEnabled: shouldAutoApply,
            hasProfile: selectedProfile != nil
        ),
           let profile = selectedProfile {
            do {
                try session.apply(
                    profile: profile,
                    to: client,
                    wheelCapability: probeReport?.capability ?? .init()
                )
                profileAppliedSuccessfully = true
            } catch {
                applyWarning = error.localizedDescription
            }
        }

        return DeviceRefreshSnapshot(
            state: state,
            probeReport: probeReport,
            becameConnected: becameConnected,
            commandError: nil,
            disconnected: false,
            applyWarning: applyWarning,
            profileAppliedSuccessfully: profileAppliedSuccessfully
        )
    }

    private func applyRefreshSnapshot(_ snapshot: DeviceRefreshSnapshot, shouldAutoApply: Bool) {
        if snapshot.disconnected {
            AutoApplyCoordinator.onDisconnect(&autoApplyState)
            wasConnected = false
            isConnected = false
            if let error = snapshot.commandError {
                statusMessage = error.localizedDescription
                if error.isPermissionIssue || error.isConflictIssue {
                    warningMessage = error.localizedDescription
                }
            } else {
                statusMessage = "Disconnected"
            }
        } else if let state = snapshot.state {
            if snapshot.becameConnected {
                AutoApplyCoordinator.onConnect(autoReapplyEnabled: shouldAutoApply, state: &autoApplyState)
            }
            if snapshot.profileAppliedSuccessfully {
                AutoApplyCoordinator.onApplySuccess(&autoApplyState)
            } else if snapshot.applyWarning != nil {
                AutoApplyCoordinator.onApplyFailure(&autoApplyState)
            }

            wasConnected = true
            isConnected = true
            batteryPercent = state.batteryPercent
            isCharging = state.isCharging
            activeDPI = state.dpiX
            pollingRateHz = state.pollingRateHz
            warningMessage = nil
            statusMessage = "Connected"
            if let applyWarning = snapshot.applyWarning {
                warningMessage = "Auto-apply failed: \(applyWarning)"
                statusMessage = "Connected (profile not applied)"
            }
            if let probeReport = snapshot.probeReport {
                wheelCapability = probeReport.capability
                wheelProbeSummary = probeReport.summary
            }
            if snapshot.profileAppliedSuccessfully {
                refreshProfileSummary()
            }
        }
        syncRemapper()
    }

    func applySelectedProfile() {
        guard let profile = selectedProfile else { return }
        let capability = wheelCapability
        hidQueue.async { [weak self] in
            guard let self else { return }
            do {
                let client = try self.session.connect()
                try self.session.apply(profile: profile, to: client, wheelCapability: capability)
                Task { @MainActor in
                    self.activeDPI = profile.activeDPI
                    self.pollingRateHz = profile.pollingRateHz
                    self.statusMessage = "Applied profile \(profile.name)"
                    self.warningMessage = nil
                    AutoApplyCoordinator.onApplySuccess(&self.autoApplyState)
                    self.syncRemapper()
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = error.localizedDescription
                    if let commandError = error as? RazerCommandError,
                       commandError.isPermissionIssue || commandError.isConflictIssue {
                        self.warningMessage = commandError.localizedDescription
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
        applySelectedProfile()
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
            applySelectedProfile()
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
            applySelectedProfile()
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
        remapperPaused = paused
        if paused {
            remapper.pause()
        } else {
            remapper.resume()
        }
    }

    func toggleRemapperPause() {
        setRemapperPaused(!remapperPaused)
    }

    func setDiagnosticsCaptureEnabled(_ enabled: Bool) {
        diagnosticsCaptureEnabled = enabled
        if enabled {
            captureSession.clear()
            captureEntries = []
            do {
                try captureSession.start()
            } catch {
                diagnosticsCaptureEnabled = false
                warningMessage = error.localizedDescription
            }
        } else {
            captureSession.stop()
            captureEntries = captureSession.snapshotEntries()
        }
    }

    func probeWheelHardware() {
        hidQueue.async { [weak self] in
            guard let self else { return }
            do {
                let client = try self.session.connect()
                let probeReport = WheelCapabilityProbe.probe(client: client)
                let readback = client.readWheelHardwareState(capability: probeReport.capability)
                let summary = WheelCapabilityProbe.summary(probeReport: probeReport, readback: readback)
                Task { @MainActor in
                    self.wheelCapability = probeReport.capability
                    self.wheelProbeSummary = summary
                }
            } catch {
                Task { @MainActor in
                    self.wheelProbeSummary = error.localizedDescription
                }
            }
        }
    }

    private func configureCaptureSession() {
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

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func configureRemapperCallbacks() {
        remapper.callbacks.onNextDPIStage = { [weak self] in
            Task { @MainActor in self?.advanceDPIStage(by: 1) }
        }
        remapper.callbacks.onPreviousDPIStage = { [weak self] in
            Task { @MainActor in self?.advanceDPIStage(by: -1) }
        }
        remapper.callbacks.onNextProfile = { [weak self] in
            Task { @MainActor in self?.advanceProfile(by: 1) }
        }
        remapper.callbacks.onPreviousProfile = { [weak self] in
            Task { @MainActor in self?.advanceProfile(by: -1) }
        }
        remapper.callbacks.onEmergencyPause = { [weak self] in
            Task { @MainActor in
                self?.setRemapperPaused(true)
                self?.statusMessage = "Remapper paused (⌃⌥⌘R)"
            }
        }
    }

    private func advanceDPIStage(by delta: Int) {
        guard var profile = selectedProfile else { return }
        let next = min(max(profile.activeStage + delta, 1), profile.dpiStages.count)
        guard next != profile.activeStage else { return }
        profile.activeStage = next
        updateProfile(profile)
    }

    private func advanceProfile(by delta: Int) {
        guard !bundle.profiles.isEmpty, let current = selectedProfile,
              let index = bundle.profiles.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIndex = (index + delta + bundle.profiles.count) % bundle.profiles.count
        selectProfile(bundle.profiles[nextIndex])
    }

    private func syncRemapper() {
        guard let profile = selectedProfile, profile.remapperEnabled, permissions.remapperReady else {
            remapper.stop()
            remapperRunning = false
            return
        }

        remapper.updateProfile(profile)
        if remapperPaused {
            remapper.pause()
        } else {
            remapper.resume()
        }

        if remapper.isRunning {
            remapperRunning = true
            return
        }

        do {
            try remapper.start()
            remapperRunning = true
        } catch {
            remapperRunning = false
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
