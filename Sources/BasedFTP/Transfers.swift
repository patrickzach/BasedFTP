import Foundation
import Darwin

enum TransferDuration {
    static func formatted(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max - 1) else { return "—" }
        let value = Int(seconds.rounded(.up))
        let units = [(value / 86400, "day", "days"), (value / 3600 % 24, "hour", "hours"),
                     (value / 60 % 60, "minute", "minutes"), (value % 60, "second", "seconds")]
        var parts = units.filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        guard let last = parts.popLast() else { return "0 seconds" }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }
}

struct TransferFileProgress: Equatable, Sendable {
    var transferred = 0
    var total = 0
    var skipped = 0
    var remaining: Int { max(0, total - transferred - skipped) }
    var text: String {
        let files = total == 1 ? "file" : "files"
        let skippedText = skipped > 0 ? " · \(skipped) skipped" : ""
        return "\(transferred) of \(total) \(files) transferred\(skippedText) · \(remaining) remaining"
    }
}

private struct TransferSize {
    var bytes: UInt64 = 0
    var files = 0
}

struct TransferWarning: Identifiable, Hashable, Sendable {
    enum Reason: String, Sendable { case symlink = "Symbolic Link", specialFile = "Special File" }
    let path: String
    let reason: Reason
    var id: String { path }
}

final class TransferCheckpoint: @unchecked Sendable {
    struct Record { let destination: String; let partial: String?; let completed: Bool; let skipped: Bool }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    func get(_ source: String) -> Record? { lock.lock(); defer { lock.unlock() }; return records[source] }
    func save(_ source: String, destination: String, partial: String? = nil, completed: Bool = false, skipped: Bool = false) {
        lock.lock(); defer { lock.unlock() }; records[source] = Record(destination: destination, partial: partial, completed: completed, skipped: skipped)
    }
}

@MainActor final class TransferJob: ObservableObject, Identifiable {
    enum State: String { case waiting = "Waiting", running = "Transferring", paused = "Paused", completed = "Completed", failed = "Error", cancelled = "Cancelled" }
    let id = UUID()
    let profile: ServerProfile
    let source: FileEntry
    let destination: String
    let upload: Bool
    let policy: ConflictPolicy
    let control = OperationControl()
    let checkpoint: TransferCheckpoint
    let resumeCheckpoint: Bool
    let initialPolicy: ConflictPolicy
    @Published var state = State.waiting
    @Published var transferred: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published private(set) var fileProgress: TransferFileProgress?
    func updateFileProgress(_ progress: TransferFileProgress) {
        if let current = fileProgress, progress.transferred + progress.skipped < current.transferred + current.skipped { return }
        fileProgress = progress
    }
    var fileProgressText: String {
        if let fileProgress { return fileProgress.text }
        switch state {
        case .running: return "Counting files…"
        case .waiting: return "Files will be counted when the transfer starts"
        default: return "File count not available yet"
        }
    }
    @Published var error: String?
    @Published var warnings: [TransferWarning] = []
    var statusText: String { state == .completed && !warnings.isEmpty ? "Completed with Warnings" : state.rawValue }
    func addWarning(_ warning: TransferWarning) { if !warnings.contains(where: { $0.id == warning.id }) { warnings.append(warning) } }
    @Published var started: Date?
    var terminal: Bool { [.completed, .failed, .cancelled].contains(state) }
    var speed: Double { guard let started else { return 0 }; return Double(transferred) / max(1, Date().timeIntervalSince(started)) }
    var eta: String {
        if state == .completed { return TransferDuration.formatted(0) }
        guard state == .running, speed > 0, total >= transferred else { return "—" }
        return TransferDuration.formatted(Double(total - transferred) / speed)
    }
    init(profile: ServerProfile, source: FileEntry, destination: String, upload: Bool, policy: ConflictPolicy, checkpoint: TransferCheckpoint = TransferCheckpoint(), resumeCheckpoint: Bool = false, initialPolicy: ConflictPolicy? = nil) {
        self.initialPolicy = initialPolicy ?? policy
        self.resumeCheckpoint = resumeCheckpoint
        self.checkpoint = checkpoint
        self.profile = profile; self.source = source; self.destination = destination; self.upload = upload; self.policy = policy
    }
}

@MainActor final class TransferQueue: ObservableObject {
    @Published var jobs: [TransferJob] = []
    @Published var limit = 2 { didSet { pump() } }
    @Published var policy = ConflictPolicy.rename
    @Published private(set) var revision = 0
    private var active: Set<UUID> = []
    var onComplete: (() -> Void)?
    func enqueue(_ entries: [FileEntry], profile: ServerProfile, destination: String, upload: Bool) {
        for entry in entries { jobs.append(TransferJob(profile: profile, source: entry, destination: FileEntry.join(destination, entry.name), upload: upload, policy: policy)) }
        pump()
    }
    func cancel(_ job: TransferJob) { job.control.cancel(); job.state = .cancelled; revision += 1; pump() }
    func pause(_ job: TransferJob) {
        if job.state == .running { job.control.setPaused(true); job.state = .paused }
        else if job.state == .waiting { job.state = .paused }
        else if job.state == .paused {
            if active.contains(job.id) { job.control.setPaused(false); job.state = .running } else { job.state = .waiting; pump() }
        }
        revision += 1
    }
    func canRetry(_ job: TransferJob) -> Bool { job.terminal && !active.contains(job.id) }
    func retry(_ job: TransferJob, resume: Bool = false) {
        guard canRetry(job) else { return }
        jobs.append(TransferJob(profile: job.profile, source: job.source, destination: job.destination, upload: job.upload, policy: resume ? .resume : job.policy, checkpoint: resume ? job.checkpoint : TransferCheckpoint(), resumeCheckpoint: resume, initialPolicy: job.initialPolicy)); pump()
    }
    func clearFinished() { jobs.removeAll { $0.terminal && !active.contains($0.id) } }
    private func pump() {
        while active.count < max(1, min(limit, 8)), let job = jobs.first(where: { $0.state == .waiting && !active.contains($0.id) }) {
            active.insert(job.id); job.state = .running; job.started = Date()
            let profile = job.profile; let source = job.source; let destination = job.destination; let upload = job.upload; let policy = job.policy; let control = job.control; let checkpoint = job.checkpoint; let resumeCheckpoint = job.resumeCheckpoint; let initialPolicy = job.initialPolicy
            Task {
                do {
                    let result = try await Task.detached(priority: .utility) {
                        let client = try SFTPClient(profile: profile, control: control); defer { client.close() }
                        let engine = TransferEngine(client: client, upload: upload, policy: policy, checkpoint: checkpoint, resumeCheckpoint: resumeCheckpoint, retryPolicy: initialPolicy)
                        try engine.run(source: source, destination: destination, warning: { warning in
                            Task { @MainActor in job.addWarning(warning) }
                        }, files: { progress in
                            Task { @MainActor in job.updateFileProgress(progress) }
                        }) { done, total in
                            Task { @MainActor in job.transferred = done; job.total = total }
                        }
                        return (warnings: engine.warnings, files: engine.fileProgress)
                    }.value
                    job.warnings = result.warnings
                    job.updateFileProgress(result.files)
                    if job.state != .cancelled { job.state = .completed }
                } catch {
                    if job.state != .cancelled { job.state = .failed; job.error = error.localizedDescription }
                }
                active.remove(job.id); revision += 1; onComplete?(); pump()
            }
        }
    }
}

final class TransferEngine {
    let client: SFTPClient
    let upload: Bool
    let policy: ConflictPolicy
    let checkpoint: TransferCheckpoint
    let resumeCheckpoint: Bool
    let retryPolicy: ConflictPolicy
    private var done: UInt64 = 0
    private var total: UInt64 = 0
    private var lastUpdate = Date.distantPast
    private(set) var fileProgress = TransferFileProgress()
    private var reportFiles: (TransferFileProgress) -> Void = { _ in }
    private(set) var warnings: [TransferWarning] = []
    private var warnedPaths: Set<String> = []
    private var reportWarning: (TransferWarning) -> Void = { _ in }
    private func skipUnsupported(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory && !entry.isRegular else { return false }
        if warnedPaths.insert(entry.path).inserted {
            let warning = TransferWarning(path: entry.path, reason: entry.isSymlink ? .symlink : .specialFile)
            warnings.append(warning); reportWarning(warning)
        }
        return true
    }
    init(client: SFTPClient, upload: Bool, policy: ConflictPolicy, checkpoint: TransferCheckpoint = TransferCheckpoint(), resumeCheckpoint: Bool = false, retryPolicy: ConflictPolicy = .rename) { self.retryPolicy = retryPolicy; self.client = client; self.upload = upload; self.policy = policy; self.checkpoint = checkpoint; self.resumeCheckpoint = resumeCheckpoint }
    private func children(_ entry: FileEntry) throws -> [FileEntry] { upload ? try LocalFiles.list(entry.path) : try client.list(entry.path) }
    private func measure(_ entry: FileEntry) throws -> TransferSize {
        guard !skipUnsupported(entry) else { return TransferSize() }
        if entry.isDirectory {
            return try children(entry).reduce(TransferSize()) { sum, child in
                let next = try measure(child)
                return TransferSize(bytes: sum.bytes + next.bytes, files: sum.files + next.files)
            }
        }
        return TransferSize(bytes: entry.size, files: 1)
    }
    func run(source: FileEntry, destination: String, warning: @escaping (TransferWarning) -> Void = { _ in }, files: @escaping (TransferFileProgress) -> Void = { _ in }, progress: (UInt64, UInt64) -> Void) throws {
        warnings = []; warnedPaths = []; done = 0; total = 0; reportWarning = warning
        fileProgress = TransferFileProgress(); reportFiles = files
        defer { reportWarning = { _ in }; reportFiles = { _ in } }
        let fresh = upload ? try LocalFiles.entry(URL(fileURLWithPath: source.path)) : try client.stat(source.path)
        let size = try measure(fresh); total = size.bytes; fileProgress.total = size.files
        progress(0, total); reportFiles(fileProgress)
        try transfer(fresh, destination: destination, progress: progress); progress(done, total); reportFiles(fileProgress)
    }
    private func destinationEntry(_ path: String) throws -> FileEntry? {
        if upload { do { return try client.stat(path) } catch let e as FTPError where e.isMissing { return nil } }
        do { return try LocalFiles.entry(URL(fileURLWithPath: path)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
    private func transfer(_ source: FileEntry, destination original: String, progress: (UInt64, UInt64) -> Void) throws {
        guard !skipUnsupported(source) else { return }
        let previous = policy == .resume ? checkpoint.get(source.path) : nil
        var destination = previous?.destination ?? original
        let conflict = resumeCheckpoint && previous == nil ? retryPolicy : policy
        if let previous, previous.completed, try destinationEntry(previous.destination) != nil {
            let size = try measure(source); done += size.bytes
            if previous.skipped { fileProgress.skipped += size.files } else { fileProgress.transferred += size.files }
            reportFiles(fileProgress); progress(done, total); return
        }
        if let existing = try destinationEntry(destination) {
            if existing.isSymlink { throw FTPError.message("The destination is a symbolic link: \(destination)") }
            if conflict == .skip { let size = try measure(source); done += size.bytes; fileProgress.skipped += size.files; reportFiles(fileProgress); checkpoint.save(source.path, destination: destination, completed: true, skipped: true); progress(done, total); return }
            if conflict == .rename {
                let directory = (original as NSString).deletingLastPathComponent
                let name = (original as NSString).lastPathComponent
                var index = 1
                repeat { destination = FileEntry.join(directory, "\(name) (\(index))"); index += 1 } while try destinationEntry(destination) != nil
            } else if source.isDirectory != existing.isDirectory { throw FTPError.message("File/folder conflict: \(destination)") }
        }
        if source.isDirectory {
            checkpoint.save(source.path, destination: destination)
            if try destinationEntry(destination) == nil {
                if upload { try client.mkdir(destination) }
                else { try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false) }
            }
            for child in try children(source) { try transfer(child, destination: FileEntry.join(destination, child.name), progress: progress) }
        } else {
            let base = done
            let update: (UInt64) -> Void = { value in
                self.done = base + value
                if Date().timeIntervalSince(self.lastUpdate) > 0.15 { self.lastUpdate = Date(); progress(self.done, self.total) }
            }
            if policy == .resume && (previous != nil || !resumeCheckpoint) {
                let target = previous?.partial ?? destination
                checkpoint.save(source.path, destination: destination, partial: previous?.partial)
                if upload { try client.upload(URL(fileURLWithPath: source.path), to: target, resume: true, progress: update) }
                else { try client.download(source.path, to: URL(fileURLWithPath: target), resume: true, progress: update) }
                if previous?.partial != nil {
                    if retryPolicy != .overwrite && retryPolicy != .resume, try destinationEntry(destination) != nil { throw FTPError.message("The destination has been created in the meantime. The staging file is retained; please resolve the conflict manually.") }
                    if upload { try client.chmod(target, mode: source.permissions & 0o777); try client.commitUpload(target, to: destination) }
                    else { try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: source.permissions & 0o777)], ofItemAtPath: target); guard Darwin.rename(target, destination) == 0 else { throw FTPError.message("Could not commit the resumed staging file.") } }
                }
            } else {
                let directory = (destination as NSString).deletingLastPathComponent
                let temporary = FileEntry.join(directory, "." + (destination as NSString).lastPathComponent + ".basedftp-" + UUID().uuidString + ".partial")
                checkpoint.save(source.path, destination: destination, partial: temporary)
                if upload {
                    try client.upload(URL(fileURLWithPath: source.path), to: temporary, resume: false, progress: update)
                    try client.chmod(temporary, mode: source.permissions & 0o777)
                    if conflict == .overwrite { try client.commitUpload(temporary, to: destination) }
                    else { try client.rename(temporary, destination) }
                } else {
                    let url = URL(fileURLWithPath: temporary)
                    try client.download(source.path, to: url, resume: false, progress: update)
                    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: source.permissions & 0o777)], ofItemAtPath: temporary)
                    if conflict == .overwrite {
                        guard Darwin.rename(temporary, destination) == 0 else { throw FTPError.message("Could not commit the local file: " + String(cString: strerror(errno))) }
                    } else { try FileManager.default.moveItem(atPath: temporary, toPath: destination) }
                }
            }
            done = base + source.size; fileProgress.transferred += 1; reportFiles(fileProgress); progress(done, total)
        }
        checkpoint.save(source.path, destination: destination, completed: true)
    }
}
