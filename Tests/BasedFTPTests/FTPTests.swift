import XCTest
@testable import BasedFTP

final class FTPTests: XCTestCase {
    private func profile(port: String = "21") -> ServerProfile {
        var p = ServerProfile(); p.transport = .ftp; p.host = "127.0.0.1"; p.user = "ftp-user"; p.port = port
        return p
    }
    func testOldProfilesRemainSFTPAndProtocolRoundTrips() throws {
        var old = ServerProfile(); old.host = "my-ssh-alias"; old.keyPath = "~/.ssh/id_ed25519"
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        json.removeValue(forKey: "transport")
        let restored = try decoder.decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, old)
        let ftp = profile()
        XCTAssertEqual(try decoder.decode(ServerProfile.self, from: encoder.encode(ftp)), ftp)
        XCTAssertNotEqual(old.passwordPurpose, ftp.passwordPurpose)
        json["transport"] = "ftps-not-implemented"
        XCTAssertThrowsError(try decoder.decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testFTPInputsAndURLPathsCannotInjectCommandsOrOptions() throws {
        var p = profile(); p.port = ""; try p.validate()
        XCTAssertEqual(try FTPPaths.url(profile: p, directory: "/a b/#%?[]ü"), "ftp://127.0.0.1:21/%2Fa%20b/%23%25%3F%5B%5D%C3%BC/")
        XCTAssertEqual(try FTPPaths.url(profile: p, directory: ""), "ftp://127.0.0.1:21/")
        XCTAssertEqual(try FTPPaths.url(profile: p, directory: "%2Ffoo"), "ftp://127.0.0.1:21/%252Ffoo/")
        XCTAssertEqual(try FTPPaths.resolved("../folder/./child", home: "/users/me"), "/users/folder/child")
        XCTAssertEqual(try FTPPaths.resolved("/../../folder", home: "/home"), "/folder")
        for path in ["/ok\r\nDELE precious", "/nul\0", "/tab\t"] { XCTAssertThrowsError(try FTPPaths.url(profile: p, directory: path)) }
        for host in ["-K", "host/path", "host:21", "user@host", "host\r\n", "host?query"] {
            p.host = host; XCTAssertThrowsError(try p.validate())
        }
        p = profile(); p.user = "bad:user"; XCTAssertThrowsError(try p.validate())
        p.user = "bad\nuser"; XCTAssertThrowsError(try p.validate())
        p.user = ""; XCTAssertThrowsError(try p.validate())
        let config = String(decoding: FTPClient.credentialConfiguration(user: "ftp-user", password: "a\"b\\c:d"), as: UTF8.self)
        XCTAssertEqual(config, "user = \"ftp-user:a\\\"b\\\\c:d\"\n")
        XCTAssertThrowsError(try FTPClient(profile: profile(), password: "bad\r\npassword"))
    }
    func testMLSDPreservesNamesTypesUTCAndUnknownMetadata() throws {
        let listing = "Type=cdir; .\r\ntype=pdir; ..\r\nTYPE=dir;UNIX.mode=0750;modify=20261107213005.123; folder ü\r\ntype=file;size=9;modify=20261107213005;  leading #%.txt\r\ntype=OS.unix=slink:/target; link\r\ntype=file; empty\r\n"
        let entries = try FTPListing.parse(Data(listing.utf8), directory: "/home")
        XCTAssertEqual(try FTPListing.parse(Data(listing.replacingOccurrences(of: "\r\n", with: "\n").utf8), directory: "/home"), entries)
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[0].path, "/home/folder ü")
        XCTAssertEqual(entries[0].modeText, "0750")
        XCTAssertEqual(entries[1].name, " leading #%.txt")
        XCTAssertEqual(entries[1].size, 9)
        XCTAssertEqual(entries[1].modeText, "—")
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: entries[1].modified)
        XCTAssertEqual(components.hour, 21); XCTAssertEqual(components.minute, 30)
        XCTAssertTrue(entries[2].isSymlink)
        XCTAssertTrue(entries[3].isRegular)
        XCTAssertEqual(entries[3].sizeText, "—")
        XCTAssertEqual(entries[3].modified, .distantPast)
        XCTAssertTrue(try FTPListing.parse(Data(), directory: "/").isEmpty)
    }
    func testMLSDRejectsUnsafeAndAmbiguousEntries() throws {
        for text in ["type=file; ../escape\r\n", "type=file; bad/name\r\n", "type=file; bad\nname\r\n",
                     "type=file;size=-1; file\r\n", "type=file;size=18446744073709551616; file\r\n",
                     "type=file;TYPE=dir; file\r\n", "type=file;unix.mode=888; file\r\n",
                     "type=file;modify=20260230010000; file\r\n", "type=file;modify=; file\r\n",
                     "type=file;charset=latin1; file\r\n", "type=file; a\r\ntype=file; a\r\n", "not an MLSD listing\r\n"] {
            XCTAssertThrowsError(try FTPListing.parse(Data(text.utf8), directory: "/"), text)
        }
        XCTAssertThrowsError(try FTPListing.parse(Data([0xff]), directory: "/"))
    }
    @MainActor func testBrowsingOnlyGatesTransfersMovesAndFileChanges() throws {
        let p = profile(), pane = PaneModel(profile: p), workspace = Workspace()
        let tab = ConnectionTab(profile: p); workspace.tabs = [tab]; workspace.selected = tab.id
        let entry = FileEntry(name: "file", path: "/file", permissions: 0o100644)
        XCTAssertFalse(pane.supportsMutations); XCTAssertFalse(workspace.supportsTransfers)
        pane.create(name: "folder", directory: true)
        XCTAssertEqual(pane.error, ServerProtocol.ftpBrowsingNotice)
        workspace.transfer(from: pane, entries: [entry])
        XCTAssertTrue(workspace.queue.jobs.isEmpty)
        XCTAssertFalse(workspace.drop([URL(fileURLWithPath: "/tmp/file").absoluteString], to: tab.remote))
        workspace.queue.enqueue([entry], profile: p, destination: "/", upload: true)
        XCTAssertTrue(workspace.queue.jobs.isEmpty)
        // Factory dispatches FTP, not SSH, without consulting an SSH configuration.
        let backend = try RemoteFileSystems.connect(profile: p)
        defer { backend.close() }
        XCTAssertTrue(backend is FTPClient)
        XCTAssertThrowsError(try backend.mkdir("/forbidden"))
        XCTAssertThrowsError(try backend.uploadEditingSnapshot(URL(fileURLWithPath: "/tmp/file"), to: "/file", permissions: 0o644))
    }
    private func integration(pasv: Bool = false, password: String? = nil, control: OperationControl = OperationControl()) throws -> FTPClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env[pasv ? "BASEDFTP_FTP_TEST_PASV_PORT" : "BASEDFTP_FTP_TEST_PORT"], let secret = env["BASEDFTP_FTP_TEST_PASSWORD"] else {
            throw XCTSkip("Start the isolated FTP servers with Scripts/ftp-integration-test.sh")
        }
        return try FTPClient(profile: profile(port: port), control: control, password: password ?? secret)
    }
    func testRealFTPPassiveLoginListingAndNavigation() throws {
        let client = try integration(); defer { client.close() }
        let home = try client.realpath(".")
        XCTAssertEqual(home, "/home")
        XCTAssertEqual(try client.realpath(""), "/home")
        let entries = try client.list(home)
        XCTAssertTrue(entries.contains { $0.name == ".hidden" })
        XCTAssertEqual(entries.first { $0.name == "hello ü #%.txt" }?.size, 9)
        XCTAssertTrue(entries.first { $0.name == "sub folder" }?.isDirectory == true)
        let sub = try client.realpath("sub folder")
        XCTAssertEqual(sub, "/home/sub folder")
        XCTAssertEqual(try client.list(sub).map(\.name), ["nested.txt"])
        XCTAssertTrue(try client.list("/home/empty").isEmpty)
        XCTAssertNil(try client.entryIfExists("/home/missing"))
        XCTAssertEqual(try client.stat("/home/hello ü #%.txt").size, 9)
        XCTAssertEqual(try client.stat("hello ü #%.txt").size, 9)
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["BASEDFTP_FTP_TEST_ROOT"])
        let commands = try String(contentsOfFile: root + "/commands-epsv", encoding: .utf8)
        XCTAssertTrue(commands.contains("EPSV\n")); XCTAssertTrue(commands.contains("MLSD\n"))
    }
    func testRealFTPPASVFallbackIgnoresAdvertisedForeignAddress() throws {
        let client = try integration(pasv: true); defer { client.close() }
        XCTAssertTrue(try client.list("/home").contains { $0.name == ".hidden" })
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["BASEDFTP_FTP_TEST_ROOT"])
        let commands = try String(contentsOfFile: root + "/commands-pasv", encoding: .utf8)
        XCTAssertTrue(commands.contains("EPSV\n")); XCTAssertTrue(commands.contains("PASV\n"))
    }
    func testRealFTPLoginDirectoryAndUnsupportedListingErrors() throws {
        let wrong = try integration(password: "wrong-password"); defer { wrong.close() }
        XCTAssertThrowsError(try wrong.realpath(".")) { XCTAssertTrue($0.localizedDescription.contains("login failed")) }
        let client = try integration(); defer { client.close() }
        for path in ["/missing", "/home/denied", "/home/no-mlsd"] {
            XCTAssertThrowsError(try client.realpath(path), path)
        }
        XCTAssertThrowsError(try client.entryIfExists("/home/denied/file"))
        XCTAssertTrue(try client.list("/home").contains { $0.name == ".hidden" })
    }
    func testRealFTPCancellationInterruptsWaitingListing() throws {
        let control = OperationControl(), client = try integration(control: control)
        defer { client.close() }
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { control.cancel() }
        XCTAssertThrowsError(try client.list("/home/slow"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let alreadyCancelled = OperationControl(); alreadyCancelled.cancel()
        XCTAssertThrowsError(try integration(control: alreadyCancelled))
    }
}
