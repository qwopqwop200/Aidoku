import CryptoKit
import Foundation
import SQLite3

/// Durable, byte-bounded LRU for OCR, translations and layout instructions.
/// File I/O, metadata decoding and eviction run on this actor, never on UIKit.
actor ReaderTranslationDiskCache {
    enum Kind: String, CaseIterable, Sendable { case ocr, translation, metadata, layout, snapshot }
    struct Statistics: Sendable {
        let bytes: Int64
        let payloadBytes: Int64
        let entries: Int
        let limit: Int64
    }
    static let maximumBytes: Int64 = 100_000_000_000
    static let defaultBytes: Int64 = 1_000_000_000
    static let limitChoices: [Int64] = [
        100_000_000, 200_000_000, 500_000_000,
        1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000, maximumBytes
    ]
    static let shared = ReaderTranslationDiskCache(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderTranslationCache-v1", isDirectory: true),
        byteLimit: (UserDefaults.standard.object(forKey: ReaderTranslationSettings.keyPrefix + "cacheLimitBytes") as? NSNumber)?.int64Value
            ?? defaultBytes,
        tracksSavedSettings: true
    )

    private let directory: URL
    private var byteLimit: Int64
    private var database: ReaderCacheDatabase?
    private var generation: UInt64 = 0
    private var metadataGeneration: UInt64 = 0
    private let tracksSavedSettings: Bool
    private var activePolicy: ReaderTranslationCachePolicy?
    private var pendingTouches: [String] = []
    private var touchFlushTask: Task<Void, Never>?

    deinit { touchFlushTask?.cancel() }

    private func recordRead(_ name: String) throws {
        pendingTouches.removeAll { $0 == name }
        pendingTouches.append(name)
        if pendingTouches.count >= 32 { try flushAccesses(); return }
        guard touchFlushTask == nil else { return }
        touchFlushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            try? await self?.flushAccesses()
        }
    }

    /// Reads coalesce metadata writes; content durability remains unchanged.
    /// Flush before mutations/eviction so in-process LRU order stays exact.
    func flushAccesses() throws {
        touchFlushTask?.cancel(); touchFlushTask = nil
        guard !pendingTouches.isEmpty, let database else { pendingTouches.removeAll(); return }
        try database.touch(pendingTouches)
        pendingTouches.removeAll()
    }

    init(directory: URL, byteLimit: Int64 = defaultBytes, tracksSavedSettings: Bool = false) {
        self.directory = directory
        self.tracksSavedSettings = tracksSavedSettings
        self.byteLimit = min(Self.maximumBytes, max(0, byteLimit))
    }

    func currentGeneration(settings: ReaderTranslationSettings? = nil, kind: Kind = .translation) -> UInt64 {
        if tracksSavedSettings { try? prepare() }
        let generation = storageGeneration(for: kind)
        // A queued request may still carry the old model even after invalidation.
        if let settings, let activePolicy {
            let requested = ReaderTranslationCachePolicy(settings)
            let matches = kind == .metadata
                ? requested.metadata == activePolicy.metadata
                : requested.translation == activePolicy.translation && requested.layout == activePolicy.layout
            if !matches { return generation &- 1 }
        }
        return generation
    }

    private func storageGeneration(for kind: Kind) -> UInt64 {
        kind == .metadata ? metadataGeneration : generation
    }

    func refreshSavedSettings() throws { try prepare() }

    func synchronizeSettings(_ settings: ReaderTranslationSettings) throws {
        try prepare()
        try applyPolicy(ReaderTranslationCachePolicy(settings))
    }

    private func applyPolicy(_ policy: ReaderTranslationCachePolicy) throws {
        guard activePolicy != policy, let database else { return }
        let changed = try database.applyPolicy(policy)
        if changed.page { generation &+= 1 }
        if changed.metadata { metadataGeneration &+= 1 }
        activePolicy = policy
    }

    func statistics() throws -> Statistics {
        try prepare()
        return Statistics(bytes: try database?.allocatedBytes() ?? 0,
                          payloadBytes: try database?.integer("SELECT bytes FROM totals") ?? 0,
                          entries: Int(try database?.integer("SELECT entries FROM totals") ?? 0), limit: byteLimit)
    }

    func setByteLimit(_ value: Int64) throws {
        byteLimit = min(Self.maximumBytes, max(0, value))
        try prepare()
        try trim()
    }

    func clear() throws {
        generation &+= 1
        metadataGeneration &+= 1
        activePolicy = nil
        touchFlushTask?.cancel(); touchFlushTask = nil
        pendingTouches.removeAll()
        database = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func data(for key: String, kind: Kind) throws -> Data? {
        try Task.checkCancellation()
        try prepare()
        let name = fileName(key, kind: kind)
        let data: Data
        do {
            guard let stored = try database?.data(name) else { return nil }
            data = stored
        } catch is DecodingError {
            try database?.delete(name)
            return nil
        }
        guard let unpacked = try? ReaderTranslationCacheCodec.unpack(data) else {
            try database?.delete(name)
            return nil
        }
        try recordRead(name)
        return unpacked
    }

    func markUsed(_ key: String, kind: Kind) throws {
        try prepare()
        try flushAccesses()
        try database?.touch(fileName(key, kind: kind))
    }

    func storeImageSize(_ size: CGSize, page: String, generation: UInt64) throws {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        try store(JSONEncoder().encode(size), for: "processed-image-size-v1-" + page, kind: .layout, generation: generation)
    }

    func imageSize(page: String) throws -> CGSize? {
        guard let data = try data(for: "processed-image-size-v1-" + page, kind: .layout),
              let size = try? JSONDecoder().decode(CGSize.self, from: data),
              size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        return size
    }

    func contains(_ key: String, kind: Kind) throws -> Bool {
        try prepare()
        return try database?.exists(fileName(key, kind: kind)) ?? false
    }

    /// Clear invalidates in-flight writers. A transaction preserves the previous entry on write failure.
    func store(_ data: Data, for key: String, kind: Kind, generation expected: UInt64) throws {
        try Task.checkCancellation()
        try prepare()
        guard storageGeneration(for: kind) == expected else { return }
        guard kind != .snapshot else { return }
        let name = fileName(key, kind: kind)
        let packed = ReaderTranslationCacheCodec.pack(data)
        guard Int64(packed.count) <= byteLimit, let database else { return }
        try flushAccesses()
        try database.store(packed, name: name)
        try trim()
    }

    func regions(for key: String, kind: Kind) throws -> [ReaderTranslationRegion]? {
        try Task.checkCancellation()
        try prepare()
        let name = fileName(key, kind: kind)
        guard let payload = try database?.payload(name) else { return nil }
        let regions: [ReaderTranslationRegion]
        do {
            if let base = payload.base {
                regions = try ReaderTranslationRegionArchive.regions(base: base, variant: payload.data)
            } else {
                let raw = try ReaderTranslationCacheCodec.unpack(payload.data)
                regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: raw).map(\.region)
            }
        } catch {
            try database?.delete(name)
            return nil
        }
        try recordRead(name)
        return regions
    }

    /// A legacy all-language translation can be narrowed without another OCR/API
    /// request. Never treat a filtered subset as a complete all-language page.
    func translatedRegions(page: String, settings: ReaderTranslationSettings) throws -> [ReaderTranslationRegion]? {
        let key = ReaderTranslationCacheIdentity.translation(page: page, settings: settings)
        if let cached = try regions(for: key, kind: .translation) { return cached }
        guard !settings.rightToLeftPanelOrder, ReaderTranslationLanguageFilter.identity(settings: settings) != nil,
              let cached = try regions(for: ReaderTranslationCacheIdentity.unfilteredTranslation(page: page, settings: settings),
                                       kind: .translation) else { return nil }
        let filtered = ReaderTranslationLanguageFilter.apply(cached, settings: settings)
        try Task.checkCancellation()
        try storeRegions(filtered, for: key, kind: .translation, generation: generation)
        return filtered
    }

    func storeRegions(_ regions: [ReaderTranslationRegion], for key: String, kind: Kind, generation: UInt64) throws {
        try Task.checkCancellation()
        try prepare()
        guard storageGeneration(for: kind) == generation else { return }
        if regions.isEmpty {
            try store(Data("[]".utf8), for: key, kind: kind, generation: generation)
            return
        }
        let archive = try ReaderTranslationRegionArchive(regions)
        guard Int64(archive.base.count + archive.variant.count) <= byteLimit else { return }
        try flushAccesses()
        try database?.store(archive.variant, name: fileName(key, kind: kind), base: archive.base)
        try trim()
    }

    func remove(_ key: String, kind: Kind) throws {
        try prepare()
        try database?.delete(fileName(key, kind: kind))
    }

    /// Upgrade old region records without changing their LRU order. Each row is atomic,
    /// so cancellation or a terminated app can resume without discarding translations.
    func compact() async throws {
        try prepare()
        guard let database else { return }
        var cursor = ""
        var processed = 0
        while let row = try database.nextLegacyRegion(after: cursor) {
            try Task.checkCancellation()
            cursor = row.name
            if let raw = try? ReaderTranslationCacheCodec.unpack(row.data),
               let regions = try? JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: raw),
               !regions.isEmpty,
               let archive = try? ReaderTranslationRegionArchive(regions.map(\.region)) {
                try database.store(archive.variant, name: row.name, base: archive.base, preservingAccess: true)
            }
            processed += 1
            if processed.isMultiple(of: 32) {
                try trim()
                await Task.yield()
                guard self.database === database else { return }
            }
        }
        // Existing variants/layouts upgrade in the background. Each UPDATE is
        // atomic and leaves source-base IDs, links and exact LRU order intact.
        if try database.integer("SELECT COUNT(*) FROM cache_policy WHERE name='payload-compression-v2'") == 0 {
            cursor = ""
            while let row = try database.nextCompressionCandidate(after: cursor) {
                try Task.checkCancellation()
                cursor = row.name
                if let packed = try? ReaderTranslationCacheCodec.repack(row.data), packed != row.data {
                    try database.replacePackedData(packed, name: row.name)
                }
                processed += 1
                if processed.isMultiple(of: 32) {
                    await Task.yield()
                    guard self.database === database else { return }
                }
            }
            try database.execute("INSERT OR IGNORE INTO cache_policy(name,value) VALUES('payload-compression-v2','1')")
        }
        // Base names remain the hash of the canonical ATZ1 bytes. Only their
        // stored payload changes, so existing links and future deduplication agree.
        if try database.integer("SELECT COUNT(*) FROM cache_policy WHERE name='base-compression-v2'") == 0 {
            cursor = ""
            while let row = try database.nextBaseCompressionCandidate(after: cursor) {
                try Task.checkCancellation()
                cursor = row.name
                if let packed = try? ReaderTranslationCacheCodec.repack(row.data), packed != row.data {
                    try database.replacePackedBase(packed, name: row.name)
                }
                processed += 1
                if processed.isMultiple(of: 32) {
                    await Task.yield()
                    guard self.database === database else { return }
                }
            }
            try Task.checkCancellation()
            // Shrinking BLOBs can leave space inside live B-tree pages that
            // auto_vacuum cannot release. Rebuild once, before marking complete;
            // SQLite keeps saved work intact and a failed rebuild retries later.
            try database.execute("VACUUM")
            try database.execute("INSERT OR IGNORE INTO cache_policy(name,value) VALUES('base-compression-v2','1')")
        }
        try trim()
    }

    private func prepare() throws {
        if database != nil {
            if tracksSavedSettings { try applyPolicy(ReaderTranslationCachePolicy(ReaderTranslationSettings())) }
            return
        }
        // An empty SQLite database needs a few pages. Below that, disable storage entirely.
        guard byteLimit >= ReaderCacheDatabase.minimumBytes else {
            try removeStorageFiles()
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let opened = try ReaderCacheDatabase(url: directory.appendingPathComponent("cache.sqlite"))
        try opened.importLegacy(directory: directory, byteLimit: byteLimit)
        try opened.separateLegacyMetadata()
        // Old full-page PNGs duplicate the original artwork. Retain all OCR,
        // translations and layouts so reopening never requires another API call.
        try opened.execute("DELETE FROM cache WHERE name GLOB 'snapshot-*'")
        try opened.optimizePageSize()
        database = opened
        activePolicy = nil
        if tracksSavedSettings { try applyPolicy(ReaderTranslationCachePolicy(ReaderTranslationSettings())) }
        try trim()
    }

    private func trim() throws {
        try flushAccesses()
        guard let database else { return }
        if byteLimit < ReaderCacheDatabase.minimumBytes {
            self.database = nil
            try removeStorageFiles()
            return
        }
        try database.trim(to: byteLimit)
    }

    private func removeStorageFiles() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            let legacy = name.hasSuffix(".cache") &&
                (Kind.allCases.contains { name.hasPrefix($0.rawValue + "-") } || name.hasPrefix("render-") || name.hasPrefix("renderIndex-"))
            if legacy || ["cache.sqlite", "cache.sqlite-journal", "cache.sqlite-wal", "cache.sqlite-shm"].contains(name) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func fileName(_ key: String, kind: Kind) -> String {
        kind.rawValue + "-" + ReaderTranslationCacheIdentity.digest(key) + ".cache"
    }
}

/// Accessed only by ReaderTranslationDiskCache's actor. SQLite owns the on-disk B-tree and bounded page cache.
private final class ReaderCacheDatabase: @unchecked Sendable {
    static let minimumBytes: Int64 = 65_536
    private var handle: OpaquePointer?
    private let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 5_000)
        // Compact text/layout BLOBs waste overflow pages in 4 KiB WITHOUT ROWID
        // tables. New databases use 1 KiB pages; existing ones migrate below.
        try execute("PRAGMA page_size=1024")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA auto_vacuum=FULL")
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA cache_size=-2048")
        try execute("CREATE TABLE IF NOT EXISTS cache (name TEXT PRIMARY KEY, data BLOB NOT NULL, accessed INTEGER NOT NULL) WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS cache_lru ON cache(accessed, name)")
        try execute("DROP INDEX IF EXISTS cache_snapshot_lru")
        try execute("CREATE TABLE IF NOT EXISTS totals (entries INTEGER NOT NULL, bytes INTEGER NOT NULL)")
        try execute("INSERT INTO totals SELECT 0, 0 WHERE NOT EXISTS (SELECT 1 FROM totals)")
        try execute("CREATE TRIGGER IF NOT EXISTS cache_insert AFTER INSERT ON cache BEGIN UPDATE totals SET entries=entries+1, bytes=bytes+length(new.data); END")
        try execute("CREATE TRIGGER IF NOT EXISTS cache_delete AFTER DELETE ON cache BEGIN UPDATE totals SET entries=entries-1, bytes=bytes-length(old.data); END")
        try execute("CREATE TRIGGER IF NOT EXISTS cache_update AFTER UPDATE OF data ON cache BEGIN UPDATE totals SET bytes=bytes+length(new.data)-length(old.data); END")
        try execute("CREATE TABLE IF NOT EXISTS cache_policy (name TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        try execute("CREATE TABLE IF NOT EXISTS region_bases (name TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID")
        try execute("CREATE TABLE IF NOT EXISTS region_links (name TEXT PRIMARY KEY REFERENCES cache(name) ON DELETE CASCADE, base TEXT NOT NULL REFERENCES region_bases(name)) WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS region_base_refs ON region_links(base)")
        try execute("CREATE TRIGGER IF NOT EXISTS region_base_insert AFTER INSERT ON region_bases BEGIN UPDATE totals SET bytes=bytes+length(new.data); END")
        try execute("CREATE TRIGGER IF NOT EXISTS region_base_update AFTER UPDATE OF data ON region_bases BEGIN UPDATE totals SET bytes=bytes+length(new.data)-length(old.data); END")
        try execute("CREATE TRIGGER IF NOT EXISTS region_base_delete AFTER DELETE ON region_bases BEGIN UPDATE totals SET bytes=bytes-length(old.data); END")
        try execute("CREATE TRIGGER IF NOT EXISTS region_unlink AFTER DELETE ON region_links BEGIN DELETE FROM region_bases WHERE name=old.base AND NOT EXISTS (SELECT 1 FROM region_links WHERE base=old.base); END")
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(handle) }

    func optimizePageSize() throws {
        let previous = try integer("PRAGMA page_size")
        guard previous != 1024 else { return }
        try execute("PRAGMA page_size=1024")
        do {
            // SQLite rebuilds atomically and preserves every key, BLOB, policy,
            // link and LRU timestamp. Its page cache remains bounded at 2 MiB.
            try execute("VACUUM")
        } catch {
            // Disk pressure or a busy reader must not turn saved work into a
            // cache miss. Keep using the original database and retry on reopen.
            try execute("PRAGMA page_size=\(previous)")
        }
    }

    private func failure() -> NSError {
        NSError(domain: "ReaderTranslationDiskCache.SQLite", code: Int(sqlite3_errcode(handle)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func statement<T>(_ sql: String, name: String? = nil, body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        if let name {
            guard sqlite3_bind_text(pointer, 1, name, -1, transient) == SQLITE_OK else { throw failure() }
        }
        return try body(pointer)
    }

    private func step(_ pointer: OpaquePointer) throws {
        guard sqlite3_step(pointer) == SQLITE_DONE else { throw failure() }
    }

    func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { pointer in
            guard sqlite3_step(pointer) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(pointer, 0)
        }
    }

    func exists(_ name: String) throws -> Bool {
        try statement("SELECT 1 FROM cache WHERE name=?", name: name) { pointer in
            let result = sqlite3_step(pointer)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
            return result == SQLITE_ROW
        }
    }

    func data(_ name: String) throws -> Data? {
        guard let payload = try payload(name) else { return nil }
        guard let base = payload.base else { return payload.data }
        // Keep data(for:) compatible without making normal region reads re-encode JSON.
        return try ReaderTranslationRegionArchive.restore(base: base, variant: payload.data)
    }

    func payload(_ name: String) throws -> (data: Data, base: Data?)? {
        try statement("SELECT cache.data, region_bases.data FROM cache LEFT JOIN region_links USING(name) LEFT JOIN region_bases ON region_bases.name=region_links.base WHERE cache.name=?", name: name) { pointer in
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return (blob(pointer, column: 0), sqlite3_column_type(pointer, 1) == SQLITE_NULL ? nil : blob(pointer, column: 1))
        }
    }

    private func blob(_ pointer: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(pointer, column))
        guard count > 0, let bytes = sqlite3_column_blob(pointer, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func nextLegacyRegion(after name: String) throws -> (name: String, data: Data)? {
        try statement("SELECT name,data FROM cache WHERE name>? AND (name LIKE 'ocr-%' OR name LIKE 'translation-%' OR name LIKE 'metadata-%') AND NOT EXISTS (SELECT 1 FROM region_links WHERE region_links.name=cache.name) ORDER BY name LIMIT 1", name: name) { pointer in
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return (String(cString: sqlite3_column_text(pointer, 0)), blob(pointer, column: 1))
        }
    }

    func nextCompressionCandidate(after name: String) throws -> (name: String, data: Data)? {
        try statement("SELECT name,data FROM cache WHERE name>? ORDER BY name LIMIT 1", name: name) { pointer in
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return (String(cString: sqlite3_column_text(pointer, 0)), blob(pointer, column: 1))
        }
    }

    func nextBaseCompressionCandidate(after name: String) throws -> (name: String, data: Data)? {
        try statement("SELECT name,data FROM region_bases WHERE name>? ORDER BY name LIMIT 1", name: name) { pointer in
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return (String(cString: sqlite3_column_text(pointer, 0)), blob(pointer, column: 1))
        }
    }

    func replacePackedBase(_ data: Data, name: String) throws {
        try statement("UPDATE region_bases SET data=?2 WHERE name=?1", name: name) { pointer in
            let result = data.withUnsafeBytes { sqlite3_bind_blob(pointer, 2, $0.baseAddress, Int32($0.count), transient) }
            guard result == SQLITE_OK else { throw failure() }
            try step(pointer)
        }
    }

    func replacePackedData(_ data: Data, name: String) throws {
        try statement("UPDATE cache SET data=?2 WHERE name=?1", name: name) { pointer in
            let result = data.withUnsafeBytes { sqlite3_bind_blob(pointer, 2, $0.baseAddress, Int32($0.count), transient) }
            guard result == SQLITE_OK else { throw failure() }
            try step(pointer)
        }
    }

    func touch(_ names: [String]) throws {
        // Keep the common newest-only read free of transaction/journal writes.
        guard names.count > 1 else { if let name = names.first { try touch(name) }; return }
        try execute("BEGIN IMMEDIATE")
        do {
            for name in names { try touch(name) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func touch(_ name: String) throws {
        // The newest entry already has the correct durable LRU position. Repeated
        // reads need no journal/fsync; alternating entries still persist exact order.
        try statement("UPDATE cache SET accessed=(SELECT COALESCE(MAX(accessed),0)+1 FROM cache) WHERE name=? AND name != (SELECT name FROM cache ORDER BY accessed DESC, name DESC LIMIT 1)", name: name, body: step)
    }

    func delete(_ name: String) throws {
        try statement("DELETE FROM cache WHERE name=?", name: name, body: step)
    }

    func store(_ data: Data, name: String, base: Data? = nil, preservingAccess: Bool = false) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let accessed: Int64? = preservingAccess ? try statement("SELECT accessed FROM cache WHERE name=?", name: name) { pointer in
                guard sqlite3_step(pointer) == SQLITE_ROW else { throw failure() }
                return sqlite3_column_int64(pointer, 0)
            } : nil
            try statement("DELETE FROM region_links WHERE name=?", name: name, body: step)
            try storeRow(data, name: name)
            if let accessed {
                try statement("UPDATE cache SET accessed=\(accessed) WHERE name=?", name: name, body: step)
            }
            if let base {
                let digest = ReaderTranslationCacheIdentity.digest(base)
                let packedBase = try ReaderTranslationCacheCodec.repack(base)
                try statement("INSERT OR IGNORE INTO region_bases(name,data) VALUES(?,?)", name: digest) { pointer in
                    let result = packedBase.withUnsafeBytes { sqlite3_bind_blob(pointer, 2, $0.baseAddress, Int32($0.count), transient) }
                    guard result == SQLITE_OK else { throw failure() }
                    try step(pointer)
                }
                try statement("INSERT INTO region_links(name,base) VALUES(?,?)", name: name) { pointer in
                    guard sqlite3_bind_text(pointer, 2, digest, -1, transient) == SQLITE_OK else { throw failure() }
                    try step(pointer)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func storeRow(_ data: Data, name: String, legacyAccess: Int64? = nil) throws {
        let sql = legacyAccess == nil
            ? "INSERT INTO cache(name,data,accessed) VALUES(?,?,(SELECT COALESCE(MAX(accessed),0)+1 FROM cache)) ON CONFLICT(name) DO UPDATE SET data=excluded.data, accessed=excluded.accessed"
            : "INSERT OR IGNORE INTO cache(name,data,accessed) VALUES(?,?,?)"
        try statement(sql, name: name) { pointer in
            let result = data.isEmpty ? sqlite3_bind_zeroblob(pointer, 2, 0) : data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(pointer, 2, bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard result == SQLITE_OK else { throw failure() }
            if let legacyAccess { sqlite3_bind_int64(pointer, 3, legacyAccess) }
            try step(pointer)
        }
    }

    /// Old metadata entries used the page namespace, but always contained one
    /// zero-sized "title" region. Move one row at a time, preserving bytes, bases
    /// and LRU order. Per-row commits make an interrupted upgrade resumable.
    func separateLegacyMetadata() throws {
        guard try integer("SELECT COUNT(*) FROM cache_policy WHERE name='metadata-kind-v1'") == 0 else { return }
        var cursor = "translation-"
        while let name = try statement("SELECT name FROM cache WHERE name>? AND name<'translation.' ORDER BY name LIMIT 1", name: cursor, body: { pointer -> String? in
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return String(cString: sqlite3_column_text(pointer, 0))
        }) {
            try Task.checkCancellation()
            cursor = name
            guard let payload = try payload(name),
                  let raw = try? ReaderTranslationCacheCodec.unpack(payload.base ?? payload.data),
                  let regions = try? JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: raw),
                  regions.count == 1, regions[0].id == "title", regions[0].rect == .zero else { continue }
            let destination = "metadata-" + name.dropFirst("translation-".count)
            try execute("BEGIN IMMEDIATE")
            do {
                if try !exists(destination) {
                    // Copy the link before deleting the old parent so its shared
                    // base remains referenced throughout the transaction.
                    for sql in [
                        "INSERT INTO cache(name,data,accessed) SELECT ?,data,accessed FROM cache WHERE name=?",
                        "INSERT INTO region_links(name,base) SELECT ?,base FROM region_links WHERE name=?"
                    ] {
                        try statement(sql, name: destination) { pointer in
                            guard sqlite3_bind_text(pointer, 2, name, -1, transient) == SQLITE_OK else { throw failure() }
                            try step(pointer)
                        }
                    }
                }
                try delete(name)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        try execute("INSERT INTO cache_policy(name,value) VALUES('metadata-kind-v1','1')")
    }

    /// The initial policy adopts existing records. Subsequent settings changes
    /// remove all obsolete translations/layouts, including their unreferenced bases.
    func applyPolicy(_ policy: ReaderTranslationCachePolicy) throws -> (page: Bool, metadata: Bool) {
        try execute("BEGIN IMMEDIATE")
        do {
            func previous(_ key: String) throws -> String? {
                try statement("SELECT value FROM cache_policy WHERE name=?", name: key) { pointer in
                    let result = sqlite3_step(pointer)
                    if result == SQLITE_DONE { return nil }
                    guard result == SQLITE_ROW else { throw failure() }
                    return String(cString: sqlite3_column_text(pointer, 0))
                }
            }
            let oldTranslation = try previous("translation")
            let oldLayout = try previous("layout")
            let oldMetadata = try previous("metadata")
            let translationChanged = oldTranslation != nil && oldTranslation != policy.translation
            let layoutChanged = oldLayout != nil && oldLayout != policy.layout
            let metadataChanged = oldMetadata != nil && oldMetadata != policy.metadata
            if translationChanged {
                try execute("DELETE FROM cache WHERE name LIKE 'translation-%' OR name LIKE 'layout-%' OR name LIKE 'snapshot-%'")
            } else if layoutChanged {
                try execute("DELETE FROM cache WHERE name LIKE 'layout-%' OR name LIKE 'snapshot-%'")
            }
            if metadataChanged { try execute("DELETE FROM cache WHERE name LIKE 'metadata-%'") }
            try statement("INSERT INTO cache_policy(name,value) VALUES('translation',?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", name: policy.translation, body: step)
            try statement("INSERT INTO cache_policy(name,value) VALUES('layout',?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", name: policy.layout, body: step)
            try statement("INSERT INTO cache_policy(name,value) VALUES('metadata',?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", name: policy.metadata, body: step)
            try execute("COMMIT")
            return (translationChanged || layoutChanged, metadataChanged)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func allocatedBytes() throws -> Int64 {
        var measured = url
        measured.removeAllCachedResourceValues()
        let values = try measured.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(max(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0, values.fileSize ?? 0))
    }

    func trim(to byteLimit: Int64) throws {
        // The indexed oldest row is O(log n); no in-memory directory inventory or full sort.
        // Batch deletions amortize commits and auto-vacuum while accounting for actual allocation.
        while try allocatedBytes() > byteLimit {
            let before = try integer("SELECT entries FROM totals")
            guard before > 0 else { break }
            let excess = try allocatedBytes() - byteLimit
            let payload = try integer("SELECT bytes FROM totals")
            let count = max(1, min(before, excess / max(1, payload / before)))
            try execute("DELETE FROM cache WHERE name IN (SELECT name FROM cache ORDER BY accessed, name LIMIT \(count))")
        }
    }

    func importLegacy(directory: URL, byteLimit: Int64) throws {
        guard try integer("PRAGMA user_version") == 0 else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                        options: [.skipsSubdirectoryDescendants]) else { return }
        var pending: [URL] = []
        func flush() throws {
            try execute("COMMIT")
            // Commit first: interruption before/during unlinking safely resumes with INSERT OR IGNORE.
            for file in pending { try FileManager.default.removeItem(at: file) }
            pending.removeAll(keepingCapacity: true)
            try trim(to: byteLimit)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for case let file as URL in files {
                try Task.checkCancellation()
                let name = file.lastPathComponent
                guard name.hasSuffix(".cache") else { continue }
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                if name.hasPrefix("render-") || name.hasPrefix("renderIndex-") || name.hasPrefix("snapshot-") {
                    try FileManager.default.removeItem(at: file)
                    continue
                }
                guard ReaderTranslationDiskCache.Kind.allCases.contains(where: { name.hasPrefix($0.rawValue + "-") }) else { continue }
                let data = ReaderTranslationCacheCodec.pack(try Data(contentsOf: file))
                let accessed = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000)
                if Int64(data.count) <= byteLimit { try storeRow(data, name: name, legacyAccess: accessed) }
                pending.append(file)
                if pending.count == 128 {
                    try flush()
                    try execute("BEGIN IMMEDIATE")
                }
            }
            try flush()
            try execute("PRAGMA user_version=1")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

}

struct ReaderTranslationStoredRegion: Codable {
    let id: String
    let rect: CGRect
    let source: String
    let translation: String?
    let polygon: [CGPoint]
    let confidence: Double
    let orientation: String
    let singleColumn: Bool?
    let auxiliaryInkRects: [CGRect]?
    let auxiliaryInkPolygons: [[CGPoint]]?
    let sourceImageAspectRatio: Double?
    let translationOrder: Int?
    let translationOrderVersion: String?
    let reuseKey: TranslationCacheKey?
    let reuseSegment: String?

    init(_ value: ReaderTranslationRegion) {
        id = value.id; rect = value.rect; source = value.source; translation = value.translation
        polygon = value.polygon; confidence = value.confidence; orientation = value.sourceOrientation.rawValue
        singleColumn = value.sourceSingleVerticalColumn
        auxiliaryInkRects = value.auxiliaryInkRects.isEmpty ? nil : value.auxiliaryInkRects
        auxiliaryInkPolygons = value.auxiliaryInkPolygons.isEmpty ? nil : value.auxiliaryInkPolygons
        sourceImageAspectRatio = value.sourceImageAspectRatio
        translationOrder = value.translationOrder
        translationOrderVersion = value.translationOrderVersion
        reuseKey = value.translationReuseIdentity?.cacheKey; reuseSegment = value.translationReuseIdentity?.segmentID
    }
    var region: ReaderTranslationRegion {
        var region = ReaderTranslationRegion(id: id, rect: rect, source: source, translation: translation, polygon: polygon,
                                             confidence: confidence, sourceOrientation: .init(tolerantRawValue: orientation),
                                             sourceSingleVerticalColumn: singleColumn)
        region.auxiliaryInkRects = auxiliaryInkRects ?? []
        region.auxiliaryInkPolygons = auxiliaryInkPolygons ?? []
        region.sourceImageAspectRatio = sourceImageAspectRatio
        region.translationOrder = translationOrder
        region.translationOrderVersion = translationOrderVersion
        if let reuseKey, let reuseSegment { region.translationReuseIdentity = .init(cacheKey: reuseKey, segmentID: reuseSegment) }
        return region
    }
}

/// Persistent global settings only: chapter direction and viewport variants may coexist.
private struct ReaderTranslationCachePolicy: Equatable {
    let translation: String
    let metadata: String
    let layout: String

    init(_ settings: ReaderTranslationSettings) {
        var persisted = settings
        persisted.rightToLeftPanelOrder = false
        translation = ReaderTranslationCacheIdentity.translation(page: "cache-policy", settings: persisted)
        metadata = ReaderTranslationCacheIdentity.encoded(TitleTranslationKind.allCases.map {
            TitleTranslation.cacheKey("cache-policy", kind: $0, settings: settings)
        })
        layout = ReaderTranslationCacheIdentity.encoded(settings.overlay)
    }
}

enum ReaderTranslationCacheIdentity {
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest((try? encoder.encode(value)) ?? Data())
    }
    static func ocr(page: String, settings: ReaderTranslationSettings) -> String {
        // OCR entries contain merged regions. A merger change must also
        // invalidate derived translations/layouts instead of replaying old boxes.
        encoded(["reader-ocr-v56-merged-rotation", page, encoded(settings.ocrConfiguration)])
    }
    static func translation(page: String, settings: ReaderTranslationSettings) -> String {
        let previous = unfilteredTranslation(page: page, settings: settings)
        let base = settings.rightToLeftPanelOrder ? encoded([previous, ReaderTranslationPanelOrder.cacheVersion]) : previous
        guard let filter = ReaderTranslationLanguageFilter.identity(settings: settings) else { return base }
        return encoded([base] + filter)
    }
    static func unfilteredTranslation(page: String, settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        return encoded([
            "reader-translation-v2-neighbor-context", ocr(page: page, settings: settings), config.provider.rawValue, config.apiProtocol.rawValue,
            config.baseURL, config.model, config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage
        ] + (settings.includePageImage ? ["page-image-v2-auto-fallback", String(TranslationImageSupport.shared.revision(for: config))] : []) + (settings.filterSFXWithLLM ? [settings.shouldAttachPageImage ? TranslationHTTPCodec.sfxPolicy : TranslationHTTPCodec.textOnlySFXPolicy] : []) + (settings.filterBackgroundWithLLM ? [settings.shouldAttachPageImage ? TranslationHTTPCodec.backgroundPolicy : TranslationHTTPCodec.textOnlyBackgroundPolicy] : []))
    }
    // Every geometry/appearance input must be included to reject stale pixels after a reader change.
    // swiftlint:disable:next function_parameter_count
    static func render(page: String, settings: ReaderTranslationSettings, imageSize: CGSize, viewport: CGSize,
                       scale: CGFloat, aspectFit: Bool, crop: CGRect, dark: Bool) -> String {
        // Auto Layout rounds view edges to display pixels. Mathematical prefetch
        // sizes differ by tiny fractions (568.016 pt vs 568 pt); those are one raster.
        let pixelScale = max(1, scale)
        let viewport = CGSize(width: (viewport.width * pixelScale).rounded() / pixelScale,
                              height: (viewport.height * pixelScale).rounded() / pixelScale)
        return encoded([
            "reader-render-v97-observed-texture", translation(page: page, settings: settings), encoded(settings.overlay),
            encoded(imageSize), encoded(viewport), String(Double(scale)), String(aspectFit), encoded(crop), String(dark),
            "balanced-columns-v15-visible-balloon-fit", "source-rotation-v7-native-balloon-fit",
            ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }
}
