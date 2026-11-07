import SwiftUI
import AppKit

@MainActor final class ConnectionTab: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ServerProfile
    let local = PaneModel()
    let remote: PaneModel
    init(profile: ServerProfile) { self.profile = profile; remote = PaneModel(profile: profile) }
}

struct DragPayload: Codable, Sendable {
    let tab: UUID
    let remote: Bool
    let entries: [FileEntryPayload]
    struct FileEntryPayload: Codable, Sendable { let path: String }
    var text: String { "basedftp:" + ((try? JSONEncoder().encode(self).base64EncodedString()) ?? "") }
    static func parse(_ text: String) -> Self? {
        guard text.hasPrefix("basedftp:"), let data = Data(base64Encoded: String(text.dropFirst(9))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Coalesce the activations produced by a double click into one connection.
struct BookmarkActivationGate {
    private var previous: (profile: UUID, time: TimeInterval)?
    mutating func shouldOpen(_ profile: UUID, at time: TimeInterval, doubleClickInterval: TimeInterval) -> Bool {
        defer { previous = (profile, time) }
        guard let previous, previous.profile == profile else { return true }
        let elapsed = time - previous.time
        return elapsed < 0 || elapsed > doubleClickInterval
    }
}

@MainActor final class Workspace: ObservableObject {
    @Published var tabs: [ConnectionTab] = []
    @Published var selected: UUID?
    @Published var activeRemote = false
    @Published var showTransfers = true
    let queue = TransferQueue()
    var tab: ConnectionTab? { tabs.first { $0.id == selected } }
    var activePane: PaneModel? { activeRemote ? tab?.remote : tab?.local }
    init() {
        queue.onComplete = { [weak self] in
            guard let self else { return }
            for tab in self.tabs { if !tab.local.busy { tab.local.refresh() }; if !tab.remote.busy { tab.remote.refresh() } }
        }
    }
    func connect(_ profile: ServerProfile) {
        let tab = ConnectionTab(profile: profile); tabs.append(tab); selected = tab.id
        tab.local.refresh(); tab.remote.refresh()
    }
    func close(_ tab: ConnectionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.remote.cancel(); tab.local.cancel(); tabs.remove(at: index)
        if selected == tab.id { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }
    func closeSelectedTab() { if let tab { close(tab) } }
    func transfer(from pane: PaneModel, entries: [FileEntry]? = nil) {
        guard let tab else { return }
        queue.enqueue(entries ?? pane.selected, profile: tab.profile, destination: pane.remote ? tab.local.path : tab.remote.path, upload: !pane.remote)
    }
    func drop(_ strings: [String], to pane: PaneModel, directory: String? = nil) -> Bool {
        guard let tab else { return false }
        let destination = directory ?? pane.path
        var accepted = false
        var selections: [Bool: Set<String>] = [:]
        var external: [String: FileEntry] = [:]
        for text in strings {
            if let payload = DragPayload.parse(text), payload.tab == tab.id {
                selections[payload.remote, default: []].formUnion(payload.entries.map(\.path))
            } else if pane.remote, let url = URL(string: text), url.isFileURL, let entry = try? LocalFiles.entry(url) {
                external[entry.path] = entry
            }
        }
        for (remote, paths) in selections {
            let sourcePane = remote ? tab.remote : tab.local
            let entries = PaneModel.topLevelSelection(sourcePane.allEntries.filter { paths.contains($0.path) })
            guard !entries.isEmpty else { continue }
            if remote == pane.remote { pane.move(entries, to: destination) }
            else { queue.enqueue(entries, profile: tab.profile, destination: destination, upload: pane.remote) }
            accepted = true
        }
        if !external.isEmpty {
            queue.enqueue(Array(external.values), profile: tab.profile, destination: destination, upload: true)
            accepted = true
        }
        return accepted
    }
}

struct RootView: View {
    @StateObject private var profiles = ProfileStore()
    @StateObject private var workspace = Workspace()
    @State private var editing: ServerProfile?
    @State private var bookmarkGate = BookmarkActivationGate()
    var body: some View {
        NavigationSplitView {
            List {
                Section("Zuletzt verwendet") {
                    ForEach(profiles.profiles.filter { $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! }.prefix(4)) { profile in
                        Button { connectBookmark(profile) } label: { Label(profile.title, systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { connectBookmark(profile) })
                    }
                }
                Section("Server") {
                    ForEach(profiles.profiles.sorted { ($0.favorite ? 0 : 1, $0.title) < ($1.favorite ? 0 : 1, $1.title) }) { profile in
                        Button { connectBookmark(profile) } label: {
                            HStack { Image(systemName: profile.favorite ? "star.fill" : "server.rack").foregroundStyle(profile.favorite ? .yellow : .secondary); VStack(alignment: .leading) { Text(profile.title); Text(profile.host).font(.caption).foregroundStyle(.secondary) } }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { connectBookmark(profile) })
                        .contextMenu {
                            Button("Verbinden") { connect(profile) }
                            Button("Bearbeiten…") { editing = profile }
                            Button(profile.favorite ? "Favorit entfernen" : "Als Favorit markieren") { var p = profile; p.favorite.toggle(); profiles.save(p) }
                            Button("Profil löschen", role: .destructive) { profiles.remove(profile) }
                        }
                    }
                }
                Section {
                    Button("Server hinzufügen", systemImage: "plus") { editing = ServerProfile() }
                    Button("SSH-Hosts importieren", systemImage: "square.and.arrow.down") { profiles.importSSHHosts() }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.tabs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 3) {
                            ForEach(workspace.tabs) { tab in
                                HStack(spacing: 8) {
                                    Button { workspace.selected = tab.id } label: { Label(tab.profile.title, systemImage: "network") }.buttonStyle(.plain)
                                    Button { workspace.close(tab) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                                }.padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(workspace.selected == tab.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }.padding(6)
                    }.background(.bar)
                    Divider()
                }
                if let tab = workspace.tab {
                    HSplitView {
                        FilePane(pane: tab.local, workspace: workspace, tabID: tab.id).frame(minWidth: 310)
                        FilePane(pane: tab.remote, workspace: workspace, tabID: tab.id).frame(minWidth: 310)
                    }.id(tab.id)
                    if workspace.showTransfers { Divider(); QueueView(queue: workspace.queue).frame(minHeight: 130, idealHeight: 180, maxHeight: 220) }
                    StatusBar(tab: tab, queue: workspace.queue)
                } else {
                    ContentUnavailableView {
                        Label("Deine Dateien. Überall.", systemImage: "externaldrive.connected.to.line.below")
                    } description: { Text("Wähle einen Server oder füge eine SSH-Verbindung hinzu.") } actions: {
                        Button("Server hinzufügen…") { editing = ServerProfile() }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .toolbar {
            ToolbarItemGroup {
                Button { editing = ServerProfile() } label: { Label("Neue Verbindung", systemImage: "plus") }.keyboardShortcut("n")
                Button { workspace.activePane?.refresh() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }.keyboardShortcut("r").disabled(workspace.tab == nil)
                Button { if let pane = workspace.activePane { workspace.transfer(from: pane) } } label: { Label("Übertragen", systemImage: "arrow.left.arrow.right") }.keyboardShortcut("t").disabled(workspace.activePane?.selected.isEmpty ?? true)
                Button { workspace.showTransfers.toggle() } label: { Label("Transfers", systemImage: "list.bullet.rectangle") }
            }
        }
        .sheet(item: $editing) { profile in ProfileEditor(profile: profile, store: profiles) { profile, remember in if remember { connect(profile) } else { workspace.connect(profile) } } }
        .alert("Profile konnten nicht gespeichert werden", isPresented: Binding(get: { profiles.persistenceError != nil }, set: { if !$0 { profiles.persistenceError = nil } })) { Button("OK") { profiles.persistenceError = nil } } message: { Text(profiles.persistenceError ?? "") }
        .focusedSceneValue(\.workspace, workspace)
    }
    private func connectBookmark(_ profile: ServerProfile) {
        guard bookmarkGate.shouldOpen(profile.id, at: ProcessInfo.processInfo.systemUptime, doubleClickInterval: NSEvent.doubleClickInterval) else { return }
        connect(profile)
    }
    private func connect(_ profile: ServerProfile) { var p = profile; p.lastUsed = Date(); profiles.save(p); workspace.connect(p) }
}

private struct WorkspaceKey: FocusedValueKey { typealias Value = Workspace }
extension FocusedValues { var workspace: Workspace? { get { self[WorkspaceKey.self] } set { self[WorkspaceKey.self] = newValue } } }

struct AppCommands: Commands {
    @FocusedValue(\.workspace) var workspace
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Tab schließen") { workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(workspace?.tab == nil)
            Button("Fenster schließen") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Dateien") {
            Button("Übertragen") { if let w = workspace, let p = w.activePane { w.transfer(from: p) } }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [])
            Button("Neuer Ordner…") { NotificationCenter.default.post(name: .paneCommand, object: "folder") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Umbenennen…") { NotificationCenter.default.post(name: .paneCommand, object: "rename") }.keyboardShortcut("\r", modifiers: .command)
            Button("Löschen…") { NotificationCenter.default.post(name: .paneCommand, object: "delete") }.keyboardShortcut(.delete, modifiers: .command)
            Button("Übergeordnetes Verzeichnis") { workspace?.activePane?.up() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Zurück") { workspace?.activePane?.back() }.keyboardShortcut("[", modifiers: .command)
            Button("Vorwärts") { workspace?.activePane?.forward() }.keyboardShortcut("]", modifiers: .command)
            Button("Versteckte Dateien") { workspace?.activePane?.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name { static let paneCommand = Notification.Name("BasedFTP.paneCommand") }
