import SwiftUI
import AppKit
import CryptoKit
import Darwin

enum SnapshotError: Error { case unstable }
struct EditFileStamp: Equatable, Sendable {
    let inode: UInt64
    let device: Int32
    let size: Int64
    let seconds: Int
    let nanoseconds: Int
    init(_ value: stat) { inode = value.st_ino; device = value.st_dev; size = value.st_size; seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec }
    static func read(_ file: URL) throws -> EditFileStamp {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SnapshotError.unstable }
        return EditFileStamp(info)
    }
}
struct EditSnapshot: Sendable {
    let file: URL
    let hash: Data
    let stamp: EditFileStamp
    static func capture(_ source: URL, in directory: URL) throws -> EditSnapshot {
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SnapshotError.unstable }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(), after = stat(), pathInfo = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SnapshotError.unstable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(UUID().uuidString)
        let outputDescriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard outputDescriptor >= 0 else { throw FTPError.message("Could not create a working snapshot: " + String(cString: strerror(errno))) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        var complete = false
        defer { if !complete { try? output.close(); try? FileManager.default.removeItem(at: target) } }
        var hash = SHA256(); var bytes = 0
        while let data = try input.read(upToCount: 65536), !data.isEmpty { try output.write(contentsOf: data); hash.update(data: data); bytes += data.count }
        guard fstat(descriptor, &after) == 0, lstat(source.path, &pathInfo) == 0,
              before.st_ino == pathInfo.st_ino, before.st_dev == pathInfo.st_dev,
              before.st_size == after.st_size, bytes == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SnapshotError.unstable }
        try output.synchronize(); try output.close(); complete = true
        return EditSnapshot(file: target, hash: Data(hash.finalize()), stamp: EditFileStamp(after))
    }
    func discard() { try? FileManager.default.removeItem(at: file) }
}

protocol RemoteEditBackend: Sendable {
    func download(to file: URL, control: OperationControl) async throws
    func upload(_ snapshot: URL, control: OperationControl) async throws
}
struct RemoteFileEditBackend: RemoteEditBackend {
    let profile: ServerProfile
    let entry: FileEntry
    let knownHosts: URL?
    init(profile: ServerProfile, entry: FileEntry, knownHosts: URL? = nil) { self.profile = profile; self.entry = entry; self.knownHosts = knownHosts }
    func download(to file: URL, control: OperationControl) async throws {
        try await Task.detached {
            let client = try RemoteFileSystems.connect(profile: profile, control: control, knownHosts: knownHosts); defer { client.close() }
            try client.download(entry.path, to: file, resume: false) { _ in }
        }.value
    }
    func upload(_ snapshot: URL, control: OperationControl) async throws {
        try await Task.detached {
            let client = try RemoteFileSystems.connect(profile: profile, control: control, knownHosts: knownHosts); defer { client.close() }
            try client.uploadEditingSnapshot(snapshot, to: entry.path, permissions: entry.permissions)
        }.value
    }
}

@MainActor final class RemoteEdit: ObservableObject, Identifiable {
    enum State: String { case downloading = "Downloading…", watching = "Watching for Changes", uploading = "Uploading…", saved = "Saved", failed = "Error", stopped = "Stopped" }
    let id = UUID()
    let profile: ServerProfile
    let entry: FileEntry
    let directory: URL
    let file: URL
    private let backend: any RemoteEditBackend
    @Published private(set) var state = State.downloading
    @Published private(set) var ready = false
    @Published private(set) var message: String?
    private(set) var stopped = false
    private var monitor: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var downloadControl: OperationControl?
    private var uploadControl: OperationControl?
    private var lastUploaded: Data?
    private var lastObservedStamp: EditFileStamp?
    private var unreadableSamples = 0
    private var readFailed = false
    private var candidate: EditSnapshot?
    private var pending: EditSnapshot?
    private var uploadingHash: Data?
    private var sampling = false
    private var blocked = false
    private var force = false
    private var selectedApplication: URL?
    private var editorOpenFailed = false
    var onUploaded: (() -> Void)?
    var busy: Bool { downloadTask != nil || uploadTask != nil }
    init(profile: ServerProfile, entry: FileEntry, backend: (any RemoteEditBackend)? = nil, directory: URL? = nil) {
        self.profile = profile; self.entry = entry
        self.backend = backend ?? RemoteFileEditBackend(profile: profile, entry: entry)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BasedFTP/Edits")
        self.directory = directory ?? root.appendingPathComponent(UUID().uuidString)
        file = self.directory.appendingPathComponent(entry.name)
    }
    func start(application: URL? = nil, openEditor: Bool = true, monitorChanges: Bool = true) {
        guard downloadTask == nil, !ready else { return }
        stopped = false; state = .downloading; message = nil; selectedApplication = application
        let control = OperationControl(); downloadControl = control
        downloadTask = Task {
            do {
                try await Task.detached { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }.value
                try await backend.download(to: file, control: control)
                let baseline = try await snapshot(); lastUploaded = baseline.hash; lastObservedStamp = baseline.stamp; baseline.discard()
                guard !stopped else { downloadTask = nil; return }
                ready = true; state = .watching
                if monitorChanges { startMonitor() }
                if openEditor { await open(in: application) }
            } catch { if !stopped { state = .failed; message = error.localizedDescription } }
            downloadTask = nil; downloadControl = nil
        }
    }
    func open(in application: URL?) async {
        guard ready, !stopped else { return }
        selectedApplication = application
        do {
            try await EditorApplications.open(file, application: application)
            if editorOpenFailed { editorOpenFailed = false; message = nil; if uploadTask == nil { state = .watching } }
        } catch { editorOpenFailed = true; message = "Could not open the application: \(error.localizedDescription)"; state = .failed }
    }
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
                guard let self, !self.stopped else { return }
                await self.checkForChanges()
            }
        }
    }
    private func snapshot() async throws -> EditSnapshot {
        let file = file; let snapshots = directory.appendingPathComponent(".snapshots")
        return try await Task.detached(priority: .utility) { try EditSnapshot.capture(file, in: snapshots) }.value
    }
    func checkForChanges() async {
        guard ready, !stopped, !sampling else { return }; sampling = true
        defer { sampling = false }
        do {
            let file = file
            let stamp = try await Task.detached(priority: .utility) { try EditFileStamp.read(file) }.value
            if stamp == lastObservedStamp && candidate == nil && !force { return }
            let value = try await snapshot()
            lastObservedStamp = value.stamp; unreadableSamples = 0
            if readFailed {
                readFailed = false
                if blocked { state = .failed; message = "Automatic upload paused. Please try again." }
                else { message = nil; state = uploadTask == nil ? .watching : .uploading }
            }
            guard !stopped else { value.discard(); return }
            // Two identical observations debounce writes and atomic editor saves.
            guard candidate?.hash == value.hash else {
                candidate?.discard(); candidate = value
                if uploadTask == nil && !blocked && value.hash != lastUploaded { state = .watching }
                return
            }
            candidate?.discard(); candidate = nil
            if value.hash == uploadingHash || (!force && value.hash == lastUploaded && uploadingHash == nil) {
                // A revert while an older upload is running must still be queued.
                pending?.discard(); pending = nil; force = false
                value.discard(); return
            }
            force = false
            pending?.discard(); pending = value
            if !blocked { pump() }
        } catch SnapshotError.unstable {
            // Atomic saves may briefly remove the file; persistent failures are visible.
            unreadableSamples += 1
            if unreadableSamples >= 4 && !stopped {
                readFailed = true; state = .failed
                message = "The working copy cannot be read. Save it again in your editor or check the working copy."
            }
        } catch { message = "Could not read the working copy: \(error.localizedDescription)"; state = .failed }
    }
    private func pump() {
        guard !stopped, !blocked, uploadTask == nil, let value = pending else { return }
        pending = nil; uploadingHash = value.hash
        let control = OperationControl(); uploadControl = control
        state = .uploading; message = nil
        uploadTask = Task {
            do {
                try await backend.upload(value.file, control: control)
                lastUploaded = value.hash; value.discard()
                if !stopped { state = candidate.map { $0.hash != value.hash } == true ? .watching : .saved; onUploaded?() }
            } catch {
                // Keep failed snapshots and the editable working copy for recovery.
                if pending == nil { pending = value }
                if !stopped { blocked = true; state = .failed; message = "Upload not confirmed. The local working copy is retained; the server file is only replaced in full. \(error.localizedDescription)" }
            }
            uploadTask = nil; uploadingHash = nil; uploadControl = nil
            if !blocked && !stopped { pump() }
        }
    }
    func retry() {
        guard !stopped, !busy else { return }
        if !ready { start(application: selectedApplication); return }
        if editorOpenFailed { Task { await open(in: selectedApplication) }; return }
        blocked = false; force = true; message = nil; state = .watching
        pending?.discard(); pending = nil; candidate?.discard(); candidate = nil
        Task { await checkForChanges() }
    }
    func stop() {
        stopped = true; monitor?.cancel(); monitor = nil
        downloadControl?.cancel(); uploadControl?.cancel()
        state = .stopped; message = "Automatic upload stopped. The local working copy is retained."
    }
    deinit { monitor?.cancel(); downloadControl?.cancel(); uploadControl?.cancel() }
}

@MainActor final class RemoteEditManager: ObservableObject {
    @Published var sessions: [RemoteEdit] = []
    var onUploaded: ((ServerProfile, String) -> Void)?
    func stopAll() { sessions.forEach { $0.stop() } }
    func open(profile: ServerProfile, entry: FileEntry, application: URL? = nil) {
        if let session = sessions.first(where: { $0.profile.id == profile.id && $0.entry.path == entry.path && !$0.stopped }) {
            if session.ready { Task { await session.open(in: application) } } else if !session.busy { session.start(application: application) }
            return
        }
        let session = RemoteEdit(profile: profile, entry: entry)
        session.onUploaded = { [weak self] in self?.onUploaded?(profile, entry.path) }
        sessions.append(session); session.start(application: application)
    }
}

struct RemoteEditsView: View {
    @ObservedObject var manager: RemoteEditManager
    var body: some View {
        if !manager.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remote editing · Save in your editor to upload automatically").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(manager.sessions) { session in RemoteEditRow(session: session) { manager.sessions.removeAll { $0.id == session.id } } }
                    }
                }.frame(maxHeight: 130)
            }.padding(10).background(.bar)
        }
    }
}
private struct RemoteEditRow: View {
    @ObservedObject var session: RemoteEdit
    let remove: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: session.state == .failed ? "exclamationmark.triangle" : "square.and.pencil").foregroundStyle(session.state == .failed ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(session.entry.name) · \(session.profile.title) · \(session.state.rawValue)").font(.caption)
                if let message = session.message { Text(message).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            Button("Working Copy") { NSWorkspace.shared.activateFileViewerSelecting([session.file]) }.disabled(!session.ready)
            if session.state == .failed { Button("Try Again") { session.retry() } }
            if !session.stopped { Button("Stop") { session.stop() } }
            else { Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from this list; keep the working copy") }
        }
    }
}
