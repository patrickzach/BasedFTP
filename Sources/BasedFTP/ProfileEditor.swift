import SwiftUI
import AppKit

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ServerProfile
    @ObservedObject var store: ProfileStore
    let connect: (ServerProfile, Bool) -> Void
    @State private var remember = true
    @State private var password = ""
    @State private var passphrase = ""
    @State private var savePassword = false
    @State private var savePassphrase = false
    @State private var busy = false
    @State private var result: String?
    @State private var trust: HostCandidate?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Server Connection", systemImage: "server.rack").font(.title2.bold())
            Form {
                Picker("Protocol", selection: $profile.transport) {
                    ForEach(ServerProtocol.allCases) { Text($0.title).tag($0) }
                }.onChange(of: profile.transport) { _, _ in
                    password = ""; passphrase = ""; savePassword = false; savePassphrase = false; result = nil
                }
                TextField("Name", text: $profile.name)
                TextField(profile.transport == .sftp ? "Host / SSH Alias" : "Host", text: $profile.host)
                TextField(profile.transport == .sftp ? "Username (blank: SSH configuration)" : "Username", text: $profile.user)
                TextField(profile.transport == .sftp ? "Port (blank: SSH configuration)" : "Port (default: \(profile.transport.defaultPort))", text: $profile.port)
                TextField("Initial Directory", text: $profile.initialPath)
                if profile.transport == .sftp {
                    HStack {
                        TextField("SSH Key (optional)", text: $profile.keyPath)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.canChooseDirectories = false
                            if panel.runModal() == .OK { profile.keyPath = panel.url?.path ?? "" }
                        }
                    }
                }
                SecureField("Password", text: $password).onChange(of: password) { _, value in if !value.isEmpty { savePassword = true } }
                Toggle("Replace password in Keychain", isOn: $savePassword)
                if profile.transport == .sftp {
                    SecureField("Key Passphrase", text: $passphrase).onChange(of: passphrase) { _, value in if !value.isEmpty { savePassphrase = true } }
                    Toggle("Replace passphrase in Keychain", isOn: $savePassphrase)
                }
                if profile.transport.usesTLS {
                    HStack {
                        TextField("CA Certificate (optional PEM)", text: $profile.caCertificatePath)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                            if panel.runModal() == .OK { profile.caCertificatePath = panel.url?.path ?? "" }
                        }
                    }
                }
                Toggle("Favorite", isOn: $profile.favorite)
                Toggle("Save server profile", isOn: $remember)
            }.textFieldStyle(.roundedBorder)
            if profile.transport == .sftp {
                Text("SSH agent and ~/.ssh/config are used automatically. Credentials are stored in macOS Keychain. Empty fields only change stored credentials when the replace option is enabled.").font(.caption).foregroundStyle(.secondary)
            } else {
                if profile.transport.usesTLS {
                    Text("TLS 1.2 or newer is required for login and data. Certificates and hostnames are verified using system trust or the selected CA bundle. Verification failures stop the connection.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("FTP sends your password and file contents without encryption. Choose SFTP or FTPS for secure connections.").font(.caption).foregroundStyle(.orange)
                }
                Text(ServerProtocol.ftpLimitationsNotice + " Passwords are stored separately in macOS Keychain; leave the field empty to use a stored password.").font(.caption).foregroundStyle(.secondary)
            }
            if let result { Text(result).font(.caption).textSelection(.enabled).frame(maxHeight: 100).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if profile.transport == .sftp { Button("Verify Host Key…") { scan() } }
                Button("Test Connection") { test() }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { if save() { dismiss() } }
                Button("Connect") { if save() { connect(profile, remember); dismiss() } }.keyboardShortcut(.defaultAction)
            }.disabled(busy)
        }.padding(24).frame(width: 660)
        .interactiveDismissDisabled(busy)
        .sheet(item: $trust) { candidate in HostTrustView(candidate: candidate) { result = $0 } }
    }
    private func save() -> Bool {
        do {
            try profile.validate()
            guard password.isEmpty || savePassword, profile.transport != .sftp || passphrase.isEmpty || savePassphrase else { throw FTPError.message("Enable the Keychain option to use the entered credentials.") }
            if savePassword { try CredentialStore.save(password, profile: profile.id, purpose: profile.passwordPurpose) }
            if profile.transport == .sftp && savePassphrase { try CredentialStore.save(passphrase, profile: profile.id, purpose: "passphrase") }
            if remember { store.save(profile) }; return true
        } catch { result = error.localizedDescription; return false }
    }
    private func test() {
        guard save() else { return }; busy = true; let p = profile
        Task {
            do {
                let path = try await Task.detached { let c = try RemoteFileSystems.connect(profile: p); defer { c.close() }; let path = try c.realpath(p.initialPath); _ = try c.list(path); return path }.value
                result = "\(p.transport == .sftp ? "SSH authentication and SFTP" : "\(p.transport.usesTLS ? "FTPS verified TLS" : "FTP") login and passive directory listing") succeeded. Directory: \(path)"
            } catch { result = error.localizedDescription }
            busy = false
        }
    }
    private func scan() {
        do { try profile.validate() } catch { result = error.localizedDescription; return }
        busy = true; let p = profile
        Task {
            do { trust = try await Task.detached { try HostTrust.scan(p) }.value }
            catch { result = error.localizedDescription }
            busy = false
        }
    }
}

struct HostCandidate: Identifiable, Sendable {
    let id = UUID()
    let host: String
    let port: String
    let lookup: String
    let keys: String
    let fingerprints: String
}

enum HostTrust {
    static var knownHosts: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts") }
    static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    static func scan(_ profile: ServerProfile) throws -> HostCandidate {
        guard profile.transport == .sftp else { throw FTPError.message("Host-key verification applies only to SFTP connections.") }
        // Resolve aliases using the same OpenSSH config engine as actual connections.
        var arguments = ["-G"]
        if !profile.port.isEmpty { arguments += ["-p", profile.port] }
        if !profile.user.isEmpty { arguments += ["-l", profile.user] }
        arguments.append(profile.host)
        let config = try run("/usr/bin/ssh", arguments)
        guard config.0 == 0 else { throw FTPError.message("Could not resolve the SSH configuration.") }
        var values: [String: String] = [:]
        for line in config.1.split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        guard values["proxyjump"] == nil || values["proxyjump"] == "none", values["proxycommand"] == nil || values["proxycommand"] == "none" else {
            throw FTPError.message("Verify host keys for ProxyJump/ProxyCommand once using ssh in Terminal. You can then connect here.")
        }
        let host = values["hostname"] ?? profile.host; let port = values["port"] ?? "22"
        let alias = values["hostkeyalias"]
        let lookup = alias ?? (port == "22" ? host : "[\(host)]:\(port)")
        guard !host.hasPrefix("-"), !lookup.contains(where: { $0.isWhitespace || $0 == "\n" }) else { throw FTPError.message("Invalid host-key alias.") }
        if FileManager.default.fileExists(atPath: knownHosts.path), try run("/usr/bin/ssh-keygen", ["-F", lookup, "-f", knownHosts.path]).0 == 0 {
            throw FTPError.message("A key is already stored for this host. Existing or changed host keys are never replaced here. If connecting fails, verify the fingerprint with your administrator.")
        }
        let scan = try run("/usr/bin/ssh-keyscan", ["-T", "10", "-p", port, host])
        let lines = scan.1.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line -> String? in
            let fields = line.split(separator: " ")
            guard fields.count == 3 else { return nil }
            return "\(lookup) \(fields[1]) \(fields[2])"
        }
        guard !lines.isEmpty else { throw FTPError.message("No host keys received. Check the host, port and network.") }
        let keys = lines.joined(separator: "\n") + "\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data(keys.utf8).write(to: temp)
        let fingerprint = try run("/usr/bin/ssh-keygen", ["-lf", temp.path, "-E", "sha256"])
        guard fingerprint.0 == 0 else { throw FTPError.message("Could not verify host keys.") }
        return HostCandidate(host: host, port: port, lookup: lookup, keys: keys, fingerprints: fingerprint.1)
    }
    static func trust(_ candidate: HostCandidate) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: knownHosts.path), try run("/usr/bin/ssh-keygen", ["-F", candidate.lookup, "-f", knownHosts.path]).0 == 0 { throw FTPError.message("A key has been added in the meantime. Please check again.") }
        let fd = Darwin.open(knownHosts.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FTPError.message("Could not safely open known_hosts.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(("\n" + candidate.keys).utf8)); try handle.synchronize()
    }
}

struct HostTrustView: View {
    @Environment(\.dismiss) var dismiss
    let candidate: HostCandidate
    let result: (String) -> Void
    @State private var verified = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Verify Server Identity", systemImage: "lock.shield").font(.title2.bold())
            Text("\(candidate.host):\(candidate.port)").font(.headline)
            Text("These keys were retrieved over an untrusted network connection. Verify every SHA256 fingerprint with your administrator through an independent channel before saving them.")
            Text(candidate.fingerprints).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Toggle("I have independently verified these fingerprints", isOn: $verified)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }; Button("Save to known_hosts") {
                do { try HostTrust.trust(candidate); result("Host keys saved. You can now test the connection."); dismiss() }
                catch { self.error = error.localizedDescription }
            }.disabled(!verified) }
        }.padding(24).frame(width: 680)
    }
}

import Darwin
