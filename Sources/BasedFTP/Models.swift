import Foundation

struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = "New Server"
    var host = ""
    var user = ""
    var port = ""
    var keyPath = ""
    var initialPath = "."
    var favorite = false
    var lastUsed: Date?
    var title: String { name.isEmpty ? host : name }
    func validate() throws {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "/" || $0 == ":" }),
              !user.contains(where: { $0.isWhitespace || $0 == "@" }),
              port.isEmpty || (Int(port).map { (1...65535).contains($0) } ?? false) else {
            throw FTPError.message("Enter a valid host (or SSH alias), username and port. Configure IPv6 using an SSH alias.")
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
    var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    var isRegular: Bool { permissions & 0o170000 == 0o100000 }
    var isSymlink: Bool { permissions & 0o170000 == 0o120000 }
    var kind: String { isDirectory ? "Folder" : isSymlink ? "Link" : (name as NSString).pathExtension.uppercased() }
    var sizeText: String { isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file) }
    var modeText: String { String(format: "%04o", permissions & 0o7777) }
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
