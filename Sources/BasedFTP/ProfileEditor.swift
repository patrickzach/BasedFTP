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
            Label("SSH-Verbindung", systemImage: "server.rack").font(.title2.bold())
            Form {
                TextField("Name", text: $profile.name)
                TextField("Host / SSH-Alias", text: $profile.host)
                TextField("Benutzer (leer: SSH-Konfiguration)", text: $profile.user)
                TextField("Port (leer: SSH-Konfiguration)", text: $profile.port)
                TextField("Startverzeichnis", text: $profile.initialPath)
                HStack {
                    TextField("SSH-Key (optional)", text: $profile.keyPath)
                    Button("Auswählen…") {
                        let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.canChooseDirectories = false
                        if panel.runModal() == .OK { profile.keyPath = panel.url?.path ?? "" }
                    }
                }
                SecureField("Passwort", text: $password).onChange(of: password) { _, value in if !value.isEmpty { savePassword = true } }
                Toggle("Passwort im Schlüsselbund ersetzen", isOn: $savePassword)
                SecureField("Key-Passphrase", text: $passphrase).onChange(of: passphrase) { _, value in if !value.isEmpty { savePassphrase = true } }
                Toggle("Passphrase im Schlüsselbund ersetzen", isOn: $savePassphrase)
                Toggle("Favorit", isOn: $profile.favorite)
                Toggle("Serverprofil speichern", isOn: $remember)
            }.textFieldStyle(.roundedBorder)
            Text("SSH-Agent und ~/.ssh/config werden automatisch verwendet. Gespeicherte Geheimnisse bleiben im macOS-Schlüsselbund; leere Felder ändern sie nur bei aktivierter Ersetzen-Option.").font(.caption).foregroundStyle(.secondary)
            if let result { Text(result).font(.caption).textSelection(.enabled).frame(maxHeight: 100).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Host-Key prüfen…") { scan() }
                Button("Verbindung testen") { test() }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Speichern") { if save() { dismiss() } }
                Button("Verbinden") { if save() { connect(profile, remember); dismiss() } }.keyboardShortcut(.defaultAction)
            }.disabled(busy)
        }.padding(24).frame(width: 660)
        .interactiveDismissDisabled(busy)
        .sheet(item: $trust) { candidate in HostTrustView(candidate: candidate) { result = $0 } }
    }
    private func save() -> Bool {
        do {
            try profile.validate()
            guard password.isEmpty || savePassword, passphrase.isEmpty || savePassphrase else { throw FTPError.message("Für Passwort-Authentifizierung die Schlüsselbund-Option aktivieren. Alternativ SSH-Key oder SSH-Agent verwenden.") }
            if savePassword { try CredentialStore.save(password, profile: profile.id, purpose: "password") }
            if savePassphrase { try CredentialStore.save(passphrase, profile: profile.id, purpose: "passphrase") }
            if remember { store.save(profile) }; return true
        } catch { result = error.localizedDescription; return false }
    }
    private func test() {
        guard save() else { return }; busy = true; let p = profile
        Task {
            do {
                let path = try await Task.detached { let c = try SFTPClient(profile: p); defer { c.close() }; return try c.realpath(p.initialPath) }.value
                result = "SSH-Authentifizierung und SFTP erfolgreich. Verzeichnis: \(path)"
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
        // Resolve aliases using the same OpenSSH config engine as actual connections.
        var arguments = ["-G"]
        if !profile.port.isEmpty { arguments += ["-p", profile.port] }
        if !profile.user.isEmpty { arguments += ["-l", profile.user] }
        arguments.append(profile.host)
        let config = try run("/usr/bin/ssh", arguments)
        guard config.0 == 0 else { throw FTPError.message("SSH-Konfiguration konnte nicht aufgelöst werden.") }
        var values: [String: String] = [:]
        for line in config.1.split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        guard values["proxyjump"] == nil || values["proxyjump"] == "none", values["proxycommand"] == nil || values["proxycommand"] == "none" else {
            throw FTPError.message("Host-Key für ProxyJump/ProxyCommand bitte einmal im Terminal mit ssh verifizieren. Danach funktioniert die Verbindung hier.")
        }
        let host = values["hostname"] ?? profile.host; let port = values["port"] ?? "22"
        let alias = values["hostkeyalias"]
        let lookup = alias ?? (port == "22" ? host : "[\(host)]:\(port)")
        guard !host.hasPrefix("-"), !lookup.contains(where: { $0.isWhitespace || $0 == "\n" }) else { throw FTPError.message("Ungültiger Host-Key-Alias.") }
        if FileManager.default.fileExists(atPath: knownHosts.path), try run("/usr/bin/ssh-keygen", ["-F", lookup, "-f", knownHosts.path]).0 == 0 {
            throw FTPError.message("Für diesen Host ist bereits ein Schlüssel hinterlegt. Vorhandene oder geänderte Host-Keys werden hier nicht ersetzt. Bei Verbindungsfehlern den Fingerprint mit dem Administrator prüfen.")
        }
        let scan = try run("/usr/bin/ssh-keyscan", ["-T", "10", "-p", port, host])
        let lines = scan.1.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line -> String? in
            let fields = line.split(separator: " ")
            guard fields.count == 3 else { return nil }
            return "\(lookup) \(fields[1]) \(fields[2])"
        }
        guard !lines.isEmpty else { throw FTPError.message("Keine Host-Keys empfangen. Host, Port und Netzwerk prüfen.") }
        let keys = lines.joined(separator: "\n") + "\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data(keys.utf8).write(to: temp)
        let fingerprint = try run("/usr/bin/ssh-keygen", ["-lf", temp.path, "-E", "sha256"])
        guard fingerprint.0 == 0 else { throw FTPError.message("Host-Keys konnten nicht geprüft werden.") }
        return HostCandidate(host: host, port: port, lookup: lookup, keys: keys, fingerprints: fingerprint.1)
    }
    static func trust(_ candidate: HostCandidate) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: knownHosts.path), try run("/usr/bin/ssh-keygen", ["-F", candidate.lookup, "-f", knownHosts.path]).0 == 0 { throw FTPError.message("Zwischenzeitlich wurde ein Schlüssel hinzugefügt. Bitte erneut prüfen.") }
        let fd = Darwin.open(knownHosts.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FTPError.message("known_hosts konnte nicht sicher geöffnet werden.") }
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
            Label("Server-Identität verifizieren", systemImage: "lock.shield").font(.title2.bold())
            Text("\(candidate.host):\(candidate.port)").font(.headline)
            Text("Die folgenden Schlüssel stammen aus einer noch nicht vertrauenswürdigen Netzwerkabfrage. Vergleiche alle angezeigten SHA256-Fingerprints über einen unabhängigen Kanal mit deinem Administrator, bevor du sie speicherst.")
            Text(candidate.fingerprints).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Toggle("Ich habe diese Fingerprints unabhängig verifiziert", isOn: $verified)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Abbrechen", role: .cancel) { dismiss() }; Button("In known_hosts speichern") {
                do { try HostTrust.trust(candidate); result("Host-Keys gespeichert. Du kannst die Verbindung jetzt testen."); dismiss() }
                catch { self.error = error.localizedDescription }
            }.disabled(!verified) }
        }.padding(24).frame(width: 680)
    }
}

import Darwin
