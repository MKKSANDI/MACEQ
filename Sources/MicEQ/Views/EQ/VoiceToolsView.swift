import SwiftUI

struct VoiceToolsView: View {
    @Binding var settings: EQSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                toneBox
                cleanupBox
                voiceIsolationBox
                broadcastBox
                noiseGateBox
                compressorBox
                deEsserBox

                HStack {
                    Spacer()
                    Button("Reset Voice Tools") {
                        settings.noiseGate = .disabled
                        settings.compressor = .disabled
                        settings.deEsser = .disabled
                        settings.voiceIsolation = .disabled

                        // Tone/Cleanup helpers (bands we reserve for quick voice tools).
                        if settings.bands.isEmpty == false {
                            let hp = safeBandIndex(0)
                            settings.bands[hp].isEnabled = true
                            settings.bands[hp].type = .highPass
                            settings.bands[hp].frequencyHz = 40
                            settings.bands[hp].q = 0.707
                            settings.bands[hp].gainDB = 0

                            for idx in [1, 2, 5, 9, 16, 20] {
                                let i = safeBandIndex(idx)
                                settings.bands[i].isEnabled = false
                                settings.bands[i].gainDB = 0
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .background(Color.clear)
        .macqRootSurface()
    }

    private var toneBox: some View {
        GroupBox("Tone Shapers (clarity, crispness, bass)") {
            VStack(alignment: .leading, spacing: 10) {
                sliderRow(
                    title: "High‑Pass (rumble remover)",
                    value: Binding(
                        get: { clamp(settings.bands[safeBandIndex(0)].frequencyHz, 30, 180) },
                        set: { hz in
                            let idx = safeBandIndex(0)
                            settings.bands[idx].isEnabled = true
                            settings.bands[idx].type = .highPass
                            settings.bands[idx].frequencyHz = clamp(hz, 30, 180)
                            settings.bands[idx].q = 0.707
                            settings.bands[idx].gainDB = 0
                        }
                    ),
                    range: 30...180,
                    step: 1,
                    valueLabel: { String(format: "%.0f Hz", settings.bands[safeBandIndex(0)].frequencyHz) }
                )

                sliderRow(
                    title: "Warmth (bass)",
                    value: Binding(
                        get: { clamp(settings.bands[safeBandIndex(2)].gainDB, -12, 12) },
                        set: { db in
                            let idx = safeBandIndex(2)
                            settings.bands[idx].type = .lowShelf
                            settings.bands[idx].frequencyHz = 110
                            settings.bands[idx].q = 0.9
                            settings.bands[idx].gainDB = clamp(db, -12, 12)
                            settings.bands[idx].isEnabled = abs(db) > 0.05
                        }
                    ),
                    range: -12...12,
                    step: 0.5,
                    valueLabel: { String(format: "%+.1f dB", settings.bands[safeBandIndex(2)].gainDB) }
                )

                sliderRow(
                    title: "Mud Reduction (boxy)",
                    value: Binding(
                        get: { clamp(-settings.bands[safeBandIndex(5)].gainDB, 0, 10) },
                        set: { amount in
                            let idx = safeBandIndex(5)
                            settings.bands[idx].type = .peaking
                            settings.bands[idx].frequencyHz = 300
                            settings.bands[idx].q = 1.0
                            let cut = -clamp(amount, 0, 10)
                            settings.bands[idx].gainDB = cut
                            settings.bands[idx].isEnabled = amount > 0.05
                        }
                    ),
                    range: 0...10,
                    step: 0.5,
                    valueLabel: { String(format: "%.1f dB cut", clamp(-settings.bands[safeBandIndex(5)].gainDB, 0, 10)) }
                )

                sliderRow(
                    title: "Nasal Reduction",
                    value: Binding(
                        get: { clamp(-settings.bands[safeBandIndex(9)].gainDB, 0, 10) },
                        set: { amount in
                            let idx = safeBandIndex(9)
                            settings.bands[idx].type = .peaking
                            settings.bands[idx].frequencyHz = 900
                            settings.bands[idx].q = 2.0
                            let cut = -clamp(amount, 0, 10)
                            settings.bands[idx].gainDB = cut
                            settings.bands[idx].isEnabled = amount > 0.05
                        }
                    ),
                    range: 0...10,
                    step: 0.5,
                    valueLabel: { String(format: "%.1f dB cut", clamp(-settings.bands[safeBandIndex(9)].gainDB, 0, 10)) }
                )

                sliderRow(
                    title: "Clarity / Presence",
                    value: Binding(
                        get: { clamp(settings.bands[safeBandIndex(16)].gainDB, -8, 8) },
                        set: { db in
                            let idx = safeBandIndex(16)
                            settings.bands[idx].type = .peaking
                            settings.bands[idx].frequencyHz = 4200
                            settings.bands[idx].q = 1.0
                            settings.bands[idx].gainDB = clamp(db, -8, 8)
                            settings.bands[idx].isEnabled = abs(db) > 0.05
                        }
                    ),
                    range: -8...8,
                    step: 0.5,
                    valueLabel: { String(format: "%+.1f dB", settings.bands[safeBandIndex(16)].gainDB) }
                )

                sliderRow(
                    title: "Crispness / Air",
                    value: Binding(
                        get: { clamp(settings.bands[safeBandIndex(20)].gainDB, -8, 8) },
                        set: { db in
                            let idx = safeBandIndex(20)
                            settings.bands[idx].type = .highShelf
                            settings.bands[idx].frequencyHz = 12_000
                            settings.bands[idx].q = 0.9
                            settings.bands[idx].gainDB = clamp(db, -8, 8)
                            settings.bands[idx].isEnabled = abs(db) > 0.05
                        }
                    ),
                    range: -8...8,
                    step: 0.5,
                    valueLabel: { String(format: "%+.1f dB", settings.bands[safeBandIndex(20)].gainDB) }
                )

                Text("Tip: small moves sound best. If it gets harsh, reduce Clarity and use De‑Esser.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var cleanupBox: some View {
        GroupBox("Mic Cleanup (typing noise, hum, jumpscare gate)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("De‑Hum (60 Hz)", isOn: Binding(
                    get: { settings.bands[safeBandIndex(1)].isEnabled },
                    set: { enabled in
                        let idx = safeBandIndex(1)
                        settings.bands[idx].type = .notch
                        settings.bands[idx].frequencyHz = 60
                        settings.bands[idx].q = 18
                        settings.bands[idx].gainDB = 0
                        settings.bands[idx].isEnabled = enabled
                    }
                ))

                Toggle("Plosive Control (less ‘P’ pops)", isOn: Binding(
                    get: { settings.bands[safeBandIndex(0)].frequencyHz >= 80 },
                    set: { enabled in
                        let idx = safeBandIndex(0)
                        settings.bands[idx].isEnabled = true
                        settings.bands[idx].type = .highPass
                        settings.bands[idx].frequencyHz = enabled ? 90 : 40
                        settings.bands[idx].q = 0.707
                        settings.bands[idx].gainDB = 0
                    }
                ))

                Toggle("Voice Isolation Starter", isOn: Binding(
                    get: { settings.voiceIsolation.isEnabled },
                    set: { enabled in
                        if enabled {
                            settings.voiceIsolation = .init(
                                isEnabled: true,
                                strength: 58,
                                noiseFloorDB: -58,
                                speechThresholdDB: -42,
                                reductionDB: 22,
                                focusLowHz: 85,
                                focusHighHz: 11_500,
                                attackMs: 8,
                                releaseMs: 320,
                                presenceBoostDB: 1.5
                            )
                        } else {
                            settings.voiceIsolation = .disabled
                        }
                    }
                ))

                Toggle("Typing Noise Helper (gate defaults)", isOn: Binding(
                    get: { settings.noiseGate.isEnabled },
                    set: { enabled in
                        if enabled {
                            // Smooth, speech-safe gate defaults (reduces “jumpscare” re-open).
                            settings.noiseGate = .init(
                                isEnabled: true,
                                thresholdDB: -45,
                                hysteresisDB: 5,
                                rangeDB: 28,
                                attackMs: 6,
                                holdMs: 140,
                                releaseMs: 240
                            )
                        } else {
                            settings.noiseGate = .disabled
                        }
                    }
                ))

                Toggle("Smooth Gate (anti‑jumpscare)", isOn: Binding(
                    get: { settings.noiseGate.isEnabled && settings.noiseGate.releaseMs >= 200 },
                    set: { enabled in
                        guard settings.noiseGate.isEnabled else { return }
                        if enabled {
                            settings.noiseGate.attackMs = max(settings.noiseGate.attackMs, 6)
                            settings.noiseGate.holdMs = max(settings.noiseGate.holdMs, 120)
                            settings.noiseGate.releaseMs = max(settings.noiseGate.releaseMs, 240)
                            settings.noiseGate.hysteresisDB = max(settings.noiseGate.hysteresisDB, 5)
                        } else {
                            settings.noiseGate.attackMs = min(settings.noiseGate.attackMs, 3)
                            settings.noiseGate.holdMs = min(settings.noiseGate.holdMs, 60)
                            settings.noiseGate.releaseMs = min(settings.noiseGate.releaseMs, 140)
                        }
                    }
                ))

                Text("For best results: use headphones, reduce room noise, and keep the mic ~20–30cm away.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var broadcastBox: some View {
        GroupBox("Broadcast Helpers") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Broadcast Compressor (starter)", isOn: Binding(
                    get: { settings.compressor.isEnabled },
                    set: { enabled in
                        if enabled {
                            settings.compressor = .init(
                                isEnabled: true,
                                thresholdDB: -20,
                                ratio: 3.0,
                                kneeDB: 6.0,
                                attackMs: 8.0,
                                releaseMs: 100.0,
                                makeupGainDB: 2.0
                            )
                        } else {
                            settings.compressor = .disabled
                        }
                    }
                ))

                Toggle("Clip Guard (limiter‑ish)", isOn: Binding(
                    get: { settings.compressor.isEnabled && settings.compressor.ratio >= 8 },
                    set: { enabled in
                        if enabled {
                            settings.compressor = .init(
                                isEnabled: true,
                                thresholdDB: -10,
                                ratio: 12.0,
                                kneeDB: 0.0,
                                attackMs: 1.5,
                                releaseMs: 80.0,
                                makeupGainDB: 0.0
                            )
                            settings.outputGainDB = min(settings.outputGainDB, 0)
                        } else {
                            settings.compressor = .disabled
                        }
                    }
                ))

                Toggle("De‑Esser Starter", isOn: Binding(
                    get: { settings.deEsser.isEnabled },
                    set: { enabled in
                        if enabled {
                            settings.deEsser = .init(
                                isEnabled: true,
                                frequencyHz: 7500,
                                q: 3.0,
                                thresholdDB: -22,
                                ratio: 6.0,
                                attackMs: 2.0,
                                releaseMs: 60.0,
                                maxReductionDB: 8.0
                            )
                        } else {
                            settings.deEsser = .disabled
                        }
                    }
                ))

                Text("Use these as a starting point, then fine-tune in the sections below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var voiceIsolationBox: some View {
        GroupBox("Voice Isolation (background noise while talking)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Voice Isolation", isOn: $settings.voiceIsolation.isEnabled)

                if settings.voiceIsolation.isEnabled {
                    sliderRow(
                        title: "Isolation Strength",
                        value: $settings.voiceIsolation.strength,
                        range: 0...100,
                        step: 1,
                        valueLabel: { String(format: "%.0f%%", settings.voiceIsolation.strength) }
                    )
                    sliderRow(
                        title: "Noise Floor",
                        value: $settings.voiceIsolation.noiseFloorDB,
                        range: -90...(-10),
                        step: 1,
                        valueLabel: { String(format: "%.0f dBFS", settings.voiceIsolation.noiseFloorDB) }
                    )
                    sliderRow(
                        title: "Speech Threshold",
                        value: $settings.voiceIsolation.speechThresholdDB,
                        range: -80...0,
                        step: 1,
                        valueLabel: { String(format: "%.0f dBFS", settings.voiceIsolation.speechThresholdDB) }
                    )
                    sliderRow(
                        title: "Noise Reduction",
                        value: $settings.voiceIsolation.reductionDB,
                        range: 0...80,
                        step: 1,
                        valueLabel: { String(format: "%.0f dB", settings.voiceIsolation.reductionDB) }
                    )
                    sliderRow(
                        title: "Voice Low Cut",
                        value: $settings.voiceIsolation.focusLowHz,
                        range: 40...400,
                        step: 1,
                        valueLabel: { String(format: "%.0f Hz", settings.voiceIsolation.focusLowHz) }
                    )
                    sliderRow(
                        title: "Voice High Cut",
                        value: $settings.voiceIsolation.focusHighHz,
                        range: 2000...18_000,
                        step: 50,
                        valueLabel: {
                            settings.voiceIsolation.focusHighHz >= 1000
                                ? String(format: "%.1f kHz", settings.voiceIsolation.focusHighHz / 1000.0)
                                : String(format: "%.0f Hz", settings.voiceIsolation.focusHighHz)
                        }
                    )
                    sliderRow(
                        title: "Open Speed",
                        value: $settings.voiceIsolation.attackMs,
                        range: 0...80,
                        step: 1,
                        valueLabel: { String(format: "%.0f ms", settings.voiceIsolation.attackMs) }
                    )
                    sliderRow(
                        title: "Smooth Release",
                        value: $settings.voiceIsolation.releaseMs,
                        range: 20...2000,
                        step: 10,
                        valueLabel: { String(format: "%.0f ms", settings.voiceIsolation.releaseMs) }
                    )
                    sliderRow(
                        title: "Presence After Isolation",
                        value: $settings.voiceIsolation.presenceBoostDB,
                        range: -6...8,
                        step: 0.5,
                        valueLabel: { String(format: "%+.1f dB", settings.voiceIsolation.presenceBoostDB) }
                    )
                } else {
                    Text("Use this when background noise is audible while you speak. It smoothly focuses the voice band instead of hard-cutting like a gate.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var noiseGateBox: some View {
        GroupBox("Noise Gate (background noise removal)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Noise Gate", isOn: $settings.noiseGate.isEnabled)

                if settings.noiseGate.isEnabled {
                    sliderRow(
                        title: "Threshold",
                        value: $settings.noiseGate.thresholdDB,
                        range: -80...0,
                        step: 1,
                        valueLabel: { String(format: "%.0f dBFS", settings.noiseGate.thresholdDB) }
                    )
                    sliderRow(
                        title: "Range",
                        value: $settings.noiseGate.rangeDB,
                        range: 0...80,
                        step: 1,
                        valueLabel: { String(format: "%.0f dB", settings.noiseGate.rangeDB) }
                    )
                    sliderRow(
                        title: "Hold",
                        value: $settings.noiseGate.holdMs,
                        range: 0...500,
                        step: 5,
                        valueLabel: { String(format: "%.0f ms", settings.noiseGate.holdMs) }
                    )
                    sliderRow(
                        title: "Release",
                        value: $settings.noiseGate.releaseMs,
                        range: 0...1500,
                        step: 5,
                        valueLabel: { String(format: "%.0f ms", settings.noiseGate.releaseMs) }
                    )
                    sliderRow(
                        title: "Hysteresis",
                        value: $settings.noiseGate.hysteresisDB,
                        range: 0...12,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f dB", settings.noiseGate.hysteresisDB) }
                    )
                    sliderRow(
                        title: "Attack",
                        value: $settings.noiseGate.attackMs,
                        range: 0...50,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f ms", settings.noiseGate.attackMs) }
                    )
                } else {
                    Text("Turn this on to reduce room noise when you’re not speaking. Use headphones when monitoring.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var compressorBox: some View {
        GroupBox("Compressor (loudness + clarity)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Compressor", isOn: $settings.compressor.isEnabled)

                if settings.compressor.isEnabled {
                    sliderRow(
                        title: "Threshold",
                        value: $settings.compressor.thresholdDB,
                        range: -60...0,
                        step: 1,
                        valueLabel: { String(format: "%.0f dBFS", settings.compressor.thresholdDB) }
                    )
                    sliderRow(
                        title: "Ratio",
                        value: $settings.compressor.ratio,
                        range: 1...20,
                        step: 0.1,
                        valueLabel: { String(format: "%.1f:1", settings.compressor.ratio) }
                    )
                    sliderRow(
                        title: "Knee",
                        value: $settings.compressor.kneeDB,
                        range: 0...24,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f dB", settings.compressor.kneeDB) }
                    )
                    sliderRow(
                        title: "Attack",
                        value: $settings.compressor.attackMs,
                        range: 0...50,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f ms", settings.compressor.attackMs) }
                    )
                    sliderRow(
                        title: "Release",
                        value: $settings.compressor.releaseMs,
                        range: 5...1000,
                        step: 5,
                        valueLabel: { String(format: "%.0f ms", settings.compressor.releaseMs) }
                    )
                    sliderRow(
                        title: "Makeup",
                        value: $settings.compressor.makeupGainDB,
                        range: -12...18,
                        step: 0.5,
                        valueLabel: { String(format: "%+.1f dB", settings.compressor.makeupGainDB) }
                    )
                } else {
                    Text("Turn this on to even out volume and bring up quieter details. If it distorts, lower Preamp or Threshold.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var deEsserBox: some View {
        GroupBox("De-Esser (reduce harsh ‘S’ sounds)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable De-Esser", isOn: $settings.deEsser.isEnabled)

                if settings.deEsser.isEnabled {
                    sliderRow(
                        title: "Frequency",
                        value: $settings.deEsser.frequencyHz,
                        range: 2000...12_000,
                        step: 50,
                        valueLabel: {
                            settings.deEsser.frequencyHz >= 1000
                                ? String(format: "%.2f kHz", settings.deEsser.frequencyHz / 1000.0)
                                : String(format: "%.0f Hz", settings.deEsser.frequencyHz)
                        }
                    )
                    sliderRow(
                        title: "Q",
                        value: $settings.deEsser.q,
                        range: 0.3...10,
                        step: 0.1,
                        valueLabel: { String(format: "%.1f", settings.deEsser.q) }
                    )
                    sliderRow(
                        title: "Threshold",
                        value: $settings.deEsser.thresholdDB,
                        range: -60...0,
                        step: 1,
                        valueLabel: { String(format: "%.0f dBFS", settings.deEsser.thresholdDB) }
                    )
                    sliderRow(
                        title: "Ratio",
                        value: $settings.deEsser.ratio,
                        range: 1...20,
                        step: 0.1,
                        valueLabel: { String(format: "%.1f:1", settings.deEsser.ratio) }
                    )
                    sliderRow(
                        title: "Max Reduction",
                        value: $settings.deEsser.maxReductionDB,
                        range: 0...24,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f dB", settings.deEsser.maxReductionDB) }
                    )
                    sliderRow(
                        title: "Attack",
                        value: $settings.deEsser.attackMs,
                        range: 0...20,
                        step: 0.2,
                        valueLabel: { String(format: "%.1f ms", settings.deEsser.attackMs) }
                    )
                    sliderRow(
                        title: "Release",
                        value: $settings.deEsser.releaseMs,
                        range: 10...500,
                        step: 2,
                        valueLabel: { String(format: "%.0f ms", settings.deEsser.releaseMs) }
                    )
                } else {
                    Text("Use this if the mic is too sharp/sibilant. Pair with small high-shelf boosts for ‘air’ without harshness.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: () -> String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .frame(minWidth: 260)
                Text(valueLabel())
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
            }
        }
    }

    private func safeBandIndex(_ idx: Int) -> Int {
        min(max(0, idx), max(0, settings.bands.count - 1))
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }
}
