import AppKit
import Foundation

struct AppAudioSource: Identifiable {
    let id: pid_t
    let processIdentifier: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?

    init(app: NSRunningApplication) {
        self.id = app.processIdentifier
        self.processIdentifier = app.processIdentifier
        self.name = Self.displayName(for: app)
        self.bundleIdentifier = app.bundleIdentifier
        self.icon = app.icon
    }

    private static func displayName(for app: NSRunningApplication) -> String {
        let raw = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? "Process \(app.processIdentifier)"
        return raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
    }
}

