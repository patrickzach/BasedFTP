import XCTest
@testable import BasedFTP

final class RemoteFileSystemTests: XCTestCase {
    func testInterfaceDistinguishesMissingEntriesFromPermissionAndConnectionErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-backend-" + UUID().uuidString)
        let restricted = root.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
            try? FileManager.default.removeItem(at: root)
        }
        let file = restricted.appendingPathComponent("file")
        try Data("keep".utf8).write(to: file)
        let client: any RemoteFileSystem = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server")
        defer { client.close() }
        XCTAssertNil(try client.entryIfExists(root.appendingPathComponent("missing").path))
        XCTAssertFalse(try client.exists(root.appendingPathComponent("missing").path))
        XCTAssertEqual(try client.entryIfExists(file.path)?.size, 4)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        XCTAssertThrowsError(try client.entryIfExists(file.path))
        XCTAssertThrowsError(try client.exists(file.path))
        client.close()
        XCTAssertThrowsError(try client.entryIfExists(file.path))
    }

    func testTransferEngineAndFileOperationsThroughRemoteInterface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-interface-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("remote")
        let downloaded = root.appendingPathComponent("downloaded")
        let content = Data(repeating: 0x5a, count: 200_003)
        try content.write(to: source)
        let client: any RemoteFileSystem = try SFTPClient(profile: nil, localServer: "/usr/libexec/sftp-server")
        defer { client.close() }
        let upload = TransferEngine(client: client, upload: true, policy: .rename)
        try upload.run(source: LocalFiles.entry(source), destination: destination.path) { _, _ in }
        XCTAssertEqual(upload.fileProgress.transferred, 1)
        let download = TransferEngine(client: client, upload: false, policy: .rename)
        try download.run(source: client.stat(destination.path), destination: downloaded.path) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: downloaded), content)
        XCTAssertEqual(download.fileProgress.transferred, 1)
        let folder = root.appendingPathComponent("folder")
        try client.mkdir(folder.path)
        let moved = folder.appendingPathComponent("moved")
        try client.rename(destination.path, moved.path)
        try client.createFile(folder.appendingPathComponent("empty").path)
        try client.chmod(moved.path, mode: 0o640)
        XCTAssertEqual(try client.stat(moved.path).permissions & 0o777, 0o640)
        XCTAssertEqual(try client.list(client.realpath(folder.path)).count, 2)
        var removed = 0
        try client.delete([client.stat(folder.path)]) { removed = $0.removed }
        XCTAssertEqual(removed, 3)
        XCTAssertNil(try client.entryIfExists(folder.path))
    }
}
