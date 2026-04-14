import Cocoa
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private weak var prManager: PRManagerType?

    private var eventMonitor: Any?

    init(popover: NSPopover, prManager: PRManagerType) {
        self.statusBar = NSStatusBar.system
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = popover
        self.prManager = prManager

        super.init()

        setupStatusBarButton()
        popover.delegate = self
        setupEventMonitor()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupStatusBarButton() {
        guard let button = statusItem.button else { return }

        // Use SF Symbol for menu bar icon (GitHub-like icon)
        if let image = NSImage(
            systemSymbolName: "arrow.triangle.pull",
            accessibilityDescription: String(localized: "Pull Requests")
        ) {
            image.isTemplate = true
            button.image = image
        } else {
            // Fallback to text if SF Symbol not available
            button.title = "PR"
        }

        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupMenu() -> NSMenu {
        let menu = NSMenu()

        // Version info
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let gitVersion = GitVersion.displayString
        let versionItem = NSMenuItem(
            title: String(localized: "PR Dashboard v\(version) (\(build)) \(gitVersion)"),
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit PR Dashboard"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func handleClick(_ sender: AnyObject) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            statusItem.menu = setupMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover(sender)
        }
    }

    private func setupEventMonitor() {
        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.hidePopover(self)
            }
        }
    }

    func updateBadge(count: Int) {
        guard let button = statusItem.button else { return }

        if count > 0 {
            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }

            // Add badge count as title
            button.title = " \(count > 99 ? "99+" : "\(count)")"
        } else {
            button.title = ""
            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }
        }
    }

    @objc func togglePopover(_ sender: AnyObject) {
        if popover.isShown {
            hidePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    func showPopover(_ sender: AnyObject) {
        guard let button = statusItem.button else { return }

        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func hidePopover(_ sender: AnyObject) {
        popover.performClose(sender)
        statusItem.button?.highlight(false)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        prManager?.enablePolling(true)
    }

    func popoverWillClose(_ notification: Notification) {
        // Keep polling active in background for notifications
        // prManager?.enablePolling(false)
        statusItem.button?.highlight(false)
    }
}
