import SwiftUI

struct PresetsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var newPresetName: String = ""
    @State private var isImporting: Bool = false
    @State private var isExporting: Bool = false
    @State private var renamingPresetID: EQPreset.ID?
    @State private var renameDraft: String = ""

    @State private var exportDoc = EQPresetDocument(preset: EQPreset(name: "Preset", settings: .default))
    @State private var exportFilename: String = "Preset.macqeq"

    var body: some View {
        VStack(spacing: 12) {
            header

            List(selection: Binding(
                get: { model.selectedPresetID },
                set: { id in
                    model.selectedPresetID = id
                    if let id { model.applyPreset(id: id) }
                }
            )) {
                ForEach(model.presets) { preset in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(preset.name)
                                .font(.headline)
                            if preset.origin == .ai {
                                Text("AI")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.cyan)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.cyan.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                        Text(preset.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .macqPanel(cornerRadius: 8, selected: model.selectedPresetID == preset.id)
                    .tag(Optional(preset.id))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button("Rename…") {
                            renamingPresetID = preset.id
                            renameDraft = preset.name
                        }
                        Button("Delete", role: .destructive) {
                            model.deletePreset(id: preset.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .padding(14)
        .macqRootSurface()
        .sheet(isPresented: Binding(
            get: { renamingPresetID != nil },
            set: { presented in if presented == false { renamingPresetID = nil } }
        )) {
            RenamePresetSheet(
                name: $renameDraft,
                onCancel: {
                    renamingPresetID = nil
                },
                onSave: {
                    guard let id = renamingPresetID else { return }
                    model.renamePreset(id: id, newName: renameDraft)
                    renamingPresetID = nil
                }
            )
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.macqPreset, .json]) { result in
            switch result {
            case .success(let url):
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let preset = try? decoder.decode(EQPreset.self, from: data) {
                        model.importPreset(preset)
                    } else if let settings = try? decoder.decode(EQSettings.self, from: data) {
                        let base = url.deletingPathExtension().lastPathComponent
                        let name = base.isEmpty ? "Imported Preset" : base
                        model.importPreset(EQPreset(name: name, settings: settings, origin: .user))
                    } else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } catch {
                    model.presentError(error.localizedDescription)
                }
            case .failure(let error):
                model.presentError(error.localizedDescription)
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDoc, contentType: .macqPreset, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result {
                model.presentError(error.localizedDescription)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Presets")
                .font(.title2.weight(.semibold))
            Spacer()

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Button("Save") {
                let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.saveCurrentPreset(name: trimmed.isEmpty ? "New Preset" : trimmed)
                newPresetName = ""
            }
            .buttonStyle(.borderedProminent)

            Button("Overwrite") {
                model.overwriteSelectedPreset()
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedPresetID == nil)

            Button("Rename") {
                guard let id = model.selectedPresetID,
                      let preset = model.presets.first(where: { $0.id == id }) else { return }
                renamingPresetID = id
                renameDraft = preset.name
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedPresetID == nil)

            Button("Delete") {
                if let id = model.selectedPresetID {
                    model.deletePreset(id: id)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedPresetID == nil)

            Divider()
                .frame(height: 20)

            Button("Import") { isImporting = true }
                .buttonStyle(.bordered)

            Button("Export") {
                guard let doc = model.exportDocumentForSelectedPreset() else { return }
                exportDoc = doc
                exportFilename = "\(doc.preset.name).macqeq"
                isExporting = true
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedPresetID == nil)
        }
    }
}

private struct RenamePresetSheet: View {
    @Binding var name: String
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Preset")
                .font(.title3.weight(.semibold))

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
        .macqRootSurface()
    }
}
