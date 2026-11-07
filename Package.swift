// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BasedFTP", platforms: [.macOS(.v14)], products: [.executable(name: "BasedFTP", targets: ["BasedFTP"])], targets: [.executableTarget(name: "BasedFTP"), .testTarget(name: "BasedFTPTests", dependencies: ["BasedFTP"])], swiftLanguageModes: [.v5])
