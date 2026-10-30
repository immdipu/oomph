import SwiftUI

/// First run: the engine's LaunchAgent isn't installed yet. Shown in its own window at
/// launch and in the menu until the install succeeds.
struct OnboardingView: View {
    @Environment(EqtuneStore.self) private var store
    var onInstalled: () -> Void = {}
    @State private var started = false

    /// Installed, but eqtune hasn't confirmed the EQ is on yet: its daemon answers nobody while
    /// macOS asks for audio-capture permission.
    private var waiting: Bool {
        started && !store.isBusy && store.failure == nil && store.status?.isOn != true
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text("Set up Oomph")
                .font(.title3.bold())
            Text("Oomph needs to install its audio engine (a small background process). You'll also be asked for audio-capture permission.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = store.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the engine. If macOS asks to let eqtune capture audio, click Allow.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            Button {
                started = true
                Task { await store.installEngine() }
            } label: {
                HStack(spacing: 6) {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Text("Install engine")
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isBusy || waiting)
        }
        .padding(24)
        .frame(width: 320)
        // Done once the EQ is on, whether installed from here or from the menu.
        .onChange(of: store.status?.isOn) { _, on in
            if on == true { onInstalled() }
        }
    }
}

#Preview {
    OnboardingView().environment(EqtuneStore(client: MockEqtuneClient()))
}
