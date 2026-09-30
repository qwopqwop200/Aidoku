import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct NativeJapaneseGroupATests {
    @Test func mangaRawBestListingKeepsBareSlugLazyCoverAndPagination() throws {
        let doc = try SwiftSoup.parse("""
        <div class="manga-vertical"><a href="/raw/series/di-2hua"></a>
        <div class="post-title"><a>Series</a></div><img class="cover" src="/placeholder" data-src="/cover.jpg"></div>
        <a class="paging_prevnext next" href="/manga-list?page=4">Last</a>
        """, "https://mangaraw.best/")
        let result = try MangarawBestSourceRunner.parseListing(doc, sourceKey: "ja.mangarawbest", page: 2)
        #expect(result.entries.first?.key == "series")
        #expect(result.entries.first?.cover == "https://mangaraw.best/cover.jpg")
        #expect(result.hasNextPage)
        #expect(try !MangarawBestSourceRunner.parseListing(doc, sourceKey: "ja.mangarawbest", page: 4).hasNextPage)
    }

    @Test func mangaRawBestChaptersPreserveDecimalNumbersExtraTitlesAndRelativeDates() throws {
        let now = Date(timeIntervalSince1970: 100000)
        let doc = try SwiftSoup.parse("""
        <div id="chapterList"><ul><li><a href="/raw/series/ch-2">
        <span class="text-ellipsis">第2.5話</span><span class="timeago">2時間前</span></a></li>
        <li><a href="/raw/series/ch-3"><span class="text-ellipsis">第3話 おまけ</span></a></li></ul></div>
        """, "https://mangaraw.best/")
        let chapters = try MangarawBestSourceRunner.parseChapters(doc, now: now)
        #expect(chapters.count == 2)
        #expect(chapters[0].chapterNumber == 2.5)
        #expect(chapters[0].title == nil)
        #expect(chapters[0].dateUploaded == now.addingTimeInterval(-7200))
        #expect(chapters[1].title == "第3話 おまけ")
    }

    @Test func mangaRawJPListingScopesFirstBlockAndCleansTitle() throws {
        let doc = try SwiftSoup.parse("""
        <div class="post-list"><a href="/manga-raw/one/"><h3>One Raw Free</h3><img data-src="/one.jpg" src="data:image/png;base64,placeholder"></a></div>
        <div class="post-list"><a href="/manga-raw/two/"><h3>Ranking</h3></a></div>
        """, "https://mangarawjp.tv/")
        let result = try MangarawJPSourceRunner.parseListing(doc, sourceKey: "ja.mangarawjp")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].key == "/manga-raw/one/")
        #expect(result.entries[0].title == "One")
        #expect(result.entries[0].cover == "https://mangarawjp.tv/one.jpg")
    }

    @Test func mangaRawJPReaderIDsParseScriptDataWithoutExecutingScripts() throws {
        let doc = try SwiftSoup.parse("<script>window.MangaId = 133; window.CNumber = 10.5; throw new Error('must never execute');</script>")
        let ids = try MangarawJPSourceRunner.readerIDs(doc)
        #expect(ids.0 == "133")
        #expect(ids.1 == "10.5")
        #expect(throws: (any Error).self) { try MangarawJPSourceRunner.readerIDs(SwiftSoup.parse("<script>window.other=1</script>")) }
    }

    @Test func rawdevartDecimalChapterKeysAndNullableListsDecode() throws {
        #expect(RawdevartSourceRunner.chapterKey(34.2) == "34.2")
        #expect(RawdevartSourceRunner.chapterKey(1) == "1")
        let data = Data("""
        {"manga_list":[{"manga_id":854721,"manga_name":" AR/MS!! ","manga_cover_img":"small","manga_cover_img_full":"full"}],"pagi":{"button":{"next":2}},"genreOpt":null}
        """.utf8)
        let response = try JSONDecoder().decode(RawdevartSourceRunner.ListResponse.self, from: data)
        let result = response.mangaPage(sourceKey: "ja.rawdevart")
        #expect(result.hasNextPage)
        #expect(result.entries[0].key == "854721")
        #expect(result.entries[0].cover == "full")
        #expect(result.entries[0].title == "AR/MS!!")
    }

    @Test func groupADeepLinksDoNotAcceptHostLookalikes() async throws {
        let best = MangarawBestSourceRunner()
        let jp = MangarawJPSourceRunner()
        let dev = RawdevartSourceRunner()
        #expect(try await best.handleDeepLink(url: "https://mangaraw.best.evil/raw/a") == nil)
        #expect(try await jp.handleDeepLink(url: "https://mangarawjp.tv.evil/manga-raw/a/") == nil)
        #expect(try await dev.handleDeepLink(url: "https://rawdevart.art.evil/g/ne123") == nil)
        let decimal = try await dev.handleDeepLink(url: "https://rawdevart.art/read/ne16523/chapter-34.2?track=1")
        #expect(decimal?.mangaKey == "16523")
        #expect(decimal?.chapterKey == "34.2")
    }

    @Test func rawdevartPageFragmentsUseServerAndDecimalEndpoint() async throws {
        let fetch: NativeSourceNetwork.Fetch = { request in
            #expect(request.url?.path == "/spa/manga/16523/34.2")
            let data = Data(#"{"chapter_detail":{"chapter_content":"<div class='chapter-img'><img data-src='/data/page.webp'></div>","server":"https://images.example/"}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        let runner = RawdevartSourceRunner(fetch: fetch)
        let pages = try await runner.getPageList(manga: .init(sourceKey: "ja.rawdevart", key: "16523", title: ""), chapter: .init(key: "34.2"))
        #expect(pages.count == 1)
        if case .url(let url, _) = pages[0].content { #expect(url.absoluteString == "https://images.example/data/page.webp") }
        else { Issue.record("Expected URL page") }
    }
}
