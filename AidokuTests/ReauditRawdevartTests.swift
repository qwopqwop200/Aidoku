import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct ReauditRawdevartTests {
    @Test(arguments: [
        #"{}"#,
        #"{"manga_cover_img":null,"manga_cover_img_full":null}"#
    ])
    func nullableDetailCoverPreservesPreviouslyKnownCover(detail: String) async throws {
        // Matching ja.rawdevart v3 lib.rs only replaces the existing cover when
        // full.or(small) is Some. Both omission and explicit null are valid.
        let runner = RawdevartSourceRunner(fetch: { request in
            #expect(request.url?.path == "/spa/manga/854721")
            return (
                Data("{\"detail\":\(detail)}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        })
        let original = AidokuRunner.Manga(
            sourceKey: "ja.rawdevart", key: "854721", title: "AR/MS!!", cover: "https://images.example/known.jpg"
        )
        let updated = try await runner.getMangaUpdate(manga: original, needsDetails: true, needsChapters: false)
        #expect(updated.cover == original.cover)
    }

    @Test(arguments: [
        "ftp://rawdevart.art/g/ne854721",
        "file://rawdevart.art/g/ne854721",
        "https://user@rawdevart.art/g/ne854721",
        "https://user:password@rawdevart.art/g/ne854721"
    ])
    func deepLinksRejectUnsupportedSchemesAndUserInfo(url: String) async throws {
        #expect(try await RawdevartSourceRunner().handleDeepLink(url: url) == nil)
    }

    @Test(arguments: ["http", "https"])
    func webDeepLinksPreserveMangaAndDecimalChapterRouting(scheme: String) async throws {
        let runner = RawdevartSourceRunner()
        let manga = try await runner.handleDeepLink(url: "\(scheme)://rawdevart.art/g/ne854721?utm_source=share#top")
        #expect(manga?.mangaKey == "854721")
        #expect(manga?.chapterKey == nil)
        let chapter = try await runner.handleDeepLink(url: "\(scheme)://rawdevart.art/read/ne16523/chapter-34.2")
        #expect(chapter?.mangaKey == "16523")
        #expect(chapter?.chapterKey == "34.2")
    }
}
