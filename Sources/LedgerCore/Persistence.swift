import Foundation

public enum RepositoryError: LocalizedError {
    case changedOnDisk
    case unreadableStore(String)
    case unavailableResult

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            return "账本已被另一个窗口或进程修改。请重新打开应用后再试；本次修改没有保存。"
        case .unreadableStore(let detail):
            return "本地账本无法读取，原文件已保留。请从 JSON 备份恢复。\n\(detail)"
        case .unavailableResult:
            return "系统未能协调账本文件访问，请重试。"
        }
    }
}

/// A single local snapshot is sufficient for a personal ledger. All writes are
/// validated, serialized on the main actor, coordinated, and atomically replaced.
@MainActor
public final class LedgerRepository {
    public let url: URL?
    public var previousURL: URL? { url?.deletingLastPathComponent().appendingPathComponent("ledger.previous.json") }
    private var memoryDocument = BackupDocument()
    private var lastReadData: Data?
    private var hasLoaded = false

    public init(url: URL? = nil, inMemory: Bool = false) throws {
        if inMemory {
            self.url = nil
        } else if let url {
            self.url = url.standardizedFileURL
        } else {
            self.url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Bitcoin Ledger", isDirectory: true)
                .appendingPathComponent("ledger.json")
        }
    }

    public func load() throws -> BackupDocument {
        guard let url else { return memoryDocument }
        let documentAndData: (BackupDocument, Data?) = try coordinated(url: url, writing: false) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return (BackupDocument(), nil) }
            do {
                let data = try Data(contentsOf: coordinatedURL)
                return (try BackupCodec.decode(data), data)
            } catch {
                throw RepositoryError.unreadableStore(error.localizedDescription)
            }
        }
        memoryDocument = documentAndData.0
        lastReadData = documentAndData.1
        hasLoaded = true
        return memoryDocument
    }

    /// Set replacingCorruptStore only after the user explicitly chooses a valid
    /// backup to restore. Unreadable bytes are preserved separately before saving.
    public func save(_ document: BackupDocument, replacingCorruptStore: Bool = false, preserveCurrent: Bool = false) throws {
        let data = try BackupCodec.encode(document)
        // Validate the precise serialized representation before touching disk.
        let validated = try BackupCodec.decode(data)
        guard let url else { memoryDocument = validated; return }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        try coordinated(url: url, writing: true) { coordinatedURL in
            let current = manager.fileExists(atPath: coordinatedURL.path) ? try Data(contentsOf: coordinatedURL) : nil
            if hasLoaded, current != lastReadData { throw RepositoryError.changedOnDisk }

            if let current {
                do {
                    _ = try BackupCodec.decode(current)
                } catch {
                    guard replacingCorruptStore else { throw RepositoryError.unreadableStore(error.localizedDescription) }
                    let preserved = directory.appendingPathComponent("ledger.corrupt-\(UUID().uuidString).json")
                    try writePrivate(current, to: preserved)
                    try writePrivate(data, to: coordinatedURL)
                    return
                }
                if preserveCurrent {
                    let preserved = directory.appendingPathComponent("ledger.before-import-\(UUID().uuidString).json")
                    try writePrivate(current, to: preserved)
                }
                // The previous file always contains a validated, complete snapshot.
                try writePrivate(current, to: directory.appendingPathComponent("ledger.previous.json"))
            }
            try writePrivate(data, to: coordinatedURL)
        }
        memoryDocument = validated
        lastReadData = data
        hasLoaded = true
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        // The containing directory is owner-only, including while Foundation
        // creates its temporary file for atomic replacement.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func coordinated<T>(url: URL, writing: Bool, operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        let accessor: (URL) -> Void = { coordinatedURL in result = Result { try operation(coordinatedURL) } }
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RepositoryError.unavailableResult }
        return try result.get()
    }
}
