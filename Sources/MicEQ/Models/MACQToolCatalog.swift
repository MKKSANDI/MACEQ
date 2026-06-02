import Foundation

enum MACQToolCatalog {
    struct Section: Identifiable, Hashable {
        let title: String
        let summary: String
        let tools: [Tool]

        var id: String { title }
    }

    struct Tool: Identifiable, Hashable {
        let name: String
        let detail: String

        var id: String { name }
    }

    static let sections: [Section] = [
        Section(
            title: "Routing + Control",
            summary: "Core app controls shared by the UI, menu-bar item, hotkeys, and AI context.",
            tools: [
                Tool(name: "Input Device", detail: "Choose the physical mic feeding MicEQ."),
                Tool(name: "MicEQ Virtual Microphone", detail: "Processed output device used by Zoom, Discord, OBS, and other apps."),
                Tool(name: "Start / Stop Processing", detail: "Start or stop live audio routing."),
                Tool(name: "Restart Audio Engine", detail: "Fully resets capture, processing, monitor, app-audio buffers, and device routing."),
                Tool(name: "Mute MicEQ", detail: "Instant output mute from UI, top-bar icon, or custom hotkey."),
                Tool(name: "Mute Hotkey", detail: "Single key or modifier combo registered globally with macOS."),
                Tool(name: "Live Monitor", detail: "Hear the processed mic while adjusting settings."),
                Tool(name: "Monitor Output", detail: "Choose a low-latency output device for live monitoring."),
                Tool(name: "Application Audio Mix", detail: "Route selected app audio into MicEQ without applying mic EQ to it."),
                Tool(name: "Application Audio Volume", detail: "Blend app audio from 0–200% independently from mic EQ.")
            ]
        ),
        Section(
            title: "EQ",
            summary: "96 full parametric bands with identical access for manual editing and AI-generated presets.",
            tools: [
                Tool(name: "EQ Bypass / Enable", detail: "Turn all EQ processing on or off without losing settings."),
                Tool(name: "Preamp", detail: "-24 to +24 dB before EQ."),
                Tool(name: "Output Gain", detail: "-24 to +24 dB after processing."),
                Tool(name: "96 EQ Bands", detail: "Each band has enabled, type, frequency, gain, and Q controls."),
                Tool(name: "Band Types", detail: "Peak, Low Shelf, High Shelf, Low Pass, High Pass, Band Pass, Notch."),
                Tool(name: "Frequency", detail: "20 Hz to 20 kHz per band."),
                Tool(name: "Gain", detail: "-24 to +24 dB per gain-capable band."),
                Tool(name: "Q / Width", detail: "0.1 to 18 per band for broad tone shaping or surgical cuts."),
                Tool(name: "Bass Modifier", detail: "Quick low-shelf bass control mapped to the same EQ model."),
                Tool(name: "Response Graph", detail: "Live EQ curve view for the current settings.")
            ]
        ),
        Section(
            title: "Voice Cleanup",
            summary: "Dynamics and isolation tools for laptop mics, typing noise, room noise, clarity, and consistency.",
            tools: [
                Tool(name: "Voice Isolation", detail: "Strength, noise floor, speech threshold, reduction, focus low/high, attack, release, presence boost."),
                Tool(name: "Noise Gate / Expander", detail: "Enable, threshold, hysteresis, range, attack, hold, release."),
                Tool(name: "Compressor", detail: "Enable, threshold, ratio, knee, attack, release, makeup gain."),
                Tool(name: "De-Esser", detail: "Enable, frequency, Q, threshold, ratio, attack, release, max reduction."),
                Tool(name: "Typing Noise Reduction", detail: "Uses voice isolation, high-pass, notches, low-mid cuts, and controlled gate release."),
                Tool(name: "Jumpscare Prevention", detail: "Uses smooth attack/release and avoids hard silence returning suddenly."),
                Tool(name: "Clarity / Crispness", detail: "Presence and air bands, de-essing, and mud cuts."),
                Tool(name: "Warmth / Bass", detail: "Low shelf plus low-mid control while preventing boominess."),
                Tool(name: "Laptop Mic Cleanup", detail: "Presets and controls optimized for built-in MacBook microphones.")
            ]
        ),
        Section(
            title: "AI Presets",
            summary: "Gemini can use the exact same settings exposed in the UI and nothing hidden.",
            tools: [
                Tool(name: "Sample Analysis", detail: "Level, peak, RMS, dynamic range, clipping, silence, pitch, consistency, spectral bands, centroid, noise estimates."),
                Tool(name: "Goal-Based Generation", detail: "Create an AI-tagged preset from mic analysis and the requested sound."),
                Tool(name: "AI Preset Chat", detail: "Edit, update, duplicate, rename, or delete AI presets with saved chat history."),
                Tool(name: "Preset Diff", detail: "Show proposed control changes before applying."),
                Tool(name: "Apply Update", detail: "Apply an AI proposal to the current preset."),
                Tool(name: "Duplicate as New", detail: "Create a new preset from an AI proposal."),
                Tool(name: "Import / Export Presets", detail: "Read and write .macqeq preset files.")
            ]
        )
    ]

    static var aiPromptText: String {
        sections.map { section in
            let tools = section.tools.map { "- \($0.name): \($0.detail)" }.joined(separator: "\n")
            return "\(section.title): \(section.summary)\n\(tools)"
        }
        .joined(separator: "\n\n")
    }
}
