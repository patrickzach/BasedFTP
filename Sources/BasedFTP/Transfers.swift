import Foundation
import Darwin

final class TransferCheckpoint: @unchecked Sendable {
    struct Record { let destination: String; let partial: String?; let completed: Bool }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    func get(_ source: String) -> Record? { lock.lock(); defer { lock.unlock() }; return records[source] }
    func save(_ source: String, destination: String, partial: String? = nil, completed: Bool = false) {
        lock.lock(); defer { lock.unlock() }; records[source] = Record(destination: destination, partial: partial, completed: completed)
    }
}

@MainActor final class TransferJob: ObservableObject, Identifiable {
    enum State: String { case waiting = "Wartet", running = "Überträgt", paused = "Pausiert", completed = "Fertig", failed = "Fehler", cancelled = "Abgebrochen" }
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
    @Published var error: String?
    @Published var started: Date?
    var terminal: Bool { [.completed, .failed, .cancelled].contains(state) }
    var speed: Double { guard let started else { return 0 }; return Double(transferred) / max(1, Date().timeIntervalSince(started)) }
    var eta: String { guard speed > 0, total >= transferred else { return "—" }; return "\(Int(Double(total - transferred) / speed)) s" }
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
                    try await Task.detached(priority: .utility) {
                        let client = try SFTPClient(profile: profile, control: control); defer { client.close() }
                        let engine = TransferEngine(client: client, upload: upload, policy: policy, checkpoint: checkpoint, resumeCheckpoint: resumeCheckpoint, retryPolicy: initialPolicy)
                        try engine.run(source: source, destination: destination) { done, total in
                            Task { @MainActor in job.transferred = done; job.total = total }
                        }
                    }.value
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
    init(client: SFTPClient, upload: Bool, policy: ConflictPolicy, checkpoint: TransferCheckpoint = TransferCheckpoint(), resumeCheckpoint: Bool = false, retryPolicy: ConflictPolicy = .rename) { self.retryPolicy = retryPolicy; self.client = client; self.upload = upload; self.policy = policy; self.checkpoint = checkpoint; self.resumeCheckpoint = resumeCheckpoint }
    private func children(_ entry: FileEntry) throws -> [FileEntry] { upload ? try LocalFiles.list(entry.path) : try client.list(entry.path) }
    private func measure(_ entry: FileEntry) throws -> UInt64 {
        guard entry.isDirectory || entry.isRegular else { throw FTPError.message("Links und Spezialdateien werden nicht übertragen: \(entry.name)") }
        if entry.isDirectory { return try children(entry).reduce(0) { try $0 + measure($1) } }
        return entry.size
    }
    func run(source: FileEntry, destination: String, progress: (UInt64, UInt64) -> Void) throws {
        let fresh = upload ? try LocalFiles.entry(URL(fileURLWithPath: source.path)) : try client.stat(source.path)
        total = try measure(fresh); progress(0, total)
        try transfer(fresh, destination: destination, progress: progress); progress(done, total)
    }
    private func destinationEntry(_ path: String) throws -> FileEntry? {
        if upload { do { return try client.stat(path) } catch let e as FTPError where e.isMissing { return nil } }
        do { return try LocalFiles.entry(URL(fileURLWithPath: path)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
    private func transfer(_ source: FileEntry, destination original: String, progress: (UInt64, UInt64) -> Void) throws {
        guard !source.isSymlink else { throw FTPError.message("Symbolischer Link wird nicht übertragen: \(source.name)") }
        let previous = policy == .resume ? checkpoint.get(source.path) : nil
        var destination = previous?.destination ?? original
        let conflict = resumeCheckpoint && previous == nil ? retryPolicy : policy
        if let previous, previous.completed, try destinationEntry(previous.destination) != nil {
            done += try measure(source); progress(done, total); return
        }
        if let existing = try destinationEntry(destination) {
            if existing.isSymlink { throw FTPError.message("Ziel ist ein symbolischer Link: \(destination)") }
            if conflict == .skip { done += try measure(source); checkpoint.save(source.path, destination: destination, completed: true); progress(done, total); return }
            if conflict == .rename {
                let directory = (original as NSString).deletingLastPathComponent
                let name = (original as NSString).lastPathComponent
                var index = 1
                repeat { destination = FileEntry.join(directory, "\(name) (\(index))"); index += 1 } while try destinationEntry(destination) != nil
            } else if source.isDirectory != existing.isDirectory { throw FTPError.message("Datei/Ordner-Konflikt: \(destination)") }
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
                    if retryPolicy != .overwrite && retryPolicy != .resume, try destinationEntry(destination) != nil { throw FTPError.message("Ziel wurde inzwischen erstellt; Arbeitsdatei bleibt erhalten. Bitte Konflikt manuell auflösen.") }
                    if upload { try client.chmod(target, mode: source.permissions & 0o777); try client.commitUpload(target, to: destination) }
                    else { try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: source.permissions & 0o777)], ofItemAtPath: target); guard Darwin.rename(target, destination) == 0 else { throw FTPError.message("Fortgesetzte Arbeitsdatei konnte nicht übernommen werden.") } }
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
                        guard Darwin.rename(temporary, destination) == 0 else { throw FTPError.message("Lokale Datei konnte nicht übernommen werden: " + String(cString: strerror(errno))) }
                    } else { try FileManager.default.moveItem(atPath: temporary, toPath: destination) }
                }
            }
            done = base + source.size; progress(done, total)
        }
        checkpoint.save(source.path, destination: destination, completed: true)
    }
}
