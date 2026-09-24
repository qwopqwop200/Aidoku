import Foundation
import Testing
@testable import Aidoku

struct DownloadPathContainmentTests {
    @Test func componentsPreserveNamesAndRejectNavigationAndAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("alias"), withDestinationURL: outside)
        for invalid in ["", ".", "..", "/", ":/", "\n", "alias"] {
            #expect(!DownloadCache.isSafeDownloadPath(components: [invalid, "manga", "chapter"], root: downloads))
        }
        for invalid in ["", ".", "..", "/", ":/", "\n"] {
            #expect(!DownloadCache.isSafeDownloadPath(components: ["source", invalid, "chapter"], root: downloads))
            #expect(!DownloadCache.isSafeDownloadPath(components: ["source", "manga", invalid], root: downloads))
        }
        for valid in ["normal", "series/chapter", "a:b", "日本語", "chapter..", ".chapter"] {
            #expect(DownloadCache.isSafeDownloadPath(components: ["source", "manga", valid], root: downloads))
            let original = downloads.appendingSafePathComponent("source").appendingSafePathComponent("manga").appendingSafePathComponent(valid)
            #expect(original.lastPathComponent == valid.directoryName)
        }
        let redirectedRoot = root.appendingPathComponent("RedirectedDownloads")
        try FileManager.default.createSymbolicLink(at: redirectedRoot, withDestinationURL: outside)
        #expect(!DownloadCache.isSafeDownloadPath(components: ["source", "manga"], root: redirectedRoot))
        #expect(!DownloadCache.isSafeChapterPath(source: "source", manga: "manga", chapter: "chapter", root: redirectedRoot))
        #expect(try Data(contentsOf: sentinel) == bytes)
    }
}
