import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(EqtuneStore.self) private var store
    @AppStorage(AppDelegate.dockIconKey) private var showDockIcon = false
    @AppStorage(EqtuneBinary.overrideKey) private var customPath = ""
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, show in
                        AppDelegate.showDockIcon(show)
                        NSApp.activate() // switching policy can drop focus from this window
                    }
                Toggle("Launch at login", isOn: Binding(get: { loginItem == .enabled }, set: setLaunchAtLogin))
                if loginItem == .requiresApproval {
                    HStack {
                        Text("Allow Oomph in Login Items to finish.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Engine") {
                if let status = store.status {
                    Toggle("Auto-off in Low Power Mode", isOn: command(status.autoOffLowPower, store.setAutoOffLowPower))
                    Toggle("Auto-off when idle", isOn: command(status.autoOffIdle, store.setAutoOffIdle))
                    Toggle("Limiter", isOn: command(status.limiter, store.setLimiter))
                } else {
                    Text("The engine isn't reachable right now.").foregroundStyle(.secondary)
                }
                if let failure = store.failure {
                    Text(failure.message).font(.caption).foregroundStyle(.red)
                }
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
                Button("Uninstall engine…", role: .destructive) { confirmUninstall = true }
                    .disabled(store.isBusy || store.blocker == .notInstalled)
            } header: {
                Text("Advanced")
            } footer: {
                Text("The engine bundled with Oomph is used first; a custom path applies only if it is missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Uninstall the audio engine?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await store.uninstallEngine() } }
        } message: {
            Text("This stops eqtune and removes its background process. Your presets stay on disk, and you can reinstall from the Oomph menu.")
        }
        .onAppear {
            store.setVisible(.settings, true)
            loginItem = SMAppService.mainApp.status
        }
        .onDisappear { store.setVisible(.settings, false) }
    }

    /// A switch that shows eqtune's value and runs a command when flipped.
    private func command(_ value: Bool, _ run: @escaping @MainActor (Bool) async -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { on in Task { await run(on) } })
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

#Preview {
    SettingsView().environment(EqtuneStore(client: MockEqtuneClient()))
}
