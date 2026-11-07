import XCTest
@testable import BasedFTP

final class FTPTransferTests: XCTestCase {
    private func server(pasv: Bool = false, control: OperationControl = OperationControl()) throws -> (FTPClient, URL, ServerProfile) {
        let env = ProcessInfo.processInfo.environment
        guard let port = env[pasv ? "BASEDFTP_FTP_TEST_PASV_PORT" : "BASEDFTP_FTP_TEST_PORT"], let password = env["BASEDFTP_FTP_TEST_PASSWORD"], let root = env["BASEDFTP_FTP_TEST_ROOT"] else {
            throw XCTSkip("Start FTP test servers with Scripts/ftp-integration-test.sh")
        }
        var p = ServerProfile(); p.transport = .ftp; p.host = "127.0.0.1"; p.port = port; p.user = "ftp-user"
        return (try FTPClient(profile: p, control: control, password: password), URL(fileURLWithPath: root).appendingPathComponent(pasv ? "files-pasv/home" : "files-epsv/home"), p)
    }
    private func local() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testBinaryAndEmptyFileRoundTripsWithByteProgressInEPSVAndPASV() throws {
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<600_017).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("source"), result = root.appendingPathComponent("result")
        try data.write(to: source)
        for pasv in [false, true] {
            let (client, remoteRoot, _) = try server(pasv: pasv); defer { client.close() }
            let name = "\"~name #%;[ü] " + UUID().uuidString
            let remote = "/home/" + name
            var uploadProgress: [UInt64] = [], downloadProgress: [UInt64] = []
            try client.upload(source, to: remote, resume: false) { uploadProgress.append($0) }
            XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent(name)), data)
            try client.download(remote, to: result, resume: false) { downloadProgress.append($0) }
            XCTAssertEqual(try Data(contentsOf: result), data)
            XCTAssertEqual(uploadProgress.last, UInt64(data.count)); XCTAssertEqual(downloadProgress.last, UInt64(data.count))
            XCTAssertTrue(uploadProgress.contains { $0 > 0 && $0 < data.count })
            XCTAssertTrue(downloadProgress.contains { $0 > 0 && $0 < data.count })
            let empty = root.appendingPathComponent("empty"); try Data().write(to: empty)
            try client.upload(empty, to: remote + "-empty", resume: false) { _ in }
            try client.download(remote + "-empty", to: result, resume: false) { _ in }
            XCTAssertEqual(try Data(contentsOf: result).count, 0)
        }
    }
    func testQueueEngineConflictStrategiesAndUnknownPermissions() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), result = root.appendingPathComponent("result")
        let data = Data("new content".utf8); try data.write(to: source)
        let name = "conflict-" + UUID().uuidString, remote = "/home/" + name
        let target = remoteRoot.appendingPathComponent(name)
        try Data("old".utf8).write(to: target)
        let skipped = TransferEngine(client: client, upload: true, policy: .skip)
        try skipped.run(source: LocalFiles.entry(source), destination: remote) { _, _ in }
        XCTAssertEqual(skipped.fileProgress.skipped, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        let renamed = TransferEngine(client: client, upload: true, policy: .rename)
        try renamed.run(source: LocalFiles.entry(source), destination: remote) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent(name + " (1)")), data)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        let overwrite = TransferEngine(client: client, upload: true, policy: .overwrite)
        try overwrite.run(source: LocalFiles.entry(source), destination: remote) { _, _ in }
        XCTAssertEqual(overwrite.fileProgress.transferred, 1)
        XCTAssertEqual(try Data(contentsOf: target), data)
        let remoteEntry = try client.stat(remote)
        XCTAssertFalse(remoteEntry.permissionsAvailable)
        try TransferEngine(client: client, upload: false, policy: .rename).run(source: remoteEntry, destination: result.path) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: result), data)
        let permissions = try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? NSNumber
        XCTAssertNotEqual(permissions?.intValue, 0)
        try Data("local old".utf8).write(to: result)
        try TransferEngine(client: client, upload: false, policy: .skip).run(source: remoteEntry, destination: result.path) { _, _ in }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "local old")
        try TransferEngine(client: client, upload: false, policy: .rename).run(source: remoteEntry, destination: result.path) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("result (1)")), data)
        try TransferEngine(client: client, upload: false, policy: .overwrite).run(source: remoteEntry, destination: result.path) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: result), data)
    }
    func testFailedUploadAndFailedCommitPreserveExistingDestination() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try Data("replacement".utf8).write(to: source)
        for name in ["commit-denied", "upload-denied/file"] {
            let old = remoteRoot.appendingPathComponent(name); try Data("precious".utf8).write(to: old)
            let checkpoint = TransferCheckpoint()
            XCTAssertThrowsError(try TransferEngine(client: client, upload: true, policy: .overwrite, checkpoint: checkpoint).run(source: LocalFiles.entry(source), destination: "/home/" + name) { _, _ in })
            XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "precious")
            if name == "commit-denied" {
                let partial = try XCTUnwrap(checkpoint.get(source.path)?.partial)
                XCTAssertEqual(try String(contentsOf: remoteRoot.appendingPathComponent((partial as NSString).lastPathComponent), encoding: .utf8), "replacement")
            }
        }
        let commands = try String(contentsOf: remoteRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("commands-epsv"), encoding: .utf8)
        XCTAssertFalse(commands.components(separatedBy: .newlines).contains("DELE"))
    }
    func testResumeUploadAndDownloadAndRejectOversizedPartials() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<250_003).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("source"), result = root.appendingPathComponent("result")
        try data.write(to: source); try data.prefix(30_007).write(to: result)
        let name = "resume-" + UUID().uuidString, remote = "/home/" + name
        try data.prefix(100_003).write(to: remoteRoot.appendingPathComponent(name))
        try client.upload(source, to: remote, resume: true) { _ in }
        XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent(name)), data)
        try client.download(remote, to: result, resume: true) { _ in }
        XCTAssertEqual(try Data(contentsOf: result), data)
        try (data + Data([1])).write(to: remoteRoot.appendingPathComponent(name))
        XCTAssertThrowsError(try client.upload(source, to: remote, resume: true) { _ in })
        try data.write(to: remoteRoot.appendingPathComponent(name))
        try (data + Data([1])).write(to: result)
        XCTAssertThrowsError(try client.download(remote, to: result, resume: true) { _ in })
        XCTAssertEqual(try Data(contentsOf: result).count, data.count + 1)
    }
    func testCancellationKeepsOldFileAndStagingCanResume() throws {
        let control = OperationControl(), (client, remoteRoot, p) = try server(control: control)
        defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), name = "cancel-" + UUID().uuidString
        let data = Data(repeating: 0x69, count: 2_000_013); try data.write(to: source)
        let target = remoteRoot.appendingPathComponent(name); try Data("keep me".utf8).write(to: target)
        let checkpoint = TransferCheckpoint()
        // Cancel independently of the queue's throttled display updates while the
        // server is still receiving/acknowledging the staged upload.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { control.cancel() }
        XCTAssertThrowsError(try TransferEngine(client: client, upload: true, policy: .overwrite, checkpoint: checkpoint).run(source: LocalFiles.entry(source), destination: "/home/" + name) { _, _ in })
        XCTAssertTrue(try Data(contentsOf: target) == Data("keep me".utf8))
        let partial = try XCTUnwrap(checkpoint.get(source.path)?.partial)
        let finished = remoteRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("finished-epsv")
        let deadline = Date().addingTimeInterval(5)
        while !((try? String(contentsOf: finished, encoding: .utf8).components(separatedBy: .newlines).contains((partial as NSString).lastPathComponent)) ?? false) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let resumed = try FTPClient(profile: p, password: ProcessInfo.processInfo.environment["BASEDFTP_FTP_TEST_PASSWORD"]); defer { resumed.close() }
        try TransferEngine(client: resumed, upload: true, policy: .resume, checkpoint: checkpoint, resumeCheckpoint: true, retryPolicy: .overwrite).run(source: LocalFiles.entry(source), destination: "/home/" + name) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
    func testCancelledDownloadPreservesLocalDestinationAndResumesStaging() throws {
        let control = OperationControl(), (client, remoteRoot, p) = try server(control: control)
        defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "download-cancel-" + UUID().uuidString
        let content = Data(repeating: 0x37, count: 2_000_013)
        try content.write(to: remoteRoot.appendingPathComponent(name))
        let target = root.appendingPathComponent("destination"); try Data("keep local".utf8).write(to: target)
        let source = try client.stat("/home/" + name), checkpoint = TransferCheckpoint()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { control.cancel() }
        XCTAssertThrowsError(try TransferEngine(client: client, upload: false, policy: .overwrite, checkpoint: checkpoint).run(source: source, destination: target.path) { _, _ in })
        XCTAssertTrue(try Data(contentsOf: target) == Data("keep local".utf8))
        XCTAssertNotNil(checkpoint.get(source.path)?.partial)
        let resumed = try FTPClient(profile: p, password: ProcessInfo.processInfo.environment["BASEDFTP_FTP_TEST_PASSWORD"])
        defer { resumed.close() }
        try TransferEngine(client: resumed, upload: false, policy: .resume, checkpoint: checkpoint, resumeCheckpoint: true, retryPolicy: .overwrite).run(source: source, destination: target.path) { _, _ in }
        XCTAssertTrue(try Data(contentsOf: target) == content)
    }
    func testPausedNativeTransferContinuesAndCanBeCancelledWhilePaused() throws {
        let control = OperationControl(), (client, _, _) = try server(control: control); defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try Data(repeating: 7, count: 800_003).write(to: source)
        var paused = false
        let start = Date()
        try client.upload(source, to: "/home/pause-" + UUID().uuidString, resume: false) { done in
            if done > 0 && done < 800_003 && !paused {
                paused = true; control.setPaused(true)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { control.setPaused(false) }
            }
        }
        XCTAssertTrue(paused); XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        let cancel = OperationControl(); cancel.setPaused(true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancel.cancel() }
        XCTAssertThrowsError(try cancel.checkpoint())
    }
    func testFoldersExclusiveCreationAndAtomicEditorUploadsAreRejected() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try TransferEngine(client: client, upload: true, policy: .rename).run(source: LocalFiles.entry(root), destination: "/home/new-folder") { _, _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent("new-folder").path))
        XCTAssertThrowsError(try TransferEngine(client: client, upload: false, policy: .rename).run(source: client.stat("/home/sub folder"), destination: root.appendingPathComponent("folder").path) { _, _ in })
        let source = root.appendingPathComponent("source"); try Data([1]).write(to: source)
        XCTAssertThrowsError(try client.upload(source, to: "/home/exclusive", resume: false, exclusive: true) { _ in })
        XCTAssertThrowsError(try client.commitUpload("/home/stage", to: "/home/target", requireAtomic: true))
        XCTAssertThrowsError(try client.uploadEditingSnapshot(source, to: "/home/target", permissions: 0o644))
        XCTAssertThrowsError(try FTPPaths.fileURL(profile: server().2, path: "/bad\r\nDELE x"))
    }
    @MainActor func testParallelTransferQueueUsesFTPFactoryForRealUploadsAndDownloads() async throws {
        let (_, remoteRoot, baseProfile) = try server()
        var p = baseProfile; p.user = "ftp-queue" // Synthetic empty-password test account; no Keychain writes.
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(); queue.limit = 2
        let entries = try (0..<3).map { index -> FileEntry in
            let url = root.appendingPathComponent("queue-\(index)-" + UUID().uuidString)
            try Data(repeating: UInt8(index), count: 700_003).write(to: url)
            return try LocalFiles.entry(url)
        }
        queue.enqueue(entries, profile: p, destination: "/home", upload: true)
        let deadline = Date().addingTimeInterval(20); var maximum = 0
        while !queue.jobs.allSatisfy(\.terminal), Date() < deadline {
            maximum = max(maximum, queue.jobs.filter { $0.state == .running }.count)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(maximum, 2)
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .completed }, queue.jobs.compactMap(\.error).joined(separator: "\n"))
        for entry in entries { XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent(entry.name)), try Data(contentsOf: URL(fileURLWithPath: entry.path))) }
        let downloads = root.appendingPathComponent("downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let (client, _, _) = try server(); defer { client.close() }
        queue.enqueue(try entries.map { try client.stat("/home/" + $0.name) }, profile: p, destination: downloads.path, upload: false)
        let end = Date().addingTimeInterval(20)
        while !queue.jobs.allSatisfy(\.terminal), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .completed }, queue.jobs.compactMap(\.error).joined(separator: "\n"))
        for entry in entries { XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent(entry.name)), try Data(contentsOf: URL(fileURLWithPath: entry.path))) }
    }
}
