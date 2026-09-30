import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct ReauditRawOtakuTests {
    @Test
    func authorlessAuthenticDetailsClearPreviouslyCachedCredits() async throws {
        // Reduced from the public 2026-09-30 response to
        // https://rawotaku.com/read/お風呂はまた明日-raw/ (HTTP 200).
        // Its #ani_detail has Type/Status/Views, with no Author or 著者 item.
        // MangaReader parser.rs resets both credits to None in this branch.
        let html = """
        <div id="ani_detail"><div class="anisc-detail">
          <h2 class="manga-name">お風呂はまた明日</h2>
          <div class="anisc-info">
            <div class="item item-title"><span class="item-head">タイプ:</span><a class="name" href="/raw-manga/">Raw Manga</a></div>
            <div class="item item-title"><span class="item-head">地位:</span><span class="name">Completed</span></div>
            <div class="item item-title"><span class="item-head">ビュー:</span><span class="name view">54</span></div>
          </div>
        </div></div>
        """
        let runner = RawOtakuSourceRunner(fetch: { request in
            (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let manga = AidokuRunner.Manga(
            sourceKey: "ja.rawotaku", key: "/read/お風呂はまた明日-raw/", title: "お風呂はまた明日",
            artists: ["Previously cached artist"], authors: ["Previously cached author"]
        )
        let updated = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false)
        #expect(updated.authors == nil)
        #expect(updated.artists == nil)
    }

    @Test
    func authenticChapterDeepLinkIsRecognizedAsAChapter() async throws {
        // Exact href/ids from the public book and reader responses (HTTP 200).
        // The reader wrapper has an unrelated English id; the Japanese list is
        // authoritative. Keys must also match MangaView's exact chapter lookup.
        let path = "/read/お風呂はまた明日/ja/chapter-1-raw/"
        let mangaPath = "/read/お風呂はまた明日-raw/"
        let details = try SwiftSoup.parse("<ul id='ja-chaps'>\(Self.listItem)</ul>", RawOtakuSourceRunner.base)
        let installedChapterKey = try #require(RawOtakuSourceRunner.parseChapters(details).first?.key)
        #expect(installedChapterKey.hasSuffix("#1853593"))
        for url in ["https://rawotaku.com" + path, try #require(URL(string: "https://rawotaku.com" + path)).absoluteString] {
            let runner = RawOtakuSourceRunner(fetch: { request in
                // iOS URL.path removes a trailing slash; URLComponents.path
                // preserves the decoded request path and its terminal slash.
                let requestURL = try #require(request.url)
                let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
                #expect(components.path == path)
                #expect(components.percentEncodedPath.hasSuffix("/"))
                return (Data(Self.readerHTML.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let link = try await runner.handleDeepLink(url: url)
            let result = try #require(link)
            #expect(result.mangaKey == mangaPath)
            #expect(result.chapterKey == installedChapterKey)
        }
        let runner = RawOtakuSourceRunner(fetch: { _ in
            Issue.record("Manga and foreign-host deep links should not fetch a reader")
            throw URLError(.badURL)
        })
        let manga = try await runner.handleDeepLink(url: RawOtakuSourceRunner.base + mangaPath)
        #expect(manga?.mangaKey == mangaPath && manga?.chapterKey == nil)
        #expect(try await runner.handleDeepLink(url: "https://rawotaku.com.evil" + path) == nil)
    }

    @Test
    func unfragmentedHomeChapterUsesMatchingJapaneseIDInsteadOfLegacyEnglishWrapper() async throws {
        // Home mangaChapterList keys omit the #id that details attach. The public
        // Japanese reader has wrapper id 1725371, which actually returns 22
        // unrelated images; its JA item 1853593 returns the one stacked JPEG.
        let runner = RawOtakuSourceRunner(fetch: { request in
            let bytes: Data
            let requestURL = try #require(request.url)
            let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
            switch components.path {
                case "/read/お風呂はまた明日/ja/chapter-1-raw/": bytes = Data(Self.readerHTML.utf8)
                case "/json/chapter":
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    #expect(query?.first(where: { $0.name == "id" })?.value == "1853593")
                    #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
                    bytes = try JSONSerialization.data(withJSONObject: ["status": 1, "html": """
                    <div class="container-reader-chapter"><div class="iv-card loader shuffled active">
                      <img src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
                           data-src="https://sv1.freeimgmg.online/files/28732/1057952/1.jpg" class="image-vertical lazyload" alt="0">
                    </div></div>
                    """])
                case "/files/28732/1057952/1.jpg":
                    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-16383")
                    // Exact 177-byte public 206 header through SOF0: 1426 x 53248.
                    bytes = try #require(Data(base64Encoded: Self.jpegHeader))
                default: throw URLError(.badURL)
            }
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let pages = try await runner.getPageList(
            manga: AidokuRunner.Manga(sourceKey: "ja.rawotaku", key: "/read/お風呂はまた明日-raw/", title: "お風呂はまた明日"),
            chapter: AidokuRunner.Chapter(key: "/read/お風呂はまた明日/ja/chapter-1-raw/")
        )
        #expect(pages.count == 26)
        for (index, page) in pages.enumerated() {
            guard case .url(let url, let context) = page.content else { Issue.record("Expected URL page"); return }
            #expect(url.absoluteString == "https://sv1.freeimgmg.online/files/28732/1057952/1.jpg")
            #expect(context == ["slice": String(index), "slices": "26"])
        }
    }

    private static let listItem = """
    <li class="item reading-item chapter-item" data-id="1853593" data-number="1">
      <a href="https://rawotaku.com/read/お風呂はまた明日/ja/chapter-1-raw/" class="item-link" title="章 1: 第1話">
        <span class="name">第1話: 第1話</span>
      </a>
    </li>
    """

    private static var readerHTML: String {
        """
        <div id="wrapper" data-reading-id="1725371" data-lang-code="en" data-manga-id="869">
          <a href="https://rawotaku.com/read/お風呂はまた明日-raw/" class="hr-manga"><h2 class="manga-name">お風呂はまた明日</h2></a>
          <ul id="ja-chapters">\(listItem)</ul>
        </div>
        """
    }

    private static let jpegHeader =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//"
        + "2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCNAABZIDASIAAhEBAxEB"
}
