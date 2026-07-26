import SwiftUI
import AppKit
import RazerCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let warning = model.warningMessage {
                warningBanner(warning)
            }
            if let warning = model.persistenceWarning {
                persistenceWarningBanner(warning)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(model.activeModel.name)
                .font(.title2.bold())
            Text(model.isConnected ? "Connected • Battery \(model.batteryPercent)%" : model.statusMessage)
                .foregroundStyle(.secondary)
                .font(.callout)
            remapperStatusRow
        }
    }

    private var remapperStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.remapperStatus.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(remapperStatusColor)
                Text(model.remapperStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = model.remapperStatus.recoveryAction {
                Button(action.buttonTitle) {
                    model.performRemapperRecoveryAction(action)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(remapperStatusColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var remapperStatusColor: Color {
        switch model.remapperStatus {
        case .active:
            return .green
        case .paused, .recovering, .awaitingConsent, .circuitOpen:
            return .orange
        case .missingPermission, .failed:
            return .red
        case .disabled:
            return .secondary
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

    private func persistenceWarningBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.orange)
            HStack {
                if let url = model.quarantinedProfileURL {
                    Button("Reveal File") {
                        model.revealInFinder(url)
                    }
                }
                if model.allowsCorruptSourceRecoveryActions {
                    Button("Retry Quarantine") {
                        model.retryQuarantineCorruptProfiles()
                    }
                    Button("Discard Corrupt File and Start Fresh", role: .destructive) {
                        model.confirmDiscardCorruptFile = true
                    }
                } else {
                    Button("Dismiss") {
                        model.dismissPersistenceWarning()
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .alert("Discard corrupt profile file?", isPresented: $model.confirmDiscardCorruptFile) {
            Button("Cancel", role: .cancel) {}
            Button("Discard Permanently", role: .destructive) {
                model.discardCorruptFileAndStartFresh()
            }
        } message: {
            Text("This permanently deletes the only remaining corrupt profile file. Recovery from that file will become impossible.")
        }
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
                            TextField("Name", text: Binding(
                                get: { model.profileDraft?.name ?? profile.name },
                                set: { newValue in
                                    guard var draft = model.profileDraft else { return }
                                    draft.name = newValue
                                    model.updateDraft(draft)
                                }
                            ))
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

                if let profile = model.selectedProfile, let draft = model.profileDraft {
                    dpiSection(profile: profile, draft: draft)
                    pollingSection(profile: profile, draft: draft)
                    behaviorSection(profile: profile, draft: draft)
                }

                if case let .failed(message) = model.persistenceStatus {
                    Text("Could not save profiles: \(message)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Apply Now") { model.applySelectedProfile(reason: .explicitApply) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(model.profileDraft?.isValid ?? false))
                    Button("Refresh") { model.refreshDeviceState() }
                    Button("Reset Controls") { model.resetSelectedProfileControls() }
                }
                if model.hardwareChangesPending {
                    Text("Hardware changes pending")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func dpiSection(profile: MouseProfile, draft: ProfileDraft) -> some View {
        GroupBox("DPI Stages (hardware)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("DPI stages are written to the connected Razer mouse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "Active stage: \(draft.activeStage)",
                    value: draftBinding(draft, keyPath: \.activeStage),
                    in: 1...max(draft.stageTexts.count, 1)
                )
                if let error = draft.activeStageError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(draft.stageTexts.indices, id: \.self) { index in
                    HStack {
                        Text("Stage \(index + 1)")
                        Spacer()
                        TextField(
                            "DPI",
                            text: Binding(
                                get: { draft.stageTexts[index] },
                                set: { newValue in
                                    var updated = draft
                                    updated.stageTexts[index] = newValue
                                    model.updateDraft(updated)
                                }
                            )
                        )
                        .frame(width: 90)
                    }
                    if let error = draft.stageErrors[index] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Button("Add Stage") {
                        var updated = draft
                        guard updated.stageTexts.count < model.activeModel.maxDPIStages else { return }
                        updated.stageTexts.append(updated.stageTexts.last ?? "800")
                        model.updateDraft(updated)
                    }
                    .disabled(draft.stageTexts.count >= model.activeModel.maxDPIStages)

                    Button("Remove Stage") {
                        var updated = draft
                        guard updated.stageTexts.count > 1 else { return }
                        updated.stageTexts.removeLast()
                        updated.activeStage = min(updated.activeStage, updated.stageTexts.count)
                        model.updateDraft(updated)
                    }
                    .disabled(draft.stageTexts.count <= 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pollingSection(profile: MouseProfile, draft: ProfileDraft) -> some View {
        GroupBox("Polling Rate (hardware)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Polling rate is a device firmware setting for the connected Razer mouse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Hz", selection: draftBinding(draft, keyPath: \.pollingRateHz)) {
                    ForEach(model.activeModel.pollingRates, id: \.self) { rate in
                        Text("\(rate) Hz").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                if let error = draft.pollingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func behaviorSection(profile: MouseProfile, draft: ProfileDraft) -> some View {
        GroupBox("Behavior") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto-reapply profile on launch/reconnect", isOn: draftBinding(draft, keyPath: \.autoReapplyEnabled))
                Toggle(
                    "Enable software remapper",
                    isOn: Binding(
                        get: { draft.remapperEnabled },
                        set: { model.setRemapperEnabled($0, on: draft) }
                    )
                )
                .disabled(!model.permissions.remapperReady && !draft.remapperEnabled)
                Text("Software remapping affects every mouse and trackpad in this login session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.remapperEnabled && !model.remapperArmed {
                    Text("Remapper preference is on, but this process is not armed yet.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !model.permissions.remapperReady {
                    Text("Required: \(model.permissions.summary)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Emergency pause: ⌃⌥⌘R")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            "Enable software remapper?",
            isPresented: Binding(
                get: { model.confirmArmRemapper },
                set: { newValue in
                    if !newValue { model.cancelArmRemapperConfirmation() }
                    else { model.confirmArmRemapper = true }
                }
            )
        ) {
            Button("Arm Remapper", role: .none) {
                model.armRemapperForSession()
            }
            Button("Cancel", role: .cancel) {
                model.cancelArmRemapperConfirmation()
            }
        } message: {
            Text("Software remapping affects every mouse and trackpad in this login session.")
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

    private func draftBinding<T>(_ draft: ProfileDraft, keyPath: WritableKeyPath<ProfileDraft, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                var updated = draft
                updated[keyPath: keyPath] = newValue
                model.updateDraft(updated)
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
                    Text("Map physical controls to software actions. These remaps are session-wide: they apply to every pointing device while the remapper is active, not only the connected Razer mouse. Requires Input Monitoring and Accessibility.")
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
                            Text("These settings talk to the connected Razer mouse over HID feature reports.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                            Text("Software scroll tuning uses the session event tap and affects all mice/trackpads while remapping is enabled.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                GroupBox("Quarantined profiles") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Previously unreadable profile files for this device. Restore re-validates the file and replaces the current profiles only if it is fully safe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.quarantinedArtifacts.isEmpty {
                            Text("No quarantine artifacts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.quarantinedArtifacts, id: \.path) { url in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(url.lastPathComponent)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(2)
                                    Spacer(minLength: 8)
                                    Button("Restore") {
                                        model.restoreQuarantinedProfile(from: url)
                                    }
                                    Button("Reveal in Finder") {
                                        model.revealInFinder(url)
                                    }
                                }
                            }
                        }
                        Button("Refresh List") {
                            model.refreshQuarantineList()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("DriverKit spike") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.driverStatusMessage)
                        Text("State: \(model.driverActivationState.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = model.driverLastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text("Physical acceptance checklist: docs/testing/driverkit-spike.md")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Activate Driver") { model.activateDriverExtension() }
                            Button("Deactivate Driver") { model.deactivateDriverExtension() }
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

                GroupBox("Input capture (opt-in, memory-only)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Capture session", isOn: Binding(
                            get: { model.diagnosticsCaptureEnabled },
                            set: { model.setDiagnosticsCaptureEnabled($0) }
                        ))
                        Text("Bounded in-memory log of event type, button number, wheel axes, control, synthetic marker, and remap disposition. Nothing is written to disk. Keyboard characters are not captured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("\(model.captureEntries.count) entries")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") { model.clearDiagnosticsCapture() }
                                .disabled(model.captureEntries.isEmpty)
                        }

                        if !model.captureEntries.isEmpty {
                            List(model.captureEntries.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.summary)
                                        .font(.system(.caption, design: .monospaced))
                                    HStack(spacing: 8) {
                                        Text(entry.eventType)
                                        Text(entry.disposition.displayName)
                                        if entry.isSynthetic {
                                            Text("synthetic")
                                        }
                                        if let button = entry.buttonNumber {
                                            Text("btn \(button)")
                                        }
                                        if let control = entry.control {
                                            Text(control.displayName)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    if let axes = entry.wheelAxes {
                                        Text(axes.summary)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(minHeight: 220)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            model.refreshPermissions()
            model.refreshQuarantineList()
            model.probeWheelHardware()
        }
    }
}

import AppKit
