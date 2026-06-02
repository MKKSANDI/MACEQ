import CoreAudio
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meters: MeterModel
    @State private var tab: Tab = .eq
    @State private var quickPreamp: Double = 0
    @State private var quickOutput: Double = 0
    @State private var quickBass: Double = 0
    @State private var isEditingQuick: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 330, ideal: 360)
        } detail: {
            Group {
                switch tab {
                case .eq:
                    ProcessingView()
                case .ai:
                    AIAssistantView()
                case .aiChat:
                    AIPresetChatView()
                case .presets:
                    PresetsView()
                }
            }
            .navigationTitle(tab.title)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                topTabBar
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.restartAudio() }
                } label: {
                    Label("Restart Audio", systemImage: "arrow.clockwise")
                }
                .buttonStyle(MACQToolbarIconButtonStyle())
                .disabled(model.isRestartingAudio)
                .help("Restart MACQ audio routing if monitoring or app audio glitches.")

                Button {
                    if model.isRunning {
                        model.stop()
                    } else {
                        Task { await model.start() }
                    }
                } label: {
                    Text(model.isRunning ? "Stop" : "Start")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .opacity(model.isRunning ? 0.85 : 1.0)
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .macqRootSurface()
        .onChange(of: model.selectedPresetID) { _ in
            if tab == .aiChat, model.selectedPreset?.origin != .ai {
                tab = .eq
            }
        }
        .onAppear {
            syncQuickControlsFromModel()
        }
        .onChange(of: model.eqSettings) { _ in
            guard isEditingQuick == false else { return }
            syncQuickControlsFromModel()
        }
    }

    private enum Tab: Hashable {
        case eq
        case ai
        case aiChat
        case presets

        var title: String {
            switch self {
            case .eq: return "EQ"
            case .ai: return "AI"
            case .aiChat: return "AI Chat"
            case .presets: return "Presets"
            }
        }
    }

    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.eq, .ai]
        if model.selectedPreset?.origin == .ai {
            tabs.append(.aiChat)
        }
        tabs.append(.presets)
        return tabs
    }

    private var topTabBar: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        tab = item
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tab == item ? Color.black.opacity(0.86) : Color.white.opacity(0.82))
                        .frame(width: item == .aiChat ? 86 : 72, height: 30)
                        .background {
                            if tab == item {
                                Capsule()
                                    .fill(MACQTheme.electricCyan)
                                    .shadow(color: Color.cyan.opacity(0.28), radius: 10, y: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(MACQTheme.controlGradient)
        .overlay {
            Capsule().stroke(MACQTheme.panelStroke, lineWidth: 1)
        }
        .clipShape(Capsule())
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                processingBox
                monitoringBox
                applicationAudioBox
                signalBox
                quickControlsBox
                micEQInfoBox
            }
            .padding(12)
        }
        .background(Color.clear)
    }

    private var processingBox: some View {
        GroupBox("Processing") {
            VStack(alignment: .leading, spacing: 10) {
                SidebarControlRow("Input") {
                    Picker("Input", selection: Binding<AudioDeviceID?>(
                        get: { model.selectedInputDevice?.id },
                        set: { newID in
                            model.selectedInputDevice = newID.flatMap { id in
                                model.inputDevices.first(where: { $0.id == id })
                            }
                        }
                    )) {
                        ForEach(model.inputDevices, id: \.id) { dev in
                            Text(dev.name).tag(Optional(dev.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button {
                        if model.isRunning {
                            model.stop()
                        } else {
                            Task { await model.start() }
                        }
                    } label: {
                        Text(model.isRunning ? "Stop Processing" : "Start Processing")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Refresh Devices") {
                        Task { await model.refresh() }
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 122)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await model.restartAudio() }
                    } label: {
                        Label(model.isRestartingAudio ? "Restarting…" : "Restart Audio", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRestartingAudio)

                    Text(model.isRunning ? "Running" : "Stopped")
                        .font(.footnote)
                        .foregroundStyle(model.isMuted ? .orange : .secondary)

                    if model.isMuted {
                        Text("Muted")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var monitoringBox: some View {
        GroupBox("Monitoring (hear yourself)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Live Monitor", isOn: $model.isMonitoringEnabled)

                SidebarControlRow("Output") {
                    Picker("Monitor Output", selection: Binding<AudioDeviceID?>(
                        get: { model.selectedMonitorOutputDevice?.id },
                        set: { newID in
                            model.selectedMonitorOutputDevice = newID.flatMap { id in
                                model.outputDevices.first(where: { $0.id == id })
                            }
                        }
                    )) {
                        ForEach(model.outputDevices, id: \.id) { dev in
                            Text(dev.name).tag(Optional(dev.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Tip: use headphones to avoid feedback.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.isMonitoringEnabled {
                    if model.selectedMonitorOutputDevice?.isBluetoothTransport == true {
                        Text("Bluetooth outputs add a lot of delay. For low-latency monitoring, use built-in output or wired headphones.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if model.selectedMonitorOutputDevice?.isAggregateTransport == true {
                        Text("Multi-Output / Aggregate devices add a lot of delay. Pick a physical output device for snappier monitoring.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if model.selectedMonitorOutputDevice?.isAirPlayTransport == true {
                        Text("AirPlay outputs add a lot of delay. Pick a wired/built-in output device for low-latency monitoring.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var applicationAudioBox: some View {
        GroupBox("Application Audio") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Play Application Audio", isOn: Binding(
                    get: { model.isApplicationAudioEnabled },
                    set: { model.setApplicationAudioEnabled($0) }
                ))

                if model.isApplicationAudioEnabled {
                    DisclosureGroup(isExpanded: $model.isApplicationAudioListExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Select App")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Refresh") {
                                    model.refreshApplicationAudioSources()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(model.applicationAudioSources) { source in
                                        Button {
                                            model.selectApplicationAudioSource(source.id)
                                        } label: {
                                            AppAudioSourceRow(
                                                source: source,
                                                isSelected: model.selectedApplicationAudioSourceID == source.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .frame(maxHeight: 180)
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = model.selectedApplicationAudioSource?.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Text(model.selectedApplicationAudioSource?.name ?? "Choose an app")
                                .lineLimit(1)
                        }
                    }

                    SidebarControlRow("App Volume") {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { model.applicationAudioVolume },
                                    set: { model.setApplicationAudioVolume($0) }
                                ),
                                in: 0...2,
                                step: 0.01
                            )

                            Text("\(Int(model.applicationAudioVolume * 100))%")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }

                    if let status = model.applicationAudioStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var signalBox: some View {
        GroupBox("Signal") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedInputDevice?.name ?? "—")
                        .font(.headline)
                        .lineLimit(2)

                    if model.selectedInputDevice?.isBluetoothTransport == true {
                        Text("Bluetooth mics can be laggy + low quality. Prefer built-in mic or a wired/USB interface.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    MeterCard(title: "In", db: meters.inputLevelDB)
                    MeterCard(title: "Out", db: meters.outputLevelDB)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var quickControlsBox: some View {
        GroupBox("Quick Controls") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.eqSettings.isBypassed == false },
                    set: { enabled in
                        var next = model.eqSettings
                        next.isBypassed = !enabled
                        model.applyEQSettings(next)
                    }
                )) {
                    Text("EQ Enabled")
                }

                SidebarControlRow("Preamp") {
                    Slider(value: $quickPreamp, in: -24...24, step: 0.5, onEditingChanged: { editing in
                        isEditingQuick = editing
                        if editing == false { commitQuickControls(preamp: true, output: false, bass: false) }
                    })
                }

                if let bassIdx = model.eqSettings.bands.firstIndex(where: { $0.type == .lowShelf }) {
                    SidebarControlRow("Bass") {
                        Slider(value: $quickBass, in: -18...18, step: 0.5, onEditingChanged: { editing in
                            isEditingQuick = editing
                            if editing == false { commitQuickControls(preamp: false, output: false, bass: true, bassIdx: bassIdx) }
                        })
                    }
                }

                SidebarControlRow("Output") {
                    Slider(value: $quickOutput, in: -24...24, step: 0.5, onEditingChanged: { editing in
                        isEditingQuick = editing
                        if editing == false { commitQuickControls(preamp: false, output: true, bass: false) }
                    })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func syncQuickControlsFromModel() {
        quickPreamp = model.eqSettings.preampDB
        quickOutput = model.eqSettings.outputGainDB
        if let bassIdx = model.eqSettings.bands.firstIndex(where: { $0.type == .lowShelf }) {
            quickBass = model.eqSettings.bands[bassIdx].gainDB
        } else {
            quickBass = 0
        }
    }

    private func commitQuickControls(preamp: Bool, output: Bool, bass: Bool, bassIdx: Int? = nil) {
        var next = model.eqSettings
        if preamp { next.preampDB = quickPreamp }
        if output { next.outputGainDB = quickOutput }
        if bass, let bassIdx {
            next.bands[bassIdx].isEnabled = true
            next.bands[bassIdx].type = .lowShelf
            next.bands[bassIdx].gainDB = quickBass
            next.bands[bassIdx].frequencyHz = max(20, min(200, next.bands[bassIdx].frequencyHz))
        }
        model.applyEQSettings(next)
    }

    private var micEQInfoBox: some View {
        GroupBox("MicEQ Device") {
            Text("Select “MicEQ” as your microphone in Zoom/Discord/OBS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }
}

private struct SidebarControlRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 92, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MACQToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(MACQTheme.electricCyan)
            .frame(width: 32, height: 32)
            .background(MACQTheme.controlGradient)
            .overlay {
                Circle().stroke(MACQTheme.panelStroke, lineWidth: 1)
            }
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MeterCard: View {
    let title: String
    let db: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f dB", db))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LevelMeterView(levelDB: db)
                .frame(height: 10)
        }
        .padding(10)
        .macqPanel(cornerRadius: 10)
    }
}

private struct AppAudioSourceRow: View {
    let source: AppAudioSource
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let icon = source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "app")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            Text(source.name)
                .lineLimit(1)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .macqPanel(cornerRadius: 8, selected: isSelected)
    }
}
