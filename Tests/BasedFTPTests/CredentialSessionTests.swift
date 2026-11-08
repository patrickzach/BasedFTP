import XCTest
@testable import BasedFTP

final class CredentialSessionTests: XCTestCase {
    func testConcurrentReadsLoadOnceAndKeepAccountsSeparate() {
        let session = CredentialSession()
        let lock = NSLock()
        var loads = 0
        var results: [String] = []
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let value = session.read(account: "profile.ftps-password") {
                loads += 1
                return "synthetic-secret"
            }
            lock.lock(); results.append(value ?? "missing"); lock.unlock()
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(results, Array(repeating: "synthetic-secret", count: 20))
        XCTAssertEqual(session.read(account: "profile.ftp-password") { "separate-secret" }, "separate-secret")
    }
    func testChangesDeletionAndClearInvalidateCachedValue() throws {
        let session = CredentialSession()
        XCTAssertEqual(session.read(account: "account") { "old" }, "old")
        var persisted = false
        session.change(account: "account", value: "new") { persisted = true }
        XCTAssertTrue(persisted)
        XCTAssertEqual(session.read(account: "account") { XCTFail("Should be cached"); return nil }, "new")
        session.change(account: "account", value: nil) {}
        XCTAssertNil(session.read(account: "account") { nil })
        XCTAssertEqual(session.read(account: "account") { "external" }, "external")
        session.clear()
        XCTAssertEqual(session.read(account: "account") { "after-clear" }, "after-clear")
    }
    func testFailureIsNotCachedAndFailedSaveInvalidatesOldValue() {
        enum Failure: Error { case denied }
        let session = CredentialSession()
        XCTAssertThrowsError(try session.read(account: "account") { throw Failure.denied })
        XCTAssertEqual(session.read(account: "account") { "old" }, "old")
        XCTAssertThrowsError(try session.change(account: "account", value: "new") { throw Failure.denied })
        XCTAssertEqual(session.read(account: "account") { "still-in-keychain" }, "still-in-keychain")
    }
}
