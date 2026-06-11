import Foundation

/// Network file protocols supported by macOS's NetFS framework.
enum ShareProtocol: String, Codable, CaseIterable, Identifiable {
    case smb
    case afp
    case nfs
    case webdav
    case webdavSecure
    case ftp

    var id: String { rawValue }

    /// User-facing name shown in the protocol picker.
    var displayName: String {
        switch self {
        case .smb: return "SMB (Windows / most NAS)"
        case .afp: return "AFP (older Apple)"
        case .nfs: return "NFS (Unix / Linux)"
        case .webdav: return "WebDAV (http)"
        case .webdavSecure: return "WebDAV (https)"
        case .ftp: return "FTP"
        }
    }

    var scheme: String {
        switch self {
        case .smb: return "smb"
        case .afp: return "afp"
        case .nfs: return "nfs"
        case .webdav: return "http"
        case .webdavSecure: return "https"
        case .ftp: return "ftp"
        }
    }

    /// Placeholder for the share/path field, since terminology varies by protocol.
    var sharePlaceholder: String {
        switch self {
        case .smb, .afp: return "e.g. Media, TimeMachine"
        case .nfs: return "exported path, e.g. volume1/Media"
        case .webdav, .webdavSecure: return "path, e.g. dav/files"
        case .ftp: return "path (often empty)"
        }
    }
}

/// A single network share the user wants kept mounted.
struct ShareConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var proto: ShareProtocol = .smb
    var host: String = ""        // e.g. "nas.local" or "192.168.1.10"
    var shareName: String = ""   // e.g. "Media" or "TimeMachine"
    var username: String = ""
    var enabled: Bool = true

    // Tolerate configs saved before the protocol field existed.
    enum CodingKeys: String, CodingKey {
        case id, proto, host, shareName, username, enabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        proto = try container.decodeIfPresent(ShareProtocol.self, forKey: .proto) ?? .smb
        host = try container.decode(String.self, forKey: .host)
        shareName = try container.decode(String.self, forKey: .shareName)
        username = try container.decode(String.self, forKey: .username)
        enabled = try container.decode(Bool.self, forKey: .enabled)
    }

    var displayName: String {
        shareName.isEmpty ? host : "\(shareName) (\(host))"
    }

    /// e.g. smb://host/share, nfs://host/export, https://host/dav
    var url: URL? {
        var components = URLComponents()
        components.scheme = proto.scheme
        components.host = host
        let path = shareName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/" : "/" + path
        return components.url
    }
}

/// Persists share configurations in UserDefaults (passwords go to the Keychain).
final class ShareStore {
    static let shared = ShareStore()
    private let defaultsKey = "shares"

    private(set) var shares: [ShareConfig] = []

    private init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ShareConfig].self, from: data) else {
            shares = []
            return
        }
        shares = decoded
    }

    func save(_ newShares: [ShareConfig]) {
        shares = newShares
        if let data = try? JSONEncoder().encode(newShares) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: .sharesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let sharesDidChange = Notification.Name("sharesDidChange")
    static let mountStateDidChange = Notification.Name("mountStateDidChange")
}
