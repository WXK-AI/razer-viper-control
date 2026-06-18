import SwiftUI
import RazerCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let warning = model.warningMessage {
                warningBanner(warning)
            }
            profileSection
            if let profile = model.selectedProfile {
                dpiSection(profile: profile)
                pollingSection(profile: profile)
                behaviorSection(profile: profile)
            }
            actionButtons
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DeviceDescriptor.productName)
                .font(.title2.bold())
            Text(model.isConnected ? "Connected • Battery \(model.batteryPercent)%" : model.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private func warningBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.orange)
            if text.localizedCaseInsensitiveContains("Input Monitoring") {
                Button("Open Input Monitoring Settings") {
                    model.openInputMonitoringSettings()
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileSection: some View {
        GroupBox("Profile") {
            VStack(alignment: .leading, spacing: 8) {
                if let profile = model.selectedProfile {
                    TextField("Name", text: binding(for: profile, keyPath: \.name))
                }

                Picker("Active profile", selection: Binding(
                    get: { model.bundle.selectedProfileID ?? UUID() },
                    set: { id in
                        if let profile = model.bundle.profiles.first(where: { $0.id == id }) {
                            model.selectProfile(profile)
                        }
                    }
                )) {
                    ForEach(model.bundle.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }

                HStack {
                    Button("Add Profile") { model.addProfile() }
                    Button("Delete Profile") { model.deleteSelectedProfile() }
                        .disabled(model.bundle.profiles.count <= 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dpiSection(profile: MouseProfile) -> some View {
        GroupBox("DPI Stages") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper(
                    "Active stage: \(profile.activeStage)",
                    value: binding(for: profile, keyPath: \.activeStage),
                    in: 1...max(profile.dpiStages.count, 1)
                )

                ForEach(profile.dpiStages.indices, id: \.self) { index in
                    HStack {
                        Text("Stage \(index + 1)")
                        Spacer()
                        TextField(
                            "DPI",
                            value: stageBinding(profile: profile, index: index),
                            format: .number
                        )
                        .frame(width: 90)
                    }
                }

                HStack {
                    Button("Add Stage") {
                        var updated = profile
                        guard updated.dpiStages.count < DeviceDescriptor.maxDPIStages else { return }
                        updated.dpiStages.append(updated.dpiStages.last ?? 800)
                        model.updateProfile(updated)
                    }
                    .disabled(profile.dpiStages.count >= DeviceDescriptor.maxDPIStages)

                    Button("Remove Stage") {
                        var updated = profile
                        guard updated.dpiStages.count > 1 else { return }
                        updated.dpiStages.removeLast()
                        updated.activeStage = min(updated.activeStage, updated.dpiStages.count)
                        model.updateProfile(updated)
                    }
                    .disabled(profile.dpiStages.count <= 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pollingSection(profile: MouseProfile) -> some View {
        GroupBox("Polling Rate") {
            Picker("Hz", selection: binding(for: profile, keyPath: \.pollingRateHz)) {
                ForEach(DeviceDescriptor.supportedPollingRates, id: \.self) { rate in
                    Text("\(rate) Hz").tag(rate)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func behaviorSection(profile: MouseProfile) -> some View {
        GroupBox("Behavior") {
            Toggle(
                "Auto-reapply profile on launch/reconnect",
                isOn: binding(for: profile, keyPath: \.autoReapplyEnabled)
            )
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Apply Now") { model.applySelectedProfile() }
                .keyboardShortcut(.defaultAction)
            Button("Refresh") { model.refreshDeviceState() }
        }
    }

    private func binding<T>(for profile: MouseProfile, keyPath: WritableKeyPath<MouseProfile, T>) -> Binding<T> {
        Binding(
            get: {
                model.bundle.profiles.first(where: { $0.id == profile.id })?[keyPath: keyPath]
                    ?? profile[keyPath: keyPath]
            },
            set: { newValue in
                var updated = profile
                updated[keyPath: keyPath] = newValue
                model.updateProfile(updated)
            }
        )
    }

    private func stageBinding(profile: MouseProfile, index: Int) -> Binding<Int> {
        Binding(
            get: {
                model.bundle.profiles.first(where: { $0.id == profile.id })?.dpiStages[index]
                    ?? profile.dpiStages[index]
            },
            set: { newValue in
                var updated = profile
                updated.dpiStages[index] = newValue
                model.updateProfile(updated)
            }
        )
    }
}
