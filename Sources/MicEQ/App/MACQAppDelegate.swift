import AppKit
import Combine

@MainActor
final class MACQAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let automaticTerminationReason = "MACQ keeps the menu-bar mic controls and audio recovery available."
    private var allowsExplicitQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(automaticTerminationReason)
        setupStatusItemIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowsExplicitQuit ? .terminateNow : .terminateCancel
    }

    func configure(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        setupStatusItemIfNeeded()
        bindStatusItem(to: model)
        updateStatusItem()
    }

    private func setupStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MACQ — click to mute/unmute, right-click for options"
        updateStatusItem()
    }

    private func bindStatusItem(to model: AppModel) {
        cancellables.removeAll()
        Publishers.CombineLatest3(model.$isMuted, model.$isRunning, model.$isRestartingAudio)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let muted = model?.isMuted ?? false
        let running = model?.isRunning ?? false
        button.image = statusImage(muted: muted)
        button.image?.isTemplate = true
        button.contentTintColor = .white
        button.appearsDisabled = false
        button.toolTip = muted
            ? "MACQ muted — click to unmute, right-click for options"
            : "MACQ \(running ? "running" : "stopped") — click to mute, right-click for options"
    }

    private func statusImage(muted: Bool) -> NSImage? {
        let name = muted ? "MACQMenubarMutedTemplate" : "MACQMenubarTemplate"
        let image = NSImage(named: NSImage.Name(name))
            ?? Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: "MACQ")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            openStatusMenu()
        } else {
            model?.toggleMute()
        }
    }

    private func openStatusMenu() {
        let menu = NSMenu()

        menu.addItem(menuItem("Open MACQ", action: #selector(openMainWindow)))
        menu.addItem(menuItem("Restart Audio Engine", action: #selector(restartAudio)))

        if let model {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem(model.isRunning ? "Stop Processing" : "Start Processing", action: #selector(toggleProcessing)))
            let muteItem = menuItem(model.isMuted ? "Unmute MicEQ" : "Mute MicEQ", action: #selector(toggleMute))
            muteItem.state = model.isMuted ? .on : .off
            menu.addItem(muteItem)
            menu.addItem(menuItem("Refresh Devices", action: #selector(refreshDevices)))
            if let hotKey = model.muteHotKey {
                let info = NSMenuItem(title: "Mute Hotkey: \(hotKey.displayString)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Quit MACQ", action: #selector(quitMACQ)))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == MACQWindowCloseHider.mainWindowIdentifier }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.windows.first(where: { $0.title == "MACQ" })?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleProcessing() {
        guard let model else { return }
        if model.isRunning {
            model.stop()
        } else {
            Task { await model.start() }
        }
    }

    @objc private func toggleMute() {
        model?.toggleMute()
    }

    @objc private func restartAudio() {
        guard let model else { return }
        Task { await model.restartAudio() }
    }

    @objc private func refreshDevices() {
        guard let model else { return }
        Task { await model.refresh() }
    }

    @objc private func quitMACQ() {
        allowsExplicitQuit = true
        ProcessInfo.processInfo.enableAutomaticTermination(automaticTerminationReason)
        NSApplication.shared.terminate(nil)
    }
}
