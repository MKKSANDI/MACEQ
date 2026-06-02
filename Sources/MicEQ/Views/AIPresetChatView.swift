import SwiftUI

struct AIPresetChatView: View {
    @EnvironmentObject private var model: AppModel

    @State private var draftMessage: String = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        model.isAIChatWorking == false &&
            model.selectedPreset?.origin == .ai &&
            draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        VStack(spacing: 16) {
            headerCard
            messagesPanel
            composer
        }
        .padding(18)
        .macqRootSurface()
        .onAppear {
            activateSelectedPresetChat()
            focused = true
        }
        .onChange(of: model.selectedPresetID) { _ in
            activateSelectedPresetChat()
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(MACQTheme.selectedGradient)
                    .frame(width: 48, height: 48)
                Image(systemName: "sparkles")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("AI Preset Chat")
                    .font(.title2.weight(.semibold))

                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(MACQTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer()

            if let preset = model.selectedPreset, preset.origin == .ai {
                PresetContextPills(preset: preset, messageCount: model.aiChatMessages.count)
            }
        }
        .padding(16)
        .macqPanel(cornerRadius: 18)
    }

    private var headerSubtitle: String {
        guard let preset = model.selectedPreset else {
            return "Select an AI preset first. The chat saves with each preset."
        }
        guard preset.origin == .ai else {
            return "This tab is for AI presets. Save or generate an AI preset to edit it here."
        }
        return "Editing \(preset.name). I use this preset, previous messages, and previous AI proposals as context."
    }

    private var messagesPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.aiChatMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }

                    if model.isAIChatWorking {
                        ThinkingRow(status: model.aiChatStatus ?? "Thinking with Gemini…")
                            .id("thinking")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .macqTransparentScroll()
            .macqPanel(cornerRadius: 18)
            .onChange(of: model.aiChatMessages) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.isAIChatWorking) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Press Enter to send")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MACQTheme.mutedText)

                TextField("Tell the AI what to change about this preset…", text: $draftMessage, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(focused ? MACQTheme.strongStroke : MACQTheme.panelStroke, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .disabled(model.isAIChatWorking || model.selectedPreset?.origin != .ai)
            }

            Button(action: sendDraft) {
                Label("Send", systemImage: "paperplane.fill")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(canSend == false)
        }
        .padding(14)
        .macqPanel(cornerRadius: 18)
    }

    private func activateSelectedPresetChat() {
        if let preset = model.selectedPreset, preset.origin == .ai {
            model.activateAIChat(for: preset.id)
        } else {
            model.clearActiveChat()
        }
    }

    private func sendDraft() {
        guard canSend else { return }
        let sending = draftMessage
        draftMessage = ""
        focused = true
        Task { await model.sendAIChatMessage(sending) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.20)) {
                if model.isAIChatWorking {
                    proxy.scrollTo("thinking", anchor: .bottom)
                } else if let last = model.aiChatMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct PresetContextPills: View {
    let preset: EQPreset
    let messageCount: Int

    var body: some View {
        HStack(spacing: 8) {
            pill("AI", systemImage: "sparkles")
            pill("\(preset.settings.bands.filter(\.isEnabled).count) bands", systemImage: "slider.horizontal.3")
            pill("\(max(0, messageCount - 1)) chats", systemImage: "text.bubble")
        }
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(MACQTheme.controlGradient)
            .clipShape(Capsule())
    }
}

private struct ThinkingRow: View {
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(status)
                    .font(.callout.weight(.semibold))
                Text("Checking the current preset, chat history, and Gemini’s proposed settings before showing an update.")
                    .font(.caption)
                    .foregroundStyle(MACQTheme.mutedText)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: 860, alignment: .leading)
        .macqPanel(cornerRadius: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var model: AppModel
    let message: AIPresetChatMessage

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 90) }

            VStack(alignment: .leading, spacing: 12) {
                messageHeader

                MarkdownText(markdown: message.markdown)

                if isAssistant, let proposed = message.proposedSettings {
                    ProposalCard(
                        messageID: message.id,
                        base: message.baseSettings ?? model.selectedPreset?.settings ?? proposed,
                        proposed: proposed,
                        proposedName: message.proposedPresetName,
                        action: message.proposedActionRaw
                    )
                } else if isAssistant, let preset = model.selectedPreset {
                    PresetActionCard(message: message, preset: preset)
                }
            }
            .padding(14)
            .background(bubbleBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isUser ? MACQTheme.strongStroke : MACQTheme.panelStroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: isUser ? 760 : 900, alignment: isUser ? .trailing : .leading)

            if isUser == false { Spacer(minLength: 90) }
        }
        .frame(maxWidth: .infinity)
    }

    private var isUser: Bool { message.role == .user }
    private var isAssistant: Bool { message.role == .assistant }

    private var messageHeader: some View {
        HStack(spacing: 8) {
            Text(roleTitle)
                .font(.caption.weight(.bold))
                .foregroundStyle(isUser ? Color.white.opacity(0.92) : Color.cyan.opacity(0.95))

            if let action = message.proposedActionRaw, action != "none", action.isEmpty == false {
                Text(action.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.cyan)
                    .clipShape(Capsule())
            }

            Spacer()

            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(MACQTheme.mutedText)
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user: return "YOU"
        case .assistant: return "MACQ AI"
        case .system: return "CONTEXT"
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if isUser { return AnyShapeStyle(MACQTheme.selectedGradient) }
        if message.role == .system { return AnyShapeStyle(MACQTheme.controlGradient) }
        return AnyShapeStyle(MACQTheme.panelGradient)
    }
}

private struct ProposalCard: View {
    @EnvironmentObject private var model: AppModel

    let messageID: AIPresetChatMessage.ID
    let base: EQSettings
    let proposed: EQSettings
    let proposedName: String?
    let action: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Proposed preset changes", systemImage: "wand.and.stars")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let proposedName, proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Text(proposedName)
                        .font(.caption)
                        .foregroundStyle(MACQTheme.mutedText)
                        .lineLimit(1)
                }
            }

            PresetDiffSummary(base: base, proposed: proposed)

            HStack(spacing: 10) {
                Button("Apply Update") {
                    model.applyProposedSettings(from: messageID)
                }
                .buttonStyle(.borderedProminent)

                Button("Duplicate as New") {
                    model.duplicatePresetFromProposal(from: messageID)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding(12)
        .macqPanel(cornerRadius: 12)
    }
}

private struct PresetActionCard: View {
    @EnvironmentObject private var model: AppModel

    let message: AIPresetChatMessage
    let preset: EQPreset

    var body: some View {
        if action == "rename", let newName = message.proposedPresetName?.trimmingCharacters(in: .whitespacesAndNewlines), newName.isEmpty == false {
            HStack(spacing: 10) {
                Button("Rename Preset") {
                    model.renamePreset(id: preset.id, newName: newName)
                }
                .buttonStyle(.borderedProminent)

                Text("New name: \(newName)")
                    .foregroundStyle(MACQTheme.mutedText)

                Spacer()
            }
            .padding(12)
            .macqPanel(cornerRadius: 12)
        } else if action == "delete" {
            HStack(spacing: 10) {
                Button("Delete Preset", role: .destructive) {
                    model.deletePreset(id: preset.id)
                }
                .buttonStyle(.borderedProminent)

                Text("This can’t be undone.")
                    .foregroundStyle(MACQTheme.mutedText)

                Spacer()
            }
            .padding(12)
            .macqPanel(cornerRadius: 12)
        }
    }

    private var action: String {
        message.proposedActionRaw?.lowercased() ?? ""
    }
}

private struct PresetDiffSummary: View {
    let base: EQSettings
    let proposed: EQSettings

    var body: some View {
        let lines = diffLines(from: base, to: proposed)

        VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty {
                Label("Settings snapshot ready. No difference from the saved base preset.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(MACQTheme.mutedText)
            } else {
                ForEach(lines.prefix(10), id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.82))
                }

                if lines.count > 10 {
                    Text("+ \(lines.count - 10) more detailed changes")
                        .font(.caption)
                        .foregroundStyle(MACQTheme.mutedText)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func diffLines(from a: EQSettings, to b: EQSettings) -> [String] {
        var parts: [String] = []

        appendDB("Preamp", a.preampDB, b.preampDB, to: &parts)
        appendDB("Output", a.outputGainDB, b.outputGainDB, to: &parts)
        if a.isBypassed != b.isBypassed {
            parts.append("EQ Enabled: \(a.isBypassed ? "Off" : "On") → \(b.isBypassed ? "Off" : "On")")
        }

        let bandCount = min(a.bands.count, b.bands.count)
        for i in 0..<bandCount {
            let x = a.bands[i]
            let y = b.bands[i]
            guard bandChanged(x, y) else { continue }
            parts.append("Band \(i + 1): \(bandSummary(x)) → \(bandSummary(y))")
        }

        appendNoiseGateDiff(a.noiseGate, b.noiseGate, to: &parts)
        appendCompressorDiff(a.compressor, b.compressor, to: &parts)
        appendDeEsserDiff(a.deEsser, b.deEsser, to: &parts)
        appendVoiceIsolationDiff(a.voiceIsolation, b.voiceIsolation, to: &parts)
        return parts
    }

    private func bandChanged(_ a: EQBand, _ b: EQBand) -> Bool {
        a.isEnabled != b.isEnabled ||
            a.type != b.type ||
            abs(a.frequencyHz - b.frequencyHz) > 1 ||
            abs(a.gainDB - b.gainDB) > 0.05 ||
            abs(a.q - b.q) > 0.02
    }

    private func bandSummary(_ band: EQBand) -> String {
        let state = band.isEnabled ? "On" : "Off"
        return String(format: "%@ %@ %.0f Hz %+0.1f dB Q %.2f", state, band.type.displayName, band.frequencyHz, band.gainDB, band.q)
    }

    private func appendDB(_ label: String, _ a: Double, _ b: Double, to parts: inout [String]) {
        if abs(a - b) > 0.05 {
            parts.append(String(format: "%@: %+.1f → %+.1f dB", label, a, b))
        }
    }

    private func appendValue(_ label: String, _ a: Double, _ b: Double, unit: String = "", to fields: inout [String]) {
        if abs(a - b) > 0.05 {
            fields.append(String(format: "%@ %.1f → %.1f%@", label, a, b, unit))
        }
    }

    private func appendNoiseGateDiff(_ a: EQSettings.NoiseGateSettings, _ b: EQSettings.NoiseGateSettings, to parts: inout [String]) {
        var fields: [String] = []
        if a.isEnabled != b.isEnabled { fields.append("enabled \(a.isEnabled ? "On" : "Off") → \(b.isEnabled ? "On" : "Off")") }
        appendValue("threshold", a.thresholdDB, b.thresholdDB, unit: " dB", to: &fields)
        appendValue("range", a.rangeDB, b.rangeDB, unit: " dB", to: &fields)
        appendValue("hold", a.holdMs, b.holdMs, unit: " ms", to: &fields)
        appendValue("release", a.releaseMs, b.releaseMs, unit: " ms", to: &fields)
        if fields.isEmpty == false { parts.append("Noise Gate: \(fields.joined(separator: ", "))") }
    }

    private func appendCompressorDiff(_ a: EQSettings.CompressorSettings, _ b: EQSettings.CompressorSettings, to parts: inout [String]) {
        var fields: [String] = []
        if a.isEnabled != b.isEnabled { fields.append("enabled \(a.isEnabled ? "On" : "Off") → \(b.isEnabled ? "On" : "Off")") }
        appendValue("threshold", a.thresholdDB, b.thresholdDB, unit: " dB", to: &fields)
        appendValue("ratio", a.ratio, b.ratio, to: &fields)
        appendValue("makeup", a.makeupGainDB, b.makeupGainDB, unit: " dB", to: &fields)
        if fields.isEmpty == false { parts.append("Compressor: \(fields.joined(separator: ", "))") }
    }

    private func appendDeEsserDiff(_ a: EQSettings.DeEsserSettings, _ b: EQSettings.DeEsserSettings, to parts: inout [String]) {
        var fields: [String] = []
        if a.isEnabled != b.isEnabled { fields.append("enabled \(a.isEnabled ? "On" : "Off") → \(b.isEnabled ? "On" : "Off")") }
        appendValue("frequency", a.frequencyHz, b.frequencyHz, unit: " Hz", to: &fields)
        appendValue("threshold", a.thresholdDB, b.thresholdDB, unit: " dB", to: &fields)
        appendValue("max cut", a.maxReductionDB, b.maxReductionDB, unit: " dB", to: &fields)
        if fields.isEmpty == false { parts.append("De-Esser: \(fields.joined(separator: ", "))") }
    }

    private func appendVoiceIsolationDiff(_ a: EQSettings.VoiceIsolationSettings, _ b: EQSettings.VoiceIsolationSettings, to parts: inout [String]) {
        var fields: [String] = []
        if a.isEnabled != b.isEnabled { fields.append("enabled \(a.isEnabled ? "On" : "Off") → \(b.isEnabled ? "On" : "Off")") }
        appendValue("strength", a.strength, b.strength, unit: "%", to: &fields)
        appendValue("noise floor", a.noiseFloorDB, b.noiseFloorDB, unit: " dBFS", to: &fields)
        appendValue("speech", a.speechThresholdDB, b.speechThresholdDB, unit: " dBFS", to: &fields)
        appendValue("reduction", a.reductionDB, b.reductionDB, unit: " dB", to: &fields)
        appendValue("release", a.releaseMs, b.releaseMs, unit: " ms", to: &fields)
        appendValue("presence", a.presenceBoostDB, b.presenceBoostDB, unit: " dB", to: &fields)
        if fields.isEmpty == false { parts.append("Voice Isolation: \(fields.joined(separator: ", "))") }
    }
}

private struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(attributed(block))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var blocks: [String] {
        normalizedMarkdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private var normalizedMarkdown: String {
        var text = markdown
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: ".I've", with: ".\n\nI've")
            .replacingOccurrences(of: ".I’ve", with: ".\n\nI’ve")

        for heading in ["Voice Isolation", "Noise Gate", "Compressor", "De-Esser", "EQ", "Bass", "Clarity", "Background Noise", "Preamp", "Output Gain"] {
            text = text.replacingOccurrences(of: ":\(heading)", with: ":\n\n**\(heading)**")
            text = text.replacingOccurrences(of: ".\(heading)", with: ".\n\n**\(heading)**")
            text = text.replacingOccurrences(of: "\(heading):", with: "**\(heading):**")
        }

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attributed(_ block: String) -> AttributedString {
        (try? AttributedString(
            markdown: block,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(block)
    }
}
