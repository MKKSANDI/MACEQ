import AppKit
import SwiftUI

struct HotKeyRecorderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    isRecording = true
                } label: {
                    Text(isRecording ? "Press key combo…" : model.muteHotKeyDisplay)
                        .frame(minWidth: 170)
                }
                .buttonStyle(.borderedProminent)

                Button("Clear") {
                    model.clearMuteHotKey()
                    isRecording = false
                }
                .disabled(model.muteHotKey == nil)

                Text("Click the top-bar MACQ icon or use this hotkey to mute/unmute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let status = model.hotKeyStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .background(
            HotKeyCaptureView(isRecording: $isRecording) { hotKey in
                model.setMuteHotKey(hotKey)
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
        )
    }
}

private struct HotKeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (MACQHotKey?) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onCapture = onCapture
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.onCapture = { hotKey in
            onCapture(hotKey)
            isRecording = false
        }
        nsView.onCancel = { isRecording = false }

        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class RecorderNSView: NSView {
        var onCapture: ((MACQHotKey?) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }

            if event.keyCode == 51 {
                onCapture?(nil)
                return
            }

            onCapture?(MACQHotKey(keyCode: event.keyCode, modifierFlags: event.modifierFlags))
        }
    }
}
