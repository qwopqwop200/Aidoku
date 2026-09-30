import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct ReauditNHentaiTests {
    // Full API-v2 schema from the matching v17 Rust models, including fields
    // intentionally unused by the native port. The canonical API id differs
    // from an accepted leading-zero deep link.
    private static let gallery = """
    {"id":42,"media_id":"12","title":{"english":"Example","japanese":null,"pretty":"Example"},
    "cover":{"path":"/galleries/12/cover.jpg","width":300,"height":400},
    "thumbnail":{"path":"/galleries/12/thumb.jpg","width":150,"height":200},
    "scanlator":"","upload_date":1700000000,"tags":[],"num_pages":1,"num_favorites":0,
    "pages":[{"number":1,"path":"/galleries/12/1.jpg","width":600,"height":800,
    "thumbnail":"/galleries/12/1t.jpg","thumbnail_width":150,"thumbnail_height":200}]}
    """

    @Test func leadingZeroDeepLinkUsesCanonicalUpdatedKeyForChapterAndCache() async throws {
        let fixture = GalleryFixture()
        let runner = NHentaiSourceRunner(fetch: { await fixture.fetch($0) }, preference: { _ in nil })
        let link = try #require(try await runner.handleDeepLink(url: "https://nhentai.net/g/00042/"))
        let key = try #require(link.mangaKey)
        let manga = AidokuRunner.Manga(sourceKey: "multi.nhentai", key: key, title: "Existing")
        let updated = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        let chapter = try #require(updated.chapters?.first)
        // v17 calls manga.copy_from(gallery.into()) first; aidoku-rs b081870
        // copy_from replaces its key before chapter and cache construction.
        #expect(updated.key == "42")
        #expect(chapter.key == updated.key)
        #expect(chapter.url?.absoluteString == "https://nhentai.net/g/42")
        let pages = try await runner.getPageList(manga: updated, chapter: .init(key: updated.key))
        #expect(pages.first?.content == .url(url: URL(string: "https://i.nhentai.net/galleries/12/1.jpg")!))
        #expect(await fixture.requests.count == 1)
    }

    @Test func canceledCurrentOwnerHomeDoesNotPublishAnEmptyReplacementLayout() async throws {
        let recorder = HomeRecorder()
        let runner = NHentaiSourceRunner(fetch: { _ in
            Issue.record("An already canceled Home invocation reached the transport")
            throw CancellationError()
        }, preference: { _ in nil }, stringListPreference: { _ in [] })
        let publisher = try #require(runner.partialHomePublisher)
        let token = await publisher.sink { recorder.record($0) }
        let task = Task {
            try await PartialResultSubscription.$id.withValue(token) {
                // Cancel deterministically before actor entry, preserving the
                // current subscription: ownership alone cannot suppress this.
                withUnsafeCurrentTask { $0?.cancel() }
                return try await runner.getHome()
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.snapshots.isEmpty)
        await publisher.removeSink(token: token)
    }

    private final class HomeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Home] = []
        func record(_ home: Home) { lock.withLock { values.append(home) } }
        var snapshots: [Home] { lock.withLock { values } }
    }

    private actor GalleryFixture {
        var requests: [URLRequest] = []
        func fetch(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            return (
                Data(ReauditNHentaiTests.gallery.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }
}
