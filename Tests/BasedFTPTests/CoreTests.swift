import XCTest
import Darwin
@testable import BasedFTP

final class CoreTests: XCTestCase {
    func testPipelinedRecursiveDeletionReportsProgressWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-delete-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("remove")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keep"), withIntermediateDirectories: true)
        let keep = root.appendingPathComponent("keep/precious")
        try Data("keep me".utf8).write(to: keep)
        for index in 0..<64 { try Data("file".utf8).write(to: target.appendingPathComponent("file-\(index)")) }
        for path in ["a/file", "a/b/file", "empty-file"] { try Data().write(to: target.appendingPathComponent(path)) }
        try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("outside-link").path, withDestinationPath: "../keep")
        try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("loop").path, withDestinationPath: ".")
        XCTAssertEqual(mkfifo(target.appendingPathComponent("pipe").path, 0o600), 0)
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        var updates: [DeletionProgress] = []
        try client.delete([client.stat(target.path)]) { updates.append($0) }
        XCTAssertFalse(try client.exists(target.path))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "keep me")
        XCTAssertEqual(updates.last?.removed, 73) // Files, directories, two links, FIFO and root.
        XCTAssertTrue(updates.contains { $0.listing })
        XCTAssertTrue(updates.contains { $0.removed > 0 && $0.removed < 73 })
        XCTAssertGreaterThanOrEqual(client.maximumOutstandingRequests, 16)
        XCTAssertLessThanOrEqual(client.maximumOutstandingRequests, 32)
        XCTAssertThrowsError(try client.delete([FileEntry(name: "/", path: "/", permissions: 0o040755)]))
    }
    func testDeletionCancellationStopsBeforeRemainingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-delete-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<64 { try Data().write(to: root.appendingPathComponent("file-\(index)")) }
        let control = OperationControl()
        let client = try SFTPClient(profile: nil, control: control, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        var removed = 0
        XCTAssertThrowsError(try client.delete([LocalFiles.entry(root)]) { progress in
            removed = progress.removed
            if removed >= 16 { control.cancel() }
        })
        XCTAssertEqual(removed, 16)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 48)
    }
    func testDeletionPermissionFailureKeepsParentAndReportsPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-delete-denied-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("protected")
        try Data("preserve".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        var removed = -1
        XCTAssertThrowsError(try client.delete([client.stat(root.path)]) { removed = $0.removed }) { error in
            XCTAssertTrue(error.localizedDescription.contains("protected"), error.localizedDescription)
        }
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testReadableTransferDuration() {
        let cases: [(TimeInterval, String)] = [
            (0, "0 seconds"), (1, "1 second"), (59, "59 seconds"),
            (60, "1 minute"), (61, "1 minute and 1 second"),
            (600, "10 minutes"), (605, "10 minutes and 5 seconds"),
            (3600, "1 hour"), (3665, "1 hour, 1 minute and 5 seconds"),
            (86400, "1 day"), (90061, "1 day, 1 hour, 1 minute and 1 second"),
            (172800, "2 days"), (0.2, "1 second")
        ]
        for (seconds, expected) in cases { XCTAssertEqual(TransferDuration.formatted(seconds), expected) }
        for invalid in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] { XCTAssertEqual(TransferDuration.formatted(invalid), "—") }
        XCTAssertEqual(TransferDuration.formatted(nil), "—")
    }
    func testFileCountsIncludeEmptyFilesAndDistinguishSkippedFilesOnResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-count-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/empty-directory"), withIntermediateDirectories: true)
        try Data("content".utf8).write(to: source.appendingPathComponent("nested/file"))
        try Data().write(to: source.appendingPathComponent("empty-file"))
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        let destination = root.appendingPathComponent("destination").path
        let checkpoint = TransferCheckpoint()
        let upload = TransferEngine(client: client, upload: true, policy: .rename)
        var updates: [TransferFileProgress] = []
        try upload.run(source: LocalFiles.entry(source), destination: destination, files: { updates.append($0) }) { _, _ in }
        XCTAssertEqual(updates.first, TransferFileProgress(transferred: 0, total: 2, skipped: 0))
        XCTAssertTrue(updates.contains { $0.transferred == 1 && $0.remaining == 1 })
        XCTAssertEqual(upload.fileProgress, TransferFileProgress(transferred: 2, total: 2, skipped: 0))
        let download = TransferEngine(client: client, upload: false, policy: .rename)
        try download.run(source: client.stat(destination), destination: root.appendingPathComponent("downloaded").path) { _, _ in }
        XCTAssertEqual(download.fileProgress.transferred, 2)
        let skip = TransferEngine(client: client, upload: true, policy: .skip, checkpoint: checkpoint)
        try skip.run(source: LocalFiles.entry(source), destination: destination) { _, _ in }
        XCTAssertEqual(skip.fileProgress, TransferFileProgress(transferred: 0, total: 2, skipped: 2))
        XCTAssertEqual(skip.fileProgress.remaining, 0)
        let resume = TransferEngine(client: client, upload: true, policy: .resume, checkpoint: checkpoint, resumeCheckpoint: true, retryPolicy: .skip)
        try resume.run(source: LocalFiles.entry(source), destination: destination) { _, _ in }
        XCTAssertEqual(resume.fileProgress, skip.fileProgress)
    }
    func testPacketRoundTripAndTruncation() throws {
        var packet = Packet(); packet.byte(42); packet.uint(0xfedcba98); packet.long(0xfedcba9876543210); packet.string("Grüße\n日本語")
        XCTAssertEqual(try packet.readByte(), 42)
        XCTAssertEqual(try packet.readUInt(), 0xfedcba98)
        XCTAssertEqual(try packet.readLong(), 0xfedcba9876543210)
        XCTAssertEqual(try packet.readString(), "Grüße\n日本語")
        XCTAssertThrowsError(try packet.readUInt())
        var malicious = Packet(); malicious.uint(UInt32.max)
        XCTAssertThrowsError(try malicious.readBytes())
    }
    func testHistoryBranching() {
        var history = NavigationHistory()
        history.visit(from: "/a", to: "/b")
        XCTAssertEqual(history.goBack(current: "/b"), "/a")
        history.visit(from: "/a", to: "/c")
        XCTAssertTrue(history.forward.isEmpty)
        XCTAssertEqual(history.goBack(current: "/c"), "/a")
        XCTAssertEqual(history.goForward(current: "/a"), "/c")
    }
    func testProfileSafety() throws {
        for host in ["-oProxyCommand=evil", "a b", "a\nb", "user@host", "host:/path", ""] {
            var p = ServerProfile(); p.host = host; XCTAssertThrowsError(try p.validate())
        }
        var p = ServerProfile(); p.host = "production"; p.port = "70000"; XCTAssertThrowsError(try p.validate())
        p.port = "2222"; try p.validate()
        XCTAssertTrue(p.sshArguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(p.sshArguments.contains("ForwardAgent=no"))
        for name in ["", ".", "..", "../evil", "a/b", "bad\0name"] { XCTAssertThrowsError(try LocalFiles.validName(name)) }
        try LocalFiles.validName("normal \" Datei\n.txt")
    }
    func testLocalOpenSSHSubsystem() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("OpenSSH sftp-server nicht verfügbar") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        let remote = root.appendingPathComponent("remote").path
        try client.mkdir(remote)
        let source = root.appendingPathComponent("Grüße \" [*]\n日本語.bin")
        let bytes = Data((0..<2800000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let target = FileEntry.join(remote, source.lastPathComponent)
        try client.upload(source, to: target, resume: false) { _ in }
        let entries = try client.list(remote)
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.name, source.lastPathComponent)
        XCTAssertEqual(entries.first?.size, UInt64(bytes.count))
        let destination = root.appendingPathComponent("download")
        try client.download(target, to: destination, resume: false) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        // Both resume directions exercise non-zero SFTP offsets.
        try Data(bytes.prefix(70000)).write(to: destination)
        try client.download(target, to: destination, resume: true) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let partial = root.appendingPathComponent("partial")
        try Data(bytes.prefix(65000)).write(to: partial)
        try client.upload(partial, to: target, resume: false) { _ in }
        try client.upload(source, to: target, resume: true) { _ in }
        try client.download(target, to: destination, resume: false) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        try client.chmod(target, mode: 0o640)
        XCTAssertEqual(try client.stat(target).permissions & 0o777, 0o640)
        let renamed = FileEntry.join(remote, "renamed")
        try client.rename(target, renamed)
        XCTAssertFalse(try client.exists(target)); XCTAssertTrue(try client.exists(renamed))
        try client.createFile(FileEntry.join(remote, "empty"))
        XCTAssertThrowsError(try client.createFile(FileEntry.join(remote, "empty")))
        try client.mkdir(remote + "/toMove"); try client.createFile(remote + "/toMove/child")
        try client.mkdir(remote + "/destination")
        try client.rename(remote + "/toMove", remote + "/destination/toMove")
        XCTAssertTrue(try client.exists(remote + "/destination/toMove/child"))
        try client.delete(client.stat(remote)); XCTAssertFalse(try client.exists(remote))
    }
    func testRecursiveTransfersAndConflictPolicies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-tree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("nested/file"))
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        let remote = root.appendingPathComponent("remote").path
        let entry = try LocalFiles.entry(source)
        try TransferEngine(client: client, upload: true, policy: .rename).run(source: entry, destination: remote) { _, _ in }
        XCTAssertEqual(try client.stat(remote + "/nested/file").size, 5)
        try TransferEngine(client: client, upload: true, policy: .rename).run(source: entry, destination: remote) { _, _ in }
        XCTAssertTrue(try client.exists(remote + " (1)/nested/file"))
        let downloaded = root.appendingPathComponent("downloaded").path
        try TransferEngine(client: client, upload: false, policy: .rename).run(source: client.stat(remote), destination: downloaded) { _, _ in }
        XCTAssertEqual(try String(contentsOfFile: downloaded + "/nested/file", encoding: .utf8), "hello")
        try Data("changed".utf8).write(to: source.appendingPathComponent("nested/file"))
        try TransferEngine(client: client, upload: true, policy: .skip).run(source: entry, destination: remote) { _, _ in }
        XCTAssertEqual(try client.stat(remote + "/nested/file").size, 5)
        try TransferEngine(client: client, upload: true, policy: .overwrite).run(source: entry, destination: remote) { _, _ in }
        XCTAssertEqual(try client.stat(remote + "/nested/file").size, 7)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "/")
        let engine = TransferEngine(client: client, upload: true, policy: .overwrite)
        try engine.run(source: LocalFiles.entry(source), destination: remote) { _, _ in }
        XCTAssertEqual(engine.warnings.map(\.path), [FileEntry.join(try LocalFiles.canonicalPath(source.path), "link")])
        XCTAssertEqual(try client.stat(remote + "/nested/file").size, 7)
        XCTAssertFalse(try client.exists(remote + "/link"))
    }
    func testUnsupportedEntriesWarnAndDoNotStopUploadsOrDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-skip-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("root content".utf8).write(to: source.appendingPathComponent("regular.txt"))
        try Data("nested content".utf8).write(to: source.appendingPathComponent("nested/regular.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("broken-link").path, withDestinationPath: "missing")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("nested/loop").path, withDestinationPath: "..")
        XCTAssertEqual(mkfifo(source.appendingPathComponent("pipe").path, 0o600), 0)
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        let sourcePath = try LocalFiles.canonicalPath(source.path)
        let expectedWarnings: Set<String> = ["broken-link", "nested/loop", "pipe"]
        for upload in [true, false] {
            let destination = root.appendingPathComponent(upload ? "uploaded" : "downloaded")
            let engine = TransferEngine(client: client, upload: upload, policy: .rename)
            var emitted: [TransferWarning] = []
            var finalBytes: UInt64 = 0, finalTotal: UInt64 = 0
            let entry = upload ? try LocalFiles.entry(URL(fileURLWithPath: sourcePath)) : try client.stat(sourcePath)
            try engine.run(source: entry, destination: destination.path, warning: { emitted.append($0) }) { done, total in finalBytes = done; finalTotal = total }
            XCTAssertEqual(Set(engine.warnings.map { String($0.path.dropFirst(sourcePath.count + 1)) }), expectedWarnings)
            XCTAssertEqual(emitted.count, 3) // Measurement and transfer must not duplicate warnings.
            XCTAssertEqual(engine.warnings.filter { $0.reason == .symlink }.count, 2)
            XCTAssertEqual(engine.warnings.filter { $0.reason == .specialFile }.count, 1)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("regular.txt"), encoding: .utf8), "root content")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("nested/regular.txt"), encoding: .utf8), "nested content")
            XCTAssertEqual(finalBytes, UInt64(Data("root contentnested content".utf8).count))
            XCTAssertEqual(finalTotal, finalBytes)
            XCTAssertEqual(engine.fileProgress, TransferFileProgress(transferred: 2, total: 2, skipped: 0))
            for path in expectedWarnings { XCTAssertFalse(try client.exists(destination.appendingPathComponent(path).path)) }
            let linkJob = TransferEngine(client: client, upload: upload, policy: .rename)
            let link = source.appendingPathComponent("broken-link")
            try linkJob.run(source: upload ? LocalFiles.entry(link) : client.stat(link.path), destination: root.appendingPathComponent("must-not-exist").path) { _, _ in }
            XCTAssertEqual(linkJob.warnings.count, 1)
            XCTAssertFalse(try client.exists(root.appendingPathComponent("must-not-exist").path))
        }
    }
    func testInterruptedStagedUploadCanResumeWithoutDamagingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let bytes = Data((0..<2800000).map { UInt8($0 % 251) })
        try bytes.write(to: source); try Data("original".utf8).write(to: destination)
        let checkpoint = TransferCheckpoint(); let control = OperationControl()
        let client = try SFTPClient(profile: nil, control: control, localServer: "/usr/libexec/sftp-server")
        let entry = try LocalFiles.entry(source)
        XCTAssertThrowsError(try TransferEngine(client: client, upload: true, policy: .overwrite, checkpoint: checkpoint).run(source: entry, destination: destination.path) { done, _ in if done > 0 { control.cancel() } })
        client.close()
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        let partial = try XCTUnwrap(checkpoint.get(source.path)?.partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial))
        let resumed = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { resumed.close() }
        try TransferEngine(client: resumed, upload: true, policy: .resume, checkpoint: checkpoint, resumeCheckpoint: true, retryPolicy: .overwrite).run(source: entry, destination: destination.path) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial))
        // A retry that failed before starting a file must preserve rename policy.
        let freshCheckpoint = TransferCheckpoint()
        try TransferEngine(client: resumed, upload: true, policy: .resume, checkpoint: freshCheckpoint, resumeCheckpoint: true, retryPolicy: .rename).run(source: entry, destination: destination.path) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + " (1)")), bytes)
    }
    func testPipelinedShortReadsAndReorderedReplies() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reordering-server.py")
        let client = try SFTPClient(profile: nil, localServer: fixture.path); defer { client.close() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try client.download("/fixture", to: destination, resume: false) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), Data((0..<900000).map { UInt8($0 % 251) }))
    }
    func testCancellationBeforeConnecting() throws {
        let control = OperationControl(); control.cancel()
        XCTAssertThrowsError(try SFTPClient(profile: nil, control: control, localServer: "/usr/libexec/sftp-server"))
    }
    func testSSHRejectsUnknownAndChangedHostKeys() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["BASEDFTP_TEST_HOST"], let wrong = env["BASEDFTP_TEST_WRONG_KNOWN_HOSTS"] else { throw XCTSkip("Isolierten SSH-Testserver mit Scripts/integration-test.sh starten") }
        var profile = ServerProfile(); profile.host = host; profile.port = env["BASEDFTP_TEST_PORT"] ?? ""; profile.user = env["BASEDFTP_TEST_USER"] ?? ""; profile.keyPath = env["BASEDFTP_TEST_KEY"] ?? ""
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: empty); defer { try? FileManager.default.removeItem(at: empty) }
        for url in [empty, URL(fileURLWithPath: wrong)] {
            XCTAssertThrowsError(try RemoteFileSystems.connect(profile: profile, knownHosts: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Host key verification failed"), error.localizedDescription)
            }
        }
    }
    func testRealSSHIntegrationWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BASEDFTP_TEST_HOST"], let directory = environment["BASEDFTP_TEST_DIRECTORY"] else { throw XCTSkip("SSH-Integration: BASEDFTP_TEST_HOST und BASEDFTP_TEST_DIRECTORY setzen") }
        var profile = ServerProfile(); profile.host = host; profile.user = environment["BASEDFTP_TEST_USER"] ?? ""; profile.port = environment["BASEDFTP_TEST_PORT"] ?? ""; profile.keyPath = environment["BASEDFTP_TEST_KEY"] ?? ""
        let client = try RemoteFileSystems.connect(profile: profile, knownHosts: environment["BASEDFTP_TEST_KNOWN_HOSTS"].map { URL(fileURLWithPath: $0) }); defer { client.close() }
        let folder = FileEntry.join(directory, "basedftp-integration-" + UUID().uuidString)
        try client.mkdir(folder)
        defer { if let entry = try? client.stat(folder) { try? client.delete(entry) } }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("SSH round trip".utf8).write(to: local)
        try client.upload(local, to: folder + "/file", resume: false) { _ in }
        XCTAssertEqual(try client.list(folder).count, 1)
        try client.download(folder + "/file", to: local, resume: false) { _ in }
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "SSH round trip")
    }
}
