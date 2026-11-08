import Foundation
import Security
#if canImport(CredentialSupport)
import CredentialSupport
#endif

#if CREDENTIAL_TEST_NO_UI
SecKeychainSetUserInteractionAllowed(false)
#endif

// Fixed helper build reused across app updates: its Keychain partition stays stable.
// Never accept a service name or arbitrary caller identity from the request.
do {
    try CredentialIdentity.verifyParent()
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= 1024 * 1024 else { exit(1) }
    }
    let request = try JSONDecoder().decode(CredentialRequest.self, from: data)
    let response: CredentialResponse
    do { response = CredentialResponse(value: try CredentialKeychain.perform(request)) }
    catch { response = CredentialResponse(error: error.localizedDescription) }
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
} catch { exit(1) }
