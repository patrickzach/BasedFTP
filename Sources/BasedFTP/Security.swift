import Foundation
import Security

enum CredentialStore {
    static let service = "app.basedftp.credentials"
    static func save(_ value: String, profile: UUID, purpose: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: profile.uuidString + "." + purpose]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw FTPError.message("Keychain: \(SecCopyErrorMessageString(result, nil) as String? ?? String(result))") }
    }
    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(profile: UUID) {
        for purpose in ["password", "passphrase"] { try? save("", profile: profile, purpose: purpose) }
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
                guard !alias.contains(where: { "*?!#".contains($0) }), !profiles.contains(where: { $0.host == alias }) else { continue }
                var p = ServerProfile(); p.name = alias; p.host = alias; profiles.append(p)
            }
        }
        persist()
    }
}
