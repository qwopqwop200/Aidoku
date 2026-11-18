#!/usr/bin/env python3
"""Exercise SQLite cache repair interleavings and the bounded decoded-region working set."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "Aidoku/Core/Translation"
disk = (root / "ReaderTranslationDiskCache.swift").read_text()
database = disk[disk.index("private final class ReaderCacheDatabase"):disk.index("struct ReaderTranslationStoredRegion")]
codec = (root / "ReaderTranslationCacheCodec.swift").read_text()
data_read = disk[disk.index("    func data(for key:"):disk.index("    func markUsed(")]

# Supply only the app model surface consumed by the database and native archive.
# A malformed fixture key invokes a second SQLite connection after the read
# statement has finalized, immediately before reporting its decoding error.
fixture = """
import CoreGraphics
import CryptoKit
import Foundation
import SQLite3

enum ReaderTranslationCacheIdentity {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).description }
}
private struct ReaderTranslationDiskCache {
    enum Kind: String, CaseIterable { case translation, ocr, metadata, layout, snapshot }
    let database: ReaderCacheDatabase?
    func prepare() throws {}
    func recordRead(_ name: String) throws {}
    func fileName(_ key: String, kind: Kind) -> String { key }
    DATA_READ
}
struct ReaderTranslationCachePolicy { let translation, layout, metadata: String }
var duringDecode: (() throws -> Void)?
struct TranslationCacheKey: Codable, Hashable {
    var value: String
    init(value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        if value == "damaged" {
            try duringDecode?()
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
struct ReuseIdentity: Codable { let cacheKey: TranslationCacheKey; let segmentID: String }
struct ReaderTranslationRegion: Codable {
    var id: String
    var rect: CGRect = .zero
    var translation: String?
    var translationReuseIdentity: ReuseIdentity?
    var translationRecoveryFailure: String?
    var keepsClassifiedSFXSource = false
    init(id: String) { self.id = id }
    init(_ value: Self) { self = value }
    var region: Self { self }
}
typealias ReaderTranslationStoredRegion = ReaderTranslationRegion
""".replace("    DATA_READ", data_read)

test = """
// Run a second connection after the payload statement releases its read lock,
// just before the first instruction of the reader's cleanup transaction.
var beforeCleanup: (() -> Void)?
var payloadReads = 0
var versionReads = 0
extension ReaderCacheDatabase {
    func observeStatements() {
        sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_STMT), { _, _, statement, _ in
            guard let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            let text = String(cString: sql)
            if text.hasPrefix("SELECT cache.data, region_bases.data") { payloadReads += 1 }
            if text == "PRAGMA data_version" { versionReads += 1 }
            if text == "BEGIN IMMEDIATE" || text == "DELETE FROM cache WHERE name=?" {
                let hook = beforeCleanup
                beforeCleanup = nil
                hook?()
            }
            return 0
        }, nil)
    }
}

func exercise() throws {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let reader = try ReaderCacheDatabase(url: url)
    let writer = try ReaderCacheDatabase(url: url)
    var damaged = ReaderTranslationRegion(id: "stale")
    damaged.translationReuseIdentity = .init(cacheKey: .init(value: "damaged"), segmentID: "x")
    let previous = try ReaderTranslationRegionArchive([damaged])
    let replacement = try ReaderTranslationRegionArchive([ReaderTranslationRegion(id: "fresh")])
    for restoresPreviousBytes in [false, true] {
        try reader.store(previous.variant, name: "row", base: previous.base)
        var completedWrites = 0
        duringDecode = {
            try writer.store(replacement.variant, name: "row", base: replacement.base)
            completedWrites += 1
            if restoresPreviousBytes {
                try writer.store(previous.variant, name: "row", base: previous.base)
                completedWrites += 1
            }
        }
        let failedRead = try reader.regionRecord("row")
        duringDecode = nil
        precondition(failedRead == nil && completedWrites == (restoresPreviousBytes ? 2 : 1))
        let survived = try reader.exists("row")
        precondition(survived, "Failed decode deleted a subsequent commit")
        let reread = try reader.regionRecord("row")
        if restoresPreviousBytes {
            precondition(reread == nil)
            let remains = try reader.exists("row")
            precondition(!remains, "A fresh read should remove the still-corrupt archive")
        } else {
            precondition(reread?.regions.first?.id == "fresh")
        }
    }
    let cache = ReaderTranslationDiskCache(database: reader)
    let fresh = Data([42])
    reader.observeStatements()
    for page in 0..<33 {
        let missing = try reader.regionRecord("new-" + String(page))
        precondition(missing == nil)
    }
    precondition(payloadReads == 33 && versionReads == 0, "A new page needs only its indexed row lookup")
    try writer.store(replacement.variant, name: "new-0", base: replacement.base)
    let inserted = try reader.regionRecord("new-0")
    precondition(inserted?.regions.first?.id == "fresh", "A previous miss must see a subsequent external insertion")
    for damaged in [Data("ATZ2".utf8) + Data([255, 255]), Data(repeating: 3, count: 64)] {
        for restoresPreviousBytes in [false, true] {
            try reader.store(damaged, name: "asset")
            var replaced = false
            beforeCleanup = {
                try! writer.store(fresh, name: "asset")
                if restoresPreviousBytes { try! writer.store(damaged, name: "asset") }
                replaced = true
            }
            let failed = try cache.data(for: "asset", kind: .layout, maximumBytes: 8, discardOversized: true)
            precondition(failed == nil && replaced)
            let survived = try reader.exists("asset")
            precondition(survived, "Failed asset read deleted a subsequent commit")
            let reread = try cache.data(for: "asset", kind: .layout, maximumBytes: 8, discardOversized: true)
            precondition(reread == (restoresPreviousBytes ? nil : fresh))
            let remains = try reader.exists("asset")
            precondition(remains == !restoresPreviousBytes)
        }
    }
    let larger = Data(repeating: 9, count: 128)
    try reader.store(larger, name: "asset")
    let budgetMiss = try cache.data(for: "asset", kind: .layout, maximumBytes: 8)
    let budgetHit = try cache.data(for: "asset", kind: .layout, maximumBytes: larger.count)
    precondition(budgetMiss == nil && budgetHit == larger)

    let pages = (0..<8).map { "page-" + String($0) }
    for page in pages {
        let archive = try ReaderTranslationRegionArchive([ReaderTranslationRegion(id: page)])
        try reader.store(archive.variant, name: page, base: archive.base)
        _ = try reader.regionRecord(page)
    }
    payloadReads = 0
    for page in pages {
        let hit = try reader.regionRecord(page)
        precondition(hit?.regions.first?.id == page)
    }
    precondition(payloadReads == 0, "Warm small pages should not decode their archives again")
    try writer.delete(pages[0])
    let externalMiss = try reader.regionRecord(pages[0])
    precondition(externalMiss == nil)

    // Four 220 KiB records fit the working set. A fifth must evict the oldest.
    for page in pages.prefix(5) {
        let largeID = page + String(repeating: "x", count: 220 * 1024)
        let archive = try ReaderTranslationRegionArchive([ReaderTranslationRegion(id: largeID)])
        try reader.store(archive.variant, name: page, base: archive.base)
        _ = try reader.regionRecord(page)
    }
    payloadReads = 0
    for page in pages[1..<5] { _ = try reader.regionRecord(page) }
    precondition(payloadReads == 0)
    _ = try reader.regionRecord(pages[0])
    precondition(payloadReads == 1, "Oldest large record must be read back from disk")
}
try exercise()
print("PASS new-page lookups and subsequent insert, concurrent region/asset replacement and ABA, corrupt/size cleanup, temporary budgets, warm reads, external invalidation, byte eviction")
"""

with tempfile.TemporaryDirectory(prefix="reader-disk-repair-") as directory:
    work = Path(directory)
    executable = work / "repair-race"
    subprocess.run(
        ["xcrun", "swiftc", "-O", "-module-cache-path", str(work / "modules"), "-", "-o", str(executable)],
        input=fixture + codec + database + test, text=True, check=True,
    )
    subprocess.run([str(executable), str(work / "cache.sqlite")], check=True)
