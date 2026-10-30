import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let dockIconKey = "showDockIcon"

    let store = EqtuneStore(client: ProcessEqtuneClient())
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.showDockIcon(UserDefaults.standard.bool(forKey: Self.dockIconKey))
        // Unit tests run inside this app; keep them away from the user's daemon.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task {
            await store.syncInstalledEngine()
            // One read so the menu bar icon is right; polling waits until the menu opens.
            await store.refresh()
            if store.blocker == .notInstalled { showOnboarding() }
        }
    }

    /// Info.plist sets LSUIElement (menu bar only); this switches at runtime.
    static func showDockIcon(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let root = OnboardingView { [weak self] in self?.onboardingWindow?.close() }.environment(store)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Welcome to Oomph"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
