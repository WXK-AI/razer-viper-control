import SwiftUI
import RazerCore

@main
struct RazerMenuBarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, openSettings: {
                openWindow(id: "settings")
                // LSUIElement apps don't auto-activate, so the Settings window
                // would otherwise open behind other apps. Bring it to front.
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                    }
                }
            })
        } label: {
            StatusItemLabel(status: model.menuStatus)
        }

        Window("Razer Viper V3 HyperSpeed", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 560, height: 680)
        .windowResizability(.contentSize)
    }
}

/// Thin status-item label driven entirely by `MenuStatusPresentation`.
private struct StatusItemLabel: View {
    let status: MenuStatusPresentation

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.isConnected ? "computermouse.fill" : "computermouse")
            if let batteryText = status.statusItemBatteryText {
                if status.statusItemShowsCharging {
                    Image(systemName: "bolt.fill")
                        .imageScale(.small)
                }
                Text(batteryText)
                    .foregroundStyle(status.statusItemIsLowBattery ? .orange : .primary)
            }
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @State private var showSaveFailureAlert = false

    private var status: MenuStatusPresentation {
        model.menuStatus
    }

    var body: some View {
        Text(DeviceDescriptor.productName)
            .font(.headline)

        if status.isConnected {
            if let batteryLine = status.batteryMenuLine {
                Text(batteryLine)
            }
            Text("Profile: \(model.profileName)")
            Text("DPI: \(model.activeDPI) • Polling: \(model.pollingRateHz.map { "\($0) Hz" } ?? "Unknown")")
            // Non-default connection status (verify/degraded/apply/command errors).
            if let detail = status.connectedDetailLine {
                Text(detail)
            }
        } else {
            Text(status.connectionLine)
        }

        if let transient = status.transientLine {
            Text(transient)
                .foregroundStyle(.secondary)
        }

        ForEach(Array(status.warningLines.enumerated()), id: \.offset) { _, warning in
            Text(warning)
                .foregroundStyle(.orange)
        }

        if let remapperTitle = status.remapperTitle {
            Text(remapperTitle)
            if let detail = status.remapperDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        if status.showPauseResume {
            Button(model.remapperPaused ? "Resume Remapper" : "Pause Remapper") {
                model.toggleRemapperPause()
            }
            .disabled(!model.remapperRunning)
        }
        if let action = status.recoveryAction,
           let title = status.recoveryButtonTitle {
            Button(title) {
                model.performRemapperRecoveryAction(action)
            }
        }
        Button("Reset Controls to Default") {
            model.resetSelectedProfileControls()
        }

        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Apply Profile") {
            model.applySelectedProfile()
        }
        .disabled(!(model.profileDraft?.isValid ?? true))

        Button("Refresh") {
            model.refreshDeviceState()
        }

        Divider()

        Button("Quit") {
            if model.flushPendingSave() {
                NSApplication.shared.terminate(nil)
            } else {
                showSaveFailureAlert = true
            }
        }
        .keyboardShortcut("q")
        .alert("Could not save profiles", isPresented: $showSaveFailureAlert) {
            Button("Retry") {
                if model.flushPendingSave() {
                    NSApplication.shared.terminate(nil)
                }
            }
            Button("Discard And Quit", role: .destructive) {
                model.discardUnsavedChangesAndMarkClean()
                NSApplication.shared.terminate(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case let .failed(message) = model.persistenceStatus {
                Text(message)
            } else {
                Text("Unsaved profile changes could not be written.")
            }
        }
    }
}

import AppKit
