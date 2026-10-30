import AppKit
import SwiftUI

/// First run: the engine's LaunchAgent isn't installed yet. Shown in its own window at
/// launch, and (compact) in the menu until the install succeeds.
struct OnboardingView: View {
    @Environment(EqtuneStore.self) private var store
    private let compact: Bool
    private let onInstalled: () -> Void
    @State private var started = false

    init(compact: Bool = false, onInstalled: @escaping () -> Void = {}) {
        self.compact = compact
        self.onInstalled = onInstalled
    }

    /// Installed, but eqtune hasn't confirmed the EQ is on yet: its daemon answers nobody while
    /// macOS asks for audio-capture permission.
    private var waiting: Bool {
        started && !store.isBusy && store.failure == nil && store.status?.isOn != true
    }

    var body: some View {
        VStack(spacing: compact ? 12 : 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: compact ? 52 : 88, height: compact ? 52 : 88)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Welcome to Oomph")
                    .font(compact ? .title3.bold() : .largeTitle.bold())
                Text("A system-wide equalizer for your Mac.")
                    .foregroundStyle(.secondary)
            }
            if !compact {
                VStack(alignment: .leading, spacing: 14) {
                    feature("slider.vertical.3", "Shape every sound",
                            "Music, movies, calls and games, in every app and on any output.")
                    feature("headphones", "Tuned for your ears",
                            "Ready-made sounds, Bass and Treble controls, and corrections for thousands of headphones.")
                    feature("lock.shield", "Private and light",
                            "No drivers or kernel extensions. Audio is processed on your Mac and never leaves it.")
                }
                .padding(.vertical, 4)
            }
            Text("Oomph installs a small audio engine that runs in the background. macOS then asks once for permission to capture system audio, which is how the EQ hears what your Mac plays.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = store.failure {
                FailureBanner(failure: failure)
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
                    Text("Install Audio Engine")
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(store.isBusy || waiting)
        }
        .padding(compact ? 4 : 36)
        .frame(width: compact ? nil : 480)
        // Done once the EQ is on, whether installed from here or from the menu.
        .onChange(of: store.status?.isOn) { _, on in
            if on == true { onInstalled() }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(LinearGradient.oomph)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    OnboardingView().environment(EqtuneStore(client: MockEqtuneClient()))
}
