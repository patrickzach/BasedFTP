import XCTest
@testable import BasedFTP

final class CoreTests: XCTestCase {
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
        XCTAssertThrowsError(try TransferEngine(client: client, upload: true, policy: .overwrite).run(source: LocalFiles.entry(source), destination: remote) { _, _ in })
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
            XCTAssertThrowsError(try SFTPClient(profile: profile, knownHosts: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Host key verification failed"), error.localizedDescription)
            }
        }
    }
    func testRealSSHIntegrationWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BASEDFTP_TEST_HOST"], let directory = environment["BASEDFTP_TEST_DIRECTORY"] else { throw XCTSkip("SSH-Integration: BASEDFTP_TEST_HOST und BASEDFTP_TEST_DIRECTORY setzen") }
        var profile = ServerProfile(); profile.host = host; profile.user = environment["BASEDFTP_TEST_USER"] ?? ""; profile.port = environment["BASEDFTP_TEST_PORT"] ?? ""; profile.keyPath = environment["BASEDFTP_TEST_KEY"] ?? ""
        let client = try SFTPClient(profile: profile, knownHosts: environment["BASEDFTP_TEST_KNOWN_HOSTS"].map { URL(fileURLWithPath: $0) }); defer { client.close() }
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
