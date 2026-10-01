import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct DownloadPathSafetyRegressionTests {
    @Test func emptyMangaPruningFailsClosedWhenEnumerationFails() throws {
        enum ReadFailure: Error { case denied }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { directory.removeItem() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("cover.png")
        let original = Data([0, 1, 2, 3])
        try original.write(to: sentinel)

        #expect(!DownloadManager.pruneEmptyMangaDirectory(directory, contents: { _ in throw ReadFailure.denied }))
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test func emptyMangaPruningCannotRecursivelyEraseNewStagingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { directory.removeItem() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: directory.appendingPathComponent("cover.png"))
        let staging = directory.appendingPathComponent(DownloadCache.tmpDirectoryPrefix + "new")
        let sentinel = staging.appendingPathComponent("001.png")
        let original = Data([4, 5, 6])

        let removed = DownloadManager.pruneEmptyMangaDirectory(directory, contents: { directory in
            let snapshot = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try original.write(to: sentinel)
            return snapshot
        })

        #expect(!removed)
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test func emptyMangaPruningRemovesOnlyAncillaryFilesThenEmptyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { directory.removeItem() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["cover.png", ".manga_metadata.json"] {
            try Data([0]).write(to: directory.appendingPathComponent(name))
        }
        #expect(DownloadManager.pruneEmptyMangaDirectory(directory))
        #expect(!directory.exists)
    }

    @Test(arguments: [false, true]) @MainActor
    func deletingLastCompletedChapterPreservesOtherStagingBytes(failed: Bool) async throws {
        let source = "download-staging-regression-\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingPathComponent(source)
        let previousQueue = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.set(previousQueue, forKey: "Data.downloadQueueState")
        }
        let manga = root.appendingPathComponent("manga")
        let completed = manga.appendingPathComponent("completed")
        let staging = manga.appendingPathComponent(DownloadCache.tmpDirectoryPrefix + "next")
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let sentinel = staging.appendingPathComponent("001.png")
        let original = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        try original.write(to: sentinel)
        if failed {
            try Data("[2]".utf8).write(to: staging.appendingPathComponent(DownloadCache.failureMarkerName))
        }

        await DownloadManager().delete(chapters: [
            .init(sourceKey: source, mangaKey: "manga", chapterKey: "completed")
        ])

        #expect(!completed.exists)
        #expect(sentinel.exists)
        if sentinel.exists { #expect(try Data(contentsOf: sentinel) == original) }
    }

    // Exercises the actual deletion API on an isolated UUID source. This test
    // also compiles before the fix; the old code removes both sentinels.
    @Test @MainActor func parentChapterCannotDeleteItsSource() async throws {
        let source = "download-path-regression-\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingPathComponent(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let manga = root.appendingPathComponent("manga")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: manga, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let original = Data("unchanged download bytes".utf8)
        let first = manga.appendingPathComponent("sentinel.png")
        let second = other.appendingPathComponent("sentinel.png")
        try original.write(to: first)
        try original.write(to: second)
        let manager = DownloadManager()
        await manager.delete(chapters: [.init(sourceKey: source, mangaKey: "manga", chapterKey: "..")])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        if first.exists { #expect(try Data(contentsOf: first) == original) }
        if second.exists { #expect(try Data(contentsOf: second) == original) }
    }

    @Test @MainActor func dotMangaCannotDeleteItsSource() async throws {
        let source = "download-path-regression-\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingPathComponent(source)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("sentinel.png")
        let bytes = Data([9, 7, 3])
        try bytes.write(to: sentinel)
        let manager = DownloadManager()
        await manager.deleteChapters(for: .init(sourceKey: source, mangaKey: "."))
        #expect(sentinel.exists)
        if sentinel.exists { #expect(try Data(contentsOf: sentinel) == bytes) }
    }
}
