import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FilePane: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var workspace: Workspace
    let tabID: UUID
    @State private var action: FileAction?
    @State private var deleteAlert = false
        enum FileAction: String, Identifiable { case folder = "New Folder", file = "New File", rename = "Rename", move = "Move", chmod = "Permissions"; var id: String { rawValue } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(pane.remote ? "Remote" : "Local", systemImage: pane.remote ? "server.rack" : "laptopcomputer").font(.headline)
                Spacer()
                if pane.busy { ProgressView().controlSize(.small); if pane.cancellable { Button { pane.cancel() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Cancel Operation") } }
                Button { workspace.transfer(from: pane) } label: { Image(systemName: pane.remote ? "arrow.down.to.line" : "arrow.up.to.line") }.accessibilityLabel(pane.remote ? "Download" : "Upload").help(pane.remote ? "Download Selection" : "Upload Selection").disabled(!workspace.canTransfer(pane.selected))
                Menu {
                    Button("New Folder…") { action = .folder }.disabled(!pane.supportsMutations)
                    Button("New File…") { action = .file }.disabled(!pane.supportsMutations)
                    Toggle("Show Hidden Files", isOn: $pane.showHidden)
                    Picker("Sort By", selection: $pane.sort) { ForEach(PaneModel.SortField.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Ascending", isOn: $pane.ascending)
                } label: {
                    Image(systemName: "ellipsis.circle").padding(.trailing, 8)
                }.menuStyle(.borderlessButton).frame(width: 40)
            }.padding(12).background(.bar)
            HStack(spacing: 8) {
                Button { pane.back() } label: { Image(systemName: "chevron.left") }.disabled(pane.history.back.isEmpty)
                Button { pane.forward() } label: { Image(systemName: "chevron.right") }.disabled(pane.history.forward.isEmpty)
                Button { pane.up() } label: { Image(systemName: "arrow.up") }
                TextField("Path", text: $pane.pathInput).textFieldStyle(.roundedBorder).onSubmit { pane.navigate(pane.pathInput) }.accessibilityLabel(pane.remote ? "Remote Path" : "Local Path")
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
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Filter files", text: $pane.filter).textFieldStyle(.plain) }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            if pane.profile?.transport == .ftp {
                Text("FTP · Unencrypted · File transfers").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            FileOutlineView(pane: pane, workspace: workspace, tabID: tabID,
                            open: open, openWith: { entry, app in open(entry, application: app) }, action: { action = $0 }, delete: { deleteAlert = true })
            if let message = pane.operationMessage {
                HStack(alignment: .top) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text(message).font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4))
            }
            if let error = pane.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { pane.refresh() }
                }.padding(10).background(Color.orange.opacity(0.08))
            }
            HStack { Text("\(pane.visible.count) items"); Spacer(); Text("\(pane.selection.count) selected") }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .onTapGesture { workspace.activeRemote = pane.remote }
        .onReceive(NotificationCenter.default.publisher(for: .paneCommand)) { notification in
            guard workspace.activePane?.id == pane.id, pane.supportsMutations else { return }
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
        .alert(pane.remote ? "Permanently delete the selection?" : "Move the selection to Trash?", isPresented: $deleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(pane.selected.count) items", role: .destructive) { pane.deleteSelection() }
        } message: { Text(pane.remote ? "Folders and all their contents will be permanently deleted." : "The files will be moved to the macOS Trash.") }
    }
    private func acceptDrop(_ providers: [NSItemProvider], directory: String) -> Bool {
        guard !pane.busy, !pane.remote || workspace.supportsTransfers else { return false }
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), pane.remote, let profile = pane.profile {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let entry = try? LocalFiles.entry(url) else { return }
                    Task { @MainActor in
                        guard workspace.canTransfer([entry]) else { pane.error = ServerProtocol.ftpLimitationsNotice; return }
                        workspace.queue.enqueue([entry], profile: profile, destination: directory, upload: true)
                    }
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
    private func inputLabel(_ action: FileAction) -> String { action == .chmod ? "Octal permissions, e.g. 644" : action == .move ? "Absolute destination folder" : "Name" }
    private func open(_ entry: FileEntry) { open(entry, application: nil) }
    private func open(_ entry: FileEntry, application: URL?) {
        if entry.isDirectory { pane.navigate(entry.path) }
        else if entry.isSymlink { pane.error = "Open symbolic links using an explicit destination path." }
        else if !entry.isRegular { pane.error = "Only regular files can be opened in an application." }
        else if let profile = pane.profile, !profile.transport.supportsRemoteEditing { pane.error = ServerProtocol.ftpLimitationsNotice }
        else if let profile = pane.profile { workspace.edits.open(profile: profile, entry: entry, application: application) }
        else {
            Task { do { try await EditorApplications.open(URL(fileURLWithPath: entry.path), application: application) } catch { pane.error = error.localizedDescription } }
        }
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
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }; Button("Confirm") { save() }.keyboardShortcut(.defaultAction).disabled(value.isEmpty) }
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
                Picker("Conflicts", selection: $queue.policy) { ForEach(ConflictPolicy.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 230)
                Stepper("Concurrent: \(queue.limit)", value: $queue.limit, in: 1...8).frame(width: 140)
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
            }.padding(10)
            if queue.policy == .resume { Text("Resume only when the existing file prefix is identical. Existing partial contents are not compared.").font(.caption).foregroundStyle(.orange) }
            if queue.jobs.isEmpty { Text("No transfers in the queue").foregroundStyle(.secondary).frame(maxHeight: .infinity) }
            else { ScrollView { LazyVStack(spacing: 0) { ForEach(queue.jobs) { job in TransferRow(job: job, queue: queue) } } } }
        }.background(.background)
    }
}
struct TransferRow: View {
    @ObservedObject var job: TransferJob
    @ObservedObject var queue: TransferQueue
    @State private var showWarnings = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(job.source.name).lineLimit(1); Text(job.profile.title).font(.caption).foregroundStyle(.secondary); Spacer(); Text(job.statusText).font(.caption).foregroundStyle(job.state == .completed && !job.warnings.isEmpty ? Color.orange : Color.secondary) }
                ProgressView(value: job.state == .completed ? 1 : Double(min(job.transferred, job.total)) / Double(max(1, job.total)), total: 1)
                Text(job.fileProgressText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if !job.warnings.isEmpty {
                    Button { showWarnings = true } label: {
                        Label("\(job.warnings.count) items skipped – Details", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showWarnings) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Skipped Items").font(.headline)
                            Text("Links and special files are skipped. All other files will continue to transfer.").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(job.warnings) { warning in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(warning.reason.rawValue).font(.caption).foregroundStyle(.orange)
                                            Text(warning.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 280)
                        }.padding(16).frame(width: 500)
                    }
                }
                if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                else { Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: job.transferred), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: job.total), countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(job.speed), countStyle: .file))/s · Remaining \(job.eta)").font(.caption2).foregroundStyle(.secondary) }
            }
            if !job.terminal {
                Button { queue.pause(job) } label: { Image(systemName: job.state == .paused ? "play.fill" : "pause.fill") }.buttonStyle(.borderless)
                Button { queue.cancel(job) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            } else if job.state == .failed || job.state == .cancelled {
                Button("Resume") { queue.retry(job, resume: true) }.buttonStyle(.borderless).help("Use only if the source file has not changed since the transfer was interrupted").disabled(!queue.canRetry(job))
                Button("Retry") { queue.retry(job) }.buttonStyle(.borderless).disabled(!queue.canRetry(job))
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
            Text(remote.busy ? "Connecting / loading directory…" : remote.error == nil ? "\(tab.profile.host) · \(tab.profile.transport == .sftp ? "SSH / SFTP" : "FTP · Unencrypted · File transfers")" : "Check Connection")
            Spacer(); Text("\(queue.jobs.filter { !$0.terminal }.count) transfers pending")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
    }
}
