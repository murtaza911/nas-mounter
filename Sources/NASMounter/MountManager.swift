import AppKit
import Foundation
import NetFS

/// Mounts SMB shares and reports their current state.
final class MountManager: @unchecked Sendable {
    static let shared = MountManager()

    private let queue = DispatchQueue(label: "com.nasmounter.mount", qos: .utility)
    private var inFlight = Set<UUID>()
    private let inFlightLock = NSLock()

    /// True if a volume backed by this share's URL is currently mounted.
    func isMounted(_ share: ShareConfig) -> Bool {
        isMounted(share, includeHiddenVolumes: false)
    }

    /// True when the share is mounted anywhere, including Time Machine's
    /// private mount beneath /Volumes/.timemachine.
    private func isMountedAnywhere(_ share: ShareConfig) -> Bool {
        isMounted(share, includeHiddenVolumes: true)
    }

    private func isMounted(_ share: ShareConfig, includeHiddenVolumes: Bool) -> Bool {
        guard let shareURL = share.url else { return false }
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: includeHiddenVolumes ? [] : [.skipHiddenVolumes]
        ) ?? []

        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  let remountURL = values.volumeURLForRemounting else { continue }
            if matches(remountURL, shareURL) { return true }
        }
        return false
    }

    private func matches(_ a: URL, _ b: URL) -> Bool {
        guard let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased() else { return false }
        let pathA = a.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathB = b.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return hostA == hostB && pathA == pathB
    }

    /// Mounts every enabled share that isn't already mounted.
    func mountAllIfNeeded(reason: String) {
        let shares = ShareStore.shared.shares.filter { $0.enabled }
        guard !shares.isEmpty else { return }
        let missingShares = shares.filter { !isMountedAnywhere($0) }
        guard !missingShares.isEmpty else { return }
        NSLog("NASMounter: mounting \(missingShares.count) missing share(s) — \(reason)")

        for share in missingShares {
            mount(share, avoidHiddenMounts: true)
        }
    }

    /// Mounts a single share asynchronously (no-op if a mount is already in progress).
    func mount(_ share: ShareConfig, avoidHiddenMounts: Bool = false) {
        guard let url = share.url, !share.host.isEmpty, !share.shareName.isEmpty else { return }

        inFlightLock.lock()
        let alreadyRunning = inFlight.contains(share.id)
        if !alreadyRunning { inFlight.insert(share.id) }
        inFlightLock.unlock()
        guard !alreadyRunning else { return }

        queue.async { [weak self] in
            defer {
                self?.inFlightLock.lock()
                self?.inFlight.remove(share.id)
                self?.inFlightLock.unlock()
                NotificationCenter.default.post(name: .mountStateDidChange, object: nil)
            }

            guard let self, !self.isMounted(share) else { return }
            if avoidHiddenMounts && self.isMountedAnywhere(share) {
                NSLog("NASMounter: skipped \(share.displayName); already mounted privately")
                return
            }

            let openOptions = NSMutableDictionary()
            // Never show a password dialog from a background daemon context;
            // credentials come from our Keychain entry (or the system one).
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI

            let mountOptions = NSMutableDictionary()
            mountOptions[kNetFSAllowSubMountsKey] = true
            mountOptions[kNetFSSoftMountKey] = true

            let username = share.username.isEmpty ? nil : share.username as CFString
            let password = Keychain.password(for: share.id) as CFString?

            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                url as CFURL,
                nil, // default mount location (/Volumes)
                username,
                password,
                openOptions,
                mountOptions,
                &mountpoints
            )
            mountpoints?.release()

            if status == 0 {
                NSLog("NASMounter: mounted \(share.displayName)")
            } else if status == EEXIST {
                NSLog("NASMounter: \(share.displayName) already mounted")
            } else {
                NSLog("NASMounter: failed to mount \(share.displayName) (error \(status))")
            }
        }
    }

    /// Unmounts a share's volume if mounted.
    func unmount(_ share: ShareConfig) {
        guard let shareURL = share.url else { return }
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  let remountURL = values.volumeURLForRemounting,
                  matches(remountURL, shareURL) else { continue }
            queue.async {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                    NSLog("NASMounter: unmounted \(share.displayName)")
                } catch {
                    NSLog("NASMounter: failed to unmount \(share.displayName): \(error.localizedDescription)")
                }
                NotificationCenter.default.post(name: .mountStateDidChange, object: nil)
            }
            return
        }
    }
}
