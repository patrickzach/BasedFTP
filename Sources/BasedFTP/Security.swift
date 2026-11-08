import Foundation
import Security
#if canImport(CredentialSupport)
import CredentialSupport
#endif

/// Serializes reads, including authorization dialogs, and retains successful values
/// only in this process. Failed/canceled reads are never mistaken for a password.
final class CredentialSession {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(account: String, load: () throws -> String?) rethrows -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = values[account] { return value }
        let value = try load()
        if let value { values[account] = value }
        return value
    }
    func change(account: String, value: String?, persist: () throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        // Invalidate even when persistence fails; never keep a possibly stale secret.
        values.removeValue(forKey: account)
        try persist()
        if let value { values[account] = value }
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }; values.removeAll()
    }
}

enum CredentialStore {
    static let service = CredentialKeychain.service
    private static let session = CredentialSession()
    private static func request(_ request: CredentialRequest) throws -> String? {
        if Bundle.main.bundleURL.pathExtension != "app" {
            // SwiftPM command-line/test executables have no bundled helper.
            return try CredentialKeychain.perform(request)
        }
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/BasedFTPCredentials"), FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CredentialFailure("The signed credential helper is missing. Rebuild with Scripts/build-app.sh.")
        }
        try CredentialIdentity.verifyHelper(helper)
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = helper
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = [:]
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CredentialFailure("The credential helper rejected this request.") }
            let response = try JSONDecoder().decode(CredentialResponse.self, from: data)
            if let status = response.status { throw CredentialFailure.keychain(status) }
            if let error = response.error { throw CredentialFailure(error) }
            return response.value
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw error
        }
    }
    static func save(_ value: String, profile: UUID, purpose: String) throws {
        let account = profile.uuidString + "." + purpose
        try session.change(account: account, value: value.isEmpty ? nil : value) {
            _ = try request(CredentialRequest(operation: .save, account: account, value: value))
        }
    }
    static func read(account: String) throws -> String? {
        try session.read(account: account) { try request(CredentialRequest(operation: .read, account: account)) }
    }
    static func clearSession() { session.clear() }
    static func delete(profile: UUID) {
        for purpose in ["password", "passphrase", "ftp-password", "ftps-password"] { try? save("", profile: profile, purpose: purpose) }
    }
}

@MainActor final class ProfileStore: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var persistenceError: String?
    private let url: URL
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BasedFTP")
        url = root.appendingPathComponent("profiles.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) { profiles = try JSONDecoder().decode([ServerProfile].self, from: Data(contentsOf: url)) }
        } catch { persistenceError = error.localizedDescription }
    }
    func save(_ profile: ServerProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        persist()
    }
    func remove(_ profile: ServerProfile) { profiles.removeAll { $0.id == profile.id }; CredentialStore.delete(profile: profile.id); persist() }
    private func persist() {
        do { try JSONEncoder().encode(profiles).write(to: url, options: .atomic) }
        catch { persistenceError = error.localizedDescription }
    }
    func importSSHHosts() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard words.first?.lowercased() == "host" else { continue }
            for word in words.dropFirst() {
                let alias = String(word)
                guard !alias.contains(where: { "*?!#".contains($0) }), !profiles.contains(where: { $0.host == alias && $0.transport == .sftp }) else { continue }
                var p = ServerProfile(); p.name = alias; p.host = alias; profiles.append(p)
            }
        }
        persist()
    }
}
