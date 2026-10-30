import SwiftUI

/// Finds the user's headphones in AutoEq's catalog and adds their correction as a preset.
struct HeadphoneSearch: View {
    @Environment(EqtuneStore.self) private var store
    @Environment(AudioOutputs.self) private var outputs
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: [AutoEq.Headphone]?
    @State private var loadFailed = false
    @State private var query = ""
    @State private var selection: AutoEq.Headphone.ID?
    @State private var useOnOutput = false
    @State private var downloading = false
    @State private var problem: String?
    @FocusState private var searching: Bool

    var body: some View {
        let matches = AutoEq.search(query, in: catalog ?? [])
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Your Headphones").font(.title2.bold())
            Text("Pick your model to add a correction that evens out its sound, so music plays the way it was mixed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $query, prompt: Text("Search \(catalog?.count ?? 0) headphones and earbuds"))
                .textFieldStyle(.roundedBorder)
                .focused($searching)
            results(matches)
                .frame(height: 280)
            if let device = outputs.current {
                Toggle("Always use it on \(device.name)", isOn: $useOnOutput)
            }
            Group {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text("Corrections from [AutoEq](https://autoeq.app), measured by the people named under each model.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(2, reservesSpace: true)
            HStack {
                Button("Import File…") {
                    let store = store // a closed sheet's environment can't be read
                    dismiss()
                    Task { await Dialogs.importPreset(store: store) }
                }
                .help("Import a parametric EQ file downloaded from autoeq.app or elsewhere")
                Spacer()
                if downloading { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Preset") { add(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.flatMap { id in matches.first { $0.id == id } } == nil || downloading)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            searching = true // type a model straight away, even while the list loads
            // Searching from the speakers is likely for headphones that aren't connected.
            useOnOutput = ["airpods", "headphones"].contains(outputs.current?.symbol)
        }
        .task { await load() }
    }

    @ViewBuilder private func results(_ matches: [AutoEq.Headphone]) -> some View {
        if loadFailed {
            ContentUnavailableView {
                Label("Couldn’t Load the Headphone List", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your internet connection.")
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if catalog == nil {
            ProgressView("Loading the headphone list…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(matches, selection: $selection) { headphone in
                HStack(spacing: 8) {
                    Image(systemName: headphone.isInEar ? "earbuds" : "headphones")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headphone.name)
                        Text(headphone.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu(forSelectionType: AutoEq.Headphone.ID.self, menu: { _ in }) { ids in add(ids.first) }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
        }
    }

    private func load() async {
        loadFailed = false
        do { catalog = try await AutoEq.loadIndex() } catch { loadFailed = true }
    }

    /// Downloads the correction while the sheet waits, then closes it and imports.
    private func add(_ id: AutoEq.Headphone.ID?) {
        guard let headphone = catalog?.first(where: { $0.id == id }), !downloading else { return }
        downloading = true
        problem = nil
        Task {
            defer { downloading = false }
            guard let text = try? await AutoEq.download(headphone.parametricEQ) else {
                problem = "Couldn’t download the correction for \(headphone.name). Check your internet connection."
                return
            }
            // Read before closing: a closed sheet's environment can't be read.
            let store = store, device = useOnOutput ? outputs.current : nil
            dismiss()
            guard let name = await Dialogs.importPreset(text, named: headphone.name, store: store) else { return }
            if let device { store.setDevicePreset(name, for: device.id) }
        }
    }
}
