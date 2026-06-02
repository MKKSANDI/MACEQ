import SwiftUI

struct MicEQCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("MACQ") {
            Button(model.isRunning ? "Stop Processing" : "Start Processing") {
                if model.isRunning {
                    model.stop()
                } else {
                    Task { await model.start() }
                }
            }
            .keyboardShortcut(.space, modifiers: [])

            Divider()

            Menu("Input Device") {
                ForEach(model.inputDevices, id: \.self) { dev in
                    Button {
                        model.selectedInputDevice = dev
                    } label: {
                        if model.selectedInputDevice == dev {
                            Text("✓ \(dev.name)")
                        } else {
                            Text(dev.name)
                        }
                    }
                }
            }

            Toggle("Live Monitor (hear yourself)", isOn: $model.isMonitoringEnabled)

            Menu("Monitor Output") {
                ForEach(model.outputDevices, id: \.self) { dev in
                    Button {
                        model.selectedMonitorOutputDevice = dev
                    } label: {
                        if model.selectedMonitorOutputDevice == dev {
                            Text("✓ \(dev.name)")
                        } else {
                            Text(dev.name)
                        }
                    }
                }
            }
            .disabled(model.isMonitoringEnabled == false)

            Divider()

            Button("Restart Audio Engine") {
                Task { await model.restartAudio() }
            }

            Button(model.isMuted ? "Unmute MicEQ" : "Mute MicEQ") {
                model.toggleMute()
            }

            Divider()

            Button(model.eqSettings.isBypassed ? "Enable EQ" : "Bypass EQ") {
                var next = model.eqSettings
                next.isBypassed.toggle()
                model.applyEQSettings(next)
            }

            Button("Reset EQ") {
                model.applyEQSettings(.default)
            }
        }
    }
}
