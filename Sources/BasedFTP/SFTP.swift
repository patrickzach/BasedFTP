import Foundation
import Darwin

struct Packet {
    var data = Data()
    var offset = 0
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint(_ value: UInt32) { var v = value.bigEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    mutating func long(_ value: UInt64) { uint(UInt32(value >> 32)); uint(UInt32(value & 0xffffffff)) }
    mutating func bytes(_ value: Data) { uint(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw FTPError.message("Invalid SFTP packet.") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func readByte() throws -> UInt8 { try take(1).first! }
    mutating func readUInt() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func readLong() throws -> UInt64 { let high = try readUInt(); return UInt64(high) << 32 | UInt64(try readUInt()) }
    mutating func readBytes() throws -> Data { let count = try readUInt(); return try take(Int(count)) }
    mutating func readString() throws -> String {
        guard let value = String(data: try readBytes(), encoding: .utf8), !value.contains("\0") else { throw FTPError.message("The server returned an unsupported filename (UTF-8 is required).") }; return value
    }
}

private final class WeakControl {
    weak var value: OperationControl?
    init(_ value: OperationControl) { self.value = value }
}
final class OperationControl: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [UUID: WeakControl] = [:]
    private let id = UUID()
    init() {
        Self.registryLock.lock(); Self.registry[id] = WeakControl(self); Self.registryLock.unlock()
    }
    static func cancelAll() {
        registryLock.lock(); let controls = registry.values.compactMap(\.value); registryLock.unlock()
        controls.forEach { $0.cancel() }
    }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var paused = false
    private var activity = Date()
    private var timer: DispatchSourceTimer?
    func attach(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = value; activity = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkTimeout() }; timer.resume(); self.timer = timer
    }
    func touch() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }; activity = Date()
    }
    func cancel() {
        lock.lock(); cancelled = true; paused = false; let p = process; lock.unlock()
        if let p, p.isRunning { kill(p.processIdentifier, SIGCONT); kill(p.processIdentifier, SIGTERM) }
    }
    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; activity = Date(); let p = process; lock.unlock()
        if let p, p.isRunning { kill(p.processIdentifier, value ? SIGSTOP : SIGCONT) }
    }
    private func checkTimeout() {
        lock.lock(); let expired = !paused && Date().timeIntervalSince(activity) > 60; lock.unlock()
        if expired { cancel() }
    }
    func detach() { lock.lock(); timer?.cancel(); timer = nil; process = nil; lock.unlock() }
    deinit { timer?.cancel(); Self.registryLock.lock(); Self.registry.removeValue(forKey: id); Self.registryLock.unlock() }
}

struct DeletionProgress: Sendable {
    let removed: Int
    let path: String
    let listing: Bool
    var text: String { "\(listing ? "Reading directory" : "Deleting"): \(path) · \(removed) \(removed == 1 ? "item" : "items") deleted" }
}

// SFTP v3 framing only. OpenSSH owns encryption, authentication and trust.
final class SFTPClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorURL: URL
    private let errorHandle: FileHandle
    private let control: OperationControl
    private var serial: UInt32 = 0
    private var isClosed = false
    private var posixRename = false
    private var outstanding: Set<UInt32> = []
    private(set) var maximumOutstandingRequests = 0
    private var buffered: [UInt32: (UInt8, Packet)] = [:]
    init(profile: ServerProfile?, control: OperationControl = OperationControl(), localServer: String? = nil, knownHosts: URL? = nil) throws {
        self.control = control
        errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("basedftp-stderr-" + UUID().uuidString)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardInput = input; process.standardOutput = output; process.standardError = errorHandle
        if let localServer { process.executableURL = URL(fileURLWithPath: localServer) }
        else if let profile {
            try profile.validate()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = (knownHosts.map { ["-o", "UserKnownHostsFile=" + $0.path] } ?? []) + profile.sshArguments
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "basedftp:0"; env["BASEDFTP_PROFILE"] = profile.id.uuidString
            process.environment = env
        } else { throw FTPError.message("No server configured.") }
        do {
            try process.run(); try control.attach(process)
            var hello = Packet(); hello.byte(1); hello.uint(3); try send(hello)
            var version = try receive()
            guard try version.readByte() == 2, try version.readUInt() == 3 else { throw FTPError.message("SFTP version 3 is required.") }
            while version.offset < version.data.count {
                let name = try version.readString(); let value = try version.readBytes()
                if name == "posix-rename@openssh.com", value == Data("1".utf8) { posixRename = true }
            }
        } catch { let failure = error; close(); throw failure }
    }
    func close() {
        guard !isClosed else { return }; isClosed = true
        control.detach()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? output.fileHandleForReading.close(); try? errorHandle.close()
        try? FileManager.default.removeItem(at: errorURL)
    }
    deinit { close() }
    private func send(_ packet: Packet) throws {
        try control.touch()
        var framed = Packet(); framed.bytes(packet.data)
        try input.fileHandleForWriting.write(contentsOf: framed.data)
    }
    private func exact(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try output.fileHandleForReading.read(upToCount: count - result.count), !chunk.isEmpty else {
                let diagnostic = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                throw FTPError.message(diagnostic.isEmpty ? "Connection closed or timed out. Reconnect and resume the transfer if needed." : diagnostic)
            }
            result.append(chunk); try control.touch()
        }
        return result
    }
    private func receive() throws -> Packet {
        var header = Packet(data: try exact(4)); let size = try header.readUInt()
        guard size > 0, size <= 16 * 1024 * 1024 else { throw FTPError.message("SFTP packet exceeds the safety limit.") }
        return Packet(data: try exact(Int(size)))
    }
    private func issue(_ type: UInt8, _ body: (inout Packet) -> Void) throws -> UInt32 {
        guard outstanding.count < 32 else { throw FTPError.message("Too many outstanding SFTP requests.") }
        serial &+= 1
        var packet = Packet(); packet.byte(type); packet.uint(serial); body(&packet)
        outstanding.insert(serial); maximumOutstandingRequests = max(maximumOutstandingRequests, outstanding.count); try send(packet); return serial
    }
    private func response(_ id: UInt32) throws -> (UInt8, Packet) {
        var result = buffered.removeValue(forKey: id)
        while result == nil {
            var packet = try receive(); let kind = try packet.readByte(); let replyID = try packet.readUInt()
            guard outstanding.contains(replyID), buffered[replyID] == nil else { throw FTPError.message("Invalid SFTP response ID.") }
            if replyID == id { result = (kind, packet) }
            else { buffered[replyID] = (kind, packet) }
        }
        outstanding.remove(id)
        var (kind, packet) = result!
        if kind == 101 {
            let code = try packet.readUInt(); let message = try packet.readString()
            if code != 0 { throw FTPError.status(code, message) }
        }
        return (kind, packet)
    }
    private func request(_ type: UInt8, _ body: (inout Packet) -> Void) throws -> (UInt8, Packet) {
        try response(issue(type, body))
    }
    private func expect(_ response: (UInt8, Packet), type: UInt8) throws -> Packet {
        guard response.0 == type else { throw FTPError.message("Unexpected SFTP response \(response.0).") }; return response.1
    }
    private func attrs(_ packet: inout Packet, name: String, path: String) throws -> FileEntry {
        let flags = try packet.readUInt()
        var size: UInt64 = 0; var permissions: UInt32 = 0; var modified = Date.distantPast
        if flags & 1 != 0 { size = try packet.readLong() }
        if flags & 2 != 0 { _ = try packet.readUInt(); _ = try packet.readUInt() }
        if flags & 4 != 0 { permissions = try packet.readUInt() }
        if flags & 8 != 0 { _ = try packet.readUInt(); modified = Date(timeIntervalSince1970: Double(try packet.readUInt())) }
        if flags & 0x80000000 != 0 {
            let count = try packet.readUInt(); guard count < 10000 else { throw FTPError.message("Too many attributes.") }
            for _ in 0..<count { _ = try packet.readBytes(); _ = try packet.readBytes() }
        }
        return FileEntry(name: name, path: path, size: size, permissions: permissions, modified: modified)
    }
    func realpath(_ path: String) throws -> String {
        var p = try expect(request(16) { $0.string(path) }, type: 104)
        guard try p.readUInt() > 0 else { throw FTPError.message("The server returned an empty path.") }; return try p.readString()
    }
    func stat(_ path: String) throws -> FileEntry {
        var p = try expect(request(7) { $0.string(path) }, type: 105)
        return try attrs(&p, name: (path as NSString).lastPathComponent, path: path)
    }
    func exists(_ path: String) throws -> Bool {
        do { _ = try stat(path); return true } catch let e as FTPError where e.isMissing { return false }
    }
    func list(_ path: String) throws -> [FileEntry] {
        var response = try expect(request(11) { $0.string(path) }, type: 102); let handle = try response.readBytes()
        defer { try? closeHandle(handle) }
        var entries: [FileEntry] = []
        while true {
            do {
                var p = try expect(request(12) { $0.bytes(handle) }, type: 104)
                let count = try p.readUInt(); guard count < 100000 else { throw FTPError.message("Invalid directory size.") }
                for _ in 0..<count {
                    let name = try p.readString(); _ = try p.readBytes()
                    guard !name.contains("/") else { throw FTPError.message("Unsafe filename returned by the server.") }
                    let entry = try attrs(&p, name: name, path: FileEntry.join(path, name))
                    if name != "." && name != ".." { entries.append(entry) }
                }
            } catch FTPError.status(1, _) { break }
        }
        return entries
    }
    private func closeHandle(_ handle: Data) throws { _ = try expect(request(4) { $0.bytes(handle) }, type: 101) }
    func mkdir(_ path: String) throws { _ = try expect(request(14) { $0.string(path); $0.uint(0) }, type: 101) }
    func rename(_ from: String, _ to: String) throws { _ = try expect(request(18) { $0.string(from); $0.string(to) }, type: 101) }
    func commitUpload(_ temporary: String, to destination: String, requireAtomic: Bool = false) throws {
        guard !requireAtomic || posixRename else { throw FTPError.message("This server does not support atomic replacement. The existing file has not been changed.") }
        if posixRename {
            _ = try expect(request(200) { $0.string("posix-rename@openssh.com"); $0.string(temporary); $0.string(destination) }, type: 101)
        } else {
            // SFTP v3 rename cannot replace existing files. Only remove after the
            // complete staged upload has been acknowledged by the server.
            if try exists(destination) {
                let existing = try stat(destination)
                guard !existing.isDirectory else { throw FTPError.message("The destination has been replaced by a folder; the upload was not committed.") }
                try delete(existing)
            }
            try rename(temporary, destination)
        }
    }
    func uploadEditingSnapshot(_ local: URL, to destination: String, permissions: UInt32) throws {
        guard posixRename else { throw FTPError.message("This server does not support atomic replacement. The existing file has not been changed.") }
        var mode = permissions & 0o777
        if try exists(destination) {
            let current = try stat(destination)
            guard current.isRegular else { throw FTPError.message("The destination is not a regular file and will not be replaced.") }
            mode = current.permissions & 0o777
        }
        let temporary = FileEntry.join((destination as NSString).deletingLastPathComponent, ".basedftp-edit-" + UUID().uuidString + ".partial")
        do {
            try upload(local, to: temporary, resume: false, exclusive: true) { _ in }
            try chmod(temporary, mode: mode)
            try commitUpload(temporary, to: destination, requireAtomic: true)
        } catch { throw FTPError.message("\(error.localizedDescription) Staging file: \(temporary)") }
    }
    func chmod(_ path: String, mode: UInt32) throws { _ = try expect(request(9) { $0.string(path); $0.uint(4); $0.uint(mode) }, type: 101) }
    func delete(_ entry: FileEntry) throws { try delete([entry]) }
    func delete(_ entries: [FileEntry], progress: (DeletionProgress) -> Void = { _ in }) throws {
        // REMOVE requests for independent siblings can be in flight together.
        // Every child deletion is acknowledged before its parent RMDIR is sent.
        for entry in entries {
            let path = (entry.path as NSString).standardizingPath
            guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { throw FTPError.message("Unsafe deletion target: \(entry.path)") }
        }
        var pending: [(id: UInt32, path: String)] = []
        var removed = 0
        var lastUpdate = Date.distantPast
        var current = entries.first?.path ?? ""
        func report(_ path: String, listing: Bool = false, force: Bool = false) {
            current = path
            if force || Date().timeIntervalSince(lastUpdate) >= 0.15 {
                lastUpdate = Date(); progress(DeletionProgress(removed: removed, path: path, listing: listing))
            }
        }
        func drain() throws {
            let batch = pending; pending.removeAll(keepingCapacity: true)
            var failure: Error?
            for request in batch {
                do {
                    _ = try expect(response(request.id), type: 101)
                    removed += 1; report(request.path)
                } catch {
                    if failure == nil { failure = FTPError.message("Deletion failed for \(request.path): \(error.localizedDescription)") }
                }
            }
            if let last = batch.last { report(last.path, force: true) }
            if let failure { throw failure }
        }
        func remove(_ entry: FileEntry) throws {
            try control.touch()
            if entry.isDirectory {
                report(entry.path, listing: true)
                // Never follow a symlink that replaced a directory since listing.
                let currentEntry = try stat(entry.path)
                if !currentEntry.isDirectory { try remove(currentEntry); return }
                for child in try list(entry.path) { try remove(child) }
                try drain()
                report(entry.path)
                let id = try issue(15) { $0.string(entry.path) }
                pending.append((id, entry.path))
            } else {
                report(entry.path)
                let id = try issue(13) { $0.string(entry.path) }
                pending.append((id, entry.path))
            }
            if pending.count >= 16 { try drain() }
        }
        do {
            for entry in entries { try remove(entry) }
            try drain(); report(current, force: true)
        } catch { report(current, force: true); throw error }
    }
    func createFile(_ path: String) throws {
        var p = try expect(request(3) { $0.string(path); $0.uint(2 | 8 | 32); $0.uint(0) }, type: 102)
        try closeHandle(p.readBytes())
    }
    func download(_ remote: String, to local: URL, resume: Bool, progress: (UInt64) -> Void) throws {
        var p = try expect(request(3) { $0.string(remote); $0.uint(1); $0.uint(0) }, type: 102)
        let handle = try p.readBytes(); var closed = false; defer { if !closed { try? closeHandle(handle) } }
        if !FileManager.default.fileExists(atPath: local.path) { guard FileManager.default.createFile(atPath: local.path, contents: nil) else { throw FTPError.message("Could not create the local file.") } }
        let file = try FileHandle(forWritingTo: local); defer { try? file.close() }
        var offset: UInt64 = 0
        if resume { offset = try file.seekToEnd() } else { try file.truncate(atOffset: 0) }
        try file.seek(toOffset: offset)
        let remoteSize = try stat(remote).size
        guard offset <= remoteSize else { throw FTPError.message("The local file is larger than the source; resume was cancelled.") }
        var pending: [(id: UInt32, offset: UInt64, length: UInt32)] = []
        var requested = offset
        while offset < remoteSize {
            while pending.count < 8 && requested < remoteSize {
                let position = requested
                let length = UInt32(min(65536, remoteSize - position))
                let id = try issue(5) { $0.bytes(handle); $0.long(position); $0.uint(length) }
                pending.append((id, position, length)); requested += UInt64(length)
            }
            let next = pending.removeFirst()
            var reply = try expect(response(next.id), type: 103)
            var data = try reply.readBytes()
            guard !data.isEmpty, data.count <= Int(next.length) else { throw FTPError.message("Invalid SFTP read length.") }
            // Servers may legally return short reads. Fill the remainder while
            // buffering replies to other in-flight requests by their IDs.
            while data.count < Int(next.length) {
                var more = try expect(request(5) { $0.bytes(handle); $0.long(next.offset + UInt64(data.count)); $0.uint(next.length - UInt32(data.count)) }, type: 103)
                let chunk = try more.readBytes()
                guard !chunk.isEmpty, chunk.count <= Int(next.length) - data.count else { throw FTPError.message("Invalid SFTP short read.") }
                data.append(chunk)
            }
            try file.write(contentsOf: data); offset += UInt64(data.count); progress(offset)
        }
        try file.synchronize()
        try closeHandle(handle); closed = true
    }
    func upload(_ local: URL, to remote: String, resume: Bool, exclusive: Bool = false, progress: (UInt64) -> Void) throws {
        let file = try FileHandle(forReadingFrom: local); defer { try? file.close() }
        let size = try file.seekToEnd()
        var offset: UInt64 = 0
        if resume, try exists(remote) { offset = try stat(remote).size }
        guard offset <= size else { throw FTPError.message("The remote file is larger than the source; resume was cancelled.") }
        try file.seek(toOffset: offset)
        var p = try expect(request(3) { $0.string(remote); $0.uint(exclusive ? 2 | 8 | 32 : (resume ? 2 | 8 : 2 | 8 | 16)); $0.uint(0) }, type: 102)
        let handle = try p.readBytes(); var closed = false; defer { if !closed { try? closeHandle(handle) } }
        var pending: [(id: UInt32, end: UInt64)] = []
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            let position = offset
            let id = try issue(6) { $0.bytes(handle); $0.long(position); $0.bytes(data) }
            offset += UInt64(data.count); pending.append((id, offset))
            if pending.count >= 8 {
                let first = pending.removeFirst(); _ = try expect(response(first.id), type: 101); progress(first.end)
            }
        }
        for item in pending { _ = try expect(response(item.id), type: 101); progress(item.end) }
        try closeHandle(handle); closed = true
    }
}
