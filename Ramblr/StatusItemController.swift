import AppKit
import SwiftUI

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let transcriptionManager: TranscriptionManager
    init(transcriptionManager: TranscriptionManager) {
        self.transcriptionManager = transcriptionManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        configurePopover()
        configureStatusItem()
        logInfo("StatusItemController: Installed menu bar status item")
    }

    @objc func togglePanel(_ sender: Any?) {
        logDebug("StatusItemController: Status item clicked")
        if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        }

        logInfo("StatusItemController: Showing control panel")
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePanel() {
        logDebug("StatusItemController: Closing control panel")
        popover.performClose(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "FreeTalking") {
            image.isTemplate = true
            button.image = image
        }

        button.toolTip = "FreeTalking"
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(transcriptionManager: transcriptionManager))
    }
}
