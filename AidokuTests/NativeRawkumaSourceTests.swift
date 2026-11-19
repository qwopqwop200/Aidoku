import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeRawkumaSourceTests {
    @Test func detailAndAJAXChaptersRetainKeysAndUTCDate() async throws {
        let source = RawkumaSourceRunner(fetch: { request in
            let html: String
            if request.url?.path == "/wp-admin/admin-ajax.php" {
                #expect(request.url?.query?.contains("manga_id=345") == true)
                html = """
                <div id="chapter-list"><div data-chapter-number="9.5"><a href="/manga/cat/chapter-9/">9</a>
                <time datetime="2026-09-01T00:00:00Z"></time></div><div data-chapter-number="invalid"></div></div>
                """
            } else {
                html = """
                <body class="single postid-345"><h1 class="text-2xl">猫</h1>
                <img class="object-cover wp-post-image" src="https://cdn.test/cat.jpg">
                <div id="tabpanel-description"><div itemprop="description">summary</div><a itemprop="genre">Ecchi</a></div>
                </body>
                """
            }
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await source.getMangaUpdate(manga: AidokuRunner.Manga(sourceKey: "ja.rawkuma", key: "/manga/cat/", title: "old"),
                                                   needsDetails: true, needsChapters: true)
        #expect(result.title == "猫" && result.description == "summary")
        #expect(result.contentRating == .suggestive)
        #expect(result.chapters?.count == 1)
        #expect(result.chapters?.first?.key == "/manga/cat/chapter-9/")
        #expect(result.chapters?.first?.chapterNumber == 9.5)
        #expect(result.chapters?.first?.dateUploaded == ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
    }
}
