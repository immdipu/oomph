import SwiftUI

/// First run: the engine's LaunchAgent isn't installed yet. Shown in its own window at
/// launch and in the menu until the install succeeds.
struct OnboardingView: View {
    @Environment(EqtuneStore.self) private var store
    var onInstalled: () -> Void = {}

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
            }
            Button {
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
            .disabled(store.isBusy)
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
