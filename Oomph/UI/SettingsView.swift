import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(EqtuneStore.self) private var store

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            DeviceSettings()
                .tabItem { Label("Devices", systemImage: "headphones") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            EngineSettings()
                .tabItem { Label("Engine", systemImage: "waveform") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540)
        .onAppear { store.setVisible(.settings, true) }
        .onDisappear { store.setVisible(.settings, false) }
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppDelegate.dockIconKey) private var showDockIcon = false
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                // Closures, not method references: Swift 6.3 crashes converting a method to
                // Binding's @isolated(any) setter.
                Toggle(isOn: Binding(get: { loginItem == .enabled }, set: { setLaunchAtLogin($0) })) {
                    Text("Launch at login")
                    Text("Needed for presets to follow your output devices.")
                }
                if loginItem == .requiresApproval {
                    HStack {
                        Text("Allow Oomph in Login Items to finish.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
                Toggle(isOn: $showDockIcon) {
                    Text("Always show in the Dock")
                    Text("Oomph lives in the menu bar and shows in the Dock only while its windows are open.")
                }
                .onChange(of: showDockIcon) {
                    AppDelegate.updateActivationPolicy()
                    NSApp.activate() // switching policy can drop focus from this window
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem = SMAppService.mainApp.status }
        // Back from System Settings' Login Items, where it may have just been allowed or removed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItem = SMAppService.mainApp.status
    }
}

/// A preset per output: headphones get their correction, speakers get theirs, and a studio
/// interface can get no EQ at all.
private struct DeviceSettings: View {
    @Environment(EqtuneStore.self) private var store
    @Environment(AudioOutputs.self) private var outputs

    var body: some View {
        Form {
            Section {
                if outputs.devices.isEmpty {
                    Text("No audio outputs found.").foregroundStyle(.secondary)
                }
                ForEach(outputs.devices) { device in
                    picker(for: device.id, unset: store.devicePresets[EqtuneStore.otherOutputs] == nil ? "Don’t switch" : "Same as other outputs") {
                        Text(device.name)
                        if device.id == outputs.current?.id { Text("Current output") }
                    } icon: {
                        Image(systemName: device.symbol)
                    }
                }
                picker(for: EqtuneStore.otherOutputs, unset: "Don’t switch") {
                    Text("Other outputs")
                    Text("Any output without a choice of its own, including ones you connect later")
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            } header: {
                Text("Preset for each output")
            } footer: {
                Text("When macOS starts playing through one of these, Oomph switches to its preset, or turns the EQ off for No EQ and back on for the next output. Oomph has to be running for this, so turn on Launch at Login.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func picker(for key: String, unset: String, @ViewBuilder title: () -> some View,
                        @ViewBuilder icon: () -> some View) -> some View {
        Picker(selection: Binding(get: { store.devicePresets[key] ?? "" },
                                  set: { store.setDevicePreset($0.isEmpty ? nil : $0, for: key) })) {
            Text(unset).tag("")
            Text("No EQ").tag(EqtuneStore.noEQ)
            Divider()
            ForEach(store.presets, id: \.self) { Text(displayName($0)).tag($0) }
        } label: {
            Label(title: title, icon: icon)
        }
        .disabled(store.presets.isEmpty)
    }
}

/// Global shortcuts, like FxSound's and Peace's: switch the EQ and presets from any app.
private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { ShortcutRow(action: $0) }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("These work in any app while Oomph is running. Click a shortcut, then press the keys, using ⌘, ⌥ or ⌃.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @AppStorage private var shortcut: Shortcut?
    @State private var monitor: Any?

    init(action: ShortcutAction) {
        self.action = action
        _shortcut = AppStorage(action.defaultsKey)
    }

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 4) {
                Button { monitor == nil ? record() : stop() } label: {
                    Text(monitor != nil ? "Press keys…" : shortcut?.display ?? "Record Shortcut")
                        .monospacedDigit()
                        .frame(minWidth: 110)
                }
                .help(monitor != nil ? "Press the shortcut, or Esc to cancel" : "Click, then press the shortcut")
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this shortcut")
                    .opacity(shortcut == nil ? 0 : 1)
                    .disabled(shortcut == nil)
            }
        }
        .onDisappear { stop() }
    }

    private func record() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
            } else if let new = Shortcut(event) {
                // One shortcut, one action: another action with it would never get the press.
                for other in ShortcutAction.allCases where UserDefaults.standard.string(forKey: other.defaultsKey) == new.rawValue {
                    UserDefaults.standard.removeObject(forKey: other.defaultsKey)
                }
                shortcut = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct EngineSettings: View {
    @Environment(EqtuneStore.self) private var store
    @AppStorage(EqtuneBinary.overrideKey) private var customPath = ""
    @State private var confirmUninstall = false
    /// Restarting takes seconds; a second click meanwhile would restart it again.
    @State private var restarting = false

    var body: some View {
        Form {
            if let status = store.status {
                Section("Sound") {
                    EqtuneToggle(isOn: status.limiter, change: { await store.setLimiter($0) }) { _ in
                        Text("Limiter")
                        Text("Gently catches peaks that boosts push past full scale, so loud audio doesn’t crackle.")
                    }
                }
                Section("Battery") {
                    EqtuneToggle(isOn: status.autoOffIdle, change: { await store.setAutoOffIdle($0) }) { _ in
                        Text("Pause when nothing is playing")
                        Text("The EQ resumes as soon as audio starts.")
                    }
                    EqtuneToggle(isOn: status.autoOffLowPower, change: { await store.setAutoOffLowPower($0) }) { _ in
                        Text("Pause in Low Power Mode")
                        Text("Turning the EQ on yourself overrides this.")
                    }
                }
            }
            Section {
                LabeledContent("Bundled engine", value: EqtuneBinary.version(of: EqtuneBinary.bundled).map { "eqtune \($0)" } ?? "Missing")
                if let status = store.status {
                    LabeledContent("Status") { StatusLine(status: status, isFailing: store.isFailing) }
                } else {
                    LabeledContent("Status", value: "Not reachable")
                }
                HStack {
                    Button("Restart Engine") {
                        restarting = true
                        Task {
                            await store.restartEngine()
                            restarting = false
                        }
                    }
                    .disabled(restarting || store.blocker == .notInstalled)
                    Spacer()
                    Button("Uninstall Engine…", role: .destructive) { confirmUninstall = true }
                        .disabled(store.blocker == .notInstalled)
                }
                if let failure = store.failure {
                    FailureBanner(failure: failure) { store.failure = nil }
                }
            } header: {
                Text("Audio engine")
            }
            Section {
                LabeledContent("eqtune binary") {
                    HStack {
                        TextField("eqtune binary", text: $customPath, prompt: Text("Auto-detect"))
                            .labelsHidden()
                        Button("Detect") { customPath = EqtuneBinary.resolve(includingCustom: false)?.path ?? "" }
                    }
                }
                LabeledContent("In use", value: EqtuneBinary.resolve()?.path ?? "None found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Advanced")
            } footer: {
                Text("The engine bundled with Oomph is used first; a custom path applies only if it’s missing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Uninstall the audio engine?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await store.uninstallEngine() } }
        } message: {
            Text("This stops eqtune and removes its background process. Your presets stay on disk, and you can reinstall from the Oomph menu.")
        }
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Oomph").font(.title.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("A system-wide equalizer for macOS, built on the open-source eqtune engine.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            HStack(spacing: 16) {
                Link("GitHub", destination: Links.repository)
                Link("Report an Issue", destination: Links.issues)
                Link("eqtune", destination: Links.eqtune)
            }
            .padding(.top, 4)
            Text("Audio engine: eqtune \(EqtuneBinary.version(of: EqtuneBinary.bundled) ?? "") by y7nieSEl5, MIT or Apache-2.0.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                Text(copyright).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SettingsView()
        .environment(EqtuneStore(client: MockEqtuneClient()))
        .environment(AudioOutputs())
}
