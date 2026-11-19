// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

struct CachedTranslation: Equatable, Sendable {
    let translations: [RemoteTranslatedSegment]
    let source: TranslationResultSource
}

struct TranslationCacheLookup: Sendable {
    let value: CachedTranslation?
    let storageGeneration: UInt64
}

enum TranslationCacheError: Error, Equatable, LocalizedError {
    case unsafeStorageObject
    case persistenceFailure

    var errorDescription: String? {
        switch self {
        case .unsafeStorageObject:
            NSLocalizedString("TRANSLATION_ERROR_CACHE_STORAGE")
        case .persistenceFailure:
            NSLocalizedString("TRANSLATION_ERROR_CACHE_SAVE")
        }
    }
}

/// In-memory LRU of provider batch results. `purgeAll` also deletes records
/// an earlier version persisted under `translation-cache-v1`.
actor TranslationCache {
    private struct MemoryEntry {
        let translations: [RemoteTranslatedSegment]
        let chargeBytes: Int
        var previous: TranslationCacheKey?
        var next: TranslationCacheKey?
    }

    private static let legacyDirectoryName = "translation-cache-v1"

    private let storageRootURL: URL
    private let maximumBytes: Int
    private var memoryEntries: [TranslationCacheKey: MemoryEntry] = [:]
    private var memoryBytes = 0
    private var oldestMemoryKey: TranslationCacheKey?
    private var newestMemoryKey: TranslationCacheKey?
    private var storageGeneration: UInt64 = 0

    init(maxSizeMiB: Int = 10, storageRootURL: URL? = nil) {
        let root = storageRootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first.map { $0.appendingPathComponent("ReaderTranslation", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ReaderTranslation", isDirectory: true)
        self.storageRootURL = root.appendingPathComponent("browser-app", isDirectory: true).standardizedFileURL
        self.maximumBytes = maxSizeMiB * 1024 * 1024
    }

    func value(for key: TranslationCacheKey) -> CachedTranslation? {
        guard let entry = memoryEntries[key] else { return nil }
        // Provider admission validates these immutable values.
        promoteMemoryEntry(key)
        return CachedTranslation(translations: entry.translations, source: .memoryCache)
    }

    /// Returns the cache result and the storage generation observed by that
    /// lookup. A provider result carries this lease back to `insert`, which
    /// prevents pre-purge work from refilling a freshly purged cache.
    func lookup(for key: TranslationCacheKey) -> TranslationCacheLookup {
        TranslationCacheLookup(value: value(for: key), storageGeneration: storageGeneration)
    }

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
        insertIntoMemory(translations, for: key)
    }

    /// Clears memory and every managed record left by the former disk tier.
    func purgeAll() throws {
        storageGeneration &+= 1
        clearMemoryEntries()
        let fileManager = FileManager.default
        let directoryURL = storageRootURL.appendingPathComponent(Self.legacyDirectoryName, isDirectory: true)
        for url in [storageRootURL, directoryURL] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue, values?.isDirectory == true, values?.isSymbolicLink != true else {
                throw TranslationCacheError.unsafeStorageObject
            }
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw TranslationCacheError.persistenceFailure
        }
        for url in urls where isManagedRecordName(url.lastPathComponent) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw TranslationCacheError.persistenceFailure
            }
        }
    }

    private func insertIntoMemory(
        _ translations: [RemoteTranslatedSegment],
        for key: TranslationCacheKey
    ) {
        guard let chargeBytes = translationEntryCharge(
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
    // for each victim when a large response arrives.
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
        }
    }
}

private func translationEntryCharge(
    key: TranslationCacheKey,
    translations: [RemoteTranslatedSegment]
) -> Int? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let keyData = try? encoder.encode(key),
          let translationData = try? encoder.encode(translations) else { return nil }
    let (payloadBytes, overflow) = keyData.count.addingReportingOverflow(
        translationData.count
    )
    guard !overflow else { return nil }
    let (chargedBytes, overheadOverflow) = payloadBytes.addingReportingOverflow(128)
    return overheadOverflow ? nil : chargedBytes
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
