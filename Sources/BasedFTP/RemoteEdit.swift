import SwiftUI
import AppKit

@MainActor final class RemoteEdit: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ServerProfile
    let entry: FileEntry
    let directory: URL
    let file: URL
    @Published var busy = false
    @Published var ready = false
    @Published var message: String?
    @Published var uploaded = false
    private var original: FileEntry?
    init(profile: ServerProfile, entry: FileEntry) {
        self.profile = profile; self.entry = entry
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-Edit-" + UUID().uuidString)
        file = directory.appendingPathComponent(entry.name)
    }
    func download() {
        busy = true; let p = profile; let entry = entry; let directory = directory; let file = file
        Task {
            do {
                original = try await Task.detached {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let client = try SFTPClient(profile: p); defer { client.close() }
                    let before = try client.stat(entry.path)
                    try client.download(entry.path, to: file, resume: false) { _ in }
                    let after = try client.stat(entry.path)
                    guard before.modified == after.modified, before.size == after.size else { throw FTPError.message("Datei wurde während des Downloads geändert. Bitte erneut öffnen.") }
                    return after
                }.value
                ready = true
                NSWorkspace.shared.open(file)
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func upload() {
        guard let original else { return }; busy = true; message = nil
        let p = profile; let remote = entry.path; let file = file
        Task {
            do {
                try await Task.detached {
                    let client = try SFTPClient(profile: p); defer { client.close() }
                    let current = try client.stat(remote)
                    guard current.size == original.size, current.modified == original.modified else { throw FTPError.message("Remote-Datei wurde zwischenzeitlich geändert. Upload abgebrochen; lokale Bearbeitung bleibt erhalten.") }
                    try client.upload(file, to: remote, resume: false) { _ in }
                }.value
                uploaded = true; message = "Änderungen hochgeladen."
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}

struct RemoteEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: RemoteEdit
    let completed: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Remote bearbeiten", systemImage: "square.and.pencil").font(.title2.bold())
            Text(session.entry.path).textSelection(.enabled)
            Text("Die Datei öffnet sich im zugeordneten macOS-Editor. Speichere dort deine Änderungen und lade sie hier ausdrücklich hoch. Größe und Änderungsdatum auf dem Server werden vor dem Upload geprüft.").foregroundStyle(.secondary)
            if session.ready { Text(session.file.path).font(.caption).textSelection(.enabled) }
            if let message = session.message { Text(message).textSelection(.enabled) }
            if session.busy { ProgressView() }
            HStack {
                if session.ready { Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([session.file]) } }
                Spacer()
                Button("Schließen") { completed(); dismiss() }.disabled(session.busy)
                Button("Änderungen hochladen") { session.upload() }.disabled(!session.ready || session.busy || session.uploaded)
            }
            Text("Die lokale Arbeitskopie bleibt im temporären Verzeichnis erhalten, damit ungespeicherte Arbeit nicht verloren geht. Remote-Bearbeitung ist kein atomarer Versionsvergleich; bei gleichzeitigen Änderungen bitte extern koordinieren.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 620).task { session.download() }.interactiveDismissDisabled(session.busy)
    }
}
