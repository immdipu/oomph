import SwiftUI

/// The presets eqtune has, and the library presets that aren't added yet. Clicking a
/// preset switches to it; its context menu manages it.
struct PresetSidebar: View {
    @Environment(EqtuneStore.self) private var store
    @Environment(AudioOutputs.self) private var outputs
    @State private var nameRequest: NameRequest?
    @State private var pendingDelete: String?
    @State private var pendingReset: String?

    var body: some View {
        List(selection: Binding(get: { store.status?.preset }, set: { name in
            guard let name, name != store.status?.preset else { return }
            Task { await store.selectPreset(name) }
        })) {
            Section("My Presets") {
                ForEach(store.presets, id: \.self) { name in
                    row(name)
                        .tag(name)
                        .contextMenu { menu(for: name) }
                }
            }
            ForEach(LibraryPreset.Category.allCases, id: \.self) { category in
                let items = SoundLibrary.presets.filter { $0.category == category && !store.presets.contains($0.id) }
                if !items.isEmpty {
                    Section(category.rawValue) {
                        ForEach(items) { item in
                            Button { Task { await Dialogs.use(item, store: store) } } label: { libraryRow(item) }
                                .buttonStyle(.plain)
                                .help("Add “\(item.title)” to your presets and switch to it")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(store.status == nil)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .namePrompt($nameRequest)
        .confirmationDialog("Delete “\(pendingDelete.map(displayName) ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { name in
            Button("Delete", role: .destructive) { whenClean { await store.deletePreset(name) } }
        } message: { name in
            Text(EqtuneStore.shippedPresets.contains(name)
                 ? "It’s one of eqtune’s own presets; Reset to Original brings it back."
                 : "This can’t be undone. Export it first if you might want it again.")
        }
        .confirmationDialog("Reset “\(pendingReset ?? "")” to its original tuning?",
                            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
                            presenting: pendingReset) { name in
            Button("Reset", role: .destructive) { whenClean { await store.resetPreset(name) } }
        } message: { _ in
            Text("Your changes to this preset are replaced by eqtune’s original version.")
        }
    }

    private func row(_ name: String) -> some View {
        let devices = outputs.devices.filter { store.devicePresets[$0.id] == name }
        return HStack(spacing: 8) {
            Image(systemName: SoundLibrary.preset(name)?.symbol ?? "slider.horizontal.3")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(displayName(name))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let device = devices.first {
                Image(systemName: device.symbol)
                    .foregroundStyle(.secondary)
                    .help("Used automatically on \(ListFormatter.localizedString(byJoining: devices.map(\.name)))")
            }
            if store.status?.dirtyPresets.contains(name) == true {
                Circle().fill(.orange).frame(width: 7, height: 7)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
        }
    }

    private func libraryRow(_ item: LibraryPreset) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.symbol)
                .foregroundStyle(LinearGradient.oomph)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder private func menu(for name: String) -> some View {
        if store.status?.dirtyPresets.contains(name) == true, name == store.status?.preset {
            Button("Save Changes") { Task { await store.savePreset(as: name) } }
            Divider()
        }
        Button("Duplicate…") {
            whenClean {
                nameRequest = NameRequest(title: "Duplicate “\(displayName(name))”", action: "Duplicate",
                                          initial: store.availableName("\(name)-copy")) {
                    await store.duplicatePreset(name, as: $0)
                }
            }
        }
        Button("Rename…") {
            whenClean {
                nameRequest = NameRequest(title: "Rename “\(displayName(name))”", action: "Rename", initial: name) {
                    await store.renamePreset(name, to: $0)
                }
            }
        }
        Button("Export…") { Task { await Dialogs.exportPreset(name, store: store) } }
        if let device = outputs.current {
            Divider()
            Toggle("Use on \(device.name)", isOn: Binding(get: { store.devicePresets[device.id] == name },
                                                          set: { store.setDevicePreset($0 ? name : nil, for: device.id) }))
        }
        Divider()
        if EqtuneStore.shippedPresets.contains(name) {
            Button("Reset to Original…") { pendingReset = name }
        }
        Button("Delete…", role: .destructive) { pendingDelete = name }
            .disabled(store.presets.count < 2)
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button("New Preset…") {
                    whenClean {
                        nameRequest = NameRequest(title: "New Preset", action: "Create", initial: store.availableName("my-preset")) {
                            await store.newPreset(named: $0)
                        }
                    }
                }
                Divider()
                Button("Import Preset File…") { Task { await Dialogs.importPreset(store: store) } }
                Button("Import Headphone Correction…") { Task { await Dialogs.importHeadphoneCorrection(store: store) } }
            } label: {
                Label("Add Preset", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New preset, or import one")
            Spacer()
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(store.status == nil || store.isBusy)
    }

    /// eqtune changes presets only without unsaved edits; asks to resolve them first.
    private func whenClean(_ change: @escaping @MainActor () async -> Void) {
        Task {
            guard await Dialogs.resolveBeforeChanging(store) else { return }
            await change()
        }
    }
}
