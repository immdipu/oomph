import SwiftUI

@main
struct OomphApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appDelegate.store)
                .environment(appDelegate.outputs)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("Equalizer", id: "equalizer") {
            EqualizerView()
                .environment(appDelegate.store)
                .environment(appDelegate.outputs)
        }
        .defaultSize(width: 1100, height: 780)

        Settings {
            SettingsView()
                .environment(appDelegate.store)
                .environment(appDelegate.outputs)
        }
    }
}
