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
    @Published var bundle: ProfileBundle
    @Published var launchAtLogin = false
    @Published var showSettings = false

    private let session = DeviceSession()
    private let profileStore = ProfileStore()
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
        refreshProfileSummary()
        startMonitoring()
    }

    deinit {
        monitorTimer?.invalidate()
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
    }

    func refreshDeviceState() {
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

            if becameConnected,
               let profile = selectedProfile,
               profile.autoReapplyEnabled {
                try session.apply(profile: profile, to: client)
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
    }

    func applySelectedProfile() {
        guard let profile = selectedProfile else { return }
        do {
            let client = try session.connect()
            try session.apply(profile: profile, to: client)
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
    }

    func selectProfile(_ profile: MouseProfile) {
        bundle.selectedProfileID = profile.id
        saveBundle()
        refreshProfileSummary()
        applySelectedProfile()
    }

    func updateProfile(_ profile: MouseProfile) {
        guard let index = bundle.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        bundle.profiles[index] = profile
        saveBundle()
        refreshProfileSummary()
        if bundle.selectedProfileID == profile.id {
            applySelectedProfile()
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
    }

    func deleteSelectedProfile() {
        guard bundle.profiles.count > 1, let selected = selectedProfile else { return }
        bundle.profiles.removeAll { $0.id == selected.id }
        bundle.selectedProfileID = bundle.profiles.first?.id
        saveBundle()
        refreshProfileSummary()
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
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
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
}

import AppKit
