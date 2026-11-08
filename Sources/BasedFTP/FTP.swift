import Foundation
import Darwin

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
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._/")
        let path = directory.hasPrefix("/") ? "%2F" + String(directory.dropFirst()) : directory
        let encoded: String
        if directory.hasPrefix("/") {
            encoded = "%2F" + (String(path.dropFirst(3)).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        } else { encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "\(profile.transport.urlScheme)://\(profile.host):\(profile.port.isEmpty ? profile.transport.defaultPort : profile.port)/\(encoded)" + (encoded.isEmpty || encoded.hasSuffix("/") ? "" : "/")
    }
    static func fileURL(profile: ServerProfile, path: String) throws -> String {
        try validate(path)
        guard !path.isEmpty, !path.hasSuffix("/") else { throw FTPError.message("An FTP file path is required.") }
        let name = (path as NSString).lastPathComponent
        try LocalFiles.validName(name)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { throw FTPError.message("Invalid FTP filename.") }
        return try url(profile: profile, directory: (path as NSString).deletingLastPathComponent) + encoded
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
                                     permissionsAvailable: facts["unix.mode"] != nil, sizeAvailable: facts["size"] != nil, linkInformationAvailable: kind == 0o120000))
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
/// File transfers use the system libcurl API for precise progress and cancellation.
final class FTPClient: RemoteFileSystem {
    let transferFeatures = RemoteTransferFeatures(directories: true, unixPermissions: false)
    private let profile: ServerProfile
    private let control: OperationControl
    private var password: String?
    private var closed = false
    private var loginHome: String?
    private var commandConnection: FTPCurlConnection?
    private var cached: (path: String, entries: [FileEntry])?
    init(profile: ServerProfile, control: OperationControl = OperationControl(), password: String? = nil) throws {
        try profile.validate()
        guard profile.transport != .sftp else { throw FTPError.message("An FTP or FTPS profile is required.") }
        self.profile = profile; self.control = control
        self.password = try password ?? CredentialStore.read(account: profile.id.uuidString + "." + profile.passwordPurpose) ?? ""
        guard !(self.password ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FTPError.message("FTP passwords cannot contain control characters.")
        }
        try control.touch()
    }
    func close() { closed = true; cached = nil; password = nil; commandConnection?.close(); commandConnection = nil }
    deinit { close() }
    static func credentialConfiguration(user: String, password: String) -> Data {
        let value = (user + ":" + password).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Data(("user = \"" + value + "\"\n").utf8)
    }
    private func directoryRequest(_ target: String, command: String = "MLSD") throws -> (path: String, data: Data) {
        try control.touch()
        guard !closed else { throw FTPError.message("The FTP connection has been closed.") }
        let url = try FTPPaths.url(profile: profile, directory: target)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let diagnosticsBuffer = FTPDiagnostics(), diagnosticsGroup = DispatchGroup()
        let marker = "BASEDFTP-" + UUID().uuidString + ":"
        let verifyMarker = "\n" + marker + "verify:"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // -q must be first: do not load ~/.curlrc. Credentials only travel over stdin.
        process.arguments = ["-q", "--config", "-", "--silent", "--show-error", "--globoff", "--path-as-is",
                             "--proto", "=" + profile.transport.urlScheme, "--proxy", "", "--noproxy", "*", "--ftp-pasv", "--ftp-skip-pasv-ip",
                             "--ftp-method", "singlecwd", "--connect-timeout", "15", "--max-time", "60",
                             "--quote", "*OPTS UTF8 ON", "--request", command, "--url", url,
                             "--write-out", "%{stderr}\n" + marker + "%{ftp_entry_path}" + verifyMarker + "%{ssl_verify_result}"]
        process.arguments = (process.arguments ?? []) + FTPTLS.listingArguments(profile: profile)
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
        let verifyRange = diagnostics.range(of: verifyMarker, options: .backwards)
        let homeDiagnostics = verifyRange.map { String(diagnostics[..<$0.lowerBound]) } ?? diagnostics
        let markerRange = homeDiagnostics.range(of: "\n" + marker, options: .backwards)
        if profile.transport.usesTLS, let verifyRange, let verification = Int(diagnostics[verifyRange.upperBound...]), verification != 0 { throw FTPTLSError.certificate }
        if process.terminationStatus != 0 {
            if profile.transport.usesTLS, let error = FTPTLS.failure(code: Int(process.terminationStatus)) { throw error }
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
        let home = String(homeDiagnostics[markerRange.upperBound...])
        let path = try FTPPaths.resolved(target, home: home)
        loginHome = home
        return (path, data)
    }
    private func directory(_ target: String, requireLinkInfo: Bool = false, attempt: Int = 0) throws -> (path: String, entries: [FileEntry]) {
        let result = try directoryRequest(target)
        let entries = try FTPListing.parse(result.data, directory: result.path)
        do {
            let unix = try directoryRequest(target, command: "LIST -a")
            guard unix.path == result.path else { throw FTPError.message("The FTP login directory changed between requests.") }
            let verified = try FTPUnixListing.merge(unix.data, entries: entries, directory: result.path, requireConsistent: requireLinkInfo)
            return (result.path, verified)
        } catch {
            if error is CancellationError || error is FTPTLSError { throw error }
            if requireLinkInfo, error is FTPUnixListing.Failure, attempt < 2 {
                // Only repeat read-only metadata requests, never mutations.
                return try directory(target, requireLinkInfo: true, attempt: attempt + 1)
            }
            if requireLinkInfo { throw FTPError.message("Recursive FTP operations require consistent Unix LIST link metadata at \(result.path): \(error.localizedDescription)") }
            // Browsing remains available on MLSD-only servers. Recursion must fail closed.
            return (result.path, entries)
        }
    }
    func listForRecursion(_ path: String) throws -> [FileEntry] {
        let canonical = try metadataPath(path)
        if canonical != "/" {
            let entry = try stat(canonical)
            guard entry.isDirectory && entry.linkInformationAvailable else { throw FTPError.message("Recursive FTP traversal requires a verified directory, not a link: \(canonical)") }
        }
        return try directory(canonical, requireLinkInfo: true).entries
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
        return try directory((canonical as NSString).deletingLastPathComponent, requireLinkInfo: true).entries.first { $0.path == canonical }
    }
    private func requireOpen() throws {
        try control.checkpoint()
        guard !closed else { throw FTPError.message("The FTP connection has been closed.") }
    }
    private func commands(_ values: [String], path: String) throws {
        try requireOpen(); cached = nil
        if commandConnection == nil { commandConnection = try FTPCurlConnection() }
        do {
            try FTPCurl.perform(profile: profile, password: password ?? "", url: FTPPaths.url(profile: profile, directory: "/"), control: control,
                                commands: values, connection: commandConnection)
        } catch {
            if error is CancellationError { throw error }
            throw FTPError.message("FTP operation failed for \(path): \(error.localizedDescription)")
        }
    }
    private func mutationPath(_ path: String) throws -> String {
        try requireOpen(); try FTPPaths.validate(path)
        let absolute = try metadataPath(path)
        guard absolute != "/" else { throw FTPError.message("The FTP root cannot be modified.") }
        return absolute
    }
    private func verifyAncestors(of path: String) throws {
        let parts = path.split(separator: "/")
        for depth in 1..<parts.count {
            let ancestor = "/" + parts.prefix(depth).joined(separator: "/")
            let entry = try stat(ancestor)
            guard entry.isDirectory && entry.linkInformationAvailable else { throw FTPError.message("FTP operations cannot traverse links or unverified directories: \(ancestor)") }
        }
    }
    func mkdir(_ path: String) throws {
        let target = try mutationPath(path); try verifyAncestors(of: target)
        guard try entryIfExists(target) == nil else { throw FTPError.message("The destination already exists: \(target)") }
        try commands(["MKD " + target], path: target)
    }
    func createFile(_ path: String) throws {
        let target = try mutationPath(path); try verifyAncestors(of: target)
        guard try entryIfExists(target) == nil else { throw FTPError.message("The destination already exists: \(target)") }
        let temporary = FileEntry.join((target as NSString).deletingLastPathComponent, ".basedftp-new-" + UUID().uuidString + ".partial")
        // Empty creation is staged too: never send STOR directly to an existing target.
        try FTPCurl.perform(profile: profile, password: password ?? "", url: FTPPaths.fileURL(profile: profile, path: temporary), control: control,
                            file: FileHandle.nullDevice, upload: true, size: 0)
        try renameStaging(temporary, to: target, overwrite: false)
    }
    func chmod(_ path: String, mode: UInt32) throws {
        guard mode <= 0o7777 else { throw FTPError.message("Invalid Unix permissions.") }
        let target = try mutationPath(path); try verifyAncestors(of: target)
        let entry = try stat(target)
        guard entry.linkInformationAvailable && !entry.isSymlink else { throw FTPError.message("Permissions cannot be changed through an FTP symbolic link or unverified entry: \(target)") }
        do { try commands(["SITE CHMOD " + String(mode, radix: 8) + " " + target], path: target) }
        catch { if error is CancellationError { throw error }; throw FTPError.message("FTP SITE CHMOD failed for \(target). The server must support this command and grant permission. \(error.localizedDescription)") }
    }
    func delete(_ entries: [FileEntry], progress: (DeletionProgress) -> Void) throws {
        let paths = try entries.map { try mutationPath($0.path) }
        // Validate every top-level path before issuing the first destructive command.
        for path in paths { try verifyAncestors(of: path) }
        let unique = Array(Set(paths)).sorted().filter { path in !paths.contains { path.hasPrefix($0 + "/") } }
        var removed = 0
        var visited: Set<String> = []
        func remove(_ path: String, supplied: FileEntry? = nil, depth: Int = 0) throws {
            try control.checkpoint()
            guard depth <= 256, visited.insert(path).inserted else { throw FTPError.message("Unsafe or excessively deep FTP directory tree: \(path)") }
            let current = try supplied ?? stat(path)
            if current.isDirectory {
                guard current.linkInformationAvailable else { throw FTPError.message("Cannot safely recurse without FTP link metadata: \(path)") }
                progress(DeletionProgress(removed: removed, path: path, listing: true))
                // Refresh the parent metadata before traversing a previously listed directory.
                let fresh = try stat(path)
                if !fresh.isDirectory { try commands(["DELE " + path], path: path) }
                else {
                    guard fresh.linkInformationAvailable else { throw FTPError.message("Cannot verify FTP directory type: \(path)") }
                    for child in try listForRecursion(path) { try remove(child.path, supplied: child, depth: depth + 1) }
                    try commands(["RMD " + path], path: path)
                }
            } else { try commands(["DELE " + path], path: path) }
            removed += 1
            progress(DeletionProgress(removed: removed, path: path, listing: false))
        }
        for path in unique {
            do { try remove(path) }
            catch {
                if error is CancellationError { throw error }
                throw FTPError.message("FTP deletion stopped at \(path) after \(removed) confirmed deletions: \(error.localizedDescription)")
            }
        }
    }
    func uploadEditingSnapshot(_ local: URL, to destination: String, permissions: UInt32) throws { throw FTPError.message(ServerProtocol.ftpLimitationsNotice) }

    private func renameStaging(_ from: String, to: String, overwrite: Bool) throws {
        try requireOpen(); try FTPPaths.validate(from); try FTPPaths.validate(to)
        let source = try mutationPath(from), destination = try mutationPath(to)
        try verifyAncestors(of: source); try verifyAncestors(of: destination)
        guard source != destination else { throw FTPError.message("FTP staging and destination paths must differ.") }
        cached = nil
        let sourceEntry = try stat(source)
        if overwrite { guard sourceEntry.isRegular else { throw FTPError.message("Only regular FTP staging files can replace a destination.") } }
        if sourceEntry.isDirectory {
            guard sourceEntry.linkInformationAvailable, !destination.hasPrefix(source + "/") else { throw FTPError.message("An FTP folder cannot be moved into itself, a subfolder, or through unverified link metadata.") }
        }
        if let existing = try entryIfExists(destination) {
            guard overwrite && existing.isRegular else { throw FTPError.message("The FTP destination already exists or is not a regular file. The staging file is retained.") }
        }
        try commands(["RNFR " + source, "RNTO " + destination], path: source + " → " + destination)
    }
    // FTP has no portable atomic no-replace primitive. Check first; never issue DELE.
    func rename(_ from: String, _ to: String) throws { try renameStaging(from, to: to, overwrite: false) }
    func commitUpload(_ temporary: String, to destination: String, requireAtomic: Bool) throws {
        guard !requireAtomic else { throw FTPError.message("FTP cannot guarantee atomic replacement. The existing file has not been changed.") }
        try renameStaging(temporary, to: destination, overwrite: true)
    }
    func download(_ remote: String, to local: URL, resume: Bool, progress: (UInt64) -> Void) throws {
        try requireOpen(); try FTPPaths.validate(remote)
        let entry = try stat(remote)
        guard entry.isRegular, entry.sizeAvailable else { throw FTPError.message("FTP downloads require a regular file with a reported MLSD size.") }
        let fd = Darwin.open(local.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw FTPError.message("Could not safely open the local download file.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw FTPError.message("The local download destination is not a regular file.") }
        let offset = resume ? try file.seekToEnd() : 0
        guard offset <= entry.size else { throw FTPError.message("The local file is larger than the source; resume was cancelled.") }
        if !resume { try file.truncate(atOffset: 0) }
        try file.seek(toOffset: offset)
        // An already complete partial requires no REST request (including empty files).
        if offset < entry.size || !resume {
            try FTPCurl.perform(profile: profile, password: password ?? "", url: FTPPaths.fileURL(profile: profile, path: remote), control: control,
                                file: file, offset: offset, size: entry.size, progress: progress)
        }
        try file.synchronize(); progress(entry.size)
    }
    func upload(_ local: URL, to remote: String, resume: Bool, exclusive: Bool, progress: (UInt64) -> Void) throws {
        try requireOpen(); try FTPPaths.validate(remote)
        guard !exclusive else { throw FTPError.message("FTP does not support guaranteed exclusive creation.") }
        let fd = Darwin.open(local.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw FTPError.message("Could not safely open the local upload source.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw FTPError.message("Only regular files can be uploaded over FTP.") }
        let size = UInt64(info.st_size)
        cached = nil
        let existing = try entryIfExists(remote)
        if let existing {
            guard resume && existing.isRegular && existing.sizeAvailable else { throw FTPError.message("The FTP upload destination already exists or cannot be resumed safely.") }
        }
        let offset = resume ? existing?.size ?? 0 : 0
        guard offset <= size else { throw FTPError.message("The FTP destination is larger than the source; resume was cancelled.") }
        if offset < size || existing == nil {
            try FTPCurl.perform(profile: profile, password: password ?? "", url: FTPPaths.fileURL(profile: profile, path: remote), control: control,
                                file: file, upload: true, offset: offset, size: size, progress: progress)
        }
        progress(size)
    }
}
