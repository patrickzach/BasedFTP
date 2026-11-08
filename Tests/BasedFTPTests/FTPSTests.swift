import XCTest
@testable import BasedFTP

final class FTPSTests: XCTestCase {
    private func environment() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BASEDFTP_FTPS_TEST_ROOT"] else { throw XCTSkip("Run Scripts/ftps-integration-test.sh for isolated TLS servers") }
        return URL(fileURLWithPath: path)
    }
    private func profile(_ mode: String = "ftps") throws -> ServerProfile {
        let root = try environment()
        var p = ServerProfile(); p.transport = mode == "ftps-implicit" ? .ftpsImplicit : .ftps
        p.host = "127.0.0.1"; p.port = try String(contentsOf: root.appendingPathComponent("port-" + mode), encoding: .utf8)
        p.user = "ftp-user"; p.caCertificatePath = root.appendingPathComponent("ca.pem").path
        return p
    }
    private var password: String { ProcessInfo.processInfo.environment["BASEDFTP_FTP_TEST_PASSWORD"] ?? "" }
    private func client(_ p: ServerProfile, control: OperationControl = OperationControl()) throws -> FTPClient {
        try FTPClient(profile: p, control: control, password: password)
    }
    private func local() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-TLS-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func commands(_ mode: String) throws -> [String] {
        let path = try environment().appendingPathComponent("commands-" + mode)
        return ((try? String(contentsOf: path, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
    }
    private func native(_ profile: ServerProfile) throws {
        try FTPCurl.perform(profile: profile, password: password, url: FTPPaths.url(profile: profile, directory: "/"), control: OperationControl(), commands: ["NOOP"])
    }
    func testProtocolModesDefaultPortsAndStrictListingPolicy() throws {
        var p = ServerProfile(); p.host = "127.0.0.1"; p.user = "user"; p.transport = .ftps
        XCTAssertTrue(p.transport.usesTLS); XCTAssertFalse(p.transport.supportsRemoteEditing)
        XCTAssertEqual(p.transport.defaultPort, "21")
        XCTAssertEqual(try FTPPaths.url(profile: p, directory: "/folder"), "ftp://127.0.0.1:21/%2Ffolder/")
        XCTAssertEqual(FTPTLS.listingArguments(profile: p), ["--ssl-reqd", "--tlsv1.2"])
        p.transport = .ftpsImplicit
        XCTAssertEqual(p.transport.defaultPort, "990")
        XCTAssertEqual(try FTPPaths.fileURL(profile: p, path: "/file"), "ftps://127.0.0.1:990/%2F/file")
        let securePurpose = p.passwordPurpose
        p.transport = .ftps; XCTAssertEqual(p.passwordPurpose, securePurpose)
        p.transport = .ftp; XCTAssertNotEqual(p.passwordPurpose, securePurpose)
        XCTAssertTrue(FTPTLS.listingArguments(profile: p).isEmpty)
        p.transport = .sftp; XCTAssertNotEqual(p.passwordPurpose, securePurpose)
    }
    func testProfileMigrationCAConfigurationAndNoInsecureOption() throws {
        var p = ServerProfile(); p.host = "server"; p.user = "user"
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(p)) as? [String: Any])
        json.removeValue(forKey: "transport"); json.removeValue(forKey: "caCertificatePath")
        XCTAssertEqual(try decoder.decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: json)), p)
        for mode in [ServerProtocol.ftps, .ftpsImplicit] {
            p.transport = mode; try p.validate()
            XCTAssertEqual(try decoder.decode(ServerProfile.self, from: encoder.encode(p)), p)
            p.caCertificatePath = "/definitely-missing-ca.pem"; XCTAssertThrowsError(try p.validate())
            p.caCertificatePath = "relative-ca.pem"; XCTAssertThrowsError(try p.validate())
            p.caCertificatePath = ""
            let args = FTPTLS.listingArguments(profile: p)
            XCTAssertFalse(args.contains("--insecure")); XCTAssertFalse(args.contains("--ssl"))
        }
    }
    func testExplicitImplicitAndPASVListingTransfersAndFileOperationsUseTLS() throws {
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), result = root.appendingPathComponent("result")
        let content = Data((0..<100_003).map { UInt8($0 % 251) }); try content.write(to: source)
        for mode in ["ftps", "ftps-pasv", "ftps-implicit"] {
            let p = try profile(mode), c = try client(p); defer { c.close() }
            XCTAssertEqual(try c.realpath("."), "/home")
            XCTAssertTrue(try c.list("/home").contains { $0.name == "hello ü #%.txt" })
            let path = "/home/secure-" + UUID().uuidString
            try c.mkdir(path); try c.createFile(path + "/empty")
            try c.upload(source, to: path + "/file ü #%.bin", resume: false) { _ in }
            try c.download(path + "/file ü #%.bin", to: result, resume: false) { _ in }
            XCTAssertTrue(try Data(contentsOf: result) == content)
            try c.rename(path + "/file ü #%.bin", path + "/renamed")
            try c.chmod(path + "/renamed", mode: 0o640)
            XCTAssertEqual(try c.stat(path + "/renamed").permissions & 0o777, 0o640)
            try c.delete(c.stat(path))
            XCTAssertFalse(try c.exists(path))
            let log = try String(contentsOf: environment().appendingPathComponent("security-" + mode), encoding: .utf8)
            XCTAssertTrue(log.contains("control TLSv1.")); XCTAssertTrue(log.contains("data TLSv1.")); XCTAssertFalse(log.contains("login-clear"))
            XCTAssertFalse(log.contains("TLSv1.1")); XCTAssertFalse(log.contains("TLSv1.0"))
            let names = try commands(mode)
            XCTAssertTrue(names.contains("PBSZ")); XCTAssertTrue(names.contains("PROT"))
            if mode == "ftps-implicit" { XCTAssertFalse(names.contains("AUTH")) }
            else { XCTAssertTrue(names.contains("AUTH")) }
            if mode == "ftps-pasv" { XCTAssertTrue(names.contains("PASV")) }
        }
    }
    func testUntrustedWrongCAHostnameAndExpiredCertificatesFailBeforeLogin() throws {
        var unknown = try profile(); unknown.caCertificatePath = ""
        var wrongCA = try profile(); wrongCA.caCertificatePath = try environment().appendingPathComponent("wrong-ca.pem").path
        var wrongHost = try profile(); wrongHost.host = "localhost"
        let expired = try profile("ftps-expired")
        for p in [unknown, wrongCA, wrongHost, expired] {
            let mode = p.port == expired.port ? "ftps-expired" : "ftps"
            let before = try commands(mode).count
            let c = try client(p); defer { c.close() }
            XCTAssertThrowsError(try c.realpath(".")) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
            XCTAssertThrowsError(try native(p)) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
            let after = Array(try commands(mode).dropFirst(before))
            XCTAssertFalse(after.contains("USER")); XCTAssertFalse(after.contains("PASS"))
        }
    }
    func testNoPlaintextFallbackAndTLS12Minimum() throws {
        for mode in ["plain", "ftps-legacy"] {
            let p = try profile(mode), before = try commands(mode).count
            let c = try client(p); defer { c.close() }
            XCTAssertThrowsError(try c.realpath(".")) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
            XCTAssertThrowsError(try native(p)) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
            let after = Array(try commands(mode).dropFirst(before))
            XCTAssertFalse(after.contains("USER")); XCTAssertFalse(after.contains("PASS"))
        }
    }
    func testRefusedDataProtectionFailsWithoutUnprotectedListingOrTransfer() throws {
        let p = try profile("ftps-no-data"), c = try client(p); defer { c.close() }
        let before = try commands("ftps-no-data").count
        XCTAssertThrowsError(try c.realpath(".")) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
        XCTAssertThrowsError(try native(p)) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
        let after = Array(try commands("ftps-no-data").dropFirst(before))
        XCTAssertFalse(after.contains("MLSD")); XCTAssertFalse(after.contains("LIST")); XCTAssertFalse(after.contains("STOR")); XCTAssertFalse(after.contains("NOOP"))
    }
    func testWrongDataChannelCertificateIsRejectedByCLIAndNativeTransfer() throws {
        let p = try profile("ftps-bad-data"), c = try client(p); defer { c.close() }
        XCTAssertThrowsError(try c.realpath(".")) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("stage")
        try Data("precious".utf8).write(to: destination)
        let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
        XCTAssertThrowsError(try FTPCurl.perform(profile: p, password: password, url: FTPPaths.fileURL(profile: p, path: "/home/hello ü #%.txt"), control: OperationControl(), file: file, size: 9)) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("precious".utf8))
    }
    func testCertificateChangeDuringSupplementaryLISTIsNotIgnored() throws {
        let p = try profile("ftps-rotate"), c = try client(p); defer { c.close() }
        XCTAssertThrowsError(try c.realpath(".")) { XCTAssertTrue($0 is FTPTLSError, $0.localizedDescription) }
        let log = try commands("ftps-rotate")
        XCTAssertTrue(log.contains("MLSD"))
        XCTAssertFalse(log.contains("LIST")) // The second TLS session must fail before LIST/login.
    }
    func testInvalidCABundleFailsClosed() throws {
        var p = try profile()
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("invalid.pem"); try Data("not a certificate".utf8).write(to: file)
        p.caCertificatePath = file.path
        let c = try client(p); defer { c.close() }
        XCTAssertThrowsError(try c.realpath("."))
        XCTAssertThrowsError(try native(p))
    }
    func testTLSResumeAndFailedStagingCommitPreserveOriginalContents() throws {
        let p = try profile(), c = try client(p); defer { c.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let remoteRoot = try environment().appendingPathComponent("files-ftps/home")
        let source = root.appendingPathComponent("source"), downloaded = root.appendingPathComponent("downloaded")
        let data = Data((0..<180_003).map { UInt8($0 % 251) }); try data.write(to: source)
        let name = "resume-" + UUID().uuidString
        try data.prefix(10_003).write(to: remoteRoot.appendingPathComponent(name))
        try c.upload(source, to: "/home/" + name, resume: true) { _ in }
        try data.prefix(33_007).write(to: downloaded)
        try c.download("/home/" + name, to: downloaded, resume: true) { _ in }
        XCTAssertTrue(try Data(contentsOf: downloaded) == data)
        XCTAssertTrue(try Data(contentsOf: remoteRoot.appendingPathComponent(name)) == data)
        let old = remoteRoot.appendingPathComponent("commit-denied"); try Data("keep".utf8).write(to: old)
        XCTAssertThrowsError(try TransferEngine(client: c, upload: true, policy: .overwrite).run(source: LocalFiles.entry(source), destination: "/home/commit-denied") { _, _ in })
        XCTAssertEqual(try Data(contentsOf: old), Data("keep".utf8))
    }
    func testNativeTLSTransferCancellation() throws {
        let p = try profile(), control = OperationControl(), c = try client(p, control: control); defer { c.close() }
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try Data(repeating: 0x73, count: 2_000_013).write(to: source)
        var cancelled = false
        XCTAssertThrowsError(try c.upload(source, to: "/home/cancel-" + UUID().uuidString, resume: false) { amount in
            if amount > 0 && amount < 2_000_013 && !cancelled { cancelled = true; control.cancel() }
        })
        XCTAssertTrue(cancelled)
    }
    @MainActor func testFTPSFactoryAndParallelFolderQueue() async throws {
        var p = try profile(); p.user = "ftp-queue"
        let root = try local(); defer { try? FileManager.default.removeItem(at: root) }
        var entries: [FileEntry] = []
        for index in 0..<2 {
            let folder = root.appendingPathComponent("tls-queue-\(index)-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("TLS folder".utf8).write(to: folder.appendingPathComponent("nested/file"))
            entries.append(try LocalFiles.entry(folder))
        }
        let queue = TransferQueue(); queue.limit = 2
        queue.enqueue(entries, profile: p, destination: "/home", upload: true)
        let deadline = Date().addingTimeInterval(45)
        while queue.jobs.contains(where: { !$0.terminal }) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .completed }, queue.jobs.compactMap(\.error).joined(separator: "\n"))
        let remote = try environment().appendingPathComponent("files-ftps/home")
        for entry in entries { XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(entry.name + "/nested/file")), Data("TLS folder".utf8)) }
    }
}
