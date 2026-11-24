import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct BackupSafetyTests {
    private func backup() -> Backup {
        Backup(date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func failedWriteReturnsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await BackupManager.shared.save(backup: backup(), url: directory) == false)
    }

    @Test func summariesAndFullRestoreReadExistingBackupFormats() throws {
        var expected = backup()
        expected.name = "서재"
        expected.automatic = true
        expected.sourceLists = ["first", "second"]
        expected.settings = ["Reader.example": .string("value")]

        let plist = PropertyListEncoder()
        plist.outputFormat = .binary
        let binary = try plist.encode(expected)
        plist.outputFormat = .xml
        let xml = try plist.encode(expected)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .secondsSince1970
        let json = try jsonEncoder.encode(expected)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for data in [binary, xml, json, Data("\n ".utf8) + json] {
            try data.write(to: url, options: .atomic)
            let info = try #require(BackupInfo.load(from: url))
            #expect(info.name == expected.name)
            #expect(info.date == expected.date)
            #expect(info.automatic)
            #expect(info.counts.sourceLists == 2)
            #expect(info.counts.settings == 1)
            #expect(info.size == Int64(data.count))
            #expect(Backup.load(from: url) == expected)
        }
        try Data("{".utf8).write(to: url, options: .atomic)
        #expect(BackupInfo.load(from: url) == nil)
        #expect(Backup.load(from: url) == nil)
    }

    @Test func cancelledBackupDoesNotReplaceAnExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.aib")
        let original = try PropertyListEncoder().encode(backup())
        try original.write(to: url)
        var changed = backup()
        changed.name = "replacement"
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BackupManager().save(backup: changed, url: url)
        }
        #expect(await !task.value)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func restorePreservesLocalFilesAndUnselectedSections() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manga = MangaObject(context: context)
        manga.sourceId = "local"
        manga.id = "one"
        manga.title = "Original"
        let file = LocalFileInfoObject(context: context)
        file.path = "Books/one"
        manga.fileInfo = file
        let chapter = ChapterObject(context: context)
        chapter.sourceId = "local"
        chapter.mangaId = "one"
        chapter.id = "chapter"
        chapter.manga = manga
        let history = HistoryObject(context: context)
        history.sourceId = "local"
        history.mangaId = "one"
        history.chapterId = "chapter"
        history.progress = 7
        chapter.history = history
        try context.save()
        let originalID = manga.objectID
        var item = BackupManga(mangaObject: manga)
        item.title = "Restored"
        var backup = backup()
        backup.manga = [item]
        try BackupManager.restoreDatabase(from: backup, context: context)
        try context.save()
        let restored = try #require(context.fetch(MangaObject.fetchRequest()).first)
        #expect(restored.objectID == originalID)
        #expect(restored.title == "Restored")
        #expect(restored.fileInfo?.path == "Books/one")
        #expect(chapter.manga === restored)
        #expect(chapter.history?.progress == 7)
    }

    @Test func outOfRangeBackupIsRejectedBeforeChangingData() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let history = HistoryObject(context: context)
        history.sourceId = "source"
        history.mangaId = "manga"
        history.chapterId = "chapter"
        history.progress = 5
        history.scrollPosition = 0.75
        try context.save()
        var item = BackupHistory(historyObject: history)
        #expect(item.scrollPosition == 0.75)
        item.progress = Int.max
        var backup = backup()
        backup.history = [item]
        #expect(throws: BackupManager.BackupError.self) {
            try BackupManager.restoreDatabase(from: backup, context: context)
        }
        #expect(!context.hasChanges)
        #expect(history.progress == 5)
    }

    @Test func corruptedBackupIntervalsCannotScheduleImmediateRecurringWork() {
        for value in ["", "0", "daily ", "never", "unknown", "-1"] {
            #expect(BackupManager.autoBackupInterval(for: value) == nil)
        }
        #expect(BackupManager.autoBackupInterval(for: "6hours") == 21_600)
        #expect(BackupManager.autoBackupInterval(for: "weekly") == 604_800)
    }
}
