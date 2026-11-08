import Foundation
import Security
import CryptoKit
import Darwin

/// Authenticate both ends of the private pipe using the same signing certificate.
/// A bundle identifier alone is never sufficient.
public enum CredentialIdentity {
    private static func ownCertificateRequirement(identifier: String) throws -> SecRequirement {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw CredentialFailure("Cannot identify the signed application.") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw CredentialFailure("Cannot inspect the application signature.") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else {
            throw CredentialFailure("Keychain access requires a certificate-signed build. Run Scripts/setup-local-signing.sh and rebuild.")
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and certificate leaf = H\"\(digest)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw CredentialFailure("Cannot verify the credential helper identity.")
        }
        return requirement
    }
    public static func verifyParent() throws {
        var parent: SecCode?
        let attributes = [kSecGuestAttributePid as String: getppid()] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent,
              SecCodeCheckValidity(parent, [], try ownCertificateRequirement(identifier: "app.basedftp.client")) == errSecSuccess else {
            throw CredentialFailure("Only the matching signed BasedFTP application can access this helper.")
        }
    }
    public static func verifyHelper(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], try ownCertificateRequirement(identifier: "app.basedftp.credentials-helper")) == errSecSuccess else {
            throw CredentialFailure("The credential helper signature does not match this application. Rebuild the app.")
        }
    }
}
