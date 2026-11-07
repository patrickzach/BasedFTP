import XCTest
import Darwin
@testable import BasedFTP

private actor ControlledEditBackend: RemoteEditBackend {
    private(set) var content = Data("original".utf8)
    private(set) var uploaded: [Data] = []
    private(set) var maxActive = 0
    private var active = 0
    private var holdFirst: Bool
    private var failures: Int
    private var release: CheckedContinuation<Void, Never>?
    init(holdFirst: Bool = false, failures: Int = 0) { self.holdFirst = holdFirst; self.failures = failures }
    func download(to file: URL, control: OperationControl) async throws { try content.write(to: file) }
    func upload(_ snapshot: URL, control: OperationControl) async throws {
        active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        let data = try Data(contentsOf: snapshot); uploaded.append(data)
        if holdFirst { holdFirst = false; await withCheckedContinuation { release = $0 } }
        if failures > 0 { failures -= 1; throw FTPError.message("Synthetischer Verbindungsabbruch") }
        try control.touch(); content = data
    }
    func releaseFirst() { release?.resume(); release = nil }
}

@MainActor final class RemoteEditTests: XCTestCase {
    private func waitFor(_ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while !(await condition()), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        let satisfied = await condition(); XCTAssertTrue(satisfied)
    }
    private func session(_ backend: ControlledEditBackend) throws -> RemoteEdit {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-editor-test-" + UUID().uuidString)
        return RemoteEdit(profile: ServerProfile(), entry: FileEntry(name: "index.html", path: "/index.html", permissions: 0o100644), backend: backend, directory: directory)
    }
    private func save(_ value: String, to session: RemoteEdit) async throws {
        try Data(value.utf8).write(to: session.file, options: .atomic)
        await session.checkForChanges(); await session.checkForChanges()
    }
    func testSavesAreSerializedAndOnlyLatestPendingVersionIsUploaded() async throws {
        let backend = ControlledEditBackend(holdFirst: true)
        let edit = try session(backend)
        defer { edit.stop(); try? FileManager.default.removeItem(at: edit.directory) }
        edit.start(openEditor: false, monitorChanges: false)
        try await waitFor { edit.ready && !edit.busy }
        try await save("first", to: edit)
        try await waitFor { await backend.uploaded.count == 1 }
        try await save("second", to: edit)
        try await save("latest", to: edit)
        await backend.releaseFirst()
        try await waitFor { edit.state == .saved && !edit.busy }
        let uploaded = await backend.uploaded
        XCTAssertEqual(uploaded, [Data("first".utf8), Data("latest".utf8)])
        let content = await backend.content, maxActive = await backend.maxActive
        XCTAssertEqual(content, Data("latest".utf8)); XCTAssertEqual(maxActive, 1)
    }
    func testRevertingToInFlightVersionDiscardsOlderPendingSave() async throws {
        for revert in ["first", "original"] {
            let backend = ControlledEditBackend(holdFirst: true); let edit = try session(backend)
            defer { edit.stop(); try? FileManager.default.removeItem(at: edit.directory) }
            edit.start(openEditor: false, monitorChanges: false)
            try await waitFor { edit.ready && !edit.busy }
            try await save("first", to: edit); try await waitFor { await backend.uploaded.count == 1 }
            try await save("obsolete", to: edit); try await save(revert, to: edit)
            await backend.releaseFirst(); try await waitFor { edit.state == .saved && !edit.busy }
            let uploaded = await backend.uploaded, content = await backend.content
            XCTAssertEqual(uploaded, revert == "first" ? [Data("first".utf8)] : [Data("first".utf8), Data("original".utf8)])
            XCTAssertEqual(content, Data(revert.utf8))
        }
    }
    func testFailureKeepsWorkingCopyAndRetryUsesNewestSave() async throws {
        let backend = ControlledEditBackend(failures: 1); let edit = try session(backend)
        defer { edit.stop(); try? FileManager.default.removeItem(at: edit.directory) }
        edit.start(openEditor: false, monitorChanges: false)
        try await waitFor { edit.ready && !edit.busy }
        try await save("failed save", to: edit)
        try await waitFor { edit.state == .failed && !edit.busy }
        let original = await backend.content
        XCTAssertEqual(original, Data("original".utf8))
        XCTAssertEqual(try String(contentsOf: edit.file, encoding: .utf8), "failed save")
        try await save("newest retry", to: edit)
        let attemptsBeforeRetry = await backend.uploaded.count
        XCTAssertEqual(attemptsBeforeRetry, 1)
        edit.retry()
        for _ in 0..<3 { await edit.checkForChanges(); try await Task.sleep(nanoseconds: 20_000_000) }
        try await waitFor { edit.state == .saved && !edit.busy }
        let content = await backend.content
        XCTAssertEqual(content, Data("newest retry".utf8))
        edit.stop()
        try Data("after stop".utf8).write(to: edit.file)
        await edit.checkForChanges(); await edit.checkForChanges()
        let unchanged = await backend.content
        XCTAssertEqual(unchanged, content)
    }
    func testSnapshotsAreImmutableAndRejectSymlinksAndFIFOs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        let snapshot = try EditSnapshot.capture(file, in: root.appendingPathComponent("snapshots"))
        try Data("after".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(try String(contentsOf: snapshot.file, encoding: .utf8), "before")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try EditSnapshot.capture(link, in: root))
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try EditSnapshot.capture(fifo, in: root))
    }
    func testEditorPreferencesArePerExtensionAndDoNotChangeSystemDefaults() {
        let suite = "BasedFTP-editor-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorPreferences(defaults: defaults)
        let app = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        store.set(app, for: "index.HTML")
        XCTAssertEqual(store.application(for: "other.html"), app)
        XCTAssertNil(store.application(for: "script.js"))
        store.set(nil, for: "index.html")
        XCTAssertNil(store.application(for: "index.HTML"))
    }
    func testSSHAutomaticRemoteEditingWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["BASEDFTP_TEST_HOST"], let root = env["BASEDFTP_TEST_DIRECTORY"] else { throw XCTSkip("Isolierten SSH-Testserver konfigurieren") }
        var profile = ServerProfile(); profile.host = host; profile.user = env["BASEDFTP_TEST_USER"] ?? ""; profile.port = env["BASEDFTP_TEST_PORT"] ?? ""; profile.keyPath = env["BASEDFTP_TEST_KEY"] ?? ""
        let hosts = env["BASEDFTP_TEST_KNOWN_HOSTS"].map { URL(fileURLWithPath: $0) }
        let client = try SFTPClient(profile: profile, knownHosts: hosts); defer { client.close() }
        let remote = FileEntry.join(root, "basedftp-edit-" + UUID().uuidString + ".html")
        try client.createFile(remote)
        defer { if let entry = try? client.stat(remote) { try? client.delete(entry) } }
        let entry = try client.stat(remote)
        let edit = RemoteEdit(profile: profile, entry: entry, backend: SFTPEditBackend(profile: profile, entry: entry, knownHosts: hosts), directory: URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString))
        defer { edit.stop() }
        edit.start(openEditor: false)
        try await waitFor { edit.ready && !edit.busy }
        try Data("<h1>Automatically saved over SSH</h1>".utf8).write(to: edit.file, options: .atomic)
        try await waitFor { edit.state == .saved && !edit.busy }
        let downloaded = URL(fileURLWithPath: root).appendingPathComponent("verify-" + UUID().uuidString)
        try client.download(remote, to: downloaded, resume: false) { _ in }
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "<h1>Automatically saved over SSH</h1>")
    }
    func testActualSFTPAtomicReplacementPreservesOldDataOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-atomic-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote ' [x]\n.html"), local = root.appendingPathComponent("local")
        try Data("old".utf8).write(to: remote); try Data("new".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: remote.path)
        let client = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server"); defer { client.close() }
        try client.uploadEditingSnapshot(local, to: remote.path, permissions: 0o644)
        XCTAssertEqual(try String(contentsOf: remote, encoding: .utf8), "new")
        XCTAssertEqual(try client.stat(remote.path).permissions & 0o777, 0o640)
        try Data("next".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try client.uploadEditingSnapshot(local, to: remote.path, permissions: 0o644))
        XCTAssertEqual(try String(contentsOf: remote, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "next")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let stage = root.appendingPathComponent("stage"), destination = root.appendingPathComponent("directory")
        try Data("stage".utf8).write(to: stage)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: destination.appendingPathComponent("child"))
        XCTAssertThrowsError(try client.commitUpload(stage.path, to: destination.path, requireAtomic: true))
        XCTAssertEqual(try String(contentsOf: stage, encoding: .utf8), "stage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("child").path))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reordering-server.py")
        let noExtension = try SFTPClient(profile: nil, localServer: fixture.path); defer { noExtension.close() }
        XCTAssertThrowsError(try noExtension.uploadEditingSnapshot(local, to: "/fixture", permissions: 0o644)) { error in
            XCTAssertTrue(error.localizedDescription.contains("atomic replacement"))
        }
    }
}
