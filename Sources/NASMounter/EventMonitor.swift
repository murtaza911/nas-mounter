import AppKit
import Foundation
import Network

/// Watches for system events that should trigger a remount:
/// wake from sleep, network path changes, screen unlock, and a periodic watchdog.
final class EventMonitor {
    static let shared = EventMonitor()

    private var pathMonitor: NWPathMonitor?
    private var watchdog: Timer?
    private var lastPathWasSatisfied = false

    private init() {}

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )

        // Screen unlock (helps when network only comes back after unlock).
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )

        startNetworkMonitor()
        startWatchdog()

        // Initial mount at launch (covers login/startup).
        triggerMount(after: 2, reason: "app launch")
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            // Only react to offline -> online transitions.
            if satisfied && !self.lastPathWasSatisfied {
                self.triggerMount(after: 3, reason: "network became reachable")
            }
            self.lastPathWasSatisfied = satisfied
        }
        monitor.start(queue: DispatchQueue(label: "com.nasmounter.network"))
        pathMonitor = monitor
    }

    private func startWatchdog() {
        // Periodic safety net: if a share dropped for any reason, remount it.
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MountManager.shared.mountAllIfNeeded(reason: "watchdog")
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    @objc private func systemDidWake() {
        // Give Wi-Fi/Ethernet a moment to re-establish before mounting.
        triggerMount(after: 5, reason: "wake from sleep")
        triggerMount(after: 15, reason: "wake from sleep (retry)")
    }

    @objc private func screenUnlocked() {
        triggerMount(after: 2, reason: "screen unlocked")
    }

    private func triggerMount(after delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MountManager.shared.mountAllIfNeeded(reason: reason)
        }
    }
}
