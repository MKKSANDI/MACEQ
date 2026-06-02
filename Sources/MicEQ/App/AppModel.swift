import Combine
import CoreAudio
import Foundation
import AppKit

@MainActor
final class AppModel: ObservableObject {
    enum DriverState: Equatable {
        case unknown
        case notInstalled
        case installed
        case installFailed(String)
    }

    struct InstallProgress: Equatable {
        var fraction: Double
        var phase: String

        static let idle = InstallProgress(fraction: 0, phase: "Idle")
    }

    @Published var driverState: DriverState = .unknown
    @Published var installProgress: InstallProgress = .idle
    @Published var lastError: String?
    @Published var microphonePermission: MicrophonePermission = MicrophonePermission.current()
    @Published var restartPrompt: RestartPrompt?

    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedInputDevice: AudioDevice?

    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedMonitorOutputDevice: AudioDevice?
    @Published var isMonitoringEnabled: Bool = false

    @Published var applicationAudioSources: [AppAudioSource] = []
    @Published var selectedApplicationAudioSourceID: AppAudioSource.ID?
    @Published var isApplicationAudioEnabled: Bool = false
    @Published var isApplicationAudioListExpanded: Bool = true
    @Published var applicationAudioVolume: Double = 0.75
    @Published var applicationAudioStatus: String?

    @Published var isRunning: Bool = false
    @Published var isRestartingAudio: Bool = false
    @Published var isMuted: Bool = false
    @Published var muteHotKey: MACQHotKey?
    @Published var hotKeyStatus: String?
    let meters = MeterModel()

    @Published var eqSettings: EQSettings = .default

    @Published var presets: [EQPreset] = []
    @Published var selectedPresetID: EQPreset.ID?

    @Published var geminiModel: String = "gemini-2.5-flash"
    @Published var isAISuggesting: Bool = false
    @Published var aiStatus: String?
    @Published var aiAnalysis: MicAudioAnalysis?
    @Published var aiSuggestedSettings: EQSettings?
    @Published var aiSuggestedGoal: String?

    @Published var aiChatPresetID: EQPreset.ID?
    @Published var aiChatMessages: [AIPresetChatMessage] = []
    @Published var isAIChatWorking: Bool = false
    @Published var aiChatStatus: String?

    private let driverInstaller = DriverInstaller()
    private let deviceService = CoreAudioDeviceService()
    private let audioEngine = MicEQAudioEngine()
    private let applicationAudioCapture = ApplicationAudioCapture()
    private let micSampleRecorder = MicSampleRecorder()
    private let micPermissionService = MicrophonePermissionService()
    private let hotKeyManager = GlobalHotKeyManager()
    private lazy var geminiKeyStore = KeychainStringStore(
        service: Bundle.main.bundleIdentifier ?? "com.macq.app",
        account: "gemini-api-key"
    )

    private let muteHotKeyDefaultsKey = "macq.muteHotKey"
    private var didRunLaunchPermissionFlow = false
    private var didAttemptAutoSetup = false
    private var aiChatCache: [EQPreset.ID: [AIPresetChatMessage]] = [:]

    init() {
        loadPresets()
        loadMuteHotKey()
        registerMuteHotKey()
        Task { await refresh() }
    }

    func presentError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = trimmed.isEmpty ? "Unknown error" : trimmed

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastError ?? "", forType: .string)
    }

    func refresh() async {
        do {
            microphonePermission = micPermissionService.status()
            if driverInstaller.isInstalled {
                // Presence of the bundle isn't enough — make sure CoreAudio has actually loaded it.
                if (try? deviceService.findDevice(named: CoreAudioDeviceService.micEQDeviceName)) != nil {
                    driverState = .installed
                } else {
                    driverState = .installFailed("Driver bundle found, but MicEQ device isn’t loaded yet. Try clicking Install again or restart CoreAudio (coreaudiod).")
                }
            } else {
                driverState = .notInstalled
            }
            inputDevices = try deviceService.listInputDevices()
            outputDevices = try deviceService.listOutputDevices()
            refreshApplicationAudioSources()

            if selectedInputDevice == nil {
                if let defaultID = try? deviceService.defaultInputDeviceID(),
                   let match = inputDevices.first(where: { $0.id == defaultID }) {
                    selectedInputDevice = match
                } else {
                    selectedInputDevice = inputDevices.first
                }
            }

            if selectedMonitorOutputDevice == nil {
                let defaultID = try? deviceService.defaultOutputDeviceID()
                let preferred = defaultID.flatMap { id in outputDevices.first(where: { $0.id == id }) }
                selectedMonitorOutputDevice = pickBestMonitorOutput(preferred: preferred, from: outputDevices)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func requestLaunchPermissionsIfNeeded() async {
        guard didRunLaunchPermissionFlow == false else { return }
        didRunLaunchPermissionFlow = true

        microphonePermission = micPermissionService.status()
        if microphonePermission == .notDetermined {
            microphonePermission = await micPermissionService.requestAccess()
        }
    }

    struct RestartPrompt: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    func restartNow() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func pickBestMonitorOutput(preferred: AudioDevice?, from devices: [AudioDevice]) -> AudioDevice? {
        func isGood(_ d: AudioDevice) -> Bool {
            // Monitoring through Bluetooth / AirPlay / Aggregate devices is usually very laggy.
            d.isOutput && d.isHighLatencyTransport == false
        }

        if let preferred, isGood(preferred) { return preferred }

        if let builtIn = devices.first(where: { isGood($0) && $0.isBuiltInTransport }) { return builtIn }
        if let firstGood = devices.first(where: { isGood($0) }) { return firstGood }
        return preferred ?? devices.first
    }

    func installDriver() async {
        lastError = nil
        installProgress = InstallProgress(fraction: 0.02, phase: "Preparing…")

        do {
            try await driverInstaller.install(progress: { [weak self] fraction, phase in
                Task { @MainActor in
                    self?.installProgress = InstallProgress(fraction: fraction, phase: phase)
                }
            })
            driverState = .installed
            installProgress = InstallProgress(fraction: 1.0, phase: "Installed")
        } catch {
            presentError(error.localizedDescription)
            driverState = .installFailed(error.localizedDescription)
            installProgress = .idle
        }
    }

    func quickSetup() async {
        await requestLaunchPermissionsIfNeeded()
        if microphonePermission != .authorized {
            presentError("Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }
        await installDriver()
        await refresh()
    }

    func autoSetupIfNeeded() async {
        guard didAttemptAutoSetup == false else { return }
        guard driverState != .installed else { return }
        didAttemptAutoSetup = true
        await quickSetup()
    }

    func uninstallDriver() async {
        lastError = nil
        if isRunning { stop() }
        installProgress = InstallProgress(fraction: 0.02, phase: "Preparing uninstall…")

        do {
            try await driverInstaller.uninstall(progress: { [weak self] fraction, phase in
                Task { @MainActor in
                    self?.installProgress = InstallProgress(fraction: fraction, phase: phase)
                }
            })
            installProgress = InstallProgress(fraction: 1.0, phase: "Uninstalled")
            await refresh()
            restartPrompt = RestartPrompt(
                title: "Restart MACQ",
                message: "MicEQ was uninstalled. Restart MACQ to refresh CoreAudio state."
            )
        } catch {
            presentError(error.localizedDescription)
            installProgress = .idle
        }
    }

    func reinstallDriver() async {
        lastError = nil
        if isRunning { stop() }
        installProgress = InstallProgress(fraction: 0.02, phase: "Preparing reinstall…")
        await installDriver()
        await refresh()
    }

    func start() async {
        guard case .installed = driverState else { return }
        guard let inputDevice = selectedInputDevice else { return }

        lastError = nil
        do {
            let micEQDevice = try deviceService.findDevice(named: CoreAudioDeviceService.micEQDeviceName)
            let monitorID: AudioDeviceID?
            if isMonitoringEnabled {
                if let chosen = selectedMonitorOutputDevice?.id {
                    monitorID = chosen
                } else {
                    // If user hasn't explicitly chosen an output yet, pick a low-latency default.
                    let best = pickBestMonitorOutput(preferred: nil, from: outputDevices)
                    selectedMonitorOutputDevice = best
                    monitorID = best?.id
                }
            } else {
                monitorID = nil
            }
            try audioEngine.start(
                inputDeviceID: inputDevice.id,
                outputDeviceID: micEQDevice.id,
                monitorOutputDeviceID: monitorID,
                eqSettings: eqSettings,
                meters: { [weak self] inputDB, outputDB in
                    DispatchQueue.main.async {
                        self?.meters.inputLevelDB = inputDB
                        self?.meters.outputLevelDB = outputDB
                    }
                }
            )
            audioEngine.setMuted(isMuted)
            audioEngine.setApplicationAudioVolume(applicationAudioVolume)
            try startApplicationAudioCaptureIfNeeded()
            isRunning = true
        } catch {
            presentError(error.localizedDescription)
            isRunning = false
        }
    }

    func stop() {
        applicationAudioCapture.stop()
        audioEngine.resetApplicationAudioBuffer()
        audioEngine.stop()
        isRunning = false
    }

    func toggleMute() {
        isMuted.toggle()
        audioEngine.setMuted(isMuted)
    }

    func restartAudio() async {
        guard isRestartingAudio == false else { return }
        isRestartingAudio = true
        let shouldResume = isRunning
        lastError = nil
        applicationAudioStatus = nil

        applicationAudioCapture.stop()
        audioEngine.resetApplicationAudioBuffer()
        audioEngine.stop()
        isRunning = false
        meters.inputLevelDB = -90
        meters.outputLevelDB = -90

        try? await Task.sleep(for: .milliseconds(220))
        await refresh()

        if shouldResume {
            await start()
        }

        isRestartingAudio = false
    }

    var muteHotKeyDisplay: String {
        muteHotKey?.displayString ?? "Not set"
    }

    func setMuteHotKey(_ hotKey: MACQHotKey?) {
        muteHotKey = hotKey
        persistMuteHotKey()
        registerMuteHotKey()
    }

    func clearMuteHotKey() {
        setMuteHotKey(nil)
    }

    private func loadMuteHotKey() {
        guard let data = UserDefaults.standard.data(forKey: muteHotKeyDefaultsKey) else { return }
        muteHotKey = try? JSONDecoder().decode(MACQHotKey.self, from: data)
    }

    private func persistMuteHotKey() {
        guard let muteHotKey else {
            UserDefaults.standard.removeObject(forKey: muteHotKeyDefaultsKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(muteHotKey)
            UserDefaults.standard.set(data, forKey: muteHotKeyDefaultsKey)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func registerMuteHotKey() {
        do {
            try hotKeyManager.register(muteHotKey) { [weak self] in
                Task { @MainActor in
                    self?.toggleMute()
                }
            }
            hotKeyStatus = muteHotKey == nil ? "No mute hotkey set." : "Mute hotkey active: \(muteHotKeyDisplay)"
        } catch {
            hotKeyStatus = "Could not register \(muteHotKeyDisplay): \(error.localizedDescription)"
            presentError(hotKeyStatus ?? error.localizedDescription)
        }
    }

    // MARK: - Application Audio

    var selectedApplicationAudioSource: AppAudioSource? {
        guard let id = selectedApplicationAudioSourceID else { return nil }
        return applicationAudioSources.first(where: { $0.id == id })
    }

    func refreshApplicationAudioSources() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.processIdentifier > 0 &&
                app.processIdentifier != currentPID &&
                app.isTerminated == false &&
                app.localizedName != nil &&
                (app.activationPolicy == .regular || app.activationPolicy == .accessory)
            }
            .map(AppAudioSource.init(app:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        applicationAudioSources = apps

        if let selectedApplicationAudioSourceID,
           apps.contains(where: { $0.id == selectedApplicationAudioSourceID }) == false {
            self.selectedApplicationAudioSourceID = nil
            applicationAudioCapture.stop()
            applicationAudioStatus = "Selected app closed."
        }

        if selectedApplicationAudioSourceID == nil {
            selectedApplicationAudioSourceID = apps.first?.id
        }
    }

    func selectApplicationAudioSource(_ id: AppAudioSource.ID) {
        selectedApplicationAudioSourceID = id
        if isRunning && isApplicationAudioEnabled {
            do {
                try restartApplicationAudioCapture()
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    func setApplicationAudioEnabled(_ enabled: Bool) {
        isApplicationAudioEnabled = enabled
        applicationAudioStatus = nil

        if enabled == false {
            applicationAudioCapture.stop()
            audioEngine.resetApplicationAudioBuffer()
            return
        }

        refreshApplicationAudioSources()
        if isRunning {
            do {
                try restartApplicationAudioCapture()
            } catch {
                presentError(error.localizedDescription)
            }
        } else {
            applicationAudioStatus = "Ready. Press Start to mix app audio into MicEQ."
        }
    }

    func setApplicationAudioVolume(_ volume: Double) {
        applicationAudioVolume = max(0, min(2, volume))
        audioEngine.setApplicationAudioVolume(applicationAudioVolume)
    }

    private func startApplicationAudioCaptureIfNeeded() throws {
        guard isApplicationAudioEnabled else {
            applicationAudioCapture.stop()
            audioEngine.resetApplicationAudioBuffer()
            applicationAudioStatus = nil
            return
        }

        refreshApplicationAudioSources()
        try restartApplicationAudioCapture()
    }

    private func restartApplicationAudioCapture() throws {
        guard let source = selectedApplicationAudioSource else {
            applicationAudioStatus = "Choose an app first."
            return
        }

        audioEngine.resetApplicationAudioBuffer()
        audioEngine.setApplicationAudioVolume(applicationAudioVolume)
        try applicationAudioCapture.start(processID: source.processIdentifier) { [audioEngine] samples, frameCount in
            audioEngine.writeApplicationAudio(samples, frameCount: frameCount)
        }
        applicationAudioStatus = "Playing \(source.name) through MicEQ."
    }

    func applyEQSettings(_ newSettings: EQSettings) {
        let sanitized = newSettings.sanitized(maxBands: 96)
        eqSettings = sanitized
        audioEngine.updateEQSettings(sanitized)
    }

    func previewEQSettings(_ newSettings: EQSettings) {
        audioEngine.updateEQSettings(newSettings.sanitized(maxBands: 96))
    }

    // MARK: - Gemini AI

    func hasGeminiAPIKey() -> Bool {
        guard let key = geminiKeyStore.read() else { return false }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func storeGeminiAPIKey(_ key: String) {
        do {
            try geminiKeyStore.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func clearGeminiAPIKey() {
        geminiKeyStore.delete()
    }

    func suggestEQWithGemini(goal: String, seconds: Double = 5.0) async {
        lastError = nil
        aiStatus = "Preparing…"
        aiAnalysis = nil
        aiSuggestedSettings = nil
        aiSuggestedGoal = goal

        guard let apiKey = geminiKeyStore.read(),
              apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            presentError("Missing Gemini API key. Add it in Settings → Gemini.")
            aiStatus = nil
            return
        }
        guard let input = selectedInputDevice else {
            presentError("Select an input device first.")
            aiStatus = nil
            return
        }

        let wasRunning = isRunning
        if wasRunning {
            stop()
            try? await Task.sleep(for: .milliseconds(150))
        }

        isAISuggesting = true
        defer {
            isAISuggesting = false
            aiStatus = nil
            if wasRunning {
                Task { await start() }
            }
        }

        do {
            aiStatus = "Recording sample…"
            let wav = try await micSampleRecorder.recordWAV(deviceID: input.id, seconds: seconds)

            aiStatus = "Analyzing audio…"
            let analysis = try await Task.detached(priority: .userInitiated) {
                try MicAudioAnalyzer.analyzeWAV16Mono(wav)
            }.value
            aiAnalysis = analysis

            aiStatus = "Asking Gemini…"
            let assistant = GeminiEQAssistant(config: .init(apiKey: apiKey, model: geminiModel))
            let deviceContext = "name=\(input.name), transportType=\(input.transportType), bluetooth=\(input.isBluetoothTransport), airplay=\(input.isAirPlayTransport), aggregate=\(input.isAggregateTransport), builtIn=\(input.isBuiltInTransport)"
            let suggested = try await assistant.suggestEQ(
                audioWAV: wav,
                goal: goal,
                current: eqSettings,
                analysis: analysis,
                deviceContext: deviceContext
            )

            aiStatus = "Ready"
            aiSuggestedSettings = suggested
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func applyAISuggestedSettings() {
        guard let s = aiSuggestedSettings else { return }
        applyEQSettings(s)
    }

    func saveAISuggestedSettingsAsPreset(name: String) {
        guard let s = aiSuggestedSettings else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = EQPreset(name: trimmed.isEmpty ? "AI Preset" : trimmed, settings: s, origin: .ai)
        presets.insert(preset, at: 0)
        selectedPresetID = preset.id
        activateAIChat(for: preset.id)
        persistPresets()
    }

    // MARK: - Presets

    func applyPreset(id: EQPreset.ID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        selectedPresetID = id
        applyEQSettings(preset.settings)
        if preset.origin == .ai {
            activateAIChat(for: id)
        }
    }

    func saveCurrentPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = EQPreset(name: trimmed.isEmpty ? "New Preset" : trimmed, settings: eqSettings, origin: .user)
        presets.insert(preset, at: 0)
        selectedPresetID = preset.id
        persistPresets()
    }

    func overwriteSelectedPreset() {
        guard let id = selectedPresetID, let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].settings = eqSettings
        presets[idx].updatedAt = Date()
        persistPresets()
    }

    func deletePreset(id: EQPreset.ID) {
        presets.removeAll { $0.id == id }
        if selectedPresetID == id { selectedPresetID = nil }
        if aiChatPresetID == id {
            aiChatPresetID = nil
            aiChatMessages = []
        }
        aiChatCache[id] = nil
        persistPresets()
    }

    func renamePreset(id: EQPreset.ID, newName: String) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        presets[idx].name = trimmed
        presets[idx].updatedAt = Date()
        persistPresets()
    }

    func importPreset(_ preset: EQPreset) {
        var incoming = preset
        if presets.contains(where: { $0.id == incoming.id }) {
            incoming = EQPreset(name: incoming.name, settings: incoming.settings, origin: incoming.origin)
        }
        presets.insert(incoming, at: 0)
        selectedPresetID = incoming.id
        applyEQSettings(incoming.settings)
        if incoming.origin == .ai {
            activateAIChat(for: incoming.id)
        }
        persistPresets()
    }

    func exportDocumentForSelectedPreset() -> EQPresetDocument? {
        guard let id = selectedPresetID, let preset = presets.first(where: { $0.id == id }) else { return nil }
        return EQPresetDocument(preset: preset)
    }

    private func presetsFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dirName = Bundle.main.bundleIdentifier ?? "com.macq.app"
        let dir = base.appendingPathComponent(dirName, isDirectory: true)
        return dir.appendingPathComponent("presets.json")
    }

    private func loadPresets() {
        let url = presetsFileURL()
        var shouldPersistAfterLoad = false
        let data: Data?
        if let d = try? Data(contentsOf: url) {
            data = d
        } else {
            // Migration from older bundle id.
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let legacy = base.appendingPathComponent("com.miceq.app", isDirectory: true).appendingPathComponent("presets.json")
            data = try? Data(contentsOf: legacy)
            shouldPersistAfterLoad = (data != nil)
        }
        guard let data else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            presets = try decoder.decode([EQPreset].self, from: data)
            if shouldPersistAfterLoad {
                persistPresets()
            }
        } catch {
            // Ignore corrupt presets file; user can re-import.
            presets = []
        }
    }

    private func persistPresets() {
        let url = presetsFileURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(presets)
            try data.write(to: url, options: [.atomic])
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - AI Preset Chat

    var selectedPreset: EQPreset? {
        guard let id = selectedPresetID else { return nil }
        return presets.first(where: { $0.id == id })
    }

    func activateAIChat(for presetID: EQPreset.ID) {
        aiChatPresetID = presetID
        if let cached = aiChatCache[presetID] {
            aiChatMessages = cached
        } else if let preset = presets.first(where: { $0.id == presetID }), preset.chatHistory.isEmpty == false {
            aiChatMessages = preset.chatHistory
            aiChatCache[presetID] = preset.chatHistory
        } else {
            let intro = defaultAIChatIntro(for: presetID)
            aiChatMessages = intro
            storeAIChatMessages(intro, for: presetID, persist: true)
        }
    }

    func clearActiveChat() {
        aiChatPresetID = nil
        aiChatMessages = []
    }

    private func defaultAIChatIntro(for presetID: EQPreset.ID) -> [AIPresetChatMessage] {
        let presetName = presets.first(where: { $0.id == presetID })?.name ?? "this preset"
        return [
            AIPresetChatMessage(
                role: .system,
                markdown: """
You’re editing **\(presetName)**. I remember this chat for this preset and use the current preset settings as context. Ask for changes like “reduce typing noise”, “make it warmer”, “more radio voice”, or “duplicate this as a crisp podcast preset”.
"""
            )
        ]
    }

    private func storeAIChatMessages(
        _ messages: [AIPresetChatMessage],
        for presetID: EQPreset.ID,
        persist: Bool
    ) {
        aiChatCache[presetID] = messages
        if let idx = presets.firstIndex(where: { $0.id == presetID }) {
            presets[idx].chatHistory = messages
            presets[idx].updatedAt = Date()
            if persist {
                persistPresets()
            }
        }
    }

    func sendAIChatMessage(_ text: String) async {
        lastError = nil
        guard let presetID = aiChatPresetID,
              let preset = presets.first(where: { $0.id == presetID }) else {
            presentError("Select an AI preset first.")
            return
        }
        guard let apiKey = geminiKeyStore.read(),
              apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            presentError("Missing Gemini API key. Add it in Settings → Gemini.")
            return
        }

        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false else { return }

        isAIChatWorking = true
        aiChatStatus = "Reading preset…"
        let priorHistory = aiChatMessages
        let userMsg = AIPresetChatMessage(role: .user, markdown: message)
        aiChatMessages.append(userMsg)
        storeAIChatMessages(aiChatMessages, for: presetID, persist: true)

        let input = selectedInputDevice
        let deviceContext = input.map { dev in
            "name=\(dev.name), transportType=\(dev.transportType), bluetooth=\(dev.isBluetoothTransport), airplay=\(dev.isAirPlayTransport), aggregate=\(dev.isAggregateTransport), builtIn=\(dev.isBuiltInTransport)"
        }

        do {
            try? await Task.sleep(for: .milliseconds(250))
            aiChatStatus = "Reviewing chat history…"
            try? await Task.sleep(for: .milliseconds(250))
            aiChatStatus = "Thinking with Gemini…"
            let assistant = GeminiEQAssistant(config: .init(apiKey: apiKey, model: geminiModel))
            let result = try await assistant.editPreset(
                message: message,
                currentPresetName: preset.name,
                current: preset.settings,
                analysis: aiAnalysis,
                deviceContext: deviceContext,
                chatHistory: priorHistory
            )

            aiChatStatus = "Comparing changes…"
            let assistantMsg = AIPresetChatMessage(
                role: .assistant,
                markdown: result.assistantMarkdown,
                proposedSettings: result.settings,
                baseSettings: preset.settings,
                proposedPresetName: result.presetName,
                proposedActionRaw: result.action.rawValue
            )
            aiChatMessages.append(assistantMsg)
            storeAIChatMessages(aiChatMessages, for: presetID, persist: true)
        } catch {
            presentError(error.localizedDescription)
        }

        isAIChatWorking = false
        aiChatStatus = nil
    }

    func applyProposedSettings(from messageID: AIPresetChatMessage.ID) {
        guard let presetID = aiChatPresetID,
              let idx = presets.firstIndex(where: { $0.id == presetID }),
              let msg = aiChatMessages.first(where: { $0.id == messageID }),
              let proposed = msg.proposedSettings else { return }

        presets[idx].settings = proposed
        presets[idx].origin = .ai
        presets[idx].updatedAt = Date()

        selectedPresetID = presetID
        applyEQSettings(proposed)

        aiChatMessages.append(AIPresetChatMessage(
            role: .system,
            markdown: "Applied this AI update to **\(presets[idx].name)**."
        ))
        storeAIChatMessages(aiChatMessages, for: presetID, persist: true)
    }

    func duplicatePresetFromProposal(from messageID: AIPresetChatMessage.ID) {
        guard let msg = aiChatMessages.first(where: { $0.id == messageID }),
              let proposed = msg.proposedSettings else { return }

        let baseName = msg.proposedPresetName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (baseName?.isEmpty == false) ? baseName! : "AI Preset (Updated)"
        var history = aiChatMessages
        history.append(AIPresetChatMessage(
            role: .system,
            markdown: "Created **\(name)** from this AI update."
        ))
        let preset = EQPreset(name: name, settings: proposed, origin: .ai, chatHistory: history)
        presets.insert(preset, at: 0)
        selectedPresetID = preset.id
        applyEQSettings(proposed)
        activateAIChat(for: preset.id)
        persistPresets()
    }
}
