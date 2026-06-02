import SwiftUI
import AppKit

@main
struct MACQApp: App {
    @NSApplicationDelegateAdaptor(MACQAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MACQ") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1220, minHeight: 620)
                .tint(.cyan)
                .macqHideMainWindowOnClose()
                .onAppear {
                    appDelegate.configure(model: model)
                }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
        .commands {
            MicEQCommands(model: model)
        }
    }
}
