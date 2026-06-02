import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var geminiKeyDraft: String = ""
    @State private var isDriverWorking: Bool = false
    @State private var showingUninstallConfirm: Bool = false

    private let geminiModels: [String] = [
        // Gemini 3.x
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite",

        // Gemini 2.5
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Driver") {
                LabeledContent("Status") {
                    Text(statusText)
                }
                LabeledContent("Microphone") {
                    Text(micPermText)
                }
                if isDriverWorking || model.installProgress.fraction > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.installProgress.fraction)
                        Text(model.installProgress.phase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button(model.driverState == .installed ? "Reinstall Driver" : "Install Driver") {
                        Task {
                            isDriverWorking = true
                            defer { isDriverWorking = false }
                            if model.driverState == .installed {
                                await model.reinstallDriver()
                            } else {
                                await model.quickSetup()
                            }
                        }
                    }

                    Button("Uninstall Driver", role: .destructive) {
                        showingUninstallConfirm = true
                    }
                    .disabled(model.driverState != .installed)
                }
                Button("Re-check Driver") {
                    Task { await model.refresh() }
                }
            }
            .confirmationDialog(
                "Uninstall MicEQ driver?",
                isPresented: $showingUninstallConfirm,
                titleVisibility: .visible
            ) {
                Button("Uninstall", role: .destructive) {
                    Task {
                        isDriverWorking = true
                        defer { isDriverWorking = false }
                        await model.uninstallDriver()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes /Library/Audio/Plug-Ins/HAL/MicEQ.driver and restarts CoreAudio. Admin permission required.")
            }

            GroupBox("Audio") {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await model.restartAudio() }
                    } label: {
                        Label(model.isRestartingAudio ? "Restarting Audio…" : "Restart Audio Engine", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRestartingAudio)

                    Toggle("Start processing at launch", isOn: .constant(false))
                        .disabled(true)

                    Text("Restart Audio resets capture, processing, monitor output, app-audio mixing, and buffers without quitting MACQ.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Mute Hotkey") {
                HotKeyRecorderView()
            }

            GroupBox("Tools Available to User + AI") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(MACQToolCatalog.sections.reduce(0) { $0 + $1.tools.count }) tools/settings groups. The UI and Gemini use this same catalog.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ForEach(MACQToolCatalog.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.cyan)
                            Text(section.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(section.tools) { tool in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.cyan)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(tool.detail)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .macqPanel(cornerRadius: 12)
                    }
                }
            }

            GroupBox("About") {
                Text("MACQ installs a virtual microphone device (“MicEQ”) and feeds it processed audio from the selected input.")
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Gemini") {
                LabeledContent("API key") {
                    HStack(spacing: 10) {
                        SecureField(model.hasGeminiAPIKey() ? "Saved in Keychain" : "Paste key…", text: $geminiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)

                        Button("Save") {
                            model.storeGeminiAPIKey(geminiKeyDraft)
                            geminiKeyDraft = ""
                        }
                        .disabled(geminiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Clear") {
                            model.clearGeminiAPIKey()
                        }
                        .disabled(model.hasGeminiAPIKey() == false)
                    }
                }

                LabeledContent("Model") {
                    Picker("Model", selection: $model.geminiModel) {
                        if geminiModels.contains(model.geminiModel) == false {
                            Text(model.geminiModel).tag(model.geminiModel)
                        }
                        ForEach(geminiModels, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 320, alignment: .leading)
                }

                Text("Your key is stored in your macOS Keychain. Audio samples are sent to Gemini only when you press Generate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .macqRootSurface()
    }

    private var statusText: String {
        switch model.driverState {
        case .unknown: return "Unknown"
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .installFailed(let reason): return "Install failed: \(reason)"
        }
    }

    private var micPermText: String {
        switch model.microphonePermission {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        }
    }
}
