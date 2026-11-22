import CryptoKit
import Foundation
import SQLite3

/// Durable, byte-bounded LRU for page translations, metadata and rendered page images.
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

    /// Best-effort LRU touches: a failed flush must not turn a hit into a miss.
    private func recordRead(_ name: String) {
        pendingTouches.removeAll { $0 == name }
        pendingTouches.append(name)
        if pendingTouches.count > 256 { pendingTouches.removeFirst(pendingTouches.count - 256) }
        if pendingTouches.count >= 32 { try? flushAccesses(); return }
        guard touchFlushTask == nil else { return }
        touchFlushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            try? await self?.flushAccesses()
        }
    }

    /// Flush before mutations/eviction so LRU order stays exact.
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
        let nextLimit = min(Self.maximumBytes, max(0, value))
        if byteLimit >= ReaderCacheDatabase.minimumBytes, nextLimit < ReaderCacheDatabase.minimumBytes {
            // Disabling storage deletes its contents like clear(); old work stays invalid.
            generation &+= 1
            metadataGeneration &+= 1
        }
        byteLimit = nextLimit
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
        guard let unpacked = try database?.unpackedData(name) else { return nil }
        recordRead(name)
        return unpacked
    }

    func contains(_ key: String, kind: Kind) throws -> Bool {
        try prepare()
        return try database?.exists(fileName(key, kind: kind)) ?? false
    }

    /// Clear invalidates in-flight writers. A transaction preserves the previous entry on write failure.
    func store(_ data: Data, for key: String, kind: Kind, generation expected: UInt64) throws {
        try Task.checkCancellation()
        try prepare()
        guard storageGeneration(for: kind) == expected, kind != .snapshot else { return }
        let packed = ReaderTranslationCacheCodec.pack(data)
        guard Int64(packed.count) <= byteLimit else { return }
        try storePayload(packed, name: fileName(key, kind: kind))
        try trim()
    }

    func regions(for key: String, kind: Kind) throws -> [ReaderTranslationRegion]? {
        try Task.checkCancellation()
        try prepare()
        let name = fileName(key, kind: kind)
        guard let record = try database?.regionRecord(name) else { return nil }
        recordRead(name)
        return record.regions
    }

    func storeRegions(_ regions: [ReaderTranslationRegion], for key: String, kind: Kind, generation: UInt64) throws {
        try Task.checkCancellation()
        try prepare()
        guard storageGeneration(for: kind) == generation else { return }
        guard kind != .translation || !regions.contains(where: { $0.translationRecoveryFailure != nil }) else { return }
        if regions.isEmpty {
            try store(Data("[]".utf8), for: key, kind: kind, generation: generation)
            return
        }
        let archive = try ReaderTranslationRegionArchive(regions)
        guard Int64(archive.base.count + archive.variant.count) <= byteLimit else { return }
        try storePayload(archive.variant, name: fileName(key, kind: kind), base: archive.base)
        try trim()
    }

    private func storePayload(_ data: Data, name: String, base: Data? = nil) throws {
        guard let database else { return }
        // Pending touches commit with the write; on failure they stay queued.
        try database.store(data, name: name, base: base, touching: pendingTouches)
        touchFlushTask?.cancel()
        touchFlushTask = nil
        pendingTouches.removeAll()
    }

    func remove(_ key: String, kind: Kind) throws {
        try prepare()
        try database?.delete(fileName(key, kind: kind))
    }

    static let legacyPipelinePurgeMarker = "legacy-pipeline-purge-v1"

    /// V2 page rows (layout JPEGs, translation block JSON) survive the legacy purge.
    static func isV2PageRow(kind: Kind, unpacked data: Data, linkedToRegionBase: Bool) -> Bool {
        guard !linkedToRegionBase else { return false }
        switch kind {
        case .layout: return data.starts(with: [0xFF, 0xD8, 0xFF])
        case .translation: return (try? JSONDecoder().decode([V2Block].self, from: data)) != nil
        case .metadata: return true
        case .ocr, .snapshot: return false
        }
    }

    /// One-time launch cleanup of legacy page-pipeline rows; returns the deleted count.
    @discardableResult
    func purgeLegacyPipelineRows() async throws -> Int {
        try prepare()
        guard let database else { return 0 }
        let marker = Self.legacyPipelinePurgeMarker
        guard try !database.hasMarker(marker) else { return 0 }
        var cursor = ""
        var deleted = 0
        var visited = 0
        while let row = try database.nextPagePipelineRow(after: cursor) {
            try Task.checkCancellation()
            cursor = row.name
            let kind = Kind.allCases.first { row.name.hasPrefix($0.rawValue + "-") } ?? .ocr
            let unpacked = (try? ReaderTranslationCacheCodec.unpack(row.data)) ?? Data()
            if !Self.isV2PageRow(kind: kind, unpacked: unpacked, linkedToRegionBase: row.linked) {
                try database.delete(row.name)
                deleted += 1
            }
            visited += 1
            if visited.isMultiple(of: 64) {
                await Task.yield()
                guard self.database === database else { return deleted }
            }
        }
        try database.execute("INSERT OR IGNORE INTO cache_policy(name,value) VALUES('\(marker)','1')")
        try trim()
        return deleted
    }

    /// Upgrades old records in place, keeping LRU order; each row is atomic and resumable.
    func compact() async throws {
        try prepare()
        guard let database else { return }
        var cursor = ""
        var processed = 0
        while let row = try database.nextRow("SELECT name,data FROM cache WHERE name>? AND (name LIKE 'ocr-%' OR name LIKE 'translation-%' "
            + "OR name LIKE 'metadata-%') AND NOT EXISTS (SELECT 1 FROM region_links WHERE region_links.name=cache.name) ORDER BY name LIMIT 1",
            after: cursor) {
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
        // Recompress payloads, then region bases. Base names stay the hash of canonical ATZ1 bytes.
        for (marker, table) in [("payload-compression-v2", "cache"), ("base-compression-v2", "region_bases")] {
            guard try !database.hasMarker(marker) else { continue }
            cursor = ""
            while let row = try database.nextRow("SELECT name,data FROM \(table) WHERE name>? ORDER BY name LIMIT 1", after: cursor) {
                try Task.checkCancellation()
                cursor = row.name
                if let packed = try? ReaderTranslationCacheCodec.repack(row.data), packed != row.data {
                    try database.bindBlob(packed, "UPDATE \(table) SET data=?2 WHERE name=?1", name: row.name)
                }
                processed += 1
                if processed.isMultiple(of: 32) {
                    await Task.yield()
                    guard self.database === database else { return }
                }
            }
            if table == "region_bases" {
                try Task.checkCancellation()
                // auto_vacuum cannot release space inside live pages; rebuild once.
                try database.execute("VACUUM")
            }
            try database.execute("INSERT OR IGNORE INTO cache_policy(name,value) VALUES('\(marker)','1')")
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
        // Old full-page PNG snapshots duplicate the artwork.
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
    private var lookupTable = "cache"
    private struct RegionRead {
        let name: String
        let version: Int64
        let record: ReaderTranslationRegionArchive.Record
        let cost: Int
    }
    private var recentRegions: [RegionRead] = []
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
        // 1 KiB pages avoid wasted overflow pages; existing databases migrate below.
        try execute("PRAGMA page_size=1024")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA auto_vacuum=FULL")
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA cache_size=-2048")
        try execute("CREATE TABLE IF NOT EXISTS cache (name TEXT PRIMARY KEY, data BLOB NOT NULL, accessed INTEGER NOT NULL) WITHOUT ROWID")
        // A key-only index lets lookups reject absent keys without reading overflow BLOBs.
        do {
            try execute("CREATE UNIQUE INDEX IF NOT EXISTS cache_key_only ON cache(name)")
            lookupTable = "cache INDEXED BY cache_key_only"
        } catch let error as NSError where [SQLITE_FULL, SQLITE_BUSY, SQLITE_LOCKED].contains(Int32(error.code)) {
            // Optional migration; retried on reopen.
        }
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
        try execute("CREATE TRIGGER IF NOT EXISTS region_unlink AFTER DELETE ON region_links BEGIN DELETE FROM region_bases WHERE "
            + "name=old.base AND NOT EXISTS (SELECT 1 FROM region_links WHERE base=old.base); END")
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(handle) }

    func optimizePageSize() throws {
        let previous = try integer("PRAGMA page_size")
        // auto_vacuum only applies to an existing database through VACUUM; without it
        // deletes never shrink the file and trim(to:) would evict everything.
        guard try previous != 1024 || integer("PRAGMA auto_vacuum") != 1 else { return }
        try execute("PRAGMA page_size=1024")
        do {
            try execute("VACUUM")
        } catch {
            // Keep the original database and retry on reopen.
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

    /// Steps once: true for a row, false when done, throws on any other result.
    private func hasRow(_ pointer: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(pointer)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func hasMarker(_ marker: String) throws -> Bool {
        try integer("SELECT COUNT(*) FROM cache_policy WHERE name='\(marker)'") != 0
    }

    /// Runs `sql` with `name` bound to ?1 and `data` borrowed as the ?2 BLOB.
    func bindBlob(_ data: Data, _ sql: String, name: String) throws {
        try data.withUnsafeBytes { bytes in
            try statement(sql, name: name) { pointer in
                let result = sqlite3_bind_blob(pointer, 2, bytes.baseAddress, Int32(bytes.count), nil)
                guard result == SQLITE_OK else { throw failure() }
                try step(pointer)
            }
        }
    }

    func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { pointer in
            guard sqlite3_step(pointer) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(pointer, 0)
        }
    }

    func exists(_ name: String) throws -> Bool {
        try statement("SELECT 1 FROM \(lookupTable) WHERE name=?", name: name, body: hasRow)
    }

    /// Decodes inside the statement lifetime, avoiding an intermediate copy.
    func unpackedData(_ name: String) throws -> Data? {
        var rejectedVersion: Int64?
        let data: Data? = try statement(payloadSQL, name: name) { pointer in
            guard try hasRow(pointer) else { return nil }
            do {
                if sqlite3_column_type(pointer, 1) != SQLITE_NULL {
                    return try ReaderTranslationRegionArchive.restore(base: blob(pointer, column: 1), variant: blob(pointer, column: 0))
                }
                return try unpackedBlob(pointer, column: 0)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The active SELECT pins the rejected bytes and this version together.
                rejectedVersion = try integer("PRAGMA data_version")
                return nil
            }
        }
        if let rejectedVersion { try delete(name, ifVersionIs: rejectedVersion) }
        return data
    }

    private func unpackedBlob(_ pointer: OpaquePointer, column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(pointer, column))
        guard count > 0, let bytes = sqlite3_column_blob(pointer, column) else { return Data() }
        let borrowed = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: count, deallocator: .none)
        guard ReaderTranslationCacheCodec.isPacked(borrowed) else {
            // Copy raw data so no SQLite pointer escapes the statement.
            return Data(bytes: bytes, count: count)
        }
        return try ReaderTranslationCacheCodec.unpack(borrowed)
    }

    func regionRecord(_ name: String) throws -> ReaderTranslationRegionArchive.Record? {
        if let index = recentRegions.firstIndex(where: { $0.name == name }) {
            let hit = recentRegions.remove(at: index)
            if hit.version == (try integer("PRAGMA data_version")) {
                recentRegions.append(hit)
                return hit.record
            }
        }
        // The SELECT holds its read snapshot while data_version is sampled.
        guard let payload = try withPayload(name, { data, base in
            (data: data, base: base, version: try integer("PRAGMA data_version"))
        }) else { return nil }
        let record: ReaderTranslationRegionArchive.Record
        do {
            if let base = payload.base {
                record = try ReaderTranslationRegionArchive.record(base: base, variant: payload.data)
            } else {
                record = try ReaderTranslationRegionArchive.record(legacy: payload.data)
            }
        } catch {
            try delete(name, ifVersionIs: payload.version)
            return nil
        }
        // Retain only small decoded records, within a 1 MiB / 8-entry budget.
        let cost = record.decodedByteCount + record.regions.count * MemoryLayout<ReaderTranslationRegion>.stride
        if cost <= 256 * 1024 {
            recentRegions.removeAll { $0.version != payload.version }
            var retainedBytes = recentRegions.reduce(cost) { $0 + $1.cost }
            while retainedBytes > 1024 * 1024 || recentRegions.count >= 8 {
                retainedBytes -= recentRegions.removeFirst().cost
            }
            recentRegions.append(.init(name: name, version: payload.version, record: record, cost: cost))
        }
        return record
    }

    private var payloadSQL: String {
        "SELECT cache.data, region_bases.data FROM \(lookupTable) LEFT JOIN region_links USING(name) LEFT JOIN region_bases ON "
            + "region_bases.name=region_links.base WHERE cache.name=?"
    }

    private func withPayload<T>(_ name: String, _ read: (Data, Data?) throws -> T) throws -> T? {
        try statement(payloadSQL, name: name) { pointer in
            guard try hasRow(pointer) else { return nil }
            return try read(blob(pointer, column: 0), sqlite3_column_type(pointer, 1) == SQLITE_NULL ? nil : blob(pointer, column: 1))
        }
    }

    private func blob(_ pointer: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(pointer, column))
        guard count > 0, let bytes = sqlite3_column_blob(pointer, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func nextRow(_ sql: String, after name: String) throws -> (name: String, data: Data)? {
        try statement(sql, name: name) { pointer in
            guard try hasRow(pointer) else { return nil }
            return (String(cString: sqlite3_column_text(pointer, 0)), blob(pointer, column: 1))
        }
    }

    /// Page-pipeline rows (never metadata) in name order, with their region-base link state.
    func nextPagePipelineRow(after name: String) throws -> (name: String, data: Data, linked: Bool)? {
        try statement("SELECT name,data,EXISTS(SELECT 1 FROM region_links WHERE region_links.name=cache.name) FROM cache "
            + "WHERE name>? AND (name GLOB 'ocr-*' OR name GLOB 'translation-*' OR name GLOB 'layout-*' OR name GLOB 'snapshot-*') "
            + "ORDER BY name LIMIT 1", name: name) { pointer in
            guard try hasRow(pointer) else { return nil }
            return (String(cString: sqlite3_column_text(pointer, 0)), blob(pointer, column: 1), sqlite3_column_int(pointer, 2) != 0)
        }
    }

    func touch(_ names: [String]) throws {
        guard names.count > 1 else { if let name = names.first { try touch(name) }; return }
        try transaction { for name in names { try touch(name) } }
    }

    func touch(_ name: String) throws {
        // Touching the newest entry is a no-op, so repeated reads write nothing.
        try statement("UPDATE cache SET accessed=(SELECT COALESCE(MAX(accessed),0)+1 FROM cache) WHERE name=? AND name != (SELECT name FROM "
            + "cache ORDER BY accessed DESC, name DESC LIMIT 1)", name: name, body: step)
    }

    func delete(_ name: String) throws {
        recentRegions.removeAll { $0.name == name }
        try statement("DELETE FROM cache WHERE name=?", name: name, body: step)
    }

    // A replacement may commit after a failed read; delete only if nothing changed since.
    private func delete(_ name: String, ifVersionIs version: Int64) throws {
        try transaction { if try integer("PRAGMA data_version") == version { try delete(name) } }
    }

    func store(_ data: Data, name: String, base: Data? = nil, preservingAccess: Bool = false, touching names: [String] = []) throws {
        recentRegions.removeAll { $0.name == name }
        try transaction {
            for name in names { try touch(name) }
            let accessed: Int64? = preservingAccess ? try statement("SELECT accessed FROM cache WHERE name=?", name: name) { pointer in
                guard sqlite3_step(pointer) == SQLITE_ROW else { throw failure() }
                return sqlite3_column_int64(pointer, 0)
            } : nil
            try statement("DELETE FROM region_links WHERE name=?", name: name, body: step)
            try storeRow(data, name: name)
            if let accessed {
                try statement("UPDATE cache SET accessed=\(accessed) WHERE name=?", name: name, body: step)
            }
            guard let base else { return }
            let digest = ReaderTranslationCacheIdentity.digest(base)
            // Fresh source data repairs a corrupt shared base kept alive by a sibling link.
            try bindBlob(try ReaderTranslationCacheCodec.repack(base), "INSERT INTO region_bases(name,data) VALUES(?,?) "
                + "ON CONFLICT(name) DO UPDATE SET data=excluded.data WHERE region_bases.data != excluded.data", name: digest)
            try statement("INSERT INTO region_links(name,base) VALUES(?,?)", name: name) { pointer in
                guard sqlite3_bind_text(pointer, 2, digest, -1, transient) == SQLITE_OK else { throw failure() }
                try step(pointer)
            }
        }
    }

    private func storeRow(_ data: Data, name: String, legacyAccess: Int64? = nil) throws {
        let sql = legacyAccess == nil
            ? "INSERT INTO cache(name,data,accessed) VALUES(?,?,(SELECT COALESCE(MAX(accessed),0)+1 FROM cache)) ON CONFLICT(name) DO UPDATE SET data=excluded.data, accessed=excluded.accessed"
            : "INSERT OR IGNORE INTO cache(name,data,accessed) VALUES(?,?,?)"
        // SQLITE_STATIC is safe: statement() finalizes before the buffer scope ends.
        try data.withUnsafeBytes { bytes in
            try statement(sql, name: name) { pointer in
                let result = bytes.isEmpty ? sqlite3_bind_zeroblob(pointer, 2, 0)
                    : sqlite3_bind_blob(pointer, 2, bytes.baseAddress, Int32(bytes.count), nil)
                guard result == SQLITE_OK else { throw failure() }
                if let legacyAccess { sqlite3_bind_int64(pointer, 3, legacyAccess) }
                try step(pointer)
            }
        }
    }

    /// Moves old metadata rows (one zero-sized "title" region in the translation
    /// namespace) row by row, preserving bytes, bases and LRU order.
    func separateLegacyMetadata() throws {
        guard try !hasMarker("metadata-kind-v1") else { return }
        var cursor = "translation-"
        while let name = try statement("SELECT name FROM cache WHERE name>? AND name<'translation.' ORDER BY name LIMIT 1", name: cursor, body: { pointer -> String? in
            guard try hasRow(pointer) else { return nil }
            return String(cString: sqlite3_column_text(pointer, 0))
        }) {
            try Task.checkCancellation()
            cursor = name
            guard let source = try withPayload(name, { data, base in base ?? data }),
                  let raw = try? ReaderTranslationCacheCodec.unpack(source),
                  let regions = try? JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: raw),
                  regions.count == 1, regions[0].id == "title", regions[0].rect == .zero else { continue }
            let destination = "metadata-" + name.dropFirst("translation-".count)
            try transaction {
                if try !exists(destination) {
                    // Copy the link first so the shared base stays referenced.
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
            }
        }
        try execute("INSERT INTO cache_policy(name,value) VALUES('metadata-kind-v1','1')")
    }

    /// The first policy adopts existing rows; later changes delete obsolete ones.
    func applyPolicy(_ policy: ReaderTranslationCachePolicy) throws -> (page: Bool, metadata: Bool) {
        recentRegions.removeAll()
        return try transaction {
            func previous(_ key: String) throws -> String? {
                try statement("SELECT value FROM cache_policy WHERE name=?", name: key) { pointer in
                    guard try hasRow(pointer) else { return nil }
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
            for (key, value) in [("translation", policy.translation), ("layout", policy.layout), ("metadata", policy.metadata)] {
                try statement("INSERT INTO cache_policy(name,value) VALUES('\(key)',?) ON CONFLICT(name) DO UPDATE SET value=excluded.value",
                              name: value, body: step)
            }
            return (translationChanged || layoutChanged, metadataChanged)
        }
    }

    func allocatedBytes() throws -> Int64 {
        var measured = url
        measured.removeAllCachedResourceValues()
        let values = try measured.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(max(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0, values.fileSize ?? 0))
    }

    func trim(to byteLimit: Int64) throws {
        // Evict oldest rows in batches sized from the average payload.
        while try allocatedBytes() > byteLimit {
            recentRegions.removeAll()
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
            // Commit first: an interrupted unlink resumes with INSERT OR IGNORE.
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

/// One stored region row. Older rows may carry retired keys; decoding ignores them.
struct ReaderTranslationStoredRegion: Codable {
    let id: String
    let rect: CGRect
    let source: String
    let translation: String?
    let polygon: [CGPoint]
    let confidence: Double
    let orientation: String
    let singleColumn: Bool?
    let sourceImageAspectRatio: Double?
    let translationOrder: Int?
    let translationOrderVersion: String?
    let reuseKey: TranslationCacheKey?
    let reuseSegment: String?
    let translationRecoveryFailure: String?
    let keepsClassifiedSFXSource: Bool?
    let rendersUnchangedSymbols: Bool?

    init(_ value: ReaderTranslationRegion) {
        id = value.id; rect = value.rect; source = value.source; translation = value.translation
        polygon = value.polygon; confidence = value.confidence; orientation = value.sourceOrientation.rawValue
        singleColumn = value.sourceSingleVerticalColumn
        sourceImageAspectRatio = value.sourceImageAspectRatio
        translationOrder = value.translationOrder
        translationOrderVersion = value.translationOrderVersion
        reuseKey = value.translationReuseIdentity?.cacheKey; reuseSegment = value.translationReuseIdentity?.segmentID
        translationRecoveryFailure = value.translationRecoveryFailure
        keepsClassifiedSFXSource = value.keepsClassifiedSFXSource ? true : nil
        rendersUnchangedSymbols = value.rendersUnchangedSymbols ? true : nil
    }
    var region: ReaderTranslationRegion {
        var region = ReaderTranslationRegion(id: id, rect: rect, source: source, translation: translation, polygon: polygon,
                                             confidence: confidence, sourceOrientation: .init(tolerantRawValue: orientation),
                                             sourceSingleVerticalColumn: singleColumn)
        region.sourceImageAspectRatio = sourceImageAspectRatio
        region.translationOrder = translationOrder
        region.translationOrderVersion = translationOrderVersion
        if let reuseKey, let reuseSegment { region.translationReuseIdentity = .init(cacheKey: reuseKey, segmentID: reuseSegment) }
        region.translationRecoveryFailure = translationRecoveryFailure
        region.keepsClassifiedSFXSource = keepsClassifiedSFXSource ?? false
        region.rendersUnchangedSymbols = rendersUnchangedSymbols ?? false
        return region
    }
}

/// Persistent global settings only: chapter direction and viewport variants may coexist.
private struct ReaderTranslationCachePolicy: Equatable {
    let translation: String
    let metadata: String
    let layout: String

    init(_ settings: ReaderTranslationSettings) {
        // Page rows are dropped when the provider, languages or source filter change.
        let config = settings.configuration
        translation = ReaderTranslationCacheIdentity.encoded([
            "page-cache-policy-v2", config.provider.rawValue, config.apiProtocol.rawValue, config.baseURL, config.model,
            config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage,
            TranslationHTTPCodec.letteringPolicy, TranslationHTTPCodec.sfxPolicy, TranslationHTTPCodec.backgroundPolicy,
            ReaderTranslationCacheIdentity.encoded(ReaderTranslationLanguageFilter.identity(settings: settings) ?? [])
        ])
        metadata = ReaderTranslationCacheIdentity.encoded(TitleTranslationKind.allCases.map {
            TitleTranslation.cacheKey("cache-policy", kind: $0, settings: settings)
        })
        layout = ReaderTranslationCacheIdentity.encoded(["page-layout-policy-v2"])
    }
}

enum ReaderTranslationCacheIdentity {
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)
    static func digest(_ value: Data) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in SHA256.hash(data: value) {
            bytes.append(hexadecimalDigits[Int(byte >> 4)])
            bytes.append(hexadecimalDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest((try? encoder.encode(value)) ?? Data())
    }
}
