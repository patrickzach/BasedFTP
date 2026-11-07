import Foundation

enum LocalFiles {
    static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw FTPError.message("Could not resolve path: " + String(cString: strerror(errno))) }
        defer { free(resolved) }; return String(cString: resolved)
    }
    static func entry(_ url: URL) throws -> FileEntry {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs[.type] as? FileAttributeType
        let kind: UInt32 = type == .typeDirectory ? 0o040000 : type == .typeSymbolicLink ? 0o120000 : type == .typeRegular ? 0o100000 : 0
        return FileEntry(name: url.lastPathComponent, path: url.path, size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0, permissions: kind | ((attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0), modified: attrs[.modificationDate] as? Date ?? .distantPast)
    }
    static func list(_ path: String) throws -> [FileEntry] {
        try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil).map(entry)
    }
    static func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw FTPError.message("Invalid filename.") }
    }
}

@MainActor final class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    let remote: Bool
    let profile: ServerProfile?
    @Published var path: String
    @Published var pathInput: String
    @Published var entries: [FileEntry] = []
    @Published var selection: Set<String> = []
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published private(set) var loadingChildren: Set<String> = []
    @Published private(set) var treeErrors: [String: String] = [:]
    @Published private(set) var depths: [String: Int] = [:]
    private var childOperations: [String: OperationControl] = [:]
    @Published var busy = false
    @Published var cancellable = false
    @Published var operationMessage: String?
    @Published var error: String?
    @Published var showHidden = false
    @Published var filter = ""
    @Published var sort = SortField.name
    @Published var ascending = true
    @Published private(set) var history = NavigationHistory()
    private var generation = UUID()
    private var operation: OperationControl?
    enum SortField: String, CaseIterable { case name = "Name", size = "Size", kind = "Kind", modified = "Modified" }
    init(profile: ServerProfile? = nil) {
        self.profile = profile; remote = profile != nil
        let initial = profile?.initialPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        path = initial; pathInput = initial
    }
    var allEntries: [FileEntry] { entries + children.values.flatMap { $0 } }
    func depth(of entry: FileEntry) -> Int { depths[entry.path] ?? 0 }
    var visible: [FileEntry] {
        func flatten(_ entries: [FileEntry]) -> [FileEntry] {
            ordered(entries).flatMap { entry -> [FileEntry] in
                let nested = expanded.contains(entry.path) ? flatten(children[entry.path] ?? []) : []
                guard filter.isEmpty || entry.name.localizedCaseInsensitiveContains(filter) || !nested.isEmpty else { return [] }
                return [entry] + nested
            }
        }
        return flatten(entries)
    }
    private func ordered(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { showHidden || !$0.name.hasPrefix(".") }.sorted {
            let comparison: Bool
            switch sort {
            case .name: comparison = $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .size: comparison = $0.size == $1.size ? $0.name < $1.name : $0.size < $1.size
            case .kind: comparison = $0.kind == $1.kind ? $0.name < $1.name : $0.kind < $1.kind
            case .modified: comparison = $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified
            }
            return ascending ? comparison : reverseCompare($0, $1)
        }
    }
    func toggleExpanded(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) { expanded.remove(entry.path) }
        else { expanded.insert(entry.path); loadChildren(entry.path) }
    }
    private func loadChildren(_ directory: String) {
        guard children[directory] == nil, !loadingChildren.contains(directory) else { return }
        let token = generation; let profile = profile; let control = OperationControl()
        childOperations[directory] = control; loadingChildren.insert(directory); treeErrors[directory] = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try control.touch()
                    if let profile { let client = try RemoteFileSystems.connect(profile: profile, control: control); defer { client.close() }; return try client.list(directory) }
                    return try LocalFiles.list(directory)
                }.value
                guard generation == token else { return }
                children[directory] = result
                let level = (depths[directory] ?? 0) + 1
                depths.merge(Dictionary(result.map { ($0.path, level) }, uniquingKeysWith: { _, new in new }), uniquingKeysWith: { _, new in new })
                loadingChildren.remove(directory); childOperations[directory] = nil
                for child in result where child.isDirectory && expanded.contains(child.path) { loadChildren(child.path) }
            } catch {
                guard generation == token else { return }
                loadingChildren.remove(directory); childOperations[directory] = nil
                treeErrors[directory] = error.localizedDescription
            }
        }
    }
    private func reverseCompare(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        switch sort {
        case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        case .size: return lhs.size == rhs.size ? lhs.name > rhs.name : lhs.size > rhs.size
        case .kind: return lhs.kind == rhs.kind ? lhs.name > rhs.name : lhs.kind > rhs.kind
        case .modified: return lhs.modified == rhs.modified ? lhs.name > rhs.name : lhs.modified > rhs.modified
        }
    }
    var selected: [FileEntry] { Self.topLevelSelection(visible.filter { selection.contains($0.id) }) }
    nonisolated static func topLevelSelection(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { entry in !entries.contains { $0.isDirectory && $0.path != entry.path && entry.path.hasPrefix($0.path + "/") } }
    }
    func navigate(_ target: String, record: Bool = true) {
        operation?.cancel()
        childOperations.values.forEach { $0.cancel() }; childOperations.removeAll(); loadingChildren = []
        let token = UUID(); generation = token
        let control = OperationControl(); operation = control; busy = true; cancellable = true; error = nil; operationMessage = nil
        let profile = profile; let oldPath = path
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (String, [FileEntry]) in
                    if let profile {
                        let client = try RemoteFileSystems.connect(profile: profile, control: control); defer { client.close() }
                        let canonical = try client.realpath(target); return (canonical, try client.list(canonical))
                    }
                    let canonical = (target as NSString).expandingTildeInPath
                    let resolved = try LocalFiles.canonicalPath(canonical)
                    return (resolved, try LocalFiles.list(resolved))
                }.value
                guard generation == token else { return }
                if record { history.visit(from: oldPath, to: result.0) }
                if oldPath != result.0 { expanded = [] }
                children = [:]; treeErrors = [:]; depths = Dictionary(result.1.map { ($0.path, 0) }, uniquingKeysWith: { _, new in new })
                path = result.0; pathInput = result.0; entries = result.1; selection = []; busy = false; cancellable = false
                for entry in entries where entry.isDirectory && expanded.contains(entry.path) { loadChildren(entry.path) }
            } catch {
                guard generation == token else { return }; self.error = error.localizedDescription; busy = false; cancellable = false; pathInput = path
            }
        }
    }
    func refresh() { navigate(path, record: false) }
    func back() { if let target = history.goBack(current: path) { navigate(target, record: false) } }
    func forward() { if let target = history.goForward(current: path) { navigate(target, record: false) } }
    func up() { navigate((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) }
    func perform(_ work: @escaping @Sendable ((any RemoteFileSystem)?) throws -> Void) {
        perform(status: nil) { client, _ in try work(client) }
    }
    private func perform(status: String?, _ work: @escaping @Sendable ((any RemoteFileSystem)?, @escaping @Sendable (String) -> Void) throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; cancellable = remote; operationMessage = status
        childOperations.values.forEach { $0.cancel() }; childOperations.removeAll(); loadingChildren = []
        let control = OperationControl(); operation = control
        let token = UUID(); generation = token
        let profile = profile
        let update: @Sendable (String) -> Void = { message in
            Task { @MainActor in guard self.generation == token, self.busy else { return }; self.operationMessage = message }
        }
        Task {
            do {
                try await Task.detached {
                    try control.touch()
                    if let profile { let client = try RemoteFileSystems.connect(profile: profile, control: control); defer { client.close() }; try work(client, update) }
                    else { try work(nil, update) }
                }.value
                guard generation == token else { return }
                busy = false; cancellable = false; operationMessage = nil; refresh()
            } catch {
                guard generation == token else { return }
                let details = status != nil ? self.operationMessage.map { "\n\($0)" } ?? "" : ""
                self.error = error.localizedDescription + details
                busy = false; cancellable = false; operationMessage = nil
                // Failed batches may already have removed some children.
                children = [:]
            }
        }
    }
    func create(name: String, directory: Bool) {
        do { try LocalFiles.validName(name) } catch { self.error = error.localizedDescription; return }
        let destination = FileEntry.join(path, name)
        perform { client in
            if let client { if directory { try client.mkdir(destination) } else { try client.createFile(destination) } }
            else if directory { try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false) }
            else {
                guard !FileManager.default.fileExists(atPath: destination) else { throw FTPError.message("The file already exists.") }
                let fd = Darwin.open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else { throw FTPError.message(String(cString: strerror(errno))) }; Darwin.close(fd)
            }
        }
    }
    func rename(_ entry: FileEntry, name: String) {
        do { try LocalFiles.validName(name) } catch { self.error = error.localizedDescription; return }
        let destination = FileEntry.join((entry.path as NSString).deletingLastPathComponent, name)
        perform { client in
            if let client { guard try !client.exists(destination) else { throw FTPError.message("The destination already exists.") }; try client.rename(entry.path, destination) }
            else { try FileManager.default.moveItem(atPath: entry.path, toPath: destination) }
        }
    }
    nonisolated static func validateMove(_ entries: [FileEntry], to destination: String) throws {
        guard destination.hasPrefix("/"), !destination.contains("\0") else { throw FTPError.message("Please enter an absolute destination folder.") }
        let destination = (destination as NSString).standardizingPath
        for entry in entries {
            let source = (entry.path as NSString).standardizingPath
            guard destination != source, !entry.isDirectory || !destination.hasPrefix(source + "/") else { throw FTPError.message("A folder cannot be moved into itself or one of its subfolders.") }
            guard (source as NSString).deletingLastPathComponent != destination else { throw FTPError.message("The selection is already in this folder.") }
        }
    }
    func move(_ entries: [FileEntry], to destination: String) {
        let entries = Self.topLevelSelection(entries)
        do { try Self.validateMove(entries, to: destination) } catch { self.error = error.localizedDescription; return }
        perform { client in
            let destination = try client?.realpath(destination) ?? LocalFiles.canonicalPath(destination)
            let canonicalEntries = try entries.map { entry -> FileEntry in
                let canonical = entry.isDirectory ? (try client?.realpath(entry.path) ?? LocalFiles.canonicalPath(entry.path)) : entry.path
                return FileEntry(name: entry.name, path: canonical, size: entry.size, permissions: entry.permissions, modified: entry.modified)
            }
            try Self.validateMove(canonicalEntries, to: destination)
            // Validate every target before moving anything; never overwrite on drop.
            for entry in entries {
                let target = FileEntry.join(destination, entry.name)
                if let client { guard try !client.exists(target) else { throw FTPError.message("The destination already exists: \(target)") } }
                else { guard !FileManager.default.fileExists(atPath: target) else { throw FTPError.message("The destination already exists: \(target)") } }
            }
            for entry in entries {
                let target = FileEntry.join(destination, entry.name)
                if let client { guard try !client.exists(target) else { throw FTPError.message("The destination already exists: \(target)") }; try client.rename(entry.path, target) }
                else { try FileManager.default.moveItem(atPath: entry.path, toPath: target) }
            }
        }
    }
    func deleteSelection() {
        let entries = selected
        perform(status: remote ? "Preparing deletion…" : "Moving to Trash…") { client, update in
            if let client { try client.delete(entries) { update($0.text) } }
            else {
                for (index, entry) in entries.enumerated() {
                    update("Trash: \(entry.path) · \(index) of \(entries.count) items")
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                }
            }
        }
    }
    func chmod(_ mode: String) {
        guard let value = UInt32(mode, radix: 8), value <= 0o7777 else { error = "Enter permissions as an octal number, such as 755."; return }
        let entries = selected
        perform { client in
            for entry in entries {
                if let client { try client.chmod(entry.path, mode: value) }
                else { try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: value)], ofItemAtPath: entry.path) }
            }
        }
    }
    func cancel() {
        if let operationMessage { error = "Operation cancelled. Items already deleted cannot be restored.\n" + operationMessage }
        operationMessage = nil
        childOperations.values.forEach { $0.cancel() }; childOperations.removeAll(); loadingChildren = []; operation?.cancel(); generation = UUID(); busy = false; cancellable = false }
}

import Darwin
