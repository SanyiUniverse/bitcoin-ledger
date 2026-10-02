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

@Test @MainActor
func v1LoadDoesNotWriteAndFirstSavePreservesOriginalBytesExactlyOnce() throws {
    let url = temporaryLedgerURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let originalBytes = legacyV1Bytes()
    try originalBytes.write(to: url)
    let repo = try LedgerRepository(url: url)
    let migrated = try repo.load()
    #expect(migrated.schemaVersion == BackupDocument.currentSchemaVersion)
    #expect(try Data(contentsOf: url) == originalBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    try repo.save(migrated)
    #expect(try BackupCodec.schemaVersion(in: Data(contentsOf: url)) == BackupDocument.currentSchemaVersion)
    let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-upgrade-v1-") }
    #expect(preserved.count == 1)
    let preservedURL = try #require(preserved.first)
    #expect(try Data(contentsOf: preservedURL) == originalBytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: preservedURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try repo.save(migrated)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.filter { $0.hasPrefix("ledger.before-upgrade-v1-") }.count == 1)
    #expect(try Data(contentsOf: preservedURL) == originalBytes)
}

@Test @MainActor
func migrationChecksConflictBeforeCreatingBackupOrOverwritingCurrentFile() throws {
    let url = temporaryLedgerURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try legacyV1Bytes().write(to: url)
    let first = try LedgerRepository(url: url)
    let second = try LedgerRepository(url: url)
    let staleDocument = try first.load()
    var latest = try second.load()
    latest.entries[0].note = "另一个写入者的有效修改"
    try second.save(latest)
    let currentBytes = try Data(contentsOf: url)
    #expect(throws: RepositoryError.self) { try first.save(staleDocument) }
    #expect(try Data(contentsOf: url) == currentBytes)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.filter { $0.hasPrefix("ledger.before-upgrade-v1-") }.count == 1)
}

@Test @MainActor
func recoveryCannotOverwriteChangedFileAfterFailedLoad() throws {
    let url = temporaryLedgerURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{corrupt".utf8).write(to: url)
    let repo = try LedgerRepository(url: url)
    #expect(throws: (any Error).self) { try repo.load() }
    let externalBytes = try BackupCodec.encode(BackupDocument())
    try externalBytes.write(to: url, options: .atomic)
    #expect(throws: RepositoryError.self) {
        try repo.save(BackupDocument(), replacingCorruptStore: true)
    }
    #expect(try Data(contentsOf: url) == externalBytes)
}

@Test @MainActor
func unsupportedPolicyIsNeverSilentlyMigrated() throws {
    let url = temporaryLedgerURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Data(#"{"schemaVersion":2,"baseCurrency":"CNY","accountingPolicy":"unknown-method"}"#.utf8)
    try original.write(to: url)
    let repo = try LedgerRepository(url: url)
    #expect(throws: (any Error).self) { try repo.load() }
    #expect(throws: (any Error).self) { try repo.save(BackupDocument()) }
    #expect(try Data(contentsOf: url) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
}

@Test @MainActor
func firstV2SavePreservesOriginalBytesBeforeUpgradingToV5() throws {
    let url = temporaryLedgerURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = legacyV2Bytes()
    try original.write(to: url)
    let repository = try LedgerRepository(url: url)
    let migrated = try repository.load()
    #expect(migrated.schemaVersion == 5)
    #expect(try Data(contentsOf: url) == original)
    try repository.save(migrated)
    #expect(try BackupCodec.schemaVersion(in: Data(contentsOf: url)) == 5)
    let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-upgrade-v2-") }
    #expect(preserved.count == 1)
    let backup = try #require(preserved.first)
    #expect(try Data(contentsOf: backup) == original)
    try repository.save(migrated)
    #expect(try Data(contentsOf: backup) == original)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.filter { $0.hasPrefix("ledger.before-upgrade-v2-") }.count == 1)
}

@Test @MainActor
func staleV2MigrationDoesNotOverwriteNewFileOrMakeExtraUpgradeBackups() throws {
    let url = temporaryLedgerURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try legacyV2Bytes().write(to: url)
    let first = try LedgerRepository(url: url)
    let second = try LedgerRepository(url: url)
    let oldDocument = try first.load()
    var newDocument = try second.load()
    newDocument.entries[0].note = "latest"
    try second.save(newDocument)
    let latestBytes = try Data(contentsOf: url)
    #expect(throws: RepositoryError.self) { try first.save(oldDocument) }
    #expect(try Data(contentsOf: url) == latestBytes)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.filter { $0.hasPrefix("ledger.before-upgrade-v2-") }.count == 1)
}
