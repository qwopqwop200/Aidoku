import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeRawkumaSourceTests {
    @Test func searchPreservesSortIncludedExcludedAndModeOverrides() throws {
        let request = try RawkumaSourceRunner.searchRequest(query: "猫 & dog", page: 3, filters: [
            .sort(.init(id: "sort", index: 4, ascending: true)),
            .multiselect(id: "genre", included: ["action", "sci-fi"], excluded: ["horror"]),
            .select(id: "inclusion", value: "AND")
        ])
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://rawkuma.net/wp-admin/admin-ajax.php?action=advanced_search")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let params = try #require(URLComponents(string: "?" + body)?.queryItems)
        #expect(params.first { $0.name == "query" }?.value == "猫 & dog")
        #expect(params.filter { $0.name == "inclusion" }.map(\.value) == ["AND"])
        #expect(params.first { $0.name == "orderby" }?.value == "title")
        #expect(params.first { $0.name == "order" }?.value == "asc")
        #expect(params.first { $0.name == "genre" }?.value == "[\"action\",\"sci-fi\"]")
        #expect(params.first { $0.name == "genre_exclude" }?.value == "[\"horror\"]")
    }

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

    @Test func pagesResolveURLsAndSetRefererAndRejectHTTPFailure() async throws {
        let source = RawkumaSourceRunner(fetch: { request in
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://rawkuma.net/")
            let html = "<section data-image-data='x'><img src='/images/1.jpg'><img src='https://cdn.test/2.jpg'></section>"
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let manga = AidokuRunner.Manga(sourceKey: "ja.rawkuma", key: "/manga/cat/", title: "cat")
        let pages = try await source.getPageList(manga: manga, chapter: AidokuRunner.Chapter(key: "/manga/cat/chapter-1/"))
        #expect(pages.count == 2)
        if case .url(let url, _) = pages[0].content { #expect(url.absoluteString == "https://rawkuma.net/images/1.jpg") }
        else { Issue.record("Expected URL content") }
        let failure = RawkumaSourceRunner(fetch: { request in
            (Data("<body>blocked</body>".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: URLError.self) { try await failure.getMangaList(listing: AidokuRunner.Listing(id: "/manga/", name: "all"), page: 1) }
    }

    @Test func linksRejectForeignOriginsAndSeparateMangaFromChapter() async throws {
        let source = RawkumaSourceRunner(fetch: { _ in throw URLError(.unsupportedURL) })
        #expect(try await source.handleDeepLink(url: "https://rawkuma.net.evil/manga/cat/") == nil)
        let manga = try await source.handleDeepLink(url: "https://rawkuma.net/manga/cat/")
        #expect(manga?.mangaKey == "/manga/cat/" && manga?.chapterKey == nil)
        let chapter = try await source.handleDeepLink(url: "https://rawkuma.net/manga/cat/chapter-4.123/")
        #expect(chapter?.mangaKey == "/manga/cat/" && chapter?.chapterKey == "/manga/cat/chapter-4.123/")
    }
}
