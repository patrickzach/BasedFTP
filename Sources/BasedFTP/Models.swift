import Foundation

enum ServerProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp, ftp, ftps, ftpsImplicit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sftp: return "SFTP (SSH)"
        case .ftp: return "FTP (Unencrypted)"
        case .ftps: return "FTPS (Explicit TLS)"
        case .ftpsImplicit: return "FTPS (Implicit TLS)"
        }
    }
    var usesTLS: Bool { self == .ftps || self == .ftpsImplicit }
    var defaultPort: String { self == .sftp ? "22" : self == .ftpsImplicit ? "990" : "21" }
    var urlScheme: String { self == .ftpsImplicit ? "ftps" : "ftp" }
    var connectionLabel: String { self == .sftp ? "SSH / SFTP" : self == .ftp ? "FTP · Unencrypted" : self == .ftps ? "FTPS · Explicit TLS" : "FTPS · Implicit TLS" }
    var supportsTransfers: Bool { true }
    var supportsRemoteEditing: Bool { self == .sftp }
    var supportsMutations: Bool { true }
    static let ftpLimitationsNotice = "FTP/FTPS remote editing is not implemented yet. Permission changes require server support for SITE CHMOD."
}

struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var transport = ServerProtocol.sftp
    var name = "New Server"
    var host = ""
    var user = ""
    var port = ""
    var keyPath = ""
    var initialPath = "."
    var caCertificatePath = ""
    var favorite = false
    var lastUsed: Date?
    var title: String { name.isEmpty ? host : name }
    var passwordPurpose: String { transport == .sftp ? "password" : transport.usesTLS ? "ftps-password" : "ftp-password" }
    var resolvedCAPath: String { (caCertificatePath as NSString).expandingTildeInPath }
    init() {}
    private enum CodingKeys: String, CodingKey { case id, transport, name, host, user, port, keyPath, initialPath, favorite, lastUsed, caCertificatePath }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Profiles written before FTP support are always SFTP. Unknown protocols fail closed.
        transport = try c.decodeIfPresent(ServerProtocol.self, forKey: .transport) ?? .sftp
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        user = try c.decode(String.self, forKey: .user)
        port = try c.decode(String.self, forKey: .port)
        keyPath = try c.decode(String.self, forKey: .keyPath)
        initialPath = try c.decode(String.self, forKey: .initialPath)
        caCertificatePath = try c.decodeIfPresent(String.self, forKey: .caCertificatePath) ?? ""
        favorite = try c.decode(Bool.self, forKey: .favorite)
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }
    func validate() throws {
        if transport == .sftp {
            guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "/" || $0 == ":" }),
                  !user.contains(where: { $0.isWhitespace || $0 == "@" }),
                  port.isEmpty || (Int(port).map { (1...65535).contains($0) } ?? false) else {
                throw FTPError.message("Enter a valid host (or SSH alias), username and port. Configure IPv6 using an SSH alias.")
            }
        } else {
            guard !host.isEmpty, !host.hasPrefix("-"),
                  host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }),
                  port.isEmpty || (port.allSatisfy(\.isNumber) && (Int(port).map { (1...65535).contains($0) } ?? false)) else {
                throw FTPError.message("Enter a valid FTP hostname or IPv4 address and a port between 1 and 65535.")
            }
            guard !user.isEmpty, !user.contains(":"), !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw FTPError.message("Enter an FTP username without colons or control characters. Use anonymous for anonymous access.")
            }
            try FTPPaths.validate(initialPath)
            if transport.usesTLS && !caCertificatePath.isEmpty {
                guard resolvedCAPath.hasPrefix("/"), !resolvedCAPath.contains("\0"), FileManager.default.isReadableFile(atPath: resolvedCAPath),
                      (try? URL(fileURLWithPath: resolvedCAPath).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw FTPError.message("Choose a readable CA certificate bundle using an absolute path. Leave it blank to use the system trust store.")
                }
            }
        }
    }
    var sshArguments: [String] {
        var args = ["-T", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=~/.ssh/known_hosts", "-o", "GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts", "-o", "NoHostAuthenticationForLocalhost=no", "-o", "VerifyHostKeyDNS=no", "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "NumberOfPasswordPrompts=1"]
        if !port.isEmpty { args += ["-p", port] }
        if !keyPath.isEmpty { args += ["-i", (keyPath as NSString).expandingTildeInPath] }
        if !user.isEmpty { args += ["-l", user] }
        args += ["-s", host, "sftp"]
        return args
    }
}

struct FileEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    var size: UInt64 = 0
    var permissions: UInt32 = 0
    var modified: Date = .distantPast
    var permissionsAvailable = true
    var sizeAvailable = true
    // Local/SFTP metadata is lstat-style; FTP sets this only after link verification.
    var linkInformationAvailable = true
    var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    var isRegular: Bool { permissions & 0o170000 == 0o100000 }
    var isSymlink: Bool { permissions & 0o170000 == 0o120000 }
    var kind: String { isDirectory ? "Folder" : isSymlink ? "Link" : (name as NSString).pathExtension.uppercased() }
    var sizeText: String { isDirectory || !sizeAvailable ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file) }
    var modeText: String { permissionsAvailable ? String(format: "%04o", permissions & 0o7777) : "—" }
    static func join(_ directory: String, _ name: String) -> String { directory == "/" ? "/" + name : directory + "/" + name }
}

enum FTPError: LocalizedError {
    case message(String), status(UInt32, String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .status(let code, let text): return "SFTP (\(code)): \(text)"
        }
    }
    var isMissing: Bool { if case .status(2, _) = self { return true }; return false }
}

struct NavigationHistory {
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    mutating func visit(from: String, to: String) { if from != to { back.append(from); forward.removeAll() } }
    mutating func goBack(current: String) -> String? { guard let path = back.popLast() else { return nil }; forward.append(current); return path }
    mutating func goForward(current: String) -> String? { guard let path = forward.popLast() else { return nil }; back.append(current); return path }
}

enum ConflictPolicy: String, CaseIterable, Identifiable {
    case skip = "Skip", rename = "Rename", overwrite = "Overwrite", resume = "Resume"
    var id: String { rawValue }
}
