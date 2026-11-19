import Foundation
import Testing
@testable import Aidoku

/// App-level path safety, deep links, launch cleanup, and memory caps.
@MainActor
struct AppMiscTests {
    @Test func localImageURLsStayInsideDocumentsAndRoundtripReservedCharacters() throws {
        #expect(URL(string: "aidoku-image:///../Library/secret")?.toAidokuFileUrl() == nil)
        let document = FileManager.default.documentDirectory.appendingPathComponent("Covers/name#?%.png")
        let portable = try #require(document.toAidokuImageUrl())
        #expect(portable.toAidokuFileUrl() == document.standardizedFileURL.resolvingSymlinksInPath())
        let sibling = FileManager.default.documentDirectory.deletingLastPathComponent().appendingPathComponent("Documents-other/file.png")
        #expect(sibling.toAidokuImageUrl() == nil)
    }

    @Test(arguments: ["simple-id", "series/chapter", "한글/作品 ?#"])
    func notificationMangaKeyRemainsOneDeepLinkComponent(key: String) throws {
        let url = try #require(AppDelegate.notificationURL(sourceId: "source.example", mangaId: key))
        // Same split-before-decoding contract used by AppDelegate.handleUrl.
        let components = url.percentEncodedPath.split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        #expect(url.host == "source.example")
        #expect(components == [key])
        #expect(url.query == nil && url.fragment == nil)
    }

    /// Launch cleanup deletes only sessions present at launch and never follows a symlink out of its root.
    @Test func launchCleanupDeletesOnlyPreviousSessionsAndDoesNotFollowSymlinks() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("ReaderSessions", isDirectory: true)
        let old = root.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([1]).write(to: old.appendingPathComponent("page.png"))
        let shared = fixture.appendingPathComponent("SharedImageSessions")
        let outside = fixture.appendingPathComponent("other", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("keep")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([2]).write(to: outsideFile)
        try fm.createSymbolicLink(at: shared, withDestinationURL: outside)

        let cleanup = try #require(AppDelegate.removePreviousReaderSessions(in: [root, shared]))
        let current = root.appendingPathComponent("new")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        await cleanup.value
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: current.path))
        #expect(!fm.fileExists(atPath: shared.path))
        #expect(try Data(contentsOf: outsideFile) == Data([2]))
    }

    /// Developer/normal performance profiles must not let a huge decode wrap into a small admission.
    @Test func imageBudgetOverflowCannotWrapIntoSmallAdmission() {
        #expect(TranslationImageWorkBudget.requiredHeadroom(decodedBytes: .max) == .max)
        #expect(TranslationImageWorkBudget.requiredHeadroom(decodedBytes: 96_000_000) >= 1_280 * 1_024 * 1_024)
    }
}
