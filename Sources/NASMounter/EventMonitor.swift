import AppKit
import Foundation
import Network

/// Watches for user-visible system events that should trigger a remount.
/// Dark wakes intentionally leave automatic mounting suspended so NAS checks do
/// not extend background activity while the lid/display is asleep.
final class EventMonitor {
    static let shared = EventMonitor()

    private var pathMonitor: NWPathMonitor?
    private var watchdog: Timer?
    private var lastPathWasSatisfied = false
    private var automaticMountsSuspended = false
    private let stateLock = NSLock()

    private init() {}

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(screenDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(screenDidWake),
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

            self.stateLock.lock()
            let becameReachable = satisfied && !self.lastPathWasSatisfied
            let automaticMountsAllowed = !self.automaticMountsSuspended
            self.lastPathWasSatisfied = satisfied
            self.stateLock.unlock()

            // Only react to offline -> online transitions.
            if becameReachable && automaticMountsAllowed {
                self.triggerMount(after: 3, reason: "network became reachable")
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.nasmounter.network"))
        pathMonitor = monitor
    }

    private func startWatchdog() {
        // Periodic safety net: if a share dropped for any reason, remount it.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard self?.automaticMountsAllowed == true else { return }
            MountManager.shared.mountAllIfNeeded(reason: "watchdog")
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    @objc private func systemWillSleep() {
        suspendAutomaticMounts(reason: "system sleep")
    }

    @objc private func screenDidSleep() {
        suspendAutomaticMounts(reason: "screen sleep")
    }

    @objc private func systemDidWake() {
        // This notification is also delivered for dark wakes. Wait for an
        // actual screen wake or unlock before touching a network share.
        NSLog("NASMounter: system woke; waiting for screen wake or unlock")
    }

    @objc private func screenDidWake() {
        resumeAutomaticMounts(reason: "screen wake")
        // Give Wi-Fi/Ethernet a moment to re-establish before mounting.
        triggerMount(after: 5, reason: "wake from sleep")
        triggerMount(after: 15, reason: "wake from sleep (retry)")
    }

    @objc private func screenUnlocked() {
        resumeAutomaticMounts(reason: "screen unlocked")
        triggerMount(after: 2, reason: "screen unlocked")
    }

    private func triggerMount(after delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.automaticMountsAllowed == true else { return }
            MountManager.shared.mountAllIfNeeded(reason: reason)
        }
    }

    private var automaticMountsAllowed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !automaticMountsSuspended
    }

    private func suspendAutomaticMounts(reason: String) {
        stateLock.lock()
        let changed = !automaticMountsSuspended
        automaticMountsSuspended = true
        stateLock.unlock()
        if changed {
            NSLog("NASMounter: automatic mounts paused — \(reason)")
        }
    }

    private func resumeAutomaticMounts(reason: String) {
        stateLock.lock()
        let changed = automaticMountsSuspended
        automaticMountsSuspended = false
        stateLock.unlock()
        if changed {
            NSLog("NASMounter: automatic mounts resumed — \(reason)")
        }
    }
}
