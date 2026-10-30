import SwiftUI

/// The presets eqtune has, and the library presets that aren't added yet. Clicking a
/// preset switches to it; its context menu manages it.
struct PresetSidebar: View {
    @Environment(EqtuneStore.self) private var store
    @Environment(AudioOutputs.self) private var outputs
    @State private var nameRequest: NameRequest?
    @State private var pendingDelete: String?
    /// The preset just clicked, shown as selected until eqtune has switched to it or
    /// refused. A switch takes eqtune about half a second; without this the list jumps
    /// back to the old preset meanwhile.
    @State private var picked: String?
    /// Library presets being added: their rows show progress, and another click on one is
    /// ignored instead of adding it twice.
    @State private var adding: Set<String> = []

    var body: some View {
        List(selection: Binding(get: { picked ?? store.status?.preset }, set: { if let name = $0 { pick(name) } })) {
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
                            Button { add(item) } label: { libraryRow(item) }
                                .buttonStyle(.plain)
                                // ForEach tags rows with their ids; arrowing onto one would ask eqtune
                                // to switch to a preset it doesn't have yet.
                                .selectionDisabled()
                                .help("Add “\(item.title)” to your presets and switch to it")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.oomph, value: store.presets)
        .animation(.oomph, value: store.status?.dirtyPresets)
        .disabled(store.status == nil)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .namePrompt($nameRequest)
        .confirmationDialog("Delete “\(pendingDelete.map(displayName) ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { name in
            Button("Delete", role: .destructive) { whenClean { await store.deletePreset(name) } }
        } message: { name in
            Text(EqtuneStore.shippedPresets.contains(name)
                 ? "It’s one of eqtune’s own presets; Reset to Original Tuning brings it back."
                 : "This can’t be undone. Export it first if you might want it again.")
        }
    }

    /// Switches to `name`, keeping it selected while eqtune switches. Picks made meanwhile
    /// (arrow keys, quick clicks) only change the target, so eqtune goes straight to the
    /// last one instead of through every preset passed on the way.
    private func pick(_ name: String) {
        guard name != (picked ?? store.status?.preset) else { return }
        let switching = picked != nil
        picked = name
        guard !switching else { return }
        Task {
            while let target = picked, target != store.status?.preset {
                await store.selectPreset(target)
                // eqtune refused it: stop, unless something else was picked meanwhile.
                if store.status?.preset != target, picked == target { break }
            }
            picked = nil
        }
    }

    private func add(_ item: LibraryPreset) {
        guard adding.insert(item.id).inserted else { return }
        Task {
            await Dialogs.use(item, store: store)
            adding.remove(item.id)
        }
    }

    private func row(_ name: String) -> some View {
        let devices = outputs.devices.filter { store.devicePresets[$0.id] == name }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(name, icon: .secondary)
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
        HStack(spacing: 4) {
            label(item.id, icon: LinearGradient.oomph)
            Spacer(minLength: 0)
            if adding.contains(item.id) { ProgressView().controlSize(.small) }
        }
        .contentShape(Rectangle())
    }

    /// A preset's icon and name, and what a library preset is for: it keeps saying so
    /// after it's added.
    private func label(_ name: String, icon: some ShapeStyle) -> some View {
        let item = SoundLibrary.preset(name)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: item?.symbol ?? "slider.horizontal.3")
                .foregroundStyle(icon)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(name))
                    .lineLimit(1)
                if let summary = item?.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func menu(for name: String) -> some View {
        if store.status?.dirtyPresets.contains(name) == true {
            if name == store.status?.preset {
                Button("Save Changes") { Task { await store.savePreset(as: name) } }
            }
            Button("Revert to Saved Version…") { Task { await Dialogs.revert(store: store) } }
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
        if Dialogs.hasOriginal(name) {
            Button("Reset to Original Tuning…") { Task { await Dialogs.resetToOriginal(name, store: store) } }
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
            .disabled(store.status == nil || store.isBusy)
            Spacer()
            // Here rather than in the toolbar, where its slot would sit in a button's glass.
            BusyIndicator(isBusy: store.isBusy)
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// eqtune changes presets only without unsaved edits; asks to resolve them first.
    private func whenClean(_ change: @escaping @MainActor () async -> Void) {
        Task {
            guard await Dialogs.resolveBeforeChanging(store) else { return }
            await change()
        }
    }
}
