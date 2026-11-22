import AidokuRunner
import Foundation

/// Small disk-only metadata cache (no images or chapter lists), used off the main thread.
final class HistoryMetadataCache: @unchecked Sendable {
    static let shared = HistoryMetadataCache(directory: FileManager.default.cachesDirectory
        .appendingPathComponent("HistoryMetadata-v1", isDirectory: true))

    private struct Entry: Codable {
        let id: ChapterIdentifier
        let manga: AidokuRunner.Manga
        let chapter: AidokuRunner.Chapter
        let storedAt: Date
        var accessedAt: Date

        // AidokuRunner deliberately excludes sourceKey from Codable.
        var restoredManga: AidokuRunner.Manga {
            AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "").copy(from: manga)
        }
    }
    private struct Archive: Codable {
        let version: Int
        let entries: [Entry]
    }

    private let queue = DispatchQueue(label: "app.aidoku.history-metadata", qos: .utility)
    private let file: URL
    private let maxEntries = 256
    private let maxBytes: Int
    private let maxAge: TimeInterval = 24 * 60 * 60
    private var revision: UInt64 = 0
    // Last decoded archive, reused while the file bytes are unchanged (avoids a full JSON decode per call).
    private var memo: (data: Data, entries: [Entry])?

    init(directory: URL, maxBytes: Int = 2 * 1024 * 1024) {
        file = directory.appendingPathComponent("metadata.json")
        self.maxBytes = max(0, maxBytes)
    }

    var generation: UInt64 { queue.sync { revision } }

    func load(chapterIds: [ChapterIdentifier]) -> HistoryMetadataBatch {
        let now = Date()
        return queue.sync {
            let requested = Set(chapterIds)
            guard !requested.isEmpty else { return HistoryMetadataBatch() }
            var entries = read(now: now)
            var result = HistoryMetadataBatch()
            var touched = false
            for index in entries.indices where requested.contains(entries[index].id) {
                let entry = entries[index]
                result.manga[entry.id.mangaIdentifier] = entry.restoredManga
                result.chapters[entry.id] = entry.chapter
                if now.timeIntervalSince(entry.accessedAt) >= 60 {
                    entries[index].accessedAt = now
                    touched = true
                }
            }
            if touched { write(entries) }
            return result
        }
    }

    /// Deletions bump the generation so late responses cannot recreate cleared metadata.
    func store(manga: AidokuRunner.Manga, chapters: [AidokuRunner.Chapter], generation: UInt64) {
        let now = Date()
        queue.sync {
            guard generation == revision, maxBytes > 0, !chapters.isEmpty else { return }
            var compact = manga
            compact.chapters = nil
            var entries = read(now: now)
            let encoder = JSONEncoder()
            var changed = false
            for chapter in chapters.prefix(maxEntries) {
                let id = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
                let entry = Entry(id: id, manga: compact, chapter: chapter, storedAt: now, accessedAt: now)
                guard let data = try? encoder.encode(entry), data.count <= min(maxBytes, 32 * 1024) else { continue }
                if let old = entries.first(where: { $0.id == id }),
                   old.restoredManga == compact, old.chapter == chapter, now.timeIntervalSince(old.storedAt) < 60 { continue }
                entries.removeAll { $0.id == id }
                entries.append(entry)
                changed = true
            }
            if changed { write(entries) }
        }
    }

    func remove(chapterIds: [ChapterIdentifier]) {
        let ids = Set(chapterIds)
        guard !ids.isEmpty else { return }
        invalidate { ids.contains($0.id) }
    }

    func remove(mangaId: MangaIdentifier) { invalidate { $0.id.mangaIdentifier == mangaId } }

    func clear() {
        queue.sync {
            revision &+= 1
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func invalidate(_ matches: (Entry) -> Bool) {
        queue.sync {
            revision &+= 1
            var entries = read(now: Date())
            entries.removeAll(where: matches)
            write(entries)
        }
    }

    private func read(now: Date) -> [Entry] {
        guard maxBytes > 0,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxBytes,
              let data = try? Data(contentsOf: file), data.count <= maxBytes else { return [] }
        if memo?.data != data {
            guard let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
                  archive.entries.count <= maxEntries else { return [] }
            memo = (data, archive.entries)
        }
        return (memo?.entries ?? []).filter {
            $0.manga.chapters == nil && $0.id.mangaKey == $0.manga.key && $0.id.chapterKey == $0.chapter.key &&
                now.timeIntervalSince($0.storedAt) < maxAge && now.timeIntervalSince($0.storedAt) >= 0
        }
    }

    private func write(_ entries: [Entry]) {
        var retained = Array(entries.sorted { $0.accessedAt > $1.accessedAt }.prefix(maxEntries))
        let encoder = JSONEncoder()
        while !retained.isEmpty {
            guard let data = try? encoder.encode(Archive(version: 1, entries: retained)) else { return }
            if data.count <= maxBytes {
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                    memo = (data, retained)
                } catch { /* A cache write failure must not prevent reading. */ }
                return
            }
            retained.removeLast()
        }
        try? FileManager.default.removeItem(at: file)
    }
}
