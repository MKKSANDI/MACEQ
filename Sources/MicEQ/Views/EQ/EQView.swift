import SwiftUI

struct EQView: View {
    @Binding var settings: EQSettings
    @State private var selectedBandID: EQBand.ID?

    var body: some View {
        VStack(spacing: 12) {
            header

            EQGraphView(settings: settings)
                .equatable()
                .frame(height: 220)
                .padding(.top, 6)

            HSplitView {
                bandList
                    .frame(minWidth: 260, idealWidth: 300)

                bandInspector
                    .frame(minWidth: 420)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .onAppear {
            if selectedBandID == nil {
                selectedBandID = settings.bands.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { settings.isBypassed == false },
                set: { enabled in settings.isBypassed = !enabled }
            )) {
                Text("EQ Enabled")
            }
            .toggleStyle(.switch)

            Divider()
                .frame(height: 18)

            InlineSliderRow("Preamp") {
                Slider(value: $settings.preampDB, in: -24...24, step: 0.5)
                    .frame(width: 160)
            }

            InlineSliderRow("Output") {
                Slider(value: $settings.outputGainDB, in: -24...24, step: 0.5)
                    .frame(width: 160)
            }

            Spacer()

            Button("Reset") { settings = .default }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var bandList: some View {
        List(selection: $selectedBandID) {
            ForEach(settings.bands.indices, id: \.self) { idx in
                let id = settings.bands[idx].id
                BandRow(index: idx, band: $settings.bands[idx])
                    .tag(id)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var bandInspector: some View {
        GroupBox {
            if let band = selectedBandBinding {
                BandInspector(band: band)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a band")
                        .font(.headline)
                    Text("Pick a band on the left to edit frequency, gain, Q, and type.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .padding(.leading, 6)
    }

    private var selectedBandBinding: Binding<EQBand>? {
        guard let id = selectedBandID,
              let idx = settings.bands.firstIndex(where: { $0.id == id }) else { return nil }
        return $settings.bands[idx]
    }
}

private struct InlineSliderRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            content
        }
    }
}

private struct BandRow: View {
    let index: Int
    @Binding var band: EQBand

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $band.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Text("Band \(index + 1)")
                    .font(.headline)
                Text(band.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(freqLabel(band.frequencyHz))
                    .font(.system(.body, design: .monospaced))
                Text(gainLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(8)
        .macqPanel(cornerRadius: 8)
    }

    private func freqLabel(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.2f kHz", hz / 1000.0)
        }
        return String(format: "%.0f Hz", hz)
    }

    private var gainLabel: String {
        if band.type == .peaking || band.type == .lowShelf || band.type == .highShelf {
            return String(format: "%+.1f dB", band.gainDB)
        }
        return "— dB"
    }
}

private struct BandInspector: View {
    @Binding var band: EQBand

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Enabled", isOn: $band.isEnabled)
                Spacer()
                Picker("Type", selection: $band.type) {
                    ForEach(EQBandType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            LabeledContent("Frequency") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { hzToNorm(band.frequencyHz) },
                            set: { band.frequencyHz = normToHz($0) }
                        ),
                        in: 0...1,
                        step: 0.001
                    )
                    Text(freqLabel(band.frequencyHz))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 86, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            if band.type == .peaking || band.type == .lowShelf || band.type == .highShelf {
                LabeledContent("Gain") {
                    HStack(spacing: 10) {
                        Slider(value: $band.gainDB, in: -24...24, step: 0.1)
                        Text(String(format: "%+.1f dB", band.gainDB))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 86, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Gain") {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Q") {
                HStack(spacing: 10) {
                    Slider(value: $band.q, in: 0.1...18, step: 0.05)
                    Text(String(format: "%.2f", band.q))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 86, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func freqLabel(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.2f kHz", hz / 1000.0)
        }
        return String(format: "%.0f Hz", hz)
    }

    private func hzToNorm(_ hz: Double) -> Double {
        let minHz = 20.0
        let maxHz = 20_000.0
        let clamped = max(minHz, min(maxHz, hz))
        let a = log10(minHz)
        let b = log10(maxHz)
        return (log10(clamped) - a) / (b - a)
    }

    private func normToHz(_ t: Double) -> Double {
        let minHz = 20.0
        let maxHz = 20_000.0
        let a = log10(minHz)
        let b = log10(maxHz)
        let x = a + max(0, min(1, t)) * (b - a)
        return pow(10.0, x)
    }
}
