import AppKit
import SwiftUI

struct MACQWindowCloseHider: NSViewRepresentable {
    static let mainWindowIdentifier = "MACQMainWindow"

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            attach(to: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            attach(to: nsView.window, coordinator: context.coordinator)
        }
    }

    private func attach(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(Self.mainWindowIdentifier)
        window.isReleasedWhenClosed = false
        if window.delegate !== coordinator {
            window.delegate = coordinator
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}

extension View {
    func macqHideMainWindowOnClose() -> some View {
        background(MACQWindowCloseHider().frame(width: 0, height: 0))
    }
}
