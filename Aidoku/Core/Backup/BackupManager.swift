//
//  BackupManager.swift
//  Aidoku
//
//  Created by Skitty on 2/26/22.
//

import BackgroundTasks
import Foundation
import CoreData
import UIKit

actor BackupManager {
    static let shared = BackupManager()

    static let directory = FileManager.default.documentDirectory.appendingPathComponent("Backups", isDirectory: true)

    static var backupUrls: [URL] {
        Self.directory.contentsByDateModified
    }

    private static let backupTaskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".backup"
    private static let maxAutoBackups = 4
    private var isCreatingAutoBackup = false
    private let dataOperations = LocalFileOperationGate()

    private static let excludedSettings: Set<String> = [
        AppSettings.browse.sourceLists.key, // stored separately
        AppSettings.general.icloudSync.key
    ]
    static let excludedSettingsPrefixes = [
        "Flag",
        "Data"
    ]
    static let allowedSettingsPrefixes = [
        "General",
        "Appearance",
        "Library",
        "Browse",
        "History",
        "Reader",
        "Tracker",
        "Tracking",
        "AutomaticBackups",
        "Downloads",
        "Manga",
        "Logs",
        "Search",
        "Token",
        "Dictionary"
    ]

    @discardableResult
    func save(backup: Backup, url: URL? = nil) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            let target: URL
            if let url {
                target = url
            } else {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                target = Self.directory.appendingPathComponent("aidoku_\(dateFormatter.string(from: backup.date))_\(UUID().uuidString).aib")
            }
            let data = try encoder.encode(backup)
            guard !Task.isCancelled else { return false }
            try data.write(to: target, options: .atomic)
            NotificationCenter.default.post(name: .updateBackupList, object: nil)
            return true
        } catch {
            LogManager.logger.error("Could not save backup: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveNewBackup(name: String = "", options: BackupOptions) async -> Bool {
        await withExclusiveDataAccess { await saveSnapshot(name: name, options: options) }
    }

    private func saveSnapshot(name: String = "", options: BackupOptions) async -> Bool {
        let backup = await createBackup(name: name, options: options)
        guard !Task.isCancelled else { return false }
        return save(backup: backup)
    }

    // The source lists, database, and settings are read or written across actor suspensions.
    func withExclusiveDataAccess(_ operation: () async -> Bool) async -> Bool {
        do { try await dataOperations.acquire() } catch { return false }
        defer { dataOperations.release() }
        return await operation()
    }

    func importBackup(from url: URL, into directory: URL = BackupManager.directory) -> Bool {
        let fileManager = FileManager.default
        var targetLocation = directory.appendingPathComponent(url.lastPathComponent)
        while targetLocation.exists {
            targetLocation = targetLocation.deletingLastPathComponent().appendingPathComponent(
                targetLocation.deletingPathExtension().lastPathComponent.appending("_1")
            ).appendingPathExtension(url.pathExtension)
        }
        let secured = url.startAccessingSecurityScopedResource()
        defer {
            if secured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stagingDirectory = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
            )
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            let stagedFile = stagingDirectory.appendingPathComponent("backup")
            try fileManager.copyItem(at: url, to: stagedFile)
            try fileManager.moveItem(at: stagedFile, to: targetLocation)
            NotificationCenter.default.post(name: .updateBackupList, object: nil)
            return true
        } catch {
            return false
        }
    }

    struct BackupOptions {
        var automatic: Bool = false
        let libraryEntries: Bool
        let history: Bool
        let chapters: Bool
        let tracking: Bool
        let readingSessions: Bool
        let vocabulary: Bool
        let updates: Bool
        let categories: Bool
        let settings: Bool
        let sourceLists: Bool
        let sensitiveSettings: Bool
    }

    func createBackup(name: String = "", options: BackupOptions) async -> Backup {
        let sourceLists: [String]? = if options.sourceLists {
            await SourceManager.shared.getSourceListURLs().map { $0.absoluteString }
        } else {
            nil
        }
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            let library: [BackupLibraryManga]? = if options.libraryEntries {
                CoreDataManager.shared.getLibraryManga(context: context).map {
                    BackupLibraryManga(libraryObject: $0, skipCategories: !options.categories)
                }
            } else {
                nil
            }
            let history: [BackupHistory]? = if options.history {
                CoreDataManager.shared.getHistory(context: context).map {
                    BackupHistory(historyObject: $0)
                }
            } else {
                nil
            }
            let manga: [BackupManga]? = if options.libraryEntries {
                CoreDataManager.shared.getManga(context: context).map {
                    BackupManga(mangaObject: $0)
                }
            } else {
                nil
            }
            let chapters: [BackupChapter]? = if options.chapters {
                CoreDataManager.shared.getChapters(context: context).map {
                    BackupChapter(chapterObject: $0)
                }
            } else {
                nil
            }
            let trackItems: [BackupTrackItem]? = if options.tracking {
                CoreDataManager.shared.getTracks(context: context).compactMap {
                    BackupTrackItem(trackObject: $0)
                }
            } else {
                nil
            }
            let sessionItems: [BackupReadingSession]? = if options.readingSessions {
                CoreDataManager.shared.getSessions(context: context).compactMap(BackupReadingSession.init)
            } else {
                nil
            }
            let vocabulary: [BackupVocabEntry]? = if options.vocabulary {
                CoreDataManager.shared.getVocab(context: context).compactMap(BackupVocabEntry.init)
            } else {
                nil
            }
            let updateItems: [BackupUpdate]? = if options.updates {
                CoreDataManager.shared.getUpdates(context: context).compactMap(BackupUpdate.init)
            } else {
                nil
            }
            let categories: [BackupCategory]? = if options.categories {
                CoreDataManager.shared.getCategories(context: context).compactMap(BackupCategory.init)
            } else {
                nil
            }
            let sources: [BackupSource] = CoreDataManager.shared.getSources(context: context).compactMap(BackupSource.init)

            let settings: [String: JSONAnyValue]? = if options.settings {
                self.exportSettings(includeSensitive: options.sensitiveSettings, sourceKeys: sources.map(\.id))
            } else {
                nil
            }

            return Backup(
                library: library,
                history: history,
                manga: manga,
                chapters: chapters,
                trackItems: trackItems,
                readingSessions: sessionItems,
                vocabulary: vocabulary,
                updates: updateItems,
                categories: categories,
                sources: sources,
                sourceLists: sourceLists,
                settings: settings,
                date: Date.now,
                name: name.isEmpty ? nil : name,
                automatic: options.automatic,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            )
        }
    }

    private nonisolated func exportSettings(includeSensitive: Bool, sourceKeys: [String]) -> [String: JSONAnyValue] {
        var allSettings = UserDefaults.standard.dictionaryRepresentation()

        // filter out potentially sensitive info
        if !includeSensitive {
            let sensitiveKeywords = ["login", "password", "token", "auth", "cookie"]
            for key in allSettings.keys where sensitiveKeywords.contains(where: key.lowercased().contains) {
                allSettings.removeValue(forKey: key)
            }
        }

        var convertedSettings: [String: JSONAnyValue] = [:]

        // convert to export compatible types
        for (key, value) in allSettings {
            guard
                Self.allowedSettingsPrefixes.contains(where: { key.hasPrefix($0) }) || sourceKeys.contains(where: { key.hasPrefix($0) }),
                !Self.excludedSettings.contains(key)
            else {
                continue
            }
            if
                let number = value as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            {
                convertedSettings[key] = .bool(number.boolValue)
            } else if let value = value as? String {
                convertedSettings[key] = .string(value)
            } else if let value = value as? Int {
                convertedSettings[key] = .int(value)
            } else if let value = value as? Double {
                convertedSettings[key] = .double(value)
            } else if let value = value as? Bool {
                convertedSettings[key] = .bool(value)
            } else if let value = value as? [String] {
                convertedSettings[key] = .array(value)
            }
        }

        return convertedSettings
    }

    func renameBackup(url: URL, name: String?) -> Bool {
        guard var backup = Backup.load(from: url) else { return false }
        backup.name = name?.isEmpty ?? true ? nil : name
        return save(backup: backup, url: url)
    }

    func removeBackup(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            NotificationCenter.default.post(name: .updateBackupList, object: url)
        } catch {
            LogManager.logger.error("Could not remove backup: \(error.localizedDescription)")
        }
    }
}

// MARK: Restoring
extension BackupManager {
    enum BackupError: Error {
        case manga
        case categories
        case library
        case history
        case chapters
        case sessions
        case vocabulary
        case updates
        case track
        case sources

        var stringValue: String {
            switch self {
                case .manga: NSLocalizedString("CONTENT")
                case .categories: NSLocalizedString("CATEGORIES")
                case .library: NSLocalizedString("LIBRARY")
                case .history: NSLocalizedString("HISTORY")
                case .chapters: NSLocalizedString("CHAPTERS")
                case .sessions: NSLocalizedString("READING_SESSIONS")
                case .vocabulary: NSLocalizedString("VOCABULARY")
                case .updates: NSLocalizedString("UPDATES")
                case .track: NSLocalizedString("TRACKERS")
                case .sources: NSLocalizedString("SOURCES")
            }
        }
    }

    /// Stage a restore in one context. The caller commits only after every section succeeds.
    nonisolated static func restoreDatabase(from backup: Backup, context: NSManagedObjectContext) throws {
        func valid16(_ values: Int?...) -> Bool {
            values.allSatisfy { $0 == nil || Int16(exactly: $0!) != nil }
        }
        guard (backup.manga ?? []).allSatisfy({
            valid16($0.status, $0.nsfw, $0.viewer, $0.chapterFlags) && Int32(exactly: $0.editedKeys ?? 0) != nil
        }) else { throw BackupError.manga }
        guard (backup.categories ?? []).allSatisfy({ valid16($0.sort) }) else { throw BackupError.categories }
        guard (backup.chapters ?? []).allSatisfy({ valid16($0.sourceOrder) }) else { throw BackupError.chapters }
        guard (backup.history ?? []).allSatisfy({
            valid16($0.progress, $0.total) && ($0.scrollPosition?.isFinite ?? true)
        }) else { throw BackupError.history }
        guard (backup.readingSessions ?? []).allSatisfy({ valid16($0.pagesRead) }) else { throw BackupError.sessions }
        guard (backup.trackItems ?? []).allSatisfy({ valid16($0.chapterOffset) }) else { throw BackupError.track }
        guard (backup.vocabulary ?? []).allSatisfy({ valid16($0.page, $0.clozeOffset) }) else { throw BackupError.vocabulary }

        func index<T: NSManagedObject, K: Hashable>(
            _ request: NSFetchRequest<T>, when needed: Bool = true, key: @escaping (T) -> K
        ) throws -> [K: T] {
            guard needed else { return [:] }
            let rows = try context.fetch(request)
            return Dictionary(rows.lazy.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        }
        func delete<T: NSManagedObject>(_ request: NSFetchRequest<T>) throws {
            for row in try context.fetch(request) { context.delete(row) }
        }
        let relinkChapterManga = backup.chapters != nil || backup.manga != nil
        let relinkChapterHistory = backup.chapters != nil || backup.history != nil
        var manga = try index(
            MangaObject.fetchRequest(), when: relinkChapterManga || backup.library?.isEmpty == false, key: { $0.identifier }
        )
        if let items = backup.manga {
            // Metadata is shared by downloads, history and unselected sections. Update it in place.
            for item in items {
                let key = MangaIdentifier(sourceKey: item.sourceId, mangaKey: item.id)
                manga[key] = item.toObject(context: context, existing: manga[key])
            }
        }
        var categories = try index(
            CategoryObject.fetchRequest(), when: backup.categories != nil || backup.library?.isEmpty == false, key: { $0.title ?? "" }
        )
        if let items = backup.categories {
            let titles = Set(items.lazy.map { $0.title ?? "" })
            for (title, row) in categories where !titles.contains(title) {
                context.delete(row)
                categories.removeValue(forKey: title)
            }
            for item in items {
                let title = item.title ?? ""
                categories[title] = item.toObject(context: context, existing: categories[title])
            }
        }
        if let items = backup.library {
            var library = try index(LibraryMangaObject.fetchRequest(), key: {
                $0.manga?.identifier ?? MangaIdentifier(sourceKey: "", mangaKey: "")
            })
            let keys = Set(items.lazy.map(\.identifier))
            for (key, row) in library where !keys.contains(key) { context.delete(row) }
            for item in items {
                guard let parent = manga[item.identifier] else { throw BackupError.library }
                let row = item.toObject(context: context, existing: library[item.identifier])
                row.manga = parent
                if let titles = item.categories {
                    row.categories = NSSet(array: titles.compactMap { categories[$0] })
                }
                library[item.identifier] = row
            }
        }
        var history = try index(
            HistoryObject.fetchRequest(), when: relinkChapterHistory || backup.readingSessions?.isEmpty == false, key: { $0.identifier }
        )
        if let items = backup.history {
            let keys = Set(items.lazy.map { ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.chapterId) })
            for (key, row) in history where !keys.contains(key) {
                // Sessions cascade from history. An unselected section must survive a partial restore.
                if backup.readingSessions == nil && (row.sessions?.count ?? 0) > 0 { continue }
                context.delete(row)
                history.removeValue(forKey: key)
            }
            for item in items {
                let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)
                history[key] = item.toObject(context: context, existing: history[key])
            }
        }
        var chapters = try index(
            ChapterObject.fetchRequest(), when: relinkChapterManga || relinkChapterHistory || backup.updates?.isEmpty == false, key: { $0.identifier }
        )
        if let items = backup.chapters {
            let keys = Set(items.lazy.map { ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.id) })
            for (key, row) in chapters where !keys.contains(key) {
                if row.fileInfo != nil || (backup.updates == nil && row.mangaUpdate != nil) { continue }
                context.delete(row)
                chapters.removeValue(forKey: key)
            }
            for item in items {
                let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.id)
                chapters[key] = item.toObject(context: context, existing: chapters[key])
            }
        }
        // Reconnect relationships whose endpoints were restored.
        for (key, row) in chapters {
            if relinkChapterManga { row.manga = manga[key.mangaIdentifier] }
            if relinkChapterHistory { row.history = history[key] }
        }
        if let items = backup.readingSessions {
            try delete(ReadingSessionObject.fetchRequest())
            for item in items where item.endDate > item.startDate && item.pagesRead > 0 {
                let row = item.toObject(context: context)
                let parent = history[item.identifier] ?? CoreDataManager.shared.getOrCreateHistory(chapterId: item.identifier, context: context)
                history[item.identifier] = parent
                row.history = parent
            }
        }
        if let items = backup.updates {
            try delete(MangaUpdateObject.fetchRequest())
            for item in items {
                let row = item.toObject(context: context)
                row.chapter = chapters[.init(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)]
            }
        }
        if let items = backup.trackItems {
            try delete(TrackObject.fetchRequest())
            for item in items { _ = item.toObject(context: context) }
        }
        if let items = backup.vocabulary {
            // Images stay on this device; preserve links for matching vocabulary entries.
            let existing = try context.fetch(VocabObject.fetchRequest())
            let images = Dictionary(existing.lazy.compactMap { row -> (BackupVocabEntry, String)? in
                guard let image = row.localImageId, let entry = BackupVocabEntry(row) else { return nil }
                return (entry, image)
            }, uniquingKeysWith: { first, _ in first })
            existing.forEach(context.delete)
            for item in items {
                let row = item.toObject(context: context)
                row.localImageId = images[item]
            }
        }
        if let items = backup.sources, items.contains(where: { $0.config != nil }) {
            var sources = try index(SourceObject.fetchRequest(), key: { $0.id ?? "" })
            for item in items where item.config != nil {
                guard item.apiVersion != nil else { throw BackupError.sources }
                if let existing = sources[item.id] {
                    existing.apiVersion = item.apiVersion
                    existing.customSource = item.config as NSObject?
                } else {
                    sources[item.id] = item.toObject(context: context)
                }
            }
        }
    }

    @discardableResult
    func restore(from url: URL) async -> Bool {
        // Keep the selected file version if a queued restore outlives a rename or automatic pruning.
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        return await withExclusiveDataAccess {
            guard let data, let backup = Backup.decode(data) else {
                await Self.presentRestoreError(NSLocalizedString("CORRUPTED_BACKUP"))
                return false
            }
            return await doRestore(from: backup)
        }
    }

    @MainActor
    private static func presentRestoreError(_ reason: String) {
        UIApplication.shared.appDelegate?.presentAlert(
            title: NSLocalizedString("BACKUP_ERROR"),
            message: String(format: NSLocalizedString("BACKUP_ERROR_TEXT"), reason)
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func doRestore(from backup: Backup) async -> Bool {
        await MainActor.run {
            UIApplication.shared.appDelegate?.showLoadingIndicator()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        var backupError: Error?
        do {
            try await CoreDataManager.shared.container.performBackgroundTask { context in
                do {
                    try Self.restoreDatabase(from: backup, context: context)
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
            if let sourceLists = backup.sourceLists {
                await SourceManager.shared.waitForSourceListsLoad()
                await SourceManager.shared.clearSourceLists()
                for sourceList in sourceLists {
                    guard let url = URL(string: sourceList) else { continue }
                    _ = await SourceManager.shared.addSourceList(url: url, allowUnavailable: true)
                }
            }
            if backup.sources?.contains(where: { $0.config != nil }) == true {
                await SourceManager.shared.reloadSources()
            }
        } catch {
            backupError = error
        }

        // Restore application and currently installed source settings as part of the initial restore.
        if backupError == nil {
            await restoreSettings(from: backup)
        }

        await Task { @MainActor in
            await UIApplication.shared.appDelegate?.hideLoadingIndicator()
            UIApplication.shared.isIdleTimerDisabled = false
        }.value

        if backupError == nil {
            let externalSourceKeys = Set((backup.sources ?? []).lazy.filter { $0.config == nil }.map(\.id))
            let missingSourceKeys = await SourceManager.shared.missingExternalSourceKeys(in: externalSourceKeys)

            if
                !missingSourceKeys.isEmpty,
                Reachability.getConnectionType() != .none,
                await confirmExternalSourceRestore(keys: missingSourceKeys)
            {
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = true
                    UIApplication.shared.appDelegate?.showLoadingIndicator(
                        style: .progress,
                        message: NSLocalizedString("INSTALLING_SOURCES")
                    )
                }

                var installedSourceKeys: Set<String> = []

                if let (installedSourceKeyStream, total) = await SourceManager.shared.installExternalSources(keys: missingSourceKeys) {
                    var current = 0
                    for await key in installedSourceKeyStream {
                        current += 1
                        installedSourceKeys.insert(key)
                        await UIApplication.shared.appDelegate?.updateLoadingIndicator(
                            progress: Float(current - 1) / Float(total)
                        )
                    }
                }

                await restoreSettings(from: backup, sourceKeys: installedSourceKeys)

                await Task { @MainActor in
                    let appDelegate = UIApplication.shared.appDelegate
                    appDelegate?.updateLoadingIndicator(progress: 1)
                    await appDelegate?.hideLoadingIndicator()
                    UIApplication.shared.isIdleTimerDisabled = false
                }.value
            }
        }

        NotificationCenter.default.post(name: .updateHistory, object: nil)
        NotificationCenter.default.post(name: .updateTrackers, object: nil)
        NotificationCenter.default.post(name: .updateCategories, object: nil)
        NotificationCenter.default.post(name: .updateLibrary, object: nil)

        let backupSourceKeys = backup.sources?.map { $0.id } ?? []
        let missingSourceKeys = await SourceManager.shared.missingExternalSourceKeys(in: Set(backupSourceKeys))

        await Task { @MainActor [backupError] in
            if let backupError {
                Self.presentRestoreError((backupError as? BackupError)?.stringValue ?? NSLocalizedString("UNKNOWN"))
            } else if !missingSourceKeys.isEmpty {
                UIApplication.shared.appDelegate?.presentAlert(
                    title: NSLocalizedString("MISSING_SOURCES"),
                    message: NSLocalizedString("MISSING_SOURCES_TEXT") + missingSourceKeys.map { "\n\($0)" }.joined()
                )
            }
        }.value

        return backupError == nil
    }

    private func restoreSettings(from backup: Backup, sourceKeys: Set<String>? = nil) async {
        guard let settings = backup.settings else { return }

        let sourceKeyPrefixes: [String]
        if let sourceKeys {
            sourceKeyPrefixes = sourceKeys.map { "\($0)." }
        } else {
            // only restore source settings for sources installed, or built-in sources that will be added from the backup restore
            let sources = await SourceManager.shared.getSourceInfos(sorted: false)
            sourceKeyPrefixes = sources.map { "\($0.sourceId)." } + (backup.sources ?? []).compactMap {
                $0.config == nil ? nil : "\($0.id)."
            }
        }

        var needsMigrate = false

        for (key, value) in settings {
            let hasAllowedPrefix = (sourceKeys == nil && Self.allowedSettingsPrefixes.contains { key.hasPrefix($0) })
                || sourceKeyPrefixes.contains { key.hasPrefix($0) }
            guard
                hasAllowedPrefix,
                !Self.excludedSettings.contains(key),
                !Self.excludedSettingsPrefixes.contains(where: { key.hasPrefix($0) })
            else {
                continue
            }
            UserDefaults.standard.set(value.toRaw(), forKey: key)
            if AppDelegate.legacySettingKeys.contains(key) {
                needsMigrate = true
            }
        }

        if needsMigrate {
            await MainActor.run {
                UIApplication.shared.appDelegate?.migrateSettings()
            }
        }
    }

    private func confirmExternalSourceRestore(keys: Set<String>) async -> Bool {
        let message = NSLocalizedString("RESTORE_MISSING_SOURCES_TEXT") + keys.sorted().map { "\n\($0)" }.joined()

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard
                    let delegate = UIApplication.shared.appDelegate,
                    delegate.topViewController != nil
                else {
                    continuation.resume(returning: false)
                    return
                }
                delegate.presentAlert(
                    title: NSLocalizedString("RESTORE_MISSING_SOURCES"),
                    message: message,
                    actions: [
                        UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel) { _ in
                            continuation.resume(returning: false)
                        },
                        UIAlertAction(title: NSLocalizedString("INSTALL_SOURCES"), style: .default) { _ in
                            continuation.resume(returning: true)
                        }
                    ]
                )
            }
        }
    }
}

// MARK: Automatic Backups
extension BackupManager {
    nonisolated func register() {
#if !targetEnvironment(simulator)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backupTaskIdentifier, using: nil) { @Sendable [weak self] task in
            guard let self, let task = task as? BGProcessingTask else { return }

            let work = Task { @Sendable in
                let success = await self.createAutoBackup()
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = { work.cancel() }
        }
#endif
    }

    nonisolated static func autoBackupInterval(for value: String) -> TimeInterval? {
        switch value {
            case "6hours": 21600
            case "12hours": 43200
            case "daily": 86400
            case "2days": 172800
            case "weekly": 604800
            default: nil
        }
    }

    private var nextAutoBackupDate: Date? {
        let settings = AppSettings.backups.autoBackups
        guard settings.enabled.get(), let interval = Self.autoBackupInterval(for: settings.interval.get()) else { return nil }
        return settings.lastBackup.get() + interval
    }

    func scheduleAutoBackup() {
        guard let nextUpdateTime = nextAutoBackupDate else {
#if !targetEnvironment(simulator)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backupTaskIdentifier)
#endif
            return
        }
        if nextUpdateTime <= Date.now {
            // interval time has passed, create auto backup now
            Task {
                await createAutoBackup()
            }
        } else {
#if !targetEnvironment(simulator)
            // schedule task for the future
            let request = BGProcessingTaskRequest(identifier: Self.backupTaskIdentifier)
            request.earliestBeginDate = nextUpdateTime
            request.requiresExternalPower = false
            request.requiresNetworkConnectivity = false

            Task {
                do {
                    try await BGTaskScheduler.shared.submit(request: request)
                } catch {
                    LogManager.logger.error("Could not schedule automatic backup: \(error)")
                }
            }
#endif
        }
    }

    // A previously submitted request may arrive after a foreground backup or a settings restore.
    func performAutoBackupIfDue(_ operation: () async -> Bool) async -> Bool {
        guard !isCreatingAutoBackup else { return false }
        isCreatingAutoBackup = true
        defer { isCreatingAutoBackup = false }
        return await withExclusiveDataAccess {
            guard let due = nextAutoBackupDate, due <= Date.now else { return true }
            return await operation()
        }
    }

    @discardableResult
    private func createAutoBackup() async -> Bool {
        let handled = await performAutoBackupIfDue { await saveAutoBackup() }
        if handled { scheduleAutoBackup() }
        return handled
    }

    private func saveAutoBackup() async -> Bool {
        let libraryEntries = AppSettings.backups.autoBackups.libraryEntries.get()
        let history = AppSettings.backups.autoBackups.history.get()
        let chapters = AppSettings.backups.autoBackups.chapters.get()
        let tracking = AppSettings.backups.autoBackups.tracking.get()
        let readingSessions = AppSettings.backups.autoBackups.readingSessions.get()
        let vocabulary = AppSettings.backups.autoBackups.vocabulary.get()
        let updates = AppSettings.backups.autoBackups.updates.get()
        let categories = AppSettings.backups.autoBackups.categories.get()
        let settings = AppSettings.backups.autoBackups.settings.get()
        let sourceLists = AppSettings.backups.autoBackups.sourceLists.get()
        let sensitiveSettings = AppSettings.backups.autoBackups.sensitiveSettings.get()

        let saved = await saveSnapshot(
            options: .init(
                automatic: true,
                libraryEntries: libraryEntries,
                history: history,
                chapters: chapters,
                tracking: tracking,
                readingSessions: readingSessions,
                vocabulary: vocabulary,
                updates: updates,
                categories: categories,
                settings: settings,
                sourceLists: sourceLists,
                sensitiveSettings: sensitiveSettings
            )
        )

        guard saved else { return false }

        // update last auto backup time
        AppSettings.backups.autoBackups.lastBackup.set(Date.now)

        cleanUpAutoBackups()
        return true
    }

    // ensure we keep only the latest maxAutoBackups automatic backups
    private func cleanUpAutoBackups() {
        var autoBackups: [BackupInfo] = []
        for backupUrl in Self.backupUrls {
            let backup = BackupInfo.load(from: backupUrl)
            if let backup, backup.automatic {
                autoBackups.append(backup)
            }
        }
        while autoBackups.count > Self.maxAutoBackups {
            let oldestBackup = autoBackups
                .min { $0.date < $1.date }
            if let oldestBackup {
                removeBackup(url: oldestBackup.url)
                autoBackups.removeAll { $0.url == oldestBackup.url }
            } else {
                break
            }
        }
    }
}
