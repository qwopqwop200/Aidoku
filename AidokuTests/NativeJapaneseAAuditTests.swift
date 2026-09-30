import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeJapaneseAAuditTests {
    @Test func groupASearchQueryPreservesLiteralPlusAcrossFormDecoding() throws {
        let url = try GroupASourceSupport.url("https://mangarawjp.tv", path: "/", query: [
            URLQueryItem(name: "s", value: "C++ & 猫")
        ])
        let encoded = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        // PHP/WordPress query parsing treats an unescaped plus as a space.
        let decoded = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        #expect(decoded == "s=C++ & 猫")
    }

    @Test func mangaRawBestStableStatusValuePrecedesDisplayLabel() async throws {
        let runner = MangarawBestSourceRunner(fetch: { request in
            let html = "<main><h1>Series</h1></main><a href='/manga-list?filter%5Bstatus%5D=2'>完了</a>"
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await runner.getMangaUpdate(
            manga: AidokuRunner.Manga(sourceKey: "ja.mangarawbest", key: "series", title: "Series"),
            needsDetails: true, needsChapters: false
        )
        #expect(result.status == .ongoing)
        #expect(result.updateStrategy == .always)
    }

    @Test func groupAProvidesUpstreamDetailPartials() async {
        let best = MangarawBestSourceRunner()
        let jp = MangarawJPSourceRunner()
        let dev = RawdevartSourceRunner()
        #expect(await best.partialMangaPublisher != nil)
        #expect(await jp.partialMangaPublisher != nil)
        #expect(await dev.partialMangaPublisher != nil)
    }
}
