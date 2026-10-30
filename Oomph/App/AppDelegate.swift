import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let dockIconKey = "showDockIcon"

    let store = EqtuneStore(client: ProcessEqtuneClient())
    let outputs = AudioOutputs()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.updateActivationPolicy()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // A closing window is still visible while it closes; look once it's gone.
                DispatchQueue.main.async { Self.updateActivationPolicy() }
            }
        }
        // Unit tests run inside this app; keep them away from the user's daemon.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        outputs.onChange = { [store] device in
            Task { await store.outputChanged(to: device.id) }
        }
        Task {
            await store.syncInstalledEngine()
            // One read so the menu bar icon is right; polling waits until the menu opens.
            await store.refresh()
            if store.blocker == .notInstalled { showOnboarding() }
        }
    }

    /// Info.plist sets LSUIElement (menu bar only). Oomph also shows in the Dock, and so in
    /// ⌘-Tab, while one of its windows is open, or always if the user asked for that.
    static func updateActivationPolicy() {
        let windowOpen = NSApp.windows.contains {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.level == .normal
        }
        let policy: NSApplication.ActivationPolicy =
            UserDefaults.standard.bool(forKey: dockIconKey) || windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let root = OnboardingView { [weak self] in self?.onboardingWindow?.close() }.environment(store)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Welcome to Oomph"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            onboardingWindow = window
        }
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Poll while it's open, so it notices when the EQ comes on and closes itself.
        store.setVisible(.onboarding, true)
    }

    func windowWillClose(_ notification: Notification) {
        store.setVisible(.onboarding, false)
    }
}
