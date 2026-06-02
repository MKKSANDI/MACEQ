import SwiftUI

struct AIAssistantView: View {
    @EnvironmentObject private var model: AppModel
    @State private var goalText: String = ""
    @State private var sampleSeconds: Double = 15.0
    @State private var aiPresetName: String = ""

    private let sampleSentence =
        "The quick brown fox jumps over the lazy dog. I can hear my voice clearly, with natural warmth and crisp detail."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                GroupBox("1) Read this sentence (repeat for the sample duration)") {
                    Text(sampleSentence)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .rounded))
                        .padding(.vertical, 6)
                }

                GroupBox("2) Describe the sound you want") {
                    TextField("Example: warm, bassy, radio voice, less nasal, less sibilant…", text: $goalText, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                }

                GroupBox("3) Generate AI Preset") {
                    HStack(spacing: 12) {
                        Text("Sample")
                            .foregroundStyle(.secondary)
                        Picker("Seconds", selection: $sampleSeconds) {
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                            Text("15s").tag(15.0)
                            Text("20s").tag(20.0)
                            Text("30s").tag(30.0)
                            Text("45s").tag(45.0)
                        }
                        .pickerStyle(.menu)

                        Spacer()
                    }
                    .padding(.bottom, 8)

                    HStack(spacing: 12) {
                        Button {
                            Task { await model.suggestEQWithGemini(goal: goalText, seconds: sampleSeconds) }
                        } label: {
                            Text(model.isAISuggesting ? "Working…" : "Generate EQ with Gemini")
                                .frame(minWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isAISuggesting)

                        if model.isAISuggesting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let status = model.aiStatus, model.isAISuggesting {
                            Text(status)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }

                    if model.hasGeminiAPIKey() == false {
                        Text("Add your Gemini API key in Settings → Gemini.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }

                    Text("Tip: use headphones and sit ~20–30cm from the mic. Keep input level below clipping.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                GroupBox("AI Preset") {
                    if let suggested = model.aiSuggestedSettings {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Gemini generated a preset. Preview it, apply it, or save it as a named preset.")
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button("Apply AI Preset") {
                                    model.applyAISuggestedSettings()
                                }
                                .buttonStyle(.borderedProminent)

                                TextField("Preset name", text: $aiPresetName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)

                                Button("Save to Presets") {
                                    model.saveAISuggestedSettingsAsPreset(name: aiPresetName)
                                    aiPresetName = ""
                                }
                                .buttonStyle(.bordered)

                                Spacer()
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Includes: EQ (96 bands), Voice Isolation, Noise Gate, Compressor, De-Esser.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Preamp \(String(format: "%+.1f dB", suggested.preampDB)) • Output \(String(format: "%+.1f dB", suggested.outputGainDB))")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } else {
                        Text("No AI preset yet. Click Generate to create one.")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Analysis (this sample)") {
                    if let a = model.aiAnalysis {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(format: "RMS %.1f dBFS • Peak %.1f dBFS • Noise ~%.1f dBFS",
                                        a.rmsDBFS, a.peakDBFS, a.noiseFloorDBFS))
                                .font(.headline)

                            Text(String(format: "SNR~%.1f dB • DynRange~%.1f dB • Crest %.1f dB • Level σ %.1f dB",
                                        a.snrEstimateDB, a.dynamicRangeDB, a.crestFactorDB, a.levelStdDevDB))
                                .foregroundStyle(.secondary)

                            if let f0 = a.estimatedPitchHz, let sd = a.pitchStdHz {
                                Text(String(format: "Pitch %.0f Hz (σ %.0f) • Voiced %.0f%%",
                                            f0, sd, a.voicedRatio * 100.0))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(String(format: "Pitch unavailable • Voiced %.0f%%", a.voicedRatio * 100.0))
                                    .foregroundStyle(.secondary)
                            }

                            if let centroid = a.spectralCentroidHz {
                                Text(String(format: "Centroid ~%.0f Hz • ZCR %.0f/s • Clip %.3f%% • Silence %.1f%%",
                                            centroid, a.zeroCrossingRateHz, a.clippedSamplePercent, a.silencePercent))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(String(format: "ZCR %.0f/s • Clip %.3f%% • Silence %.1f%%",
                                            a.zeroCrossingRateHz, a.clippedSamplePercent, a.silencePercent))
                                    .foregroundStyle(.secondary)
                            }

                            Divider().padding(.vertical, 4)

                            ForEach(a.bandEnergies) { band in
                                HStack {
                                    Text(bandLabel(band.rangeHz))
                                        .frame(width: 140, alignment: .leading)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f dBFS", band.rmsDBFS))
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } else {
                        Text("Run Generate once to record + analyze a sample.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .background(Color.clear)
        .macqRootSurface()
    }

    private func bandLabel(_ r: ClosedRange<Double>) -> String {
        if r.upperBound >= 1000 {
            return String(format: "%.0f–%.0fkHz", r.lowerBound, r.upperBound / 1000.0)
        }
        return String(format: "%.0f–%.0fHz", r.lowerBound, r.upperBound)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI EQ Assistant")
                .font(.title2.weight(.semibold))
            Text("Record a short voice sample, describe the vibe you want, and Gemini proposes EQ settings.")
                .foregroundStyle(.secondary)
        }
    }
}
