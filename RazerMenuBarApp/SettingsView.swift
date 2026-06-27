import SwiftUI
import RazerCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let warning = model.warningMessage {
                warningBanner(warning)
            }
            if let warning = model.mappingWarning {
                warningBanner(warning)
            }

            TabView {
                ProfileTab(model: model)
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                ButtonsTab(model: model)
                    .tabItem { Label("Buttons", systemImage: "computermouse") }
                WheelTab(model: model)
                    .tabItem { Label("Wheel", systemImage: "circle.dotted") }
                DiagnosticsTab(model: model)
                    .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            }
            .frame(minHeight: 520)
        }
        .padding(20)
        .frame(width: 560, height: 680)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DeviceDescriptor.productName)
                .font(.title2.bold())
            HStack(spacing: 12) {
                Text(model.isConnected ? "Connected • Battery \(model.batteryPercent)%" : model.statusMessage)
                if model.remapperRunning {
                    Text(model.remapperPaused ? "Remapper paused" : "Remapper active")
                        .foregroundStyle(model.remapperPaused ? .orange : .green)
                }
            }
            .foregroundStyle(.secondary)
            .font(.callout)
        }
    }

    private func warningBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.orange)
            HStack {
                if text.localizedCaseInsensitiveContains("Input Monitoring") {
                    Button("Open Input Monitoring") { model.openInputMonitoringSettings() }
                }
                if text.localizedCaseInsensitiveContains("Accessibility") {
                    Button("Open Accessibility") { model.openAccessibilitySettings() }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Profile tab

private struct ProfileTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                if let profile = model.selectedProfile {
                    dpiSection(profile: profile)
                    pollingSection(profile: profile)
                    behaviorSection(profile: profile)
                }

                HStack {
                    Button("Apply Now") { model.applySelectedProfile() }
                        .keyboardShortcut(.defaultAction)
                    Button("Refresh") { model.refreshDeviceState() }
                    Button("Reset Controls") { model.resetSelectedProfileControls() }
                }
            }
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
                        TextField("DPI", value: stageBinding(profile: profile, index: index), format: .number)
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
            Toggle("Auto-reapply profile on launch/reconnect", isOn: binding(for: profile, keyPath: \.autoReapplyEnabled))
            Toggle("Enable software remapper", isOn: binding(for: profile, keyPath: \.remapperEnabled))
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Text("Emergency pause: ⌃⌥⌘R")
                .font(.caption)
                .foregroundStyle(.secondary)
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

// MARK: - Buttons tab

private struct ButtonsTab: View {
    @ObservedObject var model: AppModel
    @State private var openURLString = "https://"
    @State private var urlTargetControl: PhysicalControl = .leftClick

    var body: some View {
        ScrollView {
            if let profile = model.selectedProfile {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Map physical controls to actions. Software remapping requires Input Monitoring and Accessibility.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Table(PhysicalControl.assignableControls) {
                        TableColumn("Control") { control in
                            Text(control.displayName)
                        }
                        TableColumn("Action") { control in
                            actionPicker(control: control, profile: profile)
                        }
                    }
                    .frame(minHeight: 320)

                    GroupBox("Shortcut capture") {
                        Text("Select a control row action as Keyboard Shortcut, then click Capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let control = model.shortcutCaptureControl {
                            Text("Capturing for \(control.displayName)… press a key combination (Esc to cancel).")
                                .foregroundStyle(.blue)
                        }
                    }

                    GroupBox("Open URL action") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose a control, enter an http(s) URL, then click Set URL.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Target control", selection: $urlTargetControl) {
                                ForEach(PhysicalControl.assignableControls, id: \.self) { control in
                                    Text(control.displayName).tag(control)
                                }
                            }
                            TextField("https://example.com", text: $openURLString)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Set URL on selected control") {
                                    assignOpenURL(control: urlTargetControl, profile: profile)
                                }
                                .disabled(ButtonActionValidator.validateOpenURL(openURLString) != nil)
                                if let error = ButtonActionValidator.validateOpenURL(openURLString) {
                                    Text(urlValidationMessage(error))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(ShortcutCaptureMonitor(model: model))
    }

    @ViewBuilder
    private func actionPicker(control: PhysicalControl, profile: MouseProfile) -> some View {
        let current = InputRemapperEngine.resolvedButtonAction(for: control, in: profile.buttonMappings)
        Menu(current.displayName) {
            Button("Default (passthrough)") { setAction(.passthrough, control: control, profile: profile) }
            Button("Disabled") { setAction(.disabled, control: control, profile: profile) }
            Divider()
            ForEach(MouseButtonTarget.allCases, id: \.self) { target in
                Button("Mouse: \(target.displayName)") {
                    setAction(.mouseButton(target), control: control, profile: profile)
                }
            }
            Divider()
            Button("Keyboard Shortcut…") {
                model.shortcutCaptureControl = control
            }
            Divider()
            Button("Next DPI Stage") { setAction(.nextDPIStage, control: control, profile: profile) }
            Button("Previous DPI Stage") { setAction(.previousDPIStage, control: control, profile: profile) }
            Button("Next Profile") { setAction(.nextProfile, control: control, profile: profile) }
            Button("Previous Profile") { setAction(.previousProfile, control: control, profile: profile) }
            Divider()
            Button("Open App…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    setAction(.openApp(url.path), control: control, profile: profile)
                }
            }
        }
    }

    private func assignOpenURL(control: PhysicalControl, profile: MouseProfile) {
        guard let normalized = ButtonActionValidator.normalizedOpenURL(openURLString) else { return }
        setAction(.openURL(normalized), control: control, profile: profile)
    }

    private func urlValidationMessage(_ error: ButtonActionValidator.ValidationError) -> String {
        switch error {
        case .empty: return "Enter a URL."
        case .invalidScheme: return "Use an http:// or https:// URL with a host."
        case .missingHost: return "URL must include a host."
        }
    }

    private func setAction(_ action: ButtonAction, control: PhysicalControl, profile: MouseProfile) {
        var updated = profile
        updated.buttonMappings[control] = action
        if control == .wheelClick {
            updated.buttonMappings.removeValue(forKey: .middleClick)
        }
        model.updateProfile(updated)
    }
}

private struct ShortcutCaptureMonitor: View {
    @ObservedObject var model: AppModel
    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.shortcutCaptureControl) { control in
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
                guard let control else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 {
                        model.shortcutCaptureControl = nil
                        return nil
                    }
                    let flags = UInt64(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
                    let shortcut = KeyboardShortcut(keyCode: UInt16(event.keyCode), modifierFlags: flags)
                    if var profile = model.selectedProfile {
                        profile.buttonMappings[control] = .keyboardShortcut(shortcut)
                        if control == .wheelClick {
                            profile.buttonMappings.removeValue(forKey: .middleClick)
                        }
                        model.updateProfile(profile)
                    }
                    model.shortcutCaptureControl = nil
                    return nil
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
                model.shortcutCaptureControl = nil
            }
    }
}

// MARK: - Wheel tab

private struct WheelTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            if let profile = model.selectedProfile {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Hardware Wheel (device firmware)") {
                        VStack(alignment: .leading, spacing: 8) {
                            capabilityRow("Scroll mode", model.wheelCapability.scrollMode)
                            capabilityRow("Acceleration", model.wheelCapability.acceleration)
                            capabilityRow("Smart reel", model.wheelCapability.smartReel)

                            if model.wheelCapability.scrollMode == .supported {
                                Picker("Scroll mode", selection: hardwareBinding(profile, keyPath: \.scrollMode)) {
                                    Text("Not set").tag(Optional<ScrollWheelMode>.none)
                                    ForEach(ScrollWheelMode.allCases, id: \.self) { mode in
                                        Text(mode.displayName).tag(Optional(mode))
                                    }
                                }
                            }
                            if model.wheelCapability.acceleration == .supported {
                                Toggle("Acceleration", isOn: hardwareBoolBinding(profile, keyPath: \.accelerationEnabled))
                            }
                            if model.wheelCapability.smartReel == .supported {
                                Toggle("Smart reel", isOn: hardwareBoolBinding(profile, keyPath: \.smartReelEnabled))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Software Scroll Tuning") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Direction", selection: softwareBinding(profile, keyPath: \.scrollDirection)) {
                                ForEach(ScrollDirection.allCases, id: \.self) { direction in
                                    Text(direction.displayName).tag(direction)
                                }
                            }
                            HStack {
                                Text("Vertical speed")
                                Slider(value: softwareBinding(profile, keyPath: \.verticalSpeedMultiplier), in: 0.25...3.0)
                                Text(String(format: "%.2fx", profile.wheelSettings.software.verticalSpeedMultiplier))
                                    .monospacedDigit()
                                    .frame(width: 48)
                            }
                            Picker("Horizontal with", selection: softwareBinding(profile, keyPath: \.horizontalScrollModifier)) {
                                ForEach(HorizontalScrollModifier.allCases, id: \.self) { modifier in
                                    Text(modifier.displayName).tag(modifier)
                                }
                            }
                            wheelActionPicker("Wheel up action", control: .wheelUp, profile: profile)
                            wheelActionPicker("Wheel down action", control: .wheelDown, profile: profile)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { model.probeWheelHardware() }
    }

    private func capabilityRow(_ title: String, _ result: CapabilityResult) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(result.displayName)
                .foregroundStyle(result == .supported ? .green : .secondary)
        }
    }

    private func hardwareBinding(_ profile: MouseProfile, keyPath: WritableKeyPath<HardwareWheelSettings, ScrollWheelMode?>) -> Binding<ScrollWheelMode?> {
        Binding(
            get: { model.bundle.profiles.first(where: { $0.id == profile.id })?.wheelSettings.hardware[keyPath: keyPath] },
            set: { newValue in
                var updated = profile
                updated.wheelSettings.hardware[keyPath: keyPath] = newValue
                model.updateProfile(updated)
            }
        )
    }

    private func hardwareBoolBinding(_ profile: MouseProfile, keyPath: WritableKeyPath<HardwareWheelSettings, Bool?>) -> Binding<Bool> {
        Binding(
            get: { model.bundle.profiles.first(where: { $0.id == profile.id })?.wheelSettings.hardware[keyPath: keyPath] ?? false },
            set: { newValue in
                var updated = profile
                updated.wheelSettings.hardware[keyPath: keyPath] = newValue
                model.updateProfile(updated)
            }
        )
    }

    private func softwareBinding<T>(_ profile: MouseProfile, keyPath: WritableKeyPath<SoftwareWheelSettings, T>) -> Binding<T> {
        Binding(
            get: {
                model.bundle.profiles.first(where: { $0.id == profile.id })?.wheelSettings.software[keyPath: keyPath]
                    ?? profile.wheelSettings.software[keyPath: keyPath]
            },
            set: { newValue in
                var updated = profile
                updated.wheelSettings.software[keyPath: keyPath] = newValue
                model.updateProfile(updated)
            }
        )
    }

    @ViewBuilder
    private func wheelActionPicker(_ title: String, control: PhysicalControl, profile: MouseProfile) -> some View {
        let softwareKeyPath: WritableKeyPath<SoftwareWheelSettings, ButtonAction?> = control == .wheelUp
            ? \.wheelUpAction
            : \.wheelDownAction
        let current = profile.wheelSettings.software[keyPath: softwareKeyPath]
        Menu("\(title): \(current?.displayName ?? "Use button mapping")") {
            Button("Use button mapping") {
                var updated = profile
                updated.wheelSettings.software[keyPath: softwareKeyPath] = nil
                model.updateProfile(updated)
            }
            Button("Disabled") {
                var updated = profile
                updated.wheelSettings.software[keyPath: softwareKeyPath] = .disabled
                model.updateProfile(updated)
            }
            Button("Next DPI Stage") {
                var updated = profile
                updated.wheelSettings.software[keyPath: softwareKeyPath] = .nextDPIStage
                model.updateProfile(updated)
            }
            Button("Previous DPI Stage") {
                var updated = profile
                updated.wheelSettings.software[keyPath: softwareKeyPath] = .previousDPIStage
                model.updateProfile(updated)
            }
        }
    }
}

// MARK: - Diagnostics tab

private struct DiagnosticsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.permissions.summary)
                        HStack {
                            Button("Input Monitoring") { model.openInputMonitoringSettings() }
                            Button("Accessibility") { model.openAccessibilitySettings() }
                            Button("Refresh") { model.refreshPermissions() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Feature report probe") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.wheelProbeSummary)
                            .font(.system(.body, design: .monospaced))
                        Button("Probe wheel commands") { model.probeWheelHardware() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Input capture (opt-in, not saved)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Capture session", isOn: Binding(
                            get: { model.diagnosticsCaptureEnabled },
                            set: { model.setDiagnosticsCaptureEnabled($0) }
                        ))
                        Text("Shows raw button/scroll events and detected control names. Nothing is written to disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !model.captureEntries.isEmpty {
                            List(model.captureEntries.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.summary)
                                        .font(.system(.caption, design: .monospaced))
                                    if let control = entry.control {
                                        Text(control.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(minHeight: 180)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            model.refreshPermissions()
            model.probeWheelHardware()
        }
    }
}

import AppKit
