import XCTest
import Darwin
@testable import BasedFTP

final class FTPFileOperationsTests: XCTestCase {
    private func server(pasv: Bool = false, control: OperationControl = OperationControl()) throws -> (FTPClient, URL, ServerProfile) {
        let env = ProcessInfo.processInfo.environment
        guard let port = env[pasv ? "BASEDFTP_FTP_TEST_PASV_PORT" : "BASEDFTP_FTP_TEST_PORT"], let password = env["BASEDFTP_FTP_TEST_PASSWORD"], let root = env["BASEDFTP_FTP_TEST_ROOT"] else {
            throw XCTSkip("Start FTP test servers with Scripts/ftp-integration-test.sh")
        }
        var profile = ServerProfile(); profile.transport = .ftp; profile.host = "127.0.0.1"; profile.port = port; profile.user = "ftp-user"
        return (try FTPClient(profile: profile, control: control, password: password), URL(fileURLWithPath: root).appendingPathComponent(pasv ? "files-pasv/home" : "files-epsv/home"), profile)
    }
    private func local() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-fileops-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testUnixListingDetectsLinksHiddenByMLSDAndPreservesNamesAndPermissions() throws {
        let entries = try FTPListing.parse(Data("type=dir;size=64; folder\r\ntype=dir;size=64; link\r\ntype=file;size=9;  leading name -> text\r\ntype=file;size=0; pipe\r\n".utf8), directory: "/home")
        let unix = "drwxr-sr-x 1 owner group 64 Nov 8 12:00 folder\r\nlrwxrwxrwx 1 owner group 6 Nov 8 12:00 link -> folder\r\n-rw------- 1 owner group 9 Nov 8 12:00  leading name -> text\r\nprw------- 1 owner group 0 Nov 8 12:00 pipe\r\nlrwxrwxrwx 1 owner group 7 Nov 8 12:00 broken -> missing\r\n"
        let merged = try FTPUnixListing.merge(Data(unix.utf8), entries: entries, directory: "/home")
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(merged.first { $0.name == "folder" }?.modeText, "2755")
        XCTAssertEqual(merged.first { $0.name == " leading name -> text" }?.modeText, "0600")
        XCTAssertTrue(merged.first { $0.name == "link" }?.isSymlink == true)
        XCTAssertTrue(merged.first { $0.name == "broken" }?.isSymlink == true)
        XCTAssertFalse(try XCTUnwrap(merged.first { $0.name == "link" }).sizeAvailable)
        XCTAssertFalse(try XCTUnwrap(merged.first { $0.name == "pipe" }).isRegular)
        XCTAssertTrue(merged.allSatisfy(\.linkInformationAvailable))
    }
    func testUnixListingRefusesUnknownFormatsAmbiguousLinksAndInconsistentSnapshots() throws {
        let entries = try FTPListing.parse(Data("type=dir; a\r\ntype=dir; a -> b\r\n".utf8), directory: "/home")
        for text in ["11-08-26  12:00PM <DIR> a\r\n", "lrwxrwxrwx 1 u g 6 Nov 8 12:00 a -> b -> target\r\n", "drwxr-xr-x 1 u g 64 Nov 8 12:00 a\r\n"] {
            XCTAssertThrowsError(try FTPUnixListing.merge(Data(text.utf8), entries: entries, directory: "/home"))
        }
    }
    func testCreateRenameMoveAndPermissionsInEPSVAndPASV() throws {
        for pasv in [false, true] {
            let (client, remoteRoot, _) = try server(pasv: pasv); defer { client.close() }
            let name = "ops ü \"#% " + UUID().uuidString, path = "/home/" + name
            try client.mkdir(path)
            try client.createFile(path + "/empty file")
            XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent(name + "/empty file")).count, 0)
            XCTAssertThrowsError(try client.createFile(path + "/empty file"))
            try client.rename(path + "/empty file", path + "/renamed")
            try client.chmod(path + "/renamed", mode: 0o640)
            XCTAssertEqual(try client.stat(path + "/renamed").permissions & 0o777, 0o640)
            try client.mkdir(path + "/destination")
            try client.rename(path + "/renamed", path + "/destination/moved")
            try client.mkdir(path + "/folder")
            try client.createFile(path + "/folder/child")
            try client.rename(path + "/folder", path + "/destination/folder")
            XCTAssertTrue(try client.exists(path + "/destination/folder/child"))
            XCTAssertFalse(try client.exists(path + "/folder"))
            XCTAssertThrowsError(try client.rename(path + "/destination/moved", path + "/destination/folder"))
            XCTAssertTrue(try client.exists(path + "/destination/moved"))
            try client.delete(client.stat(path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent(name).path))
        }
    }
    func testRecursiveRoundTripSkipsLinksAndSpecialFilesAndIncludesEmptyFolders() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), downloaded = root.appendingPathComponent("downloaded")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty-folder"), withIntermediateDirectories: true)
        for (name, content) in [("a/b/nested", "nested"), ("hello ü #%.txt", "contents"), (".hidden", "hidden"), ("empty-file", "")] {
            try Data(content.utf8).write(to: source.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("loop").path, withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("broken").path, withDestinationPath: "missing")
        XCTAssertEqual(mkfifo(source.appendingPathComponent("pipe").path, 0o600), 0)
        let name = "tree-" + UUID().uuidString, path = "/home/" + name
        let upload = TransferEngine(client: client, upload: true, policy: .rename)
        try upload.run(source: LocalFiles.entry(source), destination: path) { _, _ in }
        XCTAssertEqual(upload.fileProgress.transferred, 4); XCTAssertEqual(upload.warnings.count, 3)
        let remote = remoteRoot.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: remote.appendingPathComponent("loop").path, withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: remote.appendingPathComponent("broken").path, withDestinationPath: "missing")
        XCTAssertEqual(mkfifo(remote.appendingPathComponent("pipe").path, 0o600), 0)
        let download = TransferEngine(client: client, upload: false, policy: .rename)
        try download.run(source: client.stat(path), destination: downloaded.path) { _, _ in }
        XCTAssertEqual(download.fileProgress.transferred, 4); XCTAssertEqual(download.warnings.count, 3)
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("hello ü #%.txt")), Data("contents".utf8))
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("a/b/nested")), Data("nested".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("empty-folder").path))
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("empty-file")).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("loop").path))
    }
    func testRecursiveDeleteDoesNotFollowLinksAndReusesControlConnection() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let name = "delete-" + UUID().uuidString, keepName = "keep-" + UUID().uuidString
        let target = remoteRoot.appendingPathComponent(name), keep = remoteRoot.appendingPathComponent(keepName)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: keep.appendingPathComponent("file"))
        try Data("plain".utf8).write(to: target.appendingPathComponent("plain"))
        try Data("nested".utf8).write(to: target.appendingPathComponent("nested/file"))
        for (link, destination) in [("outside", "../" + keepName), ("loop", "."), ("broken", "missing")] {
            try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent(link).path, withDestinationPath: destination)
        }
        XCTAssertEqual(mkfifo(target.appendingPathComponent("pipe").path, 0o600), 0)
        let log = remoteRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("command-connections-epsv")
        let previous = (try? String(contentsOf: log, encoding: .utf8).count) ?? 0
        var updates: [DeletionProgress] = []
        try client.delete([client.stat("/home/" + name)]) { updates.append($0) }
        XCTAssertEqual(updates.last?.removed, 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("file"), encoding: .utf8), "precious")
        XCTAssertEqual(updates.last?.path, "/home/" + name)
        let lines = try String(contentsOf: log, encoding: .utf8).dropFirst(previous).split(separator: "\n")
        XCTAssertEqual(Set(lines.map { $0.split(separator: " ")[0] }).count, 1)
    }
    func testDeleteCancellationAndPermissionErrorsLeaveParentsAndRemainingEntries() throws {
        let control = OperationControl(), (client, remoteRoot, _) = try server(control: control); defer { client.close() }
        let name = "cancel-delete-" + UUID().uuidString, folder = remoteRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for index in 0..<5 { try Data([UInt8(index)]).write(to: folder.appendingPathComponent("file-\(index)")) }
        var removed = 0
        XCTAssertThrowsError(try client.delete([client.stat("/home/" + name)]) { update in
            removed = update.removed
            if removed == 2 { control.cancel() }
        })
        XCTAssertEqual(removed, 2); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
        let (fresh, _, _) = try server(); defer { fresh.close() }
        let deniedName = "denied-delete-" + UUID().uuidString, denied = remoteRoot.appendingPathComponent(deniedName)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try Data([1]).write(to: denied.appendingPathComponent("a")); try Data([2]).write(to: denied.appendingPathComponent("delete-denied"))
        XCTAssertThrowsError(try fresh.delete(fresh.stat("/home/" + deniedName))) { error in
            XCTAssertTrue(error.localizedDescription.contains("delete-denied")); XCTAssertTrue(error.localizedDescription.contains("1 confirmed"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: denied.appendingPathComponent("delete-denied").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: denied.path))
    }
    func testRootSelfMoveExistingDestinationsAndSymlinkAncestorsAreRejected() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let name = "guard-" + UUID().uuidString, path = "/home/" + name
        try client.mkdir(path); try client.createFile(path + "/precious")
        for root in ["/", "/home/..", "/."] {
            XCTAssertThrowsError(try client.delete([FileEntry(name: "root", path: root, permissions: 0o040755)]))
            XCTAssertThrowsError(try client.mkdir(root)); XCTAssertThrowsError(try client.rename(path, root))
        }
        XCTAssertThrowsError(try client.rename(path, path + "/child"))
        let alias = "alias-" + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: remoteRoot.appendingPathComponent(alias).path, withDestinationPath: name)
        XCTAssertThrowsError(try client.rename(path, "/home/" + alias + "/inside"))
        XCTAssertThrowsError(try client.delete([FileEntry(name: "precious", path: "/home/" + alias + "/precious", permissions: 0o100644)]))
        XCTAssertTrue(try client.exists(path + "/precious"))
        try client.delete(client.stat("/home/" + alias))
        XCTAssertTrue(try client.exists(path + "/precious"))
    }
    func testMissingUnixLinkMetadataAllowsBrowsingButRejectsRecursionBeforeChanges() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let folder = remoteRoot.appendingPathComponent("mlsd-only")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("file"))
        XCTAssertEqual(try client.list("/home/mlsd-only").map(\.name), ["file"])
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        try client.download("/home/mlsd-only/file", to: root.appendingPathComponent("file"), resume: false) { _ in }
        let entry = try client.stat("/home/mlsd-only/file")
        XCTAssertFalse(entry.permissionsAvailable); XCTAssertFalse(entry.linkInformationAvailable)
        XCTAssertThrowsError(try client.delete(client.stat("/home/mlsd-only")))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("file"), encoding: .utf8), "keep")
        XCTAssertThrowsError(try TransferEngine(client: client, upload: false, policy: .rename).run(source: client.stat("/home/mlsd-only"), destination: root.appendingPathComponent("copy").path) { _, _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy").path))
    }
    func testUnsupportedChmodPreservesPermissionsAndReportsPath() throws {
        let (client, remoteRoot, _) = try server(); defer { client.close() }
        let file = remoteRoot.appendingPathComponent("chmod-denied")
        try Data([1]).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        XCTAssertThrowsError(try client.chmod("/home/chmod-denied", mode: 0o600)) { error in
            XCTAssertTrue(error.localizedDescription.contains("SITE CHMOD")); XCTAssertTrue(error.localizedDescription.contains("/home/chmod-denied"))
        }
        XCTAssertEqual(try client.stat("/home/chmod-denied").permissions & 0o777, 0o640)
    }
    @MainActor func testParallelFolderQueueJobsHandleIndependentDirectoryChanges() async throws {
        let (client, remoteRoot, base) = try server(); defer { client.close() }
        var profile = base; profile.user = "ftp-queue"
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        var sources: [FileEntry] = []
        for index in 0..<3 {
            let folder = root.appendingPathComponent("parallel-folder-\(index)-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
            for file in 0..<3 { try Data(repeating: UInt8(index + file), count: 40_003).write(to: folder.appendingPathComponent("nested/file-\(file)")) }
            sources.append(try LocalFiles.entry(folder))
        }
        let queue = TransferQueue(); queue.limit = 2
        queue.enqueue(sources, profile: profile, destination: "/home", upload: true)
        let deadline = Date().addingTimeInterval(45)
        while queue.jobs.contains(where: { !$0.terminal }) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .completed }, queue.jobs.compactMap(\.error).joined(separator: "\n"))
        for source in sources {
            for file in 0..<3 {
                XCTAssertTrue(try Data(contentsOf: remoteRoot.appendingPathComponent(source.name + "/nested/file-\(file)")) == Data(contentsOf: URL(fileURLWithPath: source.path).appendingPathComponent("nested/file-\(file)")))
            }
        }
    }
    @MainActor func testPaneModelOperationsAndDragDropRouteRealFTPMovesAndFolderTransfers() async throws {
        let (client, remoteRoot, base) = try server(); defer { client.close() }
        var p = base; p.user = "ftp-queue"
        let workspace = Workspace(), tab = ConnectionTab(profile: p)
        workspace.tabs = [tab]; workspace.selected = tab.id
        let pane = tab.remote, root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        func idle(_ pane: PaneModel) async throws {
            let deadline = Date().addingTimeInterval(30)
            while pane.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(pane.busy); XCTAssertNil(pane.error)
        }
        pane.navigate("/home"); try await idle(pane)
        let name = "pane-" + UUID().uuidString
        pane.create(name: name, directory: true); try await idle(pane)
        pane.navigate("/home/" + name); try await idle(pane)
        pane.create(name: "file", directory: false); try await idle(pane)
        let entry = try XCTUnwrap(pane.entries.first { $0.name == "file" })
        pane.rename(entry, name: "renamed"); try await idle(pane)
        pane.create(name: "target", directory: true); try await idle(pane)
        let renamed = try XCTUnwrap(pane.entries.first { $0.name == "renamed" })
        let payload = DragPayload(tab: tab.id, remote: true, entries: [.init(path: renamed.path)])
        XCTAssertTrue(workspace.drop([payload.text], to: pane, directory: pane.path + "/target")); try await idle(pane)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent(name + "/target/renamed").path))
        let source = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("folder upload".utf8).write(to: source.appendingPathComponent("nested"))
        tab.local.navigate(root.path); try await idle(tab.local)
        let folder = try XCTUnwrap(tab.local.entries.first { $0.name == "folder" })
        let folderPayload = DragPayload(tab: tab.id, remote: false, entries: [.init(path: folder.path)])
        XCTAssertTrue(workspace.drop([folderPayload.text], to: pane))
        let deadline = Date().addingTimeInterval(30)
        while workspace.queue.jobs.contains(where: { !$0.terminal }) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(workspace.queue.jobs.allSatisfy { $0.state == .completed }, workspace.queue.jobs.compactMap(\.error).joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent(name + "/folder/nested")), Data("folder upload".utf8))
        try await idle(pane)
        pane.selection = [pane.path + "/folder"]; pane.deleteSelection(); try await idle(pane)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent(name + "/folder").path))
    }
}
