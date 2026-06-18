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
    @Published var mappingWarning: String?
    @Published var bundle: ProfileBundle
    @Published var launchAtLogin = false
    @Published var showSettings = false
    @Published var remapperPaused = false
    @Published var remapperRunning = false
    @Published var wheelCapability = WheelHardwareCapability()
    @Published var permissions = PermissionStatus.current()
    @Published var captureSession = InputCaptureSession()
    @Published var diagnosticsCaptureEnabled = false
    @Published var wheelProbeSummary = "Not probed yet"
    @Published var shortcutCaptureControl: PhysicalControl?

    private let session = DeviceSession()
    private let profileStore = ProfileStore()
    private let remapper = InputRemapper()
    private var monitorTimer: Timer?
    private var wasConnected = false

    init() {
        bundle = profileStore.load()
        if bundle.profiles.isEmpty {
            bundle = profileStore.defaultBundle()
            try? profileStore.save(bundle)
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = LaunchAtLoginManager.isEnabled
        }
        configureRemapperCallbacks()
        refreshProfileSummary()
        refreshMappingWarning()
        startMonitoring()
        syncRemapper()
    }

    deinit {
        monitorTimer?.invalidate()
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
        do {
            let client = try session.connect()
            let state = try client.readState()
            let becameConnected = !wasConnected
            wasConnected = true
            isConnected = true
            batteryPercent = state.batteryPercent
            isCharging = state.isCharging
            activeDPI = state.dpiX
            pollingRateHz = state.pollingRateHz
            warningMessage = nil
            statusMessage = "Connected"
            wheelCapability = WheelCapabilityProbe.probe(client: client)

            if becameConnected,
               let profile = selectedProfile,
               profile.autoReapplyEnabled {
                try session.apply(profile: profile, to: client, wheelCapability: wheelCapability)
                refreshProfileSummary()
            }
        } catch let error as RazerCommandError {
            wasConnected = false
            isConnected = false
            statusMessage = error.localizedDescription
            if error.isPermissionIssue || error.isConflictIssue {
                warningMessage = error.localizedDescription
            }
        } catch {
            wasConnected = false
            isConnected = false
            statusMessage = "Disconnected"
        }
        syncRemapper()
    }

    func applySelectedProfile() {
        guard let profile = selectedProfile else { return }
        do {
            let client = try session.connect()
            try session.apply(profile: profile, to: client, wheelCapability: wheelCapability)
            activeDPI = profile.activeDPI
            pollingRateHz = profile.pollingRateHz
            statusMessage = "Applied profile \(profile.name)"
            warningMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            if let commandError = error as? RazerCommandError,
               commandError.isPermissionIssue || commandError.isConflictIssue {
                warningMessage = commandError.localizedDescription
            }
        }
        syncRemapper()
    }

    func selectProfile(_ profile: MouseProfile) {
        bundle.selectedProfileID = profile.id
        saveBundle()
        refreshProfileSummary()
        applySelectedProfile()
        syncRemapper()
    }

    func updateProfile(_ profile: MouseProfile) {
        guard let index = bundle.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        bundle.profiles[index] = profile
        saveBundle()
        refreshProfileSummary()
        refreshMappingWarning()
        if bundle.selectedProfileID == profile.id {
            applySelectedProfile()
            syncRemapper()
        }
    }

    func addProfile() {
        let profile = MouseProfile(
            name: "Profile \(bundle.profiles.count + 1)",
            dpiStages: [800, 1600],
            activeStage: 1,
            pollingRateHz: 1000,
            autoReapplyEnabled: true
        )
        bundle.profiles.append(profile)
        bundle.selectedProfileID = profile.id
        saveBundle()
        refreshProfileSummary()
        syncRemapper()
    }

    func deleteSelectedProfile() {
        guard bundle.profiles.count > 1, let selected = selectedProfile else { return }
        bundle.profiles.removeAll { $0.id == selected.id }
        bundle.selectedProfileID = bundle.profiles.first?.id
        saveBundle()
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
            do {
                try captureSession.start()
            } catch {
                diagnosticsCaptureEnabled = false
                warningMessage = error.localizedDescription
            }
        } else {
            captureSession.stop()
        }
    }

    func probeWheelHardware() {
        do {
            let client = try session.connect()
            wheelCapability = WheelCapabilityProbe.probe(client: client)
            let state = try client.readWheelHardwareState()
            wheelProbeSummary = """
            scroll mode: \(wheelCapability.scrollMode.displayName) \(state.scrollMode?.displayName ?? "")
            acceleration: \(wheelCapability.acceleration.displayName) \(state.accelerationEnabled.map { $0 ? "on" : "off" } ?? "")
            smart reel: \(wheelCapability.smartReel.displayName) \(state.smartReelEnabled.map { $0 ? "on" : "off" } ?? "")
            """
        } catch {
            wheelProbeSummary = error.localizedDescription
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

    private func saveBundle() {
        do {
            try profileStore.save(bundle)
        } catch {
            warningMessage = error.localizedDescription
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
