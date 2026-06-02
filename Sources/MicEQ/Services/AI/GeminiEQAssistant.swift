import Foundation

struct GeminiEQAssistant {
    struct Config: Sendable, Hashable {
        var apiKey: String
        var model: String

        init(apiKey: String, model: String = "gemini-2.5-flash") {
            self.apiKey = apiKey
            self.model = model
        }
    }

    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func suggestEQ(
        audioWAV: Data,
        goal: String,
        current: EQSettings,
        analysis: MicAudioAnalysis,
        deviceContext: String? = nil
    ) async throws -> EQSettings {
        let b64 = audioWAV.base64EncodedString()
        let prompt = buildPrompt(goal: goal, current: current, analysis: analysis, deviceContext: deviceContext)

        // Retry once with a stricter "repair" prompt if the model returns non-JSON or
        // otherwise unparsable output. This makes the feature far more reliable in practice.
        let resp = try await sendGenerateContent(prompt: prompt, audioBase64: b64)
        do {
            let text = try extractResponseText(resp)
            let settings = try decodeEQSettings(fromModelText: text)
            let sanitized = sanitize(settings, maxBands: 96)
            if isTrivialPreset(sanitized) {
                let moreAggressive = prompt + "\n\nImportant: Your previous JSON didn't enable any meaningful processing. Return a non-trivial preset (enable at least a high-pass + some tonal shaping; enable gate/compressor only if needed by noiseFloorDBFS/SNR). Return ONLY valid JSON."
                let repairResp = try await sendGenerateContent(prompt: moreAggressive, audioBase64: b64)
                let repairText = try extractResponseText(repairResp)
                let repaired = try decodeEQSettings(fromModelText: repairText)
                return sanitize(repaired, maxBands: 96)
            }
            return sanitized
        } catch {
            let repairPrompt = prompt + "\n\nImportant: Your previous response could not be parsed as valid JSON for the EQSettings schema. Return ONLY valid JSON now. No commentary, no markdown."
            let repairResp = try await sendGenerateContent(prompt: repairPrompt, audioBase64: b64)
            let text = try extractResponseText(repairResp)
            let settings = try decodeEQSettings(fromModelText: text)
            return sanitize(settings, maxBands: 96)
        }
    }

    struct PresetEditResult: Sendable, Hashable {
        enum Action: String, Sendable, Hashable {
            case none
            case update
            case duplicate
            case rename
            case delete
        }

        var assistantMarkdown: String
        var action: Action
        var presetName: String?
        var settings: EQSettings?
    }

    func editPreset(
        message: String,
        currentPresetName: String,
        current: EQSettings,
        analysis: MicAudioAnalysis?,
        deviceContext: String? = nil,
        chatHistory: [AIPresetChatMessage] = []
    ) async throws -> PresetEditResult {
        let prompt = buildEditPrompt(
            message: message,
            currentPresetName: currentPresetName,
            current: current,
            analysis: analysis,
            deviceContext: deviceContext,
            chatHistory: chatHistory
        )

        let resp = try await sendGenerateContent(prompt: prompt, audioBase64: nil)
        let text = try extractResponseText(resp)
        var out = try await decodePresetEditWithRepair(fromModelText: text, originalPrompt: prompt)

        if requiresChangedSettings(out.action),
           settingsAreMeaningfullyDifferent(current, out.settings) == false {
            let repairPrompt = prompt + """

Previous response problem:
- The action was \(out.action.rawValue), but the settings were missing or effectively unchanged from the current preset.
- Return a corrected JSON response now.
- If the user asked for noise reduction, adjust noiseGate threshold/range/hold/release and/or high-pass filtering.
- If the user asked for bass/warmth, adjust a lowShelf/low-frequency band and compensate output gain if needed.
- If the user asked for clarity/crispness, adjust presence/highShelf/de-esser/compressor as appropriate.
- Do not return the same settings. Return ONLY valid JSON.
"""
            let repairResp = try await sendGenerateContent(prompt: repairPrompt, audioBase64: nil)
            let repairText = try extractResponseText(repairResp)
            out = try await decodePresetEditWithRepair(fromModelText: repairText, originalPrompt: prompt)
        }
        return out
    }

    private func buildPrompt(goal: String, current: EQSettings, analysis: MicAudioAnalysis, deviceContext: String?) -> String {
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceLine = (deviceContext?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return """
You are an expert audio engineer. A user reads a short sentence into a MacBook microphone. You are given a WAV recording of their voice.

Task:
- Propose full mic-processing settings (EQ + dynamics) that transform their mic to match the user's goal.
- Keep the result safe and realistic for voice: avoid extreme boosts; prefer cuts for resonances; keep output gain conservative to prevent clipping.
- If the user goal is empty, optimize for a clean, broadcast-style voice (natural, low noise, intelligible).

Audio analysis (JSON from this sample; use it to guide your choices):
\(analysis.promptJSON)

Current processing settings (JSON; use as a starting point but feel free to change anything):
\(currentSettingsJSON(current))

\(deviceLine.map { "Input device context: \($0)\n" } ?? "")

Shared user/AI tool catalog:
\(MACQToolCatalog.aiPromptText)

Constraints:
- preampDB and outputGainDB should be between -24 and +24.
- Each band: frequencyHz 20..20000, gainDB -24..+24, q 0.1..18, isEnabled true/false.
- Band type must be one of: peaking, lowShelf, highShelf, lowPass, highPass, bandPass, notch.
- noiseGate: { isEnabled, thresholdDB (-80..0), hysteresisDB (0..12), rangeDB (0..80), attackMs (0..50), holdMs (0..500), releaseMs (0..1500) }
- compressor: { isEnabled, thresholdDB (-60..0), ratio (1..20), kneeDB (0..24), attackMs (0..50), releaseMs (5..1000), makeupGainDB (-12..+18) }
- deEsser: { isEnabled, frequencyHz (2000..12000), q (0.3..10), thresholdDB (-60..0), ratio (1..20), attackMs (0..20), releaseMs (10..500), maxReductionDB (0..24) }
- voiceIsolation: { isEnabled, strength (0..100), noiseFloorDB (-90..-10), speechThresholdDB (-80..0), reductionDB (0..80), focusLowHz (40..400), focusHighHz (2000..18000), attackMs (0..80), releaseMs (20..2000), presenceBoostDB (-6..8) }
- You may use all 96 EQ bands. Prefer Voice Isolation for background noise while talking; use Noise Gate only for noise between phrases.
- Return ONLY JSON matching the schema; no extra keys, no markdown.
- Before you output JSON, do a strict self-check: (1) JSON schema correct; (2) settings plausibly help the goal; (3) avoid clipping given peakDBFS; (4) avoid harshness/sibilance.

User goal: "\(goalText.isEmpty ? "clean, broadcast-style voice" : goalText)"
"""
    }

    private func buildEditPrompt(
        message: String,
        currentPresetName: String,
        current: EQSettings,
        analysis: MicAudioAnalysis?,
        deviceContext: String?,
        chatHistory: [AIPresetChatMessage]
    ) -> String {
        let userMsg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMsg = userMsg.isEmpty ? "Make it sound cleaner and more natural." : userMsg
        let deviceLine = (deviceContext?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let analysisBlock = analysis.map { "Audio analysis JSON (from the most recent sample):\n\($0.promptJSON)\n\n" } ?? ""
        let historyBlock = chatHistoryPrompt(chatHistory)

        return """
You are an expert audio engineer and preset editor.

You are chatting with a user about a mic-processing preset for macOS. You will receive:
- The current preset name
- The current processing settings (JSON)
- The prior chat history for this same preset, including previous assistant proposals
- Optional audio analysis JSON from a recorded sample
- Optional device context

Task:
- Respond conversationally in Markdown (short, friendly, actionable).
- If the user requests changes, output the full updated EQSettings JSON.
- The user may ask you to update the current preset, duplicate it into a new preset, rename it, or delete it.
- Treat the current processing settings as the source of truth, then use the chat history to understand what the user means by "more", "less", "keep that", "undo that part", or "make another version".
- Do not claim you changed something unless the settings JSON actually changes that control.
- Keep assistantMarkdown readable: max 900 characters, 2 short paragraphs max, use blank lines between paragraphs, and use concise bullets only when useful.
- Avoid repeated apology walls. If the user says it sounds bad, acknowledge it in one sentence, then state the concrete controls changed.

Return ONLY JSON with this schema (no markdown outside JSON):
{
  "assistantMarkdown": "string (markdown)",
  "action": "none|update|duplicate|rename|delete",
  "presetName": "optional string (used for rename or duplicate)",
  "settings": "optional EQSettings object (required for update/duplicate)"
}

Rules:
- Always include assistantMarkdown.
- If action is update or duplicate, include settings.
- If action is duplicate, include presetName for the new preset.
- If action is rename, include presetName (new name), settings omitted.
- If action is delete, settings omitted.

Constraints (must obey):
- preampDB and outputGainDB: -24..+24
- Each EQ band: frequencyHz 20..20000, gainDB -24..+24, q 0.1..18, isEnabled true/false.
- Band type must be one of: peaking, lowShelf, highShelf, lowPass, highPass, bandPass, notch.
- noiseGate: { isEnabled, thresholdDB (-80..0), hysteresisDB (0..12), rangeDB (0..80), attackMs (0..50), holdMs (0..500), releaseMs (0..1500) }
- compressor: { isEnabled, thresholdDB (-60..0), ratio (1..20), kneeDB (0..24), attackMs (0..50), releaseMs (5..1000), makeupGainDB (-12..+18) }
- deEsser: { isEnabled, frequencyHz (2000..12000), q (0.3..10), thresholdDB (-60..0), ratio (1..20), attackMs (0..20), releaseMs (10..500), maxReductionDB (0..24) }
- voiceIsolation: { isEnabled, strength (0..100), noiseFloorDB (-90..-10), speechThresholdDB (-80..0), reductionDB (0..80), focusLowHz (40..400), focusHighHz (2000..18000), attackMs (0..80), releaseMs (20..2000), presenceBoostDB (-6..8) }
- You may use all 96 EQ bands. Prefer a focused set of enabled bands unless the user asks for surgical detail.
- For "no background noise while talking", use voiceIsolation first, then gentle noiseGate/expander settings. Avoid extreme compressor makeup gain because it raises noise.

Current preset name: "\(currentPresetName)"

\(analysisBlock)\(deviceLine.map { "Input device context: \($0)\n\n" } ?? "")Prior chat history for this preset:
\(historyBlock)

Current processing settings (JSON):
\(currentSettingsJSON(current))

Shared user/AI tool catalog:
\(MACQToolCatalog.aiPromptText)

User message: "\(safeMsg)"
"""
    }

    private func chatHistoryPrompt(_ messages: [AIPresetChatMessage]) -> String {
        let recent = messages
        guard recent.isEmpty == false else { return "No previous messages." }

        return recent.map { message in
            var lines: [String] = [
                "- \(message.role.rawValue): \(message.markdown.trimmingCharacters(in: .whitespacesAndNewlines))"
            ]
            if let action = message.proposedActionRaw, action.isEmpty == false {
                lines.append("  action: \(action)")
            }
            if let name = message.proposedPresetName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.append("  presetName: \(name)")
            }
            if let settings = message.proposedSettings {
                lines.append("  proposedSettings: \(currentSettingsJSON(settings))")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func currentSettingsJSON(_ s: EQSettings) -> String {
        struct Payload: Encodable {
            struct Band: Encodable {
                let isEnabled: Bool
                let type: EQBandType
                let frequencyHz: Double
                let gainDB: Double
                let q: Double
            }

            let preampDB: Double
            let outputGainDB: Double
            let bands: [Band]
            let isBypassed: Bool
            let noiseGate: EQSettings.NoiseGateSettings
            let compressor: EQSettings.CompressorSettings
            let deEsser: EQSettings.DeEsserSettings
            let voiceIsolation: EQSettings.VoiceIsolationSettings
        }

        let payload = Payload(
            preampDB: s.preampDB,
            outputGainDB: s.outputGainDB,
            bands: s.bands.map { b in
                Payload.Band(isEnabled: b.isEnabled, type: b.type, frequencyHz: b.frequencyHz, gainDB: b.gainDB, q: b.q)
            },
            isBypassed: s.isBypassed,
            noiseGate: s.noiseGate,
            compressor: s.compressor,
            deEsser: s.deEsser,
            voiceIsolation: s.voiceIsolation
        )

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(payload)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    private func extractResponseText(_ respData: Data) throws -> String {
        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: respData)
        return decoded.candidates.first?.content.parts
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
    }

    private func decodeEQSettings(fromModelText text: String) throws -> EQSettings {
        let extracted = extractFirstJSONObjectOrArray(from: text)
        guard let jsonData = extracted.data(using: .utf8) else {
            throw GeminiError("Gemini returned an empty response.")
        }

        do {
            return try JSONDecoder().decode(EQSettings.self, from: jsonData)
        } catch {
            let snippet = extracted.prefix(600)
            throw GeminiError("Gemini returned a response we couldn't parse as EQ JSON. First chars:\n\(snippet)")
        }
    }

    private struct EditPayload: Decodable {
        let assistantMarkdown: String
        let action: String
        let presetName: String?
        let settings: EQSettings?
    }

    private func decodePresetEdit(fromModelText text: String) throws -> PresetEditResult {
        let extracted = extractFirstJSONObjectOrArray(from: text)
        guard let jsonData = extracted.data(using: .utf8) else {
            throw GeminiError("Gemini returned an empty response.")
        }

        do {
            let decoded = try JSONDecoder().decode(EditPayload.self, from: jsonData)
            let normalized = decoded.action
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "_")
                .lowercased()

            let action: PresetEditResult.Action
            switch normalized {
            case "update", "edit", "modify":
                action = .update
            case "duplicate", "copy", "new":
                action = .duplicate
            case "rename":
                action = .rename
            case "delete", "remove":
                action = .delete
            default:
                action = .none
            }

            return PresetEditResult(
                assistantMarkdown: decoded.assistantMarkdown,
                action: action,
                presetName: decoded.presetName,
                settings: decoded.settings
            )
        } catch {
            let snippet = extracted.prefix(800)
            throw GeminiError("Gemini returned a response we couldn't parse as edit JSON. First chars:\n\(snippet)")
        }
    }

    private func decodePresetEditWithRepair(fromModelText text: String, originalPrompt: String) async throws -> PresetEditResult {
        do {
            return sanitizeEditResult(try decodePresetEdit(fromModelText: text))
        } catch {
            let repairPrompt = """
Repair this invalid Gemini edit response into valid JSON for the exact schema requested below.

Rules:
- Return ONLY one JSON object. No markdown fences.
- Keep assistantMarkdown concise and readable with blank lines.
- If settings are present, preserve all intended changes and include a complete EQSettings object.
- If the original response is truncated or malformed, infer the intended settings from the original prompt and return a complete valid update.

Original prompt:
\(originalPrompt)

Invalid response:
\(text.prefix(12_000))
"""
            let repairResp = try await sendGenerateContent(prompt: repairPrompt, audioBase64: nil)
            let repairText = try extractResponseText(repairResp)
            do {
                return sanitizeEditResult(try decodePresetEdit(fromModelText: repairText))
            } catch {
                throw GeminiError("Gemini returned invalid edit JSON even after repair. I copied the short error to your clipboard; try the same request again.")
            }
        }
    }

    private func sanitizeEditResult(_ result: PresetEditResult) -> PresetEditResult {
        var out = result
        out.assistantMarkdown = formatAssistantMarkdown(out.assistantMarkdown)
        if let s = out.settings {
            out.settings = s.sanitized(maxBands: 96)
            out.settings?.isBypassed = false
        }
        return out
    }

    private func formatAssistantMarkdown(_ markdown: String) -> String {
        var text = markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\n", with: "\n")

        let headings = [
            "Voice Isolation", "Noise Gate", "Compressor", "De-Esser", "EQ", "Bass",
            "Clarity", "Crispness", "Preamp", "Output Gain", "Background Noise",
            "No More", "Louder Voice", "More Clear"
        ]

        for heading in headings {
            text = text.replacingOccurrences(of: ".\(heading)", with: ".\n\n**\(heading)**")
            text = text.replacingOccurrences(of: ":\(heading)", with: ":\n\n**\(heading)**")
            text = text.replacingOccurrences(of: "\(heading):", with: "**\(heading):**")
        }

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return text
    }

    private func requiresChangedSettings(_ action: PresetEditResult.Action) -> Bool {
        action == .update || action == .duplicate
    }

    private func settingsAreMeaningfullyDifferent(_ a: EQSettings, _ maybeB: EQSettings?) -> Bool {
        guard let b = maybeB else { return false }
        if abs(a.preampDB - b.preampDB) > 0.05 { return true }
        if abs(a.outputGainDB - b.outputGainDB) > 0.05 { return true }
        if a.isBypassed != b.isBypassed { return true }
        if dynamicsDiffer(a.noiseGate, b.noiseGate) { return true }
        if dynamicsDiffer(a.compressor, b.compressor) { return true }
        if dynamicsDiffer(a.deEsser, b.deEsser) { return true }
        if dynamicsDiffer(a.voiceIsolation, b.voiceIsolation) { return true }

        let count = min(a.bands.count, b.bands.count)
        if a.bands.count != b.bands.count { return true }
        for i in 0..<count {
            let x = a.bands[i]
            let y = b.bands[i]
            if x.isEnabled != y.isEnabled { return true }
            if x.type != y.type { return true }
            if abs(x.frequencyHz - y.frequencyHz) > 1 { return true }
            if abs(x.gainDB - y.gainDB) > 0.05 { return true }
            if abs(x.q - y.q) > 0.02 { return true }
        }

        return false
    }

    private func dynamicsDiffer(_ a: EQSettings.NoiseGateSettings, _ b: EQSettings.NoiseGateSettings) -> Bool {
        a.isEnabled != b.isEnabled ||
            abs(a.thresholdDB - b.thresholdDB) > 0.05 ||
            abs(a.hysteresisDB - b.hysteresisDB) > 0.05 ||
            abs(a.rangeDB - b.rangeDB) > 0.05 ||
            abs(a.attackMs - b.attackMs) > 0.05 ||
            abs(a.holdMs - b.holdMs) > 0.05 ||
            abs(a.releaseMs - b.releaseMs) > 0.05
    }

    private func dynamicsDiffer(_ a: EQSettings.CompressorSettings, _ b: EQSettings.CompressorSettings) -> Bool {
        a.isEnabled != b.isEnabled ||
            abs(a.thresholdDB - b.thresholdDB) > 0.05 ||
            abs(a.ratio - b.ratio) > 0.02 ||
            abs(a.kneeDB - b.kneeDB) > 0.05 ||
            abs(a.attackMs - b.attackMs) > 0.05 ||
            abs(a.releaseMs - b.releaseMs) > 0.05 ||
            abs(a.makeupGainDB - b.makeupGainDB) > 0.05
    }

    private func dynamicsDiffer(_ a: EQSettings.DeEsserSettings, _ b: EQSettings.DeEsserSettings) -> Bool {
        a.isEnabled != b.isEnabled ||
            abs(a.frequencyHz - b.frequencyHz) > 1 ||
            abs(a.q - b.q) > 0.02 ||
            abs(a.thresholdDB - b.thresholdDB) > 0.05 ||
            abs(a.ratio - b.ratio) > 0.02 ||
            abs(a.attackMs - b.attackMs) > 0.05 ||
            abs(a.releaseMs - b.releaseMs) > 0.05 ||
            abs(a.maxReductionDB - b.maxReductionDB) > 0.05
    }

    private func dynamicsDiffer(_ a: EQSettings.VoiceIsolationSettings, _ b: EQSettings.VoiceIsolationSettings) -> Bool {
        a.isEnabled != b.isEnabled ||
            abs(a.strength - b.strength) > 0.05 ||
            abs(a.noiseFloorDB - b.noiseFloorDB) > 0.05 ||
            abs(a.speechThresholdDB - b.speechThresholdDB) > 0.05 ||
            abs(a.reductionDB - b.reductionDB) > 0.05 ||
            abs(a.focusLowHz - b.focusLowHz) > 1 ||
            abs(a.focusHighHz - b.focusHighHz) > 1 ||
            abs(a.attackMs - b.attackMs) > 0.05 ||
            abs(a.releaseMs - b.releaseMs) > 0.05 ||
            abs(a.presenceBoostDB - b.presenceBoostDB) > 0.05
    }

    private func isTrivialPreset(_ s: EQSettings) -> Bool {
        let anyBandsEnabled = s.bands.contains(where: { $0.isEnabled })
        let anyDynamics = s.noiseGate.isEnabled || s.compressor.isEnabled || s.deEsser.isEnabled || s.voiceIsolation.isEnabled
        return anyBandsEnabled == false && anyDynamics == false
    }

    private var usesGemini3ThinkingLevel: Bool {
        config.model.lowercased().contains("gemini-3")
    }

    private var camelThinkingConfig: [String: Any] {
        if usesGemini3ThinkingLevel {
            return [
                "includeThoughts": false,
                "thinkingLevel": "HIGH",
            ]
        }
        return [
            "includeThoughts": false,
            "thinkingBudget": 1024,
        ]
    }

    private var snakeThinkingConfig: [String: Any] {
        if usesGemini3ThinkingLevel {
            return [
                "include_thoughts": false,
                "thinking_level": "HIGH",
            ]
        }
        return [
            "include_thoughts": false,
            "thinking_budget": 1024,
        ]
    }

    private func makeRequestBody(prompt: String, audioBase64: String) -> [String: Any] {
        [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": audioBase64,
                            ]
                        ],
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 8192,
                "responseMimeType": "application/json",
                "thinkingConfig": camelThinkingConfig,
            ],
        ]
    }

    private func makeRequestBodyTextOnly(prompt: String) -> [String: Any] {
        [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 8192,
                "responseMimeType": "application/json",
                "thinkingConfig": camelThinkingConfig,
            ],
        ]
    }

    private func makeRequestBodySnakeConfigTextOnly(prompt: String) -> [String: Any] {
        [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "max_output_tokens": 8192,
                "response_mime_type": "application/json",
                "thinking_config": snakeThinkingConfig,
            ],
        ]
    }

    private func makeRequestBodyLegacyTextOnly(prompt: String) -> [String: Any] {
        [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                    ]
                ]
            ],
            "generation_config": [
                "temperature": 0.2,
                "max_output_tokens": 8192,
                "response_mime_type": "application/json",
                "thinking_config": snakeThinkingConfig,
            ],
        ]
    }

    private func sanitize(_ settings: EQSettings, maxBands: Int) -> EQSettings {
        var s = settings
        s.preampDB = clamp(s.preampDB, -24, 24)
        s.outputGainDB = clamp(s.outputGainDB, -24, 24)
        s.isBypassed = false

        if s.bands.count > maxBands {
            s.bands = Array(s.bands.prefix(maxBands))
        }

        for i in s.bands.indices {
            s.bands[i].frequencyHz = clamp(s.bands[i].frequencyHz, 20, 20_000)
            s.bands[i].gainDB = clamp(s.bands[i].gainDB, -24, 24)
            s.bands[i].q = clamp(s.bands[i].q, 0.1, 18)
        }

        // Noise gate
        s.noiseGate.thresholdDB = clamp(s.noiseGate.thresholdDB, -80, 0)
        s.noiseGate.hysteresisDB = clamp(s.noiseGate.hysteresisDB, 0, 12)
        s.noiseGate.rangeDB = clamp(s.noiseGate.rangeDB, 0, 80)
        s.noiseGate.attackMs = clamp(s.noiseGate.attackMs, 0, 50)
        s.noiseGate.holdMs = clamp(s.noiseGate.holdMs, 0, 500)
        s.noiseGate.releaseMs = clamp(s.noiseGate.releaseMs, 0, 1500)
        if s.noiseGate.rangeDB <= 0 { s.noiseGate.isEnabled = false }

        // Compressor
        s.compressor.thresholdDB = clamp(s.compressor.thresholdDB, -60, 0)
        s.compressor.ratio = clamp(s.compressor.ratio, 1, 20)
        s.compressor.kneeDB = clamp(s.compressor.kneeDB, 0, 24)
        s.compressor.attackMs = clamp(s.compressor.attackMs, 0, 50)
        s.compressor.releaseMs = clamp(s.compressor.releaseMs, 5, 1000)
        s.compressor.makeupGainDB = clamp(s.compressor.makeupGainDB, -12, 18)
        if s.compressor.ratio <= 1.01 { s.compressor.isEnabled = false }

        // De-esser
        s.deEsser.frequencyHz = clamp(s.deEsser.frequencyHz, 2000, 12_000)
        s.deEsser.q = clamp(s.deEsser.q, 0.3, 10)
        s.deEsser.thresholdDB = clamp(s.deEsser.thresholdDB, -60, 0)
        s.deEsser.ratio = clamp(s.deEsser.ratio, 1, 20)
        s.deEsser.attackMs = clamp(s.deEsser.attackMs, 0, 20)
        s.deEsser.releaseMs = clamp(s.deEsser.releaseMs, 10, 500)
        s.deEsser.maxReductionDB = clamp(s.deEsser.maxReductionDB, 0, 24)
        if s.deEsser.ratio <= 1.01 || s.deEsser.maxReductionDB <= 0 { s.deEsser.isEnabled = false }

        s.voiceIsolation.strength = clamp(s.voiceIsolation.strength, 0, 100)
        s.voiceIsolation.noiseFloorDB = clamp(s.voiceIsolation.noiseFloorDB, -90, -10)
        s.voiceIsolation.speechThresholdDB = clamp(s.voiceIsolation.speechThresholdDB, -80, 0)
        s.voiceIsolation.reductionDB = clamp(s.voiceIsolation.reductionDB, 0, 80)
        s.voiceIsolation.focusLowHz = clamp(s.voiceIsolation.focusLowHz, 40, 400)
        s.voiceIsolation.focusHighHz = clamp(s.voiceIsolation.focusHighHz, 2_000, 18_000)
        if s.voiceIsolation.focusHighHz <= s.voiceIsolation.focusLowHz + 500 {
            s.voiceIsolation.focusHighHz = s.voiceIsolation.focusLowHz + 500
        }
        s.voiceIsolation.attackMs = clamp(s.voiceIsolation.attackMs, 0, 80)
        s.voiceIsolation.releaseMs = clamp(s.voiceIsolation.releaseMs, 20, 2_000)
        s.voiceIsolation.presenceBoostDB = clamp(s.voiceIsolation.presenceBoostDB, -6, 8)
        if s.voiceIsolation.strength <= 0 || s.voiceIsolation.reductionDB <= 0 {
            s.voiceIsolation.isEnabled = false
        }

        return s
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(hi, max(lo, v))
    }

    private func sendGenerateContent(prompt: String, audioBase64: String?) async throws -> Data {
        let modelCode: String
        if config.model.hasPrefix("models/") {
            modelCode = String(config.model.dropFirst("models/".count))
        } else {
            modelCode = config.model
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelCode):generateContent")!

        // The Gemini REST API has historically exposed both camelCase and snake_case field names
        // across examples and SDKs. To be resilient, we attempt a few payload variants.
        let candidates: [[String: Any]]
        if let audioBase64 {
            candidates = [
                makeRequestBody(prompt: prompt, audioBase64: audioBase64),
                makeRequestBodySnakeConfig(prompt: prompt, audioBase64: audioBase64),
                makeRequestBodyLegacy(prompt: prompt, audioBase64: audioBase64),
            ]
        } else {
            candidates = [
                makeRequestBodyTextOnly(prompt: prompt),
                makeRequestBodySnakeConfigTextOnly(prompt: prompt),
                makeRequestBodyLegacyTextOnly(prompt: prompt),
            ]
        }

        var lastError: Error?
        for body in candidates {
            do {
                    return try await sendGenerateContentOnce(url: url, requestBody: body)
                } catch {
                    lastError = error
                    if let http = error as? GeminiHTTPError, [401, 403].contains(http.statusCode) {
                        throw http
                    }
            }
        }

        throw lastError ?? GeminiError("Gemini request failed.")
    }

    private func sendGenerateContentOnce(url: URL, requestBody: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let (respData, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if (200...299).contains(status) { return respData }

        if let apiError = try? JSONDecoder().decode(GeminiErrorResponse.self, from: respData) {
            throw GeminiHTTPError(statusCode: status, message: apiError.error.message)
        }
        throw GeminiHTTPError(statusCode: status, message: "Gemini request failed (HTTP \(status))")
    }

    private func makeRequestBodySnakeConfig(prompt: String, audioBase64: String) -> [String: Any] {
        // Same structure, but use snake_case response_mime_type and omit thinkingConfig.
        [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": audioBase64,
                            ]
                        ],
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "max_output_tokens": 8192,
                "response_mime_type": "application/json",
                "thinking_config": snakeThinkingConfig,
            ],
        ]
    }

    private func makeRequestBodyLegacy(prompt: String, audioBase64: String) -> [String: Any] {
        // Legacy variants seen in some SDKs/examples: generation_config + response_mime_type.
        [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": audioBase64,
                            ]
                        ],
                    ]
                ]
            ],
            "generation_config": [
                "temperature": 0.2,
                "max_output_tokens": 8192,
                "response_mime_type": "application/json",
                "thinking_config": snakeThinkingConfig,
            ],
        ]
    }

    private func extractFirstJSONObjectOrArray(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        if trimmed.first == "{", let obj = extractBalancedJSON(from: trimmed, open: "{", close: "}") { return obj }
        if trimmed.first == "[", let arr = extractBalancedJSON(from: trimmed, open: "[", close: "]") { return arr }

        // Try to find a JSON object/array in a larger response (code fences, preambles, etc.).
        if let obj = extractBalancedJSON(from: trimmed, open: "{", close: "}") { return obj }
        if let arr = extractBalancedJSON(from: trimmed, open: "[", close: "]") { return arr }
        return trimmed
    }

    private func extractBalancedJSON(from text: String, open: Character, close: Character) -> String? {
        guard let start = text.firstIndex(of: open) else { return nil }

        var idx = start
        var depth = 0
        var inString = false
        var isEscaped = false

        while idx < text.endIndex {
            let ch = text[idx]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == open {
                    depth += 1
                } else if ch == close {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }

            idx = text.index(after: idx)
        }
        return nil
    }
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content
    }

    struct Content: Decodable {
        let parts: [Part]
    }

    struct Part: Decodable {
        let text: String?
        let thought: Bool?
    }

    let candidates: [Candidate]
}

private struct GeminiErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
        let status: String?
    }
    let error: ErrorBody
}

private struct GeminiError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct GeminiHTTPError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { message }
}
