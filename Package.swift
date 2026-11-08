// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BasedFTP", platforms: [.macOS(.v14)], products: [.executable(name: "BasedFTP", targets: ["BasedFTP"])], targets: [.systemLibrary(name: "CCurl"), .target(name: "CredentialSupport"), .executableTarget(name: "BasedFTPCredentials", dependencies: ["CredentialSupport"]), .executableTarget(name: "BasedFTP", dependencies: ["CCurl", "CredentialSupport"]), .testTarget(name: "BasedFTPTests", dependencies: ["BasedFTP"])], swiftLanguageModes: [.v5])
