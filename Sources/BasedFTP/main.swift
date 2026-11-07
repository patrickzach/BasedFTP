import SwiftUI
import Foundation
import AppKit

// OpenSSH invokes the app executable as a short-lived ASKPASS helper.
// Secrets travel only through the helper's stdout pipe to ssh.
if let profile = ProcessInfo.processInfo.environment["BASEDFTP_PROFILE"],
   ProcessInfo.processInfo.environment["SSH_ASKPASS_REQUIRE"] == "force",
   CommandLine.arguments.count > 1 {
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
    let purpose = prompt.contains("passphrase") ? "passphrase" : "password"
    guard let secret = CredentialStore.read(account: profile + "." + purpose) else { exit(1) }
    FileHandle.standardOutput.write(Data((secret + "\n").utf8)); exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { OperationControl.cancelAll() }
}

struct BasedFTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(nil) }
            .windowStyle(.automatic)
            .defaultSize(width: 1320, height: 820)
            .commands { AppCommands() }
    }
}
BasedFTPApp.main()
