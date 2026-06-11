import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "externaldrive.connected.to.line.below",
                accessibilityDescription: "NAS Mounter"
            )
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        EventMonitor.shared.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .mountStateDidChange, object: nil
        )

        // First run: open settings so the user can add shares.
        if ShareStore.shared.shares.isEmpty {
            openSettings()
        }
    }

    @objc private func stateChanged() {
        DispatchQueue.main.async { self.updateIcon() }
    }

    private func updateIcon() {
        let shares = ShareStore.shared.shares.filter { $0.enabled }
        let allMounted = !shares.isEmpty && shares.allSatisfy { MountManager.shared.isMounted($0) }
        let symbol = allMounted
            ? "externaldrive.fill.badge.checkmark"
            : "externaldrive.connected.to.line.below"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "NAS Mounter"
        )
    }

    // MARK: - Menu actions

    @objc private func mountAllNow() {
        MountManager.shared.mountAllIfNeeded(reason: "manual request")
    }

    @objc private func toggleShare(_ sender: NSMenuItem) {
        guard let share = sender.representedObject as? ShareConfig else { return }
        if MountManager.shared.isMounted(share) {
            MountManager.shared.unmount(share)
        } else {
            MountManager.shared.mount(share)
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "NAS Mounter Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Menu construction

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let shares = ShareStore.shared.shares
        if shares.isEmpty {
            let item = NSMenuItem(title: "No shares configured", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for share in shares {
                let mounted = MountManager.shared.isMounted(share)
                let title = "\(mounted ? "🟢" : "⚪️") \(share.displayName)"
                let item = NSMenuItem(title: title, action: #selector(toggleShare(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = share
                item.toolTip = mounted ? "Click to unmount" : "Click to mount"
                if !share.enabled {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let mountAll = NSMenuItem(title: "Mount All Now", action: #selector(mountAllNow), keyEquivalent: "m")
        mountAll.target = self
        menu.addItem(mountAll)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NAS Mounter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
