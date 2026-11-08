import Foundation
import Security

public struct CredentialFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public static func keychain(_ status: OSStatus) -> CredentialFailure {
        CredentialFailure("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}
public struct CredentialRequest: Codable {
    public enum Operation: String, Codable { case read, save }
    public let operation: Operation
    public let account: String
    public let value: String?
    public init(operation: Operation, account: String, value: String? = nil) {
        self.operation = operation; self.account = account; self.value = value
    }
}
public struct CredentialResponse: Codable {
    public let value: String?
    public let status: OSStatus?
    public let error: String?
    public init(value: String? = nil, status: OSStatus? = nil, error: String? = nil) {
        self.value = value; self.status = status; self.error = error
    }
}
public enum CredentialKeychain {
    public static let service = "app.basedftp.credentials"
    public static func perform(_ request: CredentialRequest) throws -> String? {
        let parts = request.account.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              ["password", "passphrase", "ftp-password", "ftps-password"].contains(String(parts[1])) else {
            throw CredentialFailure("Invalid credential account.")
        }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: request.account]
        switch request.operation {
        case .read:
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw CredentialFailure.keychain(status) }
            guard let data = value as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw CredentialFailure("The stored credential is not valid UTF-8. Replace it in the server settings.")
            }
            return secret
        case .save:
            guard let value = request.value else { throw CredentialFailure("Missing credential value.") }
            if value.isEmpty {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialFailure.keychain(status) }
                return nil
            }
            let attributes = [kSecValueData as String: Data(value.utf8)]
            // Preserve existing access-control grants when replacing a password.
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = Data(value.utf8)
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(query as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    query.removeValue(forKey: kSecValueData as String)
                    query.removeValue(forKey: kSecAttrAccessible as String)
                    status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                }
            }
            guard status == errSecSuccess else { throw CredentialFailure.keychain(status) }
            return nil
        }
    }
}
