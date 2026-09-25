// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

struct TranslationCacheConfiguration: Codable, Equatable, Sendable {
    static let minimumSizeMiB = 1
    static let maximumSizeMiB = 1_024
    static let defaultSizeMiB = 10

    var memoryEnabled: Bool
    var diskEnabled: Bool
    var maxSizeMiB: Int

    init(
        memoryEnabled: Bool = true,
        diskEnabled: Bool = true,
        maxSizeMiB: Int = Self.defaultSizeMiB
    ) {
        self.memoryEnabled = memoryEnabled
        self.diskEnabled = diskEnabled
        self.maxSizeMiB = maxSizeMiB
    }

    func validatedMaximumBytes() throws -> Int {
        guard (Self.minimumSizeMiB...Self.maximumSizeMiB).contains(maxSizeMiB)
        else {
            throw TranslationCacheError.invalidSizeMiB(maxSizeMiB)
        }
        return maxSizeMiB * 1024 * 1024
    }

}

enum TranslationCacheStorageNamespace: String, CaseIterable, Sendable {
    case browserApplication = "browser-app"
}

struct TranslationCacheStatistics: Equatable, Sendable {
    let memoryEntries: Int
    let memoryBytes: Int
    let diskEntries: Int
    let diskBytes: Int
    let memoryHits: UInt64
    let diskHits: UInt64
    let misses: UInt64
    let evictions: UInt64
    let pendingDiskWrites: Int
    let lastPersistenceFailure: String?
}

struct CachedTranslation: Equatable, Sendable {
    let translations: [RemoteTranslatedSegment]
    let source: TranslationResultSource
}

struct TranslationCacheLookup: Sendable {
    let value: CachedTranslation?
    let storageGeneration: UInt64
}

enum TranslationCacheError: Error, Equatable, LocalizedError {
    case invalidSizeMiB(Int)
    case invalidStorageRoot
    case unsafeStorageObject
    case encodingFailure
    case persistenceFailure

    var errorDescription: String? {
        switch self {
        case .invalidSizeMiB:
            NSLocalizedString("TRANSLATION_ERROR_CACHE_SIZE")
        case .invalidStorageRoot, .unsafeStorageObject:
            NSLocalizedString("TRANSLATION_ERROR_CACHE_STORAGE")
        case .encodingFailure, .persistenceFailure:
            NSLocalizedString("TRANSLATION_ERROR_CACHE_SAVE")
        }
    }
}

actor TranslationCache {
    private struct MemoryEntry {
        let translations: [RemoteTranslatedSegment]
        let chargeBytes: Int
        var previous: TranslationCacheKey?
        var next: TranslationCacheKey?
    }

    private(set) var configuration: TranslationCacheConfiguration
    private let storageRootURL: URL
    private var maximumBytes: Int
    private var memoryEntries: [TranslationCacheKey: MemoryEntry] = [:]
    private var memoryBytes = 0
    private var oldestMemoryKey: TranslationCacheKey?
    private var newestMemoryKey: TranslationCacheKey?
    private var diskStore: TranslationDiskStore?
    private var pendingDiskWrites:
        [TranslationCacheKey: [RemoteTranslatedSegment]] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var memoryHits: UInt64 = 0
    private var diskHits: UInt64 = 0
    private var misses: UInt64 = 0
    private var evictions: UInt64 = 0
    private var lastPersistenceFailure: String?
    private var storageGeneration: UInt64 = 0

    init(
        configuration: TranslationCacheConfiguration = .init(),
        storageRootURL: URL? = nil,
        storageNamespace: TranslationCacheStorageNamespace = .browserApplication,
        storageScope: String? = nil
    ) throws {
        let maximumBytes = try configuration.validatedMaximumBytes()
        let root = storageRootURL ?? Self.defaultStorageRootURL()
        guard root.isFileURL else {
            throw TranslationCacheError.invalidStorageRoot
        }
        if let storageScope {
            guard Self.isSafeStorageScope(storageScope) else {
                throw TranslationCacheError.invalidStorageRoot
            }
        }
        self.configuration = configuration
        let namespacedRoot = root
            .appendingPathComponent(
                storageNamespace.rawValue,
                isDirectory: true
            )
            .standardizedFileURL
        self.storageRootURL = storageScope.map {
            namespacedRoot.appendingPathComponent($0, isDirectory: true)
                .standardizedFileURL
        } ?? namespacedRoot
        self.maximumBytes = maximumBytes
        if configuration.diskEnabled {
            diskStore = try TranslationDiskStore(
                storageRootURL: self.storageRootURL,
                maximumBytes: maximumBytes
            )
        }
    }

    deinit {
        persistenceTask?.cancel()
    }

    func value(for key: TranslationCacheKey) throws -> CachedTranslation? {
        try resolvedValue(for: key, recordsMiss: true)
    }

    /// Looks up a value for first-paint hydration. A miss is intentionally not
    /// counted because the ordinary translation path will perform the
    /// authoritative lookup immediately afterward. Hits remain real cache
    /// hits and are counted normally.
    func valueIfPresent(
        for key: TranslationCacheKey
    ) throws -> CachedTranslation? {
        try resolvedValue(for: key, recordsMiss: false)
    }

    private func resolvedValue(
        for key: TranslationCacheKey,
        recordsMiss: Bool
    ) throws -> CachedTranslation? {
        if configuration.memoryEnabled, let entry = memoryEntries[key] {
            if !cachedTranslationsAreValid(entry.translations, for: key) {
                removeMemoryEntry(key)
            } else {
                promoteMemoryEntry(key)
                memoryHits &+= 1
                return CachedTranslation(
                    translations: entry.translations,
                    source: .memoryCache
                )
            }
        }

        if configuration.diskEnabled {
            if let pending = pendingDiskWrites[key] {
                diskHits &+= 1
                if configuration.memoryEnabled {
                    insertIntoMemory(pending, for: key)
                }
                return CachedTranslation(
                    translations: pending,
                    source: .diskCache
                )
            }
            if let persisted = try diskStore?.value(for: key) {
                diskHits &+= 1
                if configuration.memoryEnabled {
                    insertIntoMemory(persisted, for: key)
                }
                return CachedTranslation(
                    translations: persisted,
                    source: .diskCache
                )
            }
        }

        if recordsMiss {
            misses &+= 1
        }
        return nil
    }

    /// Returns the cache result and the storage generation observed by that
    /// lookup. A provider result carries this lease back to `insert`, which
    /// prevents pre-purge work from refilling a freshly purged cache.
    func lookup(for key: TranslationCacheKey) -> TranslationCacheLookup {
        TranslationCacheLookup(
            value: try? value(for: key),
            storageGeneration: storageGeneration
        )
    }

    /// Updates every enabled cache tier before returning. A successful
    /// provider response must cross this durability boundary before callers
    /// can treat it as complete; otherwise force-quitting the app during the
    /// former debounce window could lose an apparently cached translation.
    /// Failed writes remain queued and retry in the background while the valid
    /// memory result stays available.
    func insert(
        _ translations: [RemoteTranslatedSegment],
        for key: TranslationCacheKey,
        admittedStorageGeneration: UInt64? = nil
    ) {
        if let admittedStorageGeneration,
           admittedStorageGeneration != storageGeneration
        {
            return
        }
        guard cachedTranslationsAreValid(translations, for: key) else { return }
        if configuration.memoryEnabled {
            insertIntoMemory(translations, for: key)
        }
        if configuration.diskEnabled {
            pendingDiskWrites[key] = translations
            do {
                try persistPendingDiskWrites()
                lastPersistenceFailure = nil
            } catch {
                lastPersistenceFailure =
                    "translation cache persistence failed"
                schedulePersistence()
            }
        }
    }

    /// Stop accumulating new provider results after persistent storage failure
    /// exhausts the pending-result budget. Existing answers remain readable.
    /// This is a failure circuit breaker, not a hard cap on already admitted work.
    func ensureProviderPersistenceAdmission() throws {
        try Task.checkCancellation()
        guard configuration.diskEnabled, lastPersistenceFailure != nil else { return }
        // Only the failure path measures pending results. Healthy translation
        // avoids another JSON encoding and keeps its existing persistence path.
        var remainingBytes = maximumBytes
        for (key, translations) in pendingDiskWrites {
            let charge: Int
            do {
                charge = try translationEntryCharge(key: key, translations: translations)
            } catch {
                throw TranslationCacheError.persistenceFailure
            }
            if charge >= remainingBytes {
                // Retry actual persistence before denying admission, so repaired
                // storage can recover without an app restart or dropping data.
                do {
                    try persistPendingDiskWrites()
                    lastPersistenceFailure = nil
                } catch {
                    schedulePersistence()
                    throw TranslationCacheError.persistenceFailure
                }
                return
            }
            remainingBytes -= charge
        }
    }

    func reconfigure(_ next: TranslationCacheConfiguration) throws {
        let nextMaximumBytes = try next.validatedMaximumBytes()
        persistenceTask?.cancel()
        persistenceTask = nil
        do {
            if configuration.diskEnabled {
                try persistPendingDiskWrites()
            }

            // Complete fallible storage work before publishing configuration or
            // dropping the old memory tier. A failed disk enable must not leave
            // diskEnabled=true with no store (which silently loses new results).
            let nextDiskStore: TranslationDiskStore?
            if next.diskEnabled {
                if let diskStore {
                    evictions &+= UInt64(try diskStore.setMaximumBytes(nextMaximumBytes))
                    nextDiskStore = diskStore
                } else {
                    nextDiskStore = try TranslationDiskStore(
                        storageRootURL: storageRootURL,
                        maximumBytes: nextMaximumBytes
                    )
                }
            } else {
                try diskStore?.clear()
                nextDiskStore = nil
            }

            diskStore = nextDiskStore
            maximumBytes = nextMaximumBytes
            configuration = next
            if !next.memoryEnabled {
                clearMemoryEntries()
            }
            trimMemoryToBudget()
            if !next.diskEnabled {
                pendingDiskWrites.removeAll(keepingCapacity: false)
            }
            lastPersistenceFailure = nil
        } catch {
            // Reconfiguration must not cancel the only retry for an existing
            // valid result when storage is temporarily unavailable.
            if !pendingDiskWrites.isEmpty { schedulePersistence() }
            throw error
        }
    }

    /// Explicit durability boundary for scene backgrounding and orderly exit.
    func flush() throws {
        persistenceTask?.cancel()
        persistenceTask = nil
        try persistPendingDiskWrites()
        lastPersistenceFailure = nil
    }

    func clear(memory: Bool = true, disk: Bool = true) throws {
        if memory {
            clearMemoryEntries()
        }
        if disk {
            persistenceTask?.cancel()
            persistenceTask = nil
            pendingDiskWrites.removeAll(keepingCapacity: false)
            try diskStore?.clear()
        }
    }

    /// Clears every managed cache record, including persistent records left
    /// from an earlier configuration where disk caching was enabled.
    ///
    /// `clear(disk:)` deliberately operates only on the currently configured
    /// disk tier so it remains cheap for memory-pressure handling. An explicit
    /// user purge has stronger semantics and must inspect the namespace even
    /// when that tier is currently disabled.
    func purgeAll() throws {
        storageGeneration &+= 1
        persistenceTask?.cancel()
        persistenceTask = nil
        pendingDiskWrites.removeAll(keepingCapacity: false)
        clearMemoryEntries()

        if let diskStore {
            try diskStore.clear()
        } else {
            let persistentStore = try TranslationDiskStore(
                storageRootURL: storageRootURL,
                maximumBytes: maximumBytes
            )
            try persistentStore.clear()
        }
        lastPersistenceFailure = nil
    }

    func statistics() -> TranslationCacheStatistics {
        TranslationCacheStatistics(
            memoryEntries: memoryEntries.count,
            memoryBytes: memoryBytes,
            diskEntries: diskStore?.entryCount ?? 0,
            diskBytes: diskStore?.usedBytes ?? 0,
            memoryHits: memoryHits,
            diskHits: diskHits,
            misses: misses,
            evictions: evictions,
            pendingDiskWrites: pendingDiskWrites.count,
            lastPersistenceFailure: lastPersistenceFailure
        )
    }

    private static func defaultStorageRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport.appendingPathComponent("ReaderTranslation", isDirectory: true)
    }

    private static func isSafeStorageScope(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) ||
                $0 == "-" || $0 == "_"
        }
    }

    private func insertIntoMemory(
        _ translations: [RemoteTranslatedSegment],
        for key: TranslationCacheKey
    ) {
        guard let chargeBytes = try? translationEntryCharge(
            key: key,
            translations: translations
        ), chargeBytes <= maximumBytes else {
            removeMemoryEntry(key)
            return
        }
        removeMemoryEntry(key)
        memoryEntries[key] = MemoryEntry(
            translations: translations,
            chargeBytes: chargeBytes,
            previous: newestMemoryKey
        )
        if let newestMemoryKey { memoryEntries[newestMemoryKey]?.next = key }
        else { oldestMemoryKey = key }
        newestMemoryKey = key
        memoryBytes += chargeBytes
        trimMemoryToBudget()
    }

    // Keep an explicit LRU chain: eviction must not scan all cached translations
    // for each victim when a large response arrives or the budget shrinks.
    private func unlinkMemoryEntry(_ entry: MemoryEntry) {
        if let previous = entry.previous { memoryEntries[previous]?.next = entry.next }
        else { oldestMemoryKey = entry.next }
        if let next = entry.next { memoryEntries[next]?.previous = entry.previous }
        else { newestMemoryKey = entry.previous }
    }

    private func promoteMemoryEntry(_ key: TranslationCacheKey) {
        guard newestMemoryKey != key, var entry = memoryEntries[key] else { return }
        unlinkMemoryEntry(entry)
        entry.previous = newestMemoryKey
        entry.next = nil
        if let newestMemoryKey { memoryEntries[newestMemoryKey]?.next = key }
        memoryEntries[key] = entry
        newestMemoryKey = key
    }

    private func removeMemoryEntry(_ key: TranslationCacheKey) {
        guard let entry = memoryEntries.removeValue(forKey: key) else { return }
        unlinkMemoryEntry(entry)
        memoryBytes -= entry.chargeBytes
    }

    private func clearMemoryEntries() {
        memoryEntries.removeAll(keepingCapacity: false)
        oldestMemoryKey = nil
        newestMemoryKey = nil
        memoryBytes = 0
    }

    private func trimMemoryToBudget() {
        while memoryBytes > maximumBytes, let oldestMemoryKey {
            removeMemoryEntry(oldestMemoryKey)
            evictions &+= 1
        }
    }

    private func schedulePersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushInBackground()
        }
    }

    private func flushInBackground() {
        persistenceTask = nil
        do {
            try persistPendingDiskWrites()
            lastPersistenceFailure = nil
        } catch {
            // Do not include paths, OCR text, translations, or provider data in
            // diagnostics exposed to settings.
            lastPersistenceFailure = "translation cache persistence failed"
            if !pendingDiskWrites.isEmpty {
                schedulePersistence()
            }
        }
    }

    private func persistPendingDiskWrites() throws {
        guard configuration.diskEnabled, let diskStore else {
            pendingDiskWrites.removeAll(keepingCapacity: false)
            return
        }
        let snapshot = pendingDiskWrites.sorted {
            stableCacheFileName(for: $0.key) < stableCacheFileName(for: $1.key)
        }
        for (key, translations) in snapshot {
            do {
                let result = try diskStore.put(translations, for: key)
                evictions &+= UInt64(result.evictions)
                if pendingDiskWrites[key] == translations {
                    pendingDiskWrites.removeValue(forKey: key)
                }
            } catch {
                lastPersistenceFailure = "translation cache persistence failed"
                throw error
            }
        }
    }
}

private final class TranslationDiskStore {
    private struct Metadata {
        let fileURL: URL
        let byteCount: Int
        let modifiedAt: Date
    }

    private struct PersistentRecord: Codable {
        let version: Int
        let key: TranslationCacheKey
        let translations: [RemoteTranslatedSegment]
    }

    struct PutResult {
        let accepted: Bool
        let evictions: Int
    }

    static let directoryName = "translation-cache-v1"
    static let recordVersion = 2

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private var maximumBytes: Int
    private var entries: [TranslationCacheKey: Metadata] = [:]
    private var fileOwners: [String: TranslationCacheKey] = [:]
    private(set) var usedBytes = 0

    var entryCount: Int { entries.count }

    init(storageRootURL: URL, maximumBytes: Int) throws {
        self.maximumBytes = maximumBytes
        directoryURL = storageRootURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .standardizedFileURL
        try prepareDirectory(storageRootURL)
        try prepareDirectory(directoryURL)
        try loadIndex()
        _ = try trimToBudget()
    }

    func value(
        for key: TranslationCacheKey
    ) throws -> [RemoteTranslatedSegment]? {
        guard let metadata = entries[key] else { return nil }
        guard try isSafeRegularFile(metadata.fileURL),
              metadata.byteCount <= maximumBytes
        else {
            try remove(key)
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: metadata.fileURL, options: [.mappedIfSafe])
        } catch {
            try remove(key)
            return nil
        }
        guard data.count == metadata.byteCount,
              let record = try? JSONDecoder().decode(PersistentRecord.self, from: data),
              record.version == Self.recordVersion,
              record.key == key,
              cachedTranslationsAreValid(record.translations, for: key)
        else {
            try remove(key)
            return nil
        }

        let now = Date()
        do {
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: metadata.fileURL.path
            )
            entries[key] = Metadata(
                fileURL: metadata.fileURL,
                byteCount: metadata.byteCount,
                modifiedAt: now
            )
        } catch {
            // A valid cache hit remains usable even if its best-effort LRU
            // touch cannot be persisted.
        }
        return record.translations
    }

    func put(
        _ translations: [RemoteTranslatedSegment],
        for key: TranslationCacheKey
    ) throws -> PutResult {
        let record = PersistentRecord(
            version: Self.recordVersion,
            key: key,
            translations: translations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw TranslationCacheError.encodingFailure
        }
        guard data.count <= maximumBytes else {
            try remove(key)
            return PutResult(accepted: false, evictions: 0)
        }

        let fileName = stableCacheFileName(for: key)
        if let owner = fileOwners[fileName], owner != key {
            // Two independent hashes plus the encoded length make this
            // fantastically unlikely, but exact cache correctness wins over
            // overwriting a different key.
            throw TranslationCacheError.unsafeStorageObject
        }
        let target = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        if fileManager.fileExists(atPath: target.path),
           try !isSafeRegularFile(target)
        {
            throw TranslationCacheError.unsafeStorageObject
        }

        let previousSize = entries[key]?.byteCount ?? 0
        var evictions = 0
        while usedBytes - previousSize + data.count > maximumBytes {
            guard let victim = leastRecentlyUsed(excluding: key) else {
                return PutResult(accepted: false, evictions: evictions)
            }
            try remove(victim)
            evictions += 1
        }

        var options: Data.WritingOptions = [.atomic]
#if os(iOS)
        options.insert(.completeFileProtection)
#endif
        do {
            try data.write(to: target, options: options)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableTarget = target
            try? mutableTarget.setResourceValues(resourceValues)
        } catch {
            throw TranslationCacheError.persistenceFailure
        }

        if let previous = entries.removeValue(forKey: key) {
            usedBytes -= previous.byteCount
            fileOwners.removeValue(forKey: previous.fileURL.lastPathComponent)
        }
        let metadata = Metadata(
            fileURL: target,
            byteCount: data.count,
            modifiedAt: Date()
        )
        entries[key] = metadata
        fileOwners[fileName] = key
        usedBytes += data.count
        return PutResult(accepted: true, evictions: evictions)
    }

    func setMaximumBytes(_ value: Int) throws -> Int {
        let previousMaximumBytes = maximumBytes
        maximumBytes = value
        do {
            return try trimToBudget()
        } catch {
            maximumBytes = previousMaximumBytes
            throw error
        }
    }

    func clear() throws {
        let managedURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { isManagedRecordName($0.lastPathComponent) }
        for url in managedURLs {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw TranslationCacheError.persistenceFailure
            }
        }
        entries.removeAll(keepingCapacity: false)
        fileOwners.removeAll(keepingCapacity: false)
        usedBytes = 0
    }

    private func loadIndex() throws {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TranslationCacheError.persistenceFailure
        }
        for url in urls where isManagedRecordName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isSymbolicLink != true,
                  values?.isRegularFile == true,
                  let fileSize = values?.fileSize,
                  fileSize > 0,
                  fileSize <= maximumBytes,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count == fileSize,
                  let record = try? JSONDecoder().decode(PersistentRecord.self, from: data),
                  record.version == Self.recordVersion,
                  stableCacheFileName(for: record.key) == url.lastPathComponent,
                  cachedTranslationsAreValid(
                      record.translations,
                      for: record.key
                  )
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            let metadata = Metadata(
                fileURL: url,
                byteCount: fileSize,
                modifiedAt: modifiedAt
            )
            entries[record.key] = metadata
            fileOwners[url.lastPathComponent] = record.key
            usedBytes += fileSize
        }
    }

    private func trimToBudget() throws -> Int {
        var evictions = 0
        while usedBytes > maximumBytes, let victim = leastRecentlyUsed(excluding: nil) {
            try remove(victim)
            evictions += 1
        }
        return evictions
    }

    private func leastRecentlyUsed(
        excluding excluded: TranslationCacheKey?
    ) -> TranslationCacheKey? {
        entries
            .filter { $0.key != excluded }
            .min { left, right in
                if left.value.modifiedAt == right.value.modifiedAt {
                    return left.value.fileURL.lastPathComponent <
                        right.value.fileURL.lastPathComponent
                }
                return left.value.modifiedAt < right.value.modifiedAt
            }?
            .key
    }

    private func remove(_ key: TranslationCacheKey) throws {
        guard let metadata = entries[key] else { return }
        do {
            try fileManager.removeItem(at: metadata.fileURL)
        } catch {
            let error = error as NSError
            // Only confirmed absence completes eviction. fileExists can also
            // report false for an inaccessible ancestor, which is not removal.
            guard error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError else {
                // A failed eviction still occupies disk space. Keep its ownership
                // and byte charge so the next retry can remove the same record.
                throw TranslationCacheError.persistenceFailure
            }
        }
        entries.removeValue(forKey: key)
        fileOwners.removeValue(forKey: metadata.fileURL.lastPathComponent)
        usedBytes -= metadata.byteCount
    }

    private func prepareDirectory(_ url: URL) throws {
        guard url.isFileURL else {
            throw TranslationCacheError.invalidStorageRoot
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TranslationCacheError.unsafeStorageObject
            }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                throw TranslationCacheError.unsafeStorageObject
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw TranslationCacheError.persistenceFailure
            }
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func isSafeRegularFile(_ url: URL) throws -> Bool {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw TranslationCacheError.persistenceFailure
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

private func translationEntryCharge(
    key: TranslationCacheKey,
    translations: [RemoteTranslatedSegment]
) throws -> Int {
    let keyData: Data
    let translationData: Data
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        keyData = try encoder.encode(key)
        translationData = try encoder.encode(translations)
    } catch {
        throw TranslationCacheError.encodingFailure
    }
    let (payloadBytes, overflow) = keyData.count.addingReportingOverflow(
        translationData.count
    )
    guard !overflow else { throw TranslationCacheError.encodingFailure }
    let (chargedBytes, overheadOverflow) = payloadBytes.addingReportingOverflow(128)
    guard !overheadOverflow else { throw TranslationCacheError.encodingFailure }
    return chargedBytes
}

private func cachedTranslationsAreValid(
    _ translations: [RemoteTranslatedSegment],
    for key: TranslationCacheKey
) -> Bool {
    guard translations.count == key.segments.count else { return false }
    let expectedIDs = key.segments.map(\.id)
    var accepted = Set<String>()
    for translation in translations {
        guard expectedIDs.contains(translation.id),
              accepted.insert(translation.id).inserted,
              !translation.text.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              translation.text.utf8.count <=
                TranslationHTTPCodec.maximumTranslationBytes
        else {
            return false
        }
    }
    return accepted.count == expectedIDs.count
}

private func stableCacheFileName(for key: TranslationCacheKey) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(key)) ?? Data()
    var primary: UInt64 = 0xcbf29ce484222325
    var verifier: UInt64 = 0x9e3779b97f4a7c15
    for (index, byte) in data.enumerated() {
        primary ^= UInt64(byte)
        primary &*= 0x00000100000001b3
        verifier = (verifier << 7) | (verifier >> 57)
        verifier &+= UInt64(byte) &+ UInt64(index & 0xffff)
        verifier &*= 0x9e3779b185ebca87
    }
    return String(
        format: "%016llx-%016llx-%08x.json",
        primary,
        verifier,
        UInt32(truncatingIfNeeded: data.count)
    )
}

private func isManagedRecordName(_ value: String) -> Bool {
    guard value.hasSuffix(".json") else { return false }
    let stem = String(value.dropLast(5))
    let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
    guard pieces.count == 3,
          pieces[0].count == 16,
          pieces[1].count == 16,
          pieces[2].count == 8
    else {
        return false
    }
    return pieces.joined().unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
    }
}
