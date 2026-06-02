import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppBackgroundView()

            Group {
                switch model.driverState {
                case .installed:
                    MainView(meters: model.meters)
                case .unknown, .notInstalled, .installFailed:
                    InstallView()
                }
            }
        }
        .macqRootSurface()
        .alert(alertTitle, isPresented: Binding(
            get: { model.lastError != nil || model.restartPrompt != nil },
            set: { presented in
                if presented == false {
                    model.lastError = nil
                    model.restartPrompt = nil
                }
            }
        )) {
            if model.restartPrompt != nil {
                Button("Restart Now") { model.restartNow() }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(alertMessage)
        }
        .onChange(of: model.selectedInputDevice) { _ in
            if model.isRunning {
                Task { await model.start() }
            }
        }
        .onChange(of: model.isMonitoringEnabled) { _ in
            if model.isRunning {
                Task { await model.start() }
            }
        }
        .onChange(of: model.selectedMonitorOutputDevice) { _ in
            if model.isRunning && model.isMonitoringEnabled {
                Task { await model.start() }
            }
        }
        .onAppear {
            Task { await model.refresh() }
            Task { await model.requestLaunchPermissionsIfNeeded() }
        }
    }

    private var alertTitle: String {
        model.restartPrompt?.title ?? "MACQ"
    }

    private var alertMessage: String {
        if let prompt = model.restartPrompt { return prompt.message }
        return model.lastError ?? ""
    }
}
