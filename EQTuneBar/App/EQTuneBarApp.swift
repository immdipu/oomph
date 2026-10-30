import SwiftUI

@main
struct EQTuneBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(appDelegate.store)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("Bands", id: "band-editor") {
            BandEditorView().environment(appDelegate.store)
        }
        .defaultSize(width: 820, height: 680)

        Settings {
            SettingsView().environment(appDelegate.store)
        }
    }
}
