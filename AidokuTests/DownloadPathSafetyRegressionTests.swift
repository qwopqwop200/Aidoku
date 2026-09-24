import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct DownloadPathSafetyRegressionTests {
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
