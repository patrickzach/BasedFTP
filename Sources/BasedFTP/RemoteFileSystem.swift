import Foundation

struct DeletionProgress: Sendable {
    let removed: Int
    let path: String
    let listing: Bool
    var text: String { "\(listing ? "Reading directory" : "Deleting"): \(path) · \(removed) \(removed == 1 ? "item" : "items") deleted" }
}

struct RemoteTransferFeatures {
    let directories: Bool
    let unixPermissions: Bool
}

/// A single remote session, used serially on a worker task, never on the UI actor.
/// Implementations own protocol details and must propagate connection/permission errors.
/// Paths are remote POSIX paths. `stat` inspects links rather than following them.
protocol RemoteFileSystem: AnyObject {
    var transferFeatures: RemoteTransferFeatures { get }
    func close()
    func realpath(_ path: String) throws -> String
    func stat(_ path: String) throws -> FileEntry
    /// Only a confirmed missing entry returns nil; other failures must throw.
    func entryIfExists(_ path: String) throws -> FileEntry?
    func list(_ path: String) throws -> [FileEntry]
    func mkdir(_ path: String) throws
    /// Move after checking for conflicts; FTP cannot guarantee atomic no-replace semantics.
    func rename(_ from: String, _ to: String) throws
    func createFile(_ path: String) throws
    func chmod(_ path: String, mode: UInt32) throws
    func delete(_ entries: [FileEntry], progress: (DeletionProgress) -> Void) throws
    /// Commit a complete staging file; requireAtomic forbids destructive fallbacks.
    func commitUpload(_ temporary: String, to destination: String, requireAtomic: Bool) throws
    func download(_ remote: String, to local: URL, resume: Bool, progress: (UInt64) -> Void) throws
    func upload(_ local: URL, to remote: String, resume: Bool, exclusive: Bool, progress: (UInt64) -> Void) throws
    /// Must either replace atomically or fail while preserving the existing destination.
    /// A lost acknowledgment may leave either the old or the complete new version.
    func uploadEditingSnapshot(_ local: URL, to destination: String, permissions: UInt32) throws
}

extension RemoteFileSystem {
    func exists(_ path: String) throws -> Bool { try entryIfExists(path) != nil }
    func delete(_ entry: FileEntry) throws { try delete([entry], progress: { _ in }) }
    func delete(_ entries: [FileEntry]) throws { try delete(entries, progress: { _ in }) }
    func commitUpload(_ temporary: String, to destination: String) throws {
        try commitUpload(temporary, to: destination, requireAtomic: false)
    }
    func upload(_ local: URL, to remote: String, resume: Bool, progress: (UInt64) -> Void) throws {
        try upload(local, to: remote, resume: resume, exclusive: false, progress: progress)
    }
}

/// The only production entry point for creating remote file sessions.
/// SFTP supports all operations; FTP currently supports browsing and regular file transfers.
enum RemoteFileSystems {
    static func connect(profile: ServerProfile, control: OperationControl = OperationControl(), knownHosts: URL? = nil) throws -> any RemoteFileSystem {
        switch profile.transport {
        case .sftp: return try SFTPClient(profile: profile, control: control, knownHosts: knownHosts)
        case .ftp: return try FTPClient(profile: profile, control: control)
        }
    }
}
