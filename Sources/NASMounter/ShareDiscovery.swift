import Foundation

/// Enumerates the shares/exports a server offers, so the user can pick one
/// visually instead of typing the name. Typing remains fully supported —
/// discovery is strictly optional.
enum ShareDiscovery {

    enum DiscoveryError: LocalizedError {
        case unsupportedProtocol
        case commandFailed(String)
        case noSharesFound

        var errorDescription: String? {
            switch self {
            case .unsupportedProtocol:
                return "Share discovery is only available for SMB and NFS."
            case .commandFailed(let message):
                return message.isEmpty ? "Could not reach the server." : message
            case .noSharesFound:
                return "The server did not report any shares."
            }
        }
    }

    static func supportsDiscovery(_ proto: ShareProtocol) -> Bool {
        proto == .smb || proto == .nfs
    }

    /// Lists share names on `host`. Runs shell tools off the main thread.
    static func listShares(
        host: String,
        proto: ShareProtocol,
        username: String,
        password: String
    ) async throws -> [String] {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw DiscoveryError.commandFailed("Enter a server first.") }

        switch proto {
        case .smb:
            return try await listSMBShares(host: host, username: username, password: password)
        case .nfs:
            return try await listNFSExports(host: host)
        default:
            throw DiscoveryError.unsupportedProtocol
        }
    }

    // MARK: - SMB (smbutil view)

    private static func listSMBShares(host: String, username: String, password: String) async throws -> [String] {
        var arguments = ["view"]
        let target: String
        if username.isEmpty {
            // No credentials: ask smbutil not to prompt (guest/anonymous listing).
            arguments.append("-N")
            target = "//\(host)"
        } else {
            let allowed = CharacterSet.urlUserAllowed
            let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
            if password.isEmpty {
                arguments.append("-N")
                target = "//\(user)@\(host)"
            } else {
                let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
                target = "//\(user):\(pass)@\(host)"
            }
        }
        arguments.append(target)

        let result = try await run("/usr/bin/smbutil", arguments: arguments)
        guard result.exitCode == 0 else {
            throw DiscoveryError.commandFailed(friendlySMBError(result.stderr))
        }

        let shares = parseSMBView(result.stdout)
        guard !shares.isEmpty else { throw DiscoveryError.noSharesFound }
        return shares
    }

    /// `smbutil view` output is a whitespace-aligned table:
    ///   Share        Type   Comments
    ///   ----------------------------
    ///   Media        Disk
    ///   IPC$         Pipe   IPC Service
    /// We keep "Disk" shares and hide administrative ones ending in "$".
    static func parseSMBView(_ output: String) -> [String] {
        var shares: [String] = []
        for line in output.components(separatedBy: .newlines) {
            guard let range = line.range(of: #"^(.*?)\s{2,}(Disk)(\s|$)"#, options: .regularExpression) else {
                continue
            }
            let matched = String(line[range])
            guard let typeRange = matched.range(of: #"\s{2,}Disk(\s|$)"#, options: .regularExpression) else {
                continue
            }
            let name = String(matched[..<typeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != "Share", !name.hasSuffix("$") {
                shares.append(name)
            }
        }
        return shares
    }

    private static func friendlySMBError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("authentication") || lower.contains("permission denied") || lower.contains("logon failure") {
            return "The server refused the listing. Fill in the username and password, then try again."
        }
        if lower.contains("connection") || lower.contains("unreachable") || lower.contains("timed out") {
            return "Could not connect to the server. Check the address and that it is online."
        }
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - NFS (showmount -e)

    private static func listNFSExports(host: String) async throws -> [String] {
        let result = try await run("/usr/bin/showmount", arguments: ["-e", host])
        guard result.exitCode == 0 else {
            throw DiscoveryError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let exports = parseShowmount(result.stdout)
        guard !exports.isEmpty else { throw DiscoveryError.noSharesFound }
        return exports
    }

    /// `showmount -e` output:
    ///   Exports list on nas.local:
    ///   /volume1/Media    192.168.1.0/24
    static func parseShowmount(_ output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("/") else { return nil }
            return line.components(separatedBy: .whitespaces).first
        }
    }

    // MARK: - Process helper

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: DiscoveryError.commandFailed(error.localizedDescription))
                    return
                }

                // Read pipes before waiting so a chatty process can't deadlock on a full buffer.
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
