import AppKit
import SwiftUI

struct InstallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isInstalling = false
    @State private var didAutoStart = false
    @State private var animateIn = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                if let url = Bundle.main.url(forResource: "MACQ_logo", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 86)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                        .scaleEffect(animateIn ? 1 : 0.96)
                        .opacity(animateIn ? 1 : 0)
                } else {
                    Text("MACQ")
                        .font(.system(size: 42, weight: .semibold))
                }
                Text("Virtual microphone driver + realtime EQ")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                statusRow
                if isInstalling || model.installProgress.fraction > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.installProgress.fraction)
                        Text(model.installProgress.phase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastError = model.lastError {
                    Text(lastError)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .macqPanel(cornerRadius: 10)
            .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button {
                    Task {
                        isInstalling = true
                        defer { isInstalling = false }
                        await model.quickSetup()
                    }
                } label: {
                    Text("Quick Setup")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)

                Button {
                    Task { await model.refresh() }
                } label: {
                    Text("Re-check")
                }
                .buttonStyle(.bordered)
                .disabled(isInstalling)
            }

            Text("Installing requires admin permission and will restart CoreAudio (brief audio cut).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macqRootSurface()
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                animateIn = true
            }

            guard didAutoStart == false else { return }
            didAutoStart = true
            Task {
                isInstalling = true
                defer { isInstalling = false }
                await model.autoSetupIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.headline)
            Spacer()
        }
    }

    private var statusText: String {
        switch model.driverState {
        case .unknown:
            return "Checking driver…"
        case .notInstalled:
            return "Driver not installed"
        case .installed:
            return "Driver installed"
        case .installFailed:
            return "Install failed"
        }
    }

    private var statusColor: Color {
        switch model.driverState {
        case .installed:
            return .green
        case .unknown:
            return .gray
        case .notInstalled, .installFailed:
            return .orange
        }
    }
}
