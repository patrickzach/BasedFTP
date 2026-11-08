import Foundation

/// Shared security policy for listing subprocesses and native libcurl requests.
/// There is deliberately no insecure/trust-all or opportunistic TLS option.
enum FTPTLS {
    static func listingArguments(profile: ServerProfile) -> [String] {
        guard profile.transport.usesTLS else { return [] }
        var arguments = ["--ssl-reqd", "--tlsv1.2"]
        if !profile.caCertificatePath.isEmpty { arguments += ["--cacert", profile.resolvedCAPath] }
        return arguments
    }
    static func failure(code: Int) -> FTPTLSError? {
        switch code {
        case 51, 60, 83, 90, 91: return .certificate
        case 77: return .caBundle
        case 64: return .required
        case 35, 59: return .handshake
        default: return nil
        }
    }
}

enum FTPTLSError: LocalizedError {
    case certificate, caBundle, required, handshake
    var errorDescription: String? {
        switch self {
        case .certificate: return "FTPS certificate verification failed. Check the hostname, certificate validity, and issuing CA. Use a trusted CA bundle for a private server; verification cannot be disabled."
        case .caBundle: return "The FTPS CA bundle could not be loaded. Select a valid PEM certificate bundle, or leave the field blank for system trust."
        case .required: return "FTPS requires TLS on both control and data connections. The server refused the required protection; plain FTP was not attempted."
        case .handshake: return "The FTPS TLS handshake failed. Check the TLS mode, port, and server support for TLS 1.2 or newer. Plain FTP was not attempted."
        }
    }
}
