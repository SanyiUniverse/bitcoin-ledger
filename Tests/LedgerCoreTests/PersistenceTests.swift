import Foundation
import Testing
@testable import LedgerCore

private func temporaryLedgerURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BitcoinLedgerTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("ledger.json")
}

@Test @MainActor
func persistenceReopensAndUsesPrivatePermissions() throws {
    let url = temporaryLedgerURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repo = try LedgerRepository(url: url)
    #expect(try repo.load().entries.isEmpty)
    let first = BackupDocument(exportedAt: Date(timeIntervalSince1970: 1000))
    try repo.save(first)
    let reopened = try LedgerRepository(url: url)
    #expect(try reopened.load() == first)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test @MainActor
func invalidSaveLeavesOriginalAndMemoryUnchanged() throws {
    let url = temporaryLedgerURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repo = try LedgerRepository(url: url)
    let original = BackupDocument(exportedAt: Date(timeIntervalSince1970: 1000))
    try repo.save(original)
    let bytes = try Data(contentsOf: url)
    var invalid = original
    invalid.schemaVersion = 999
    #expect(throws: (any Error).self) { try repo.save(invalid) }
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try repo.load() == original)
    let memory = try LedgerRepository(inMemory: true)
    try memory.save(original)
    #expect(throws: (any Error).self) { try memory.save(invalid) }
    #expect(try memory.load() == original)
}

@Test @MainActor
func previousSnapshotAndCorruptionRecoveryPreserveBytes() throws {
    let url = temporaryLedgerURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repo = try LedgerRepository(url: url)
    let first = BackupDocument(exportedAt: Date(timeIntervalSince1970: 1000))
    let second = BackupDocument(exportedAt: Date(timeIntervalSince1970: 2000))
    try repo.save(first)
    try repo.save(second)
    let previous = try #require(repo.previousURL)
    #expect(try BackupCodec.decode(Data(contentsOf: previous)) == first)

    let corruptBytes = Data("{broken".utf8)
    try corruptBytes.write(to: url, options: .atomic)
    let recovery = try LedgerRepository(url: url)
    #expect(throws: (any Error).self) { try recovery.load() }
    #expect(throws: (any Error).self) { try recovery.save(first) }
    #expect(try Data(contentsOf: url) == corruptBytes)
    try recovery.save(first, replacingCorruptStore: true)
    #expect(try recovery.load() == first)
    #expect(try BackupCodec.decode(Data(contentsOf: previous)) == first)
    let preserved = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.corrupt-") }
    #expect(preserved.count == 1)
    #expect(try Data(contentsOf: #require(preserved.first)) == corruptBytes)
}

@Test @MainActor
func staleWriterCannotOverwriteAnotherSavedSnapshot() throws {
    let url = temporaryLedgerURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try LedgerRepository(url: url)
    let second = try LedgerRepository(url: url)
    try first.save(BackupDocument(exportedAt: Date(timeIntervalSince1970: 1000)))
    _ = try second.load()
    let changed = BackupDocument(exportedAt: Date(timeIntervalSince1970: 2000))
    try first.save(changed)
    #expect(throws: RepositoryError.self) {
        try second.save(BackupDocument(exportedAt: Date(timeIntervalSince1970: 3000)))
    }
    #expect(try first.load() == changed)
}

@Test @MainActor
func importPreservesSnapshotBeyondNextOrdinarySave() throws {
    let url = temporaryLedgerURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repo = try LedgerRepository(url: url)
    let original = BackupDocument(exportedAt: Date(timeIntervalSince1970: 1000))
    try repo.save(original)
    try repo.save(BackupDocument(exportedAt: Date(timeIntervalSince1970: 2000)), preserveCurrent: true)
    try repo.save(BackupDocument(exportedAt: Date(timeIntervalSince1970: 3000)))
    let preserved = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-import-") }
    #expect(preserved.count == 1)
    #expect(try BackupCodec.decode(Data(contentsOf: #require(preserved.first))) == original)
}
