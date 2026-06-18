import SwiftUI
import RazerCore

@main
struct RazerMenuBarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, openSettings: { openWindow(id: "settings") })
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isConnected ? "computermouse.fill" : "computermouse")
                if model.isConnected {
                    Text("\(model.batteryPercent)%")
                }
            }
        }

        Window("Razer Viper V3 HyperSpeed", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentSize)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Text(DeviceDescriptor.productName)
            .font(.headline)

        if model.isConnected {
            Text("Battery: \(model.batteryPercent)%\(model.isCharging ? " (charging)" : "")")
            Text("Profile: \(model.profileName)")
            Text("DPI: \(model.activeDPI) • \(model.pollingRateHz) Hz")
        } else {
            Text(model.statusMessage)
        }

        Divider()

        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Apply Profile") {
            model.applySelectedProfile()
        }

        Button("Refresh") {
            model.refreshDeviceState()
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

import AppKit
