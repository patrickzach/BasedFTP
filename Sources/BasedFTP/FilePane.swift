import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FilePane: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var workspace: Workspace
    let tabID: UUID
    @State private var action: FileAction?
    @State private var deleteAlert = false
    @State private var edit: RemoteEdit?
        enum FileAction: String, Identifiable { case folder = "Neuer Ordner", file = "Neue Datei", rename = "Umbenennen", move = "Verschieben", chmod = "Berechtigungen"; var id: String { rawValue } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(pane.remote ? "Remote" : "Lokal", systemImage: pane.remote ? "server.rack" : "laptopcomputer").font(.headline)
                Spacer()
                if pane.busy { ProgressView().controlSize(.small); if pane.cancellable { Button { pane.cancel() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Vorgang abbrechen") } }
                Button { workspace.transfer(from: pane) } label: { Image(systemName: pane.remote ? "arrow.down.to.line" : "arrow.up.to.line") }.accessibilityLabel(pane.remote ? "Herunterladen" : "Hochladen").help(pane.remote ? "Auswahl herunterladen" : "Auswahl hochladen").disabled(pane.selected.isEmpty)
                Menu {
                    Button("Neuer Ordner…") { action = .folder }
                    Button("Neue Datei…") { action = .file }
                    Toggle("Versteckte Dateien", isOn: $pane.showHidden)
                    Picker("Sortieren", selection: $pane.sort) { ForEach(PaneModel.SortField.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Aufsteigend", isOn: $pane.ascending)
                } label: {
                    Image(systemName: "ellipsis.circle").padding(.trailing, 8)
                }.menuStyle(.borderlessButton).frame(width: 40)
            }.padding(12).background(.bar)
            HStack(spacing: 8) {
                Button { pane.back() } label: { Image(systemName: "chevron.left") }.disabled(pane.history.back.isEmpty)
                Button { pane.forward() } label: { Image(systemName: "chevron.right") }.disabled(pane.history.forward.isEmpty)
                Button { pane.up() } label: { Image(systemName: "arrow.up") }
                TextField("Pfad", text: $pane.pathInput).textFieldStyle(.roundedBorder).onSubmit { pane.navigate(pane.pathInput) }.accessibilityLabel(pane.remote ? "Remote-Pfad" : "Lokaler Pfad")
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("/") { pane.navigate("/") }.onDrop(of: [UTType.utf8PlainText, UTType.fileURL], isTargeted: nil) { acceptDrop($0, directory: "/") }
                    let components = pane.path.split(separator: "/")
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(String(component)) { pane.navigate("/" + components.prefix(index + 1).joined(separator: "/")) }.onDrop(of: [UTType.utf8PlainText, UTType.fileURL], isTargeted: nil) { acceptDrop($0, directory: "/" + components.prefix(index + 1).joined(separator: "/")) }
                    }
                }.buttonStyle(.plain).font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            }
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Dateien filtern", text: $pane.filter).textFieldStyle(.plain) }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            FileOutlineView(pane: pane, workspace: workspace, tabID: tabID,
                            open: open, action: { action = $0 }, delete: { deleteAlert = true })
            if let error = pane.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Erneut versuchen") { pane.refresh() }
                }.padding(10).background(Color.orange.opacity(0.08))
            }
            HStack { Text("\(pane.visible.count) Objekte"); Spacer(); Text("\(pane.selection.count) ausgewählt") }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .onTapGesture { workspace.activeRemote = pane.remote }
        .onReceive(NotificationCenter.default.publisher(for: .paneCommand)) { notification in
            guard workspace.activePane?.id == pane.id else { return }
            switch notification.object as? String {
            case "folder": action = .folder
            case "rename": if pane.selected.count == 1 { action = .rename }
            case "delete": if !pane.selected.isEmpty { deleteAlert = true }
            default: break
            }
        }
        .sheet(item: $action) { action in
            InputSheet(title: action.rawValue, label: inputLabel(action), initial: action == .rename ? pane.selected.first?.name ?? "" : "") { value in
                switch action {
                case .folder: pane.create(name: value, directory: true)
                case .file: pane.create(name: value, directory: false)
                case .rename: if let entry = pane.selected.first { pane.rename(entry, name: value) }
                case .move: pane.move(pane.selected, to: value)
                case .chmod: pane.chmod(value)
                }
            }
        }
        .sheet(item: $edit) { session in RemoteEditView(session: session) { pane.refresh() } }
        .alert(pane.remote ? "Auswahl endgültig löschen?" : "Auswahl in den Papierkorb verschieben?", isPresented: $deleteAlert) {
            Button("Abbrechen", role: .cancel) {}
            Button("\(pane.selected.count) Objekte löschen", role: .destructive) { pane.deleteSelection() }
        } message: { Text(pane.remote ? "Ordner und ihr gesamter Inhalt werden unwiderruflich entfernt." : "Die Dateien werden in den macOS-Papierkorb verschoben.") }
    }
    private func acceptDrop(_ providers: [NSItemProvider], directory: String) -> Bool {
        guard !pane.busy else { return false }
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), pane.remote, let profile = pane.profile {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let entry = try? LocalFiles.entry(url) else { return }
                    Task { @MainActor in workspace.queue.enqueue([entry], profile: profile, destination: directory, upload: true) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let value = value as? NSString else { return }
                    let text = value as String
                    Task { @MainActor in _ = workspace.drop([text], to: pane, directory: directory) }
                }
            }
        }
        return accepted
    }
    private func inputLabel(_ action: FileAction) -> String { action == .chmod ? "Oktale Rechte, z. B. 644" : action == .move ? "Absoluter Zielordner" : "Name" }
    private func open(_ entry: FileEntry) {
        if entry.isDirectory { pane.navigate(entry.path) }
        else if entry.isSymlink { pane.error = "Symbolische Links bitte über einen expliziten Verzeichnispfad öffnen." }
        else if let profile = pane.profile { edit = RemoteEdit(profile: profile, entry: entry) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
    }

}

struct InputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let label: String
    @State private var value: String
    let submit: (String) -> Void
    init(title: String, label: String, initial: String = "", submit: @escaping (String) -> Void) { self.title = title; self.label = label; _value = State(initialValue: initial); self.submit = submit }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            TextField(label, text: $value).textFieldStyle(.roundedBorder).onSubmit { save() }
            HStack { Spacer(); Button("Abbrechen", role: .cancel) { dismiss() }; Button("Bestätigen") { save() }.keyboardShortcut(.defaultAction).disabled(value.isEmpty) }
        }.padding(24).frame(width: 420)
    }
    private func save() { guard !value.isEmpty else { return }; submit(value); dismiss() }
}

struct QueueView: View {
    @ObservedObject var queue: TransferQueue
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Picker("Konflikte", selection: $queue.policy) { ForEach(ConflictPolicy.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 230)
                Stepper("Parallel: \(queue.limit)", value: $queue.limit, in: 1...8).frame(width: 140)
                Spacer()
                Button("Aufräumen") { queue.clearFinished() }
            }.padding(10)
            if queue.policy == .resume { Text("Fortsetzen nur bei identischem Datei-Präfix verwenden; SFTP prüft vorhandene Teilinhalte nicht.").font(.caption).foregroundStyle(.orange) }
            if queue.jobs.isEmpty { Text("Keine Transfers in der Warteschlange").foregroundStyle(.secondary).frame(maxHeight: .infinity) }
            else { ScrollView { LazyVStack(spacing: 0) { ForEach(queue.jobs) { job in TransferRow(job: job, queue: queue) } } } }
        }.background(.background)
    }
}
struct TransferRow: View {
    @ObservedObject var job: TransferJob
    @ObservedObject var queue: TransferQueue
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(job.source.name).lineLimit(1); Text(job.profile.title).font(.caption).foregroundStyle(.secondary); Spacer(); Text(job.state.rawValue).font(.caption) }
                ProgressView(value: Double(min(job.transferred, job.total)), total: Double(max(1, job.total)))
                if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                else { Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: job.transferred), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: job.total), countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(job.speed), countStyle: .file))/s · Rest \(job.eta)").font(.caption2).foregroundStyle(.secondary) }
            }
            if !job.terminal {
                Button { queue.pause(job) } label: { Image(systemName: job.state == .paused ? "play.fill" : "pause.fill") }.buttonStyle(.borderless)
                Button { queue.cancel(job) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            } else if job.state == .failed || job.state == .cancelled {
                Button("Fortsetzen") { queue.retry(job, resume: true) }.buttonStyle(.borderless).help("Nur verwenden, wenn die Quelldatei seit dem Abbruch unverändert ist").disabled(!queue.canRetry(job))
                Button("Erneut") { queue.retry(job) }.buttonStyle(.borderless).disabled(!queue.canRetry(job))
            }
        }.padding(.horizontal, 12).padding(.vertical, 7)
    }
}
struct StatusBar: View {
    @ObservedObject var tab: ConnectionTab
    @ObservedObject var queue: TransferQueue
    @ObservedObject var remote: PaneModel
    init(tab: ConnectionTab, queue: TransferQueue) { self.tab = tab; self.queue = queue; remote = tab.remote }
    var body: some View {
        HStack {
            Circle().fill(remote.busy ? .orange : remote.error == nil && !remote.entries.isEmpty ? .green : .secondary).frame(width: 6, height: 6)
            Text(remote.busy ? "Verbinde / lade Verzeichnis…" : remote.error == nil ? "\(tab.profile.host) · SSH / SFTP" : "Verbindung prüfen")
            Spacer(); Text("\(queue.jobs.filter { !$0.terminal }.count) Transfers offen")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
    }
}
