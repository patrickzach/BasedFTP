import Foundation

enum FTPPaths {
    static func validate(_ path: String) throws {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FTPError.message("FTP paths cannot contain control characters.")
        }
    }
    static func resolved(_ path: String, home: String) throws -> String {
        try validate(path); try validate(home)
        guard home.hasPrefix("/") else { throw FTPError.message("The FTP server returned an invalid login directory.") }
        var parts: [Substring] = []
        for part in (path.hasPrefix("/") ? path : FileEntry.join(home, path)).split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
    static func url(profile: ServerProfile, directory: String) throws -> String {
        try profile.validate(); try validate(directory)
        // FTP URL paths are relative to login by default. Encoded leading slash selects root.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        let path = directory.hasPrefix("/") ? "%2F" + String(directory.dropFirst()) : directory
        let encoded: String
        if directory.hasPrefix("/") {
            encoded = "%2F" + (String(path.dropFirst(3)).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        } else { encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "ftp://\(profile.host):\(profile.port.isEmpty ? "21" : profile.port)/\(encoded)" + (encoded.isEmpty || encoded.hasSuffix("/") ? "" : "/")
    }
}

/// RFC 3659 machine-readable directory entries. No locale-dependent LIST guessing.
enum FTPListing {
    static func parse(_ data: Data, directory: String) throws -> [FileEntry] {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw FTPError.message("The FTP server returned an unsupported listing (UTF-8 MLSD is required).")
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX")
        date.calendar = Calendar(identifier: .gregorian); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyyMMddHHmmss"; date.isLenient = false
        var entries: [FileEntry] = []; var paths: Set<String> = []
        // libcurl normalizes FTP listing CRLF to LF; accept either representation.
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.isEmpty { continue }
            guard !raw.contains("\n"), !raw.contains("\r"), let separator = raw.firstIndex(of: " ") else {
                throw FTPError.message("The FTP server returned an invalid MLSD listing.")
            }
            let name = String(raw[raw.index(after: separator)...])
            var facts: [String: String] = [:]
            let prefix = raw[..<separator]
            guard prefix.isEmpty || prefix.hasSuffix(";") else { throw FTPError.message("Malformed FTP listing facts.") }
            for fact in prefix.split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty, facts[String(pair[0]).lowercased()] == nil else { throw FTPError.message("Malformed FTP listing facts.") }
                facts[String(pair[0]).lowercased()] = String(pair[1])
            }
            let type = facts["type"]?.lowercased() ?? ""
            if type == "cdir" || type == "pdir" { continue }
            try LocalFiles.validName(name); try FTPPaths.validate(name)
            if let charset = facts["charset"], !["utf-8", "us-ascii"].contains(charset.lowercased()) {
                throw FTPError.message("The FTP server uses an unsupported filename character set: \(charset)")
            }
            let kind: UInt32 = type == "dir" ? 0o040000 : type == "file" ? 0o100000 : type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") ? 0o120000 : 0
            var mode: UInt32 = 0
            if let value = facts["unix.mode"] {
                guard !value.isEmpty, value.allSatisfy({ "01234567".contains($0) }), let parsed = UInt32(value, radix: 8), parsed <= 0o7777 else { throw FTPError.message("Invalid FTP permissions.") }
                mode = parsed
            }
            var size: UInt64 = 0
            if let value = facts["size"] {
                guard !value.isEmpty, value.allSatisfy({ "0123456789".contains($0) }), let parsed = UInt64(value) else { throw FTPError.message("Invalid FTP file size.") }
                size = parsed
            }
            var modified = Date.distantPast
            if let value = facts["modify"] {
                let parts = value.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count <= 2, parts[0].count == 14, parts[0].allSatisfy({ "0123456789".contains($0) }),
                      parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ "0123456789".contains($0) })),
                      let parsed = date.date(from: String(parts[0])), date.string(from: parsed) == String(parts[0]) else { throw FTPError.message("Invalid FTP modification time.") }
                modified = parsed
            }
            let path = FileEntry.join(directory, name)
            guard paths.insert(path).inserted else { throw FTPError.message("Duplicate entry in FTP listing: \(name)") }
            entries.append(FileEntry(name: name, path: path, size: size, permissions: kind | mode, modified: modified,
                                     permissionsAvailable: facts["unix.mode"] != nil, sizeAvailable: facts["size"] != nil))
        }
        return entries
    }
}

/// Drain stderr concurrently without writing possible server echoes to disk.
private final class FTPDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 65536 - data.count)))
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// curl/libcurl owns FTP login, passive data connections, and EPSV/PASV negotiation.
/// This implementation deliberately offers directory browsing only.
final class FTPClient: RemoteFileSystem {
    private let profile: ServerProfile
    private let control: OperationControl
    private var password: String?
    private var closed = false
    private var loginHome: String?
    private var cached: (path: String, entries: [FileEntry])?
    init(profile: ServerProfile, control: OperationControl = OperationControl(), password: String? = nil) throws {
        try profile.validate()
        guard profile.transport == .ftp else { throw FTPError.message("An FTP profile is required.") }
        self.profile = profile; self.control = control
        self.password = password ?? CredentialStore.read(account: profile.id.uuidString + "." + profile.passwordPurpose) ?? ""
        guard !(self.password ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FTPError.message("FTP passwords cannot contain control characters.")
        }
        try control.touch()
    }
    func close() { closed = true; cached = nil; password = nil }
    deinit { close() }
    static func credentialConfiguration(user: String, password: String) -> Data {
        let value = (user + ":" + password).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Data(("user = \"" + value + "\"\n").utf8)
    }
    private func directory(_ target: String) throws -> (path: String, entries: [FileEntry]) {
        try control.touch()
        guard !closed else { throw FTPError.message("The FTP connection has been closed.") }
        let url = try FTPPaths.url(profile: profile, directory: target)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let diagnosticsBuffer = FTPDiagnostics(), diagnosticsGroup = DispatchGroup()
        let marker = "BASEDFTP-" + UUID().uuidString + ":"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // -q must be first: do not load ~/.curlrc. Credentials only travel over stdin.
        process.arguments = ["-q", "--config", "-", "--silent", "--show-error", "--globoff", "--path-as-is",
                             "--proto", "=ftp", "--proxy", "", "--noproxy", "*", "--ftp-pasv", "--ftp-skip-pasv-ip",
                             "--ftp-method", "singlecwd", "--connect-timeout", "15", "--max-time", "60",
                             "--quote", "*OPTS UTF8 ON", "--request", "MLSD", "--url", url,
                             "--write-out", "%{stderr}\n" + marker + "%{ftp_entry_path}"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        // Do not inherit proxy settings, curl configuration variables, or application secrets.
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            diagnosticsGroup.wait()
            try? errors.fileHandleForReading.close()
            control.detach()
        }
        try process.run()
        diagnosticsGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { diagnosticsGroup.leave() }
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty { diagnosticsBuffer.append(chunk) }
        }
        try control.attach(process)
        try input.fileHandleForWriting.write(contentsOf: Self.credentialConfiguration(user: profile.user, password: password ?? ""))
        try input.fileHandleForWriting.close()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count + chunk.count <= 32 * 1024 * 1024 else { throw FTPError.message("The FTP listing exceeds the 32 MiB safety limit.") }
            data.append(chunk); try control.touch()
        }
        process.waitUntilExit(); try control.touch()
        diagnosticsGroup.wait()
        let diagnostics = diagnosticsBuffer.text
        let markerRange = diagnostics.range(of: "\n" + marker, options: .backwards)
        if process.terminationStatus != 0 {
            switch process.terminationStatus {
            case 67: throw FTPError.message("FTP login failed. Check the username and password.")
            case 6: throw FTPError.message("Could not resolve the FTP hostname.")
            case 7: throw FTPError.message("Could not connect to the FTP server. Check the host, port, and network.")
            case 28: throw FTPError.message("The FTP connection timed out. Try again.")
            case 9: throw FTPError.message("The FTP directory is unavailable or access was denied: \(target)")
            case 19: throw FTPError.message("FTP directory listing failed. This step requires MLSD support and permission to list the directory.")
            default:
                // Do not display arbitrary server replies, which may echo credentials.
                throw FTPError.message("FTP browsing failed (curl \(process.terminationStatus)). Check server access, passive data ports, and MLSD support.")
            }
        }
        guard let markerRange else { throw FTPError.message("The FTP server did not return a login directory.") }
        let home = String(diagnostics[markerRange.upperBound...])
        let path = try FTPPaths.resolved(target, home: home)
        loginHome = home
        return (path, try FTPListing.parse(data, directory: path))
    }
    func realpath(_ path: String) throws -> String {
        let result = try directory(path); cached = result; return result.path
    }
    func list(_ path: String) throws -> [FileEntry] {
        try control.touch(); guard !closed else { throw FTPError.message("The FTP connection has been closed.") }
        if let result = cached, result.path == path { cached = nil; return result.entries }
        return try directory(path).entries
    }
    private func metadataPath(_ path: String) throws -> String {
        if path.hasPrefix("/") { return try FTPPaths.resolved(path, home: "/") }
        if loginHome == nil { _ = try directory(".") }
        return try FTPPaths.resolved(path, home: loginHome ?? "/")
    }
    func stat(_ path: String) throws -> FileEntry {
        let canonical = try metadataPath(path)
        if canonical == "/" { _ = try list("/"); return FileEntry(name: "/", path: "/", permissions: 0o040000, permissionsAvailable: false, sizeAvailable: false) }
        let parent = (canonical as NSString).deletingLastPathComponent
        guard let entry = try list(parent).first(where: { $0.path == canonical }) else { throw FTPError.message("FTP entry not found: \(canonical)") }
        return entry
    }
    func entryIfExists(_ path: String) throws -> FileEntry? {
        let canonical = try metadataPath(path)
        if canonical == "/" { return try stat(canonical) }
        // A denied/missing parent listing throws; FTP 550 is never assumed to mean absence.
        return try list((canonical as NSString).deletingLastPathComponent).first { $0.path == canonical }
    }
    private func unsupported() throws -> Never { throw FTPError.message(ServerProtocol.ftpBrowsingNotice) }
    func mkdir(_ path: String) throws { try unsupported() }
    func rename(_ from: String, _ to: String) throws { try unsupported() }
    func createFile(_ path: String) throws { try unsupported() }
    func chmod(_ path: String, mode: UInt32) throws { try unsupported() }
    func delete(_ entries: [FileEntry], progress: (DeletionProgress) -> Void) throws { try unsupported() }
    func commitUpload(_ temporary: String, to destination: String, requireAtomic: Bool) throws { try unsupported() }
    func download(_ remote: String, to local: URL, resume: Bool, progress: (UInt64) -> Void) throws { try unsupported() }
    func upload(_ local: URL, to remote: String, resume: Bool, exclusive: Bool, progress: (UInt64) -> Void) throws { try unsupported() }
    func uploadEditingSnapshot(_ local: URL, to destination: String, permissions: UInt32) throws { try unsupported() }
}
