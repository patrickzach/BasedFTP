// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BasedFTP", platforms: [.macOS(.v14)], products: [.executable(name: "BasedFTP", targets: ["BasedFTP"])], targets: [.systemLibrary(name: "CCurl"), .executableTarget(name: "BasedFTP", dependencies: ["CCurl"]), .testTarget(name: "BasedFTPTests", dependencies: ["BasedFTP"])], swiftLanguageModes: [.v5])
