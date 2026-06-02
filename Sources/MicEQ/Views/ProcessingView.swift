import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: EQSettings = .default
    @State private var page: Page = .eq
    @State private var applyQueued: Bool = false
    @State private var applyGeneration: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Text("Mode")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                    modeButton("EQ", .eq)
                    modeButton("Voice Tools", .voiceTools)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .overlay(MACQTheme.panelStroke)

            Group {
                switch page {
                case .eq:
                    EQView(settings: $draft)
                case .voiceTools:
                    VoiceToolsView(settings: $draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .macqRootSurface()
        .onAppear {
            // Initialize local state from the model, but keep local editing smooth by
            // not binding every slider tick directly to the global model object.
            draft = model.eqSettings
        }
        .onChange(of: draft) { _ in
            recordDraftChange()
        }
        .onChange(of: model.eqSettings) { newValue in
            // If we're not in the middle of a local drag/apply burst, reflect external changes
            // (presets, AI apply, reset-from-menu, etc).
            guard applyQueued == false else { return }
            if draft != newValue {
                draft = newValue
            }
        }
    }

    private enum Page: Hashable {
        case eq
        case voiceTools
    }

    private func modeButton(_ title: String, _ value: Page) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                page = value
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(page == value ? Color.black.opacity(0.86) : Color.white.opacity(0.80))
                .frame(width: value == .eq ? 92 : 116, height: 28)
                .background {
                    Capsule()
                        .fill(page == value ? AnyShapeStyle(MACQTheme.electricCyan) : AnyShapeStyle(MACQTheme.controlGradient))
                }
                .overlay {
                    Capsule().stroke(page == value ? MACQTheme.strongStroke : MACQTheme.panelStroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func recordDraftChange() {
        applyGeneration &+= 1
        scheduleDrainIfNeeded()
    }

    private func scheduleDrainIfNeeded() {
        guard applyQueued == false else { return }
        applyQueued = true
        Task { @MainActor in await drainApplies() }
    }

    private func drainApplies() async {
        var lastApplied: UInt64 = 0
        while true {
            let gen = applyGeneration
            guard gen != lastApplied else { break }
            lastApplied = gen

            // Do not push every slider tick into the realtime engine. Waiting for a
            // short idle window keeps dragging smooth and applies right after release.
            try? await Task.sleep(for: .milliseconds(180))
        }

        applyQueued = false

        // Commit once after the user stops changing controls.
        if model.eqSettings != draft {
            model.applyEQSettings(draft)
        }

        // If something changed after we dropped the queued flag, run one more drain.
        if applyGeneration != lastApplied {
            scheduleDrainIfNeeded()
        }
    }
}
