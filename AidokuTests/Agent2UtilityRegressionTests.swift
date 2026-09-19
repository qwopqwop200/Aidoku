import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite struct Agent2UtilityRegressionTests {
    @Test func configuredTimeoutIsApplied() {
        let session = URLSession.withTimeoutInterval(3.5)
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.timeoutIntervalForRequest == 3.5)
    }

    @Test func blockingCompletionSupportsNilAndRepeatedFailure() async {
        await Task.detached {
            let nilTask = BlockingTask<Int?> { nil }
            #expect(nilTask.get() == nil)
            #expect(nilTask.get() == nil)
            enum ExpectedError: Error { case failure }
            let failed = BlockingThrowingTask<Int> { throw ExpectedError.failure }
            for _ in 0..<2 {
                #expect(throws: ExpectedError.self) { try failed.get() }
            }
        }.value
    }

    @Test @MainActor func archivePageRoundtripRetainsArchiveContent() {
        let page = AidokuRunner.Page(content: .zipFile(url: URL(fileURLWithPath: "/tmp/chapter.cbz"), filePath: "pages/001.jpg"))
        let roundtrip = page.toOld(sourceId: "local", chapterId: "chapter", language: nil).toNew()
        guard case let .zipFile(url, filePath) = roundtrip.content else {
            Issue.record("Archive page changed into an ordinary URL")
            return
        }
        #expect(url.path == "/tmp/chapter.cbz")
        #expect(filePath == "pages/001.jpg")
    }
    @Test func localImageURLsStayInsideDocumentsAndRoundtripReservedCharacters() throws {
        #expect(URL(string: "aidoku-image:///../Library/secret")?.toAidokuFileUrl() == nil)
        let document = FileManager.default.documentDirectory.appendingPathComponent("Covers/name#?%.png")
        let portable = try #require(document.toAidokuImageUrl())
        #expect(portable.toAidokuFileUrl() == document.standardizedFileURL.resolvingSymlinksInPath())
        let sibling = FileManager.default.documentDirectory.deletingLastPathComponent().appendingPathComponent("Documents-other/file.png")
        #expect(sibling.toAidokuImageUrl() == nil)
    }

}
