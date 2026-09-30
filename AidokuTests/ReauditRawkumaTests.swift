import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct ReauditRawkumaTests {
    @Test func searchAndListingSkipCardsMissingUpstreamRequiredElements() async throws {
        let runner = RawkumaSourceRunner(fetch: { request in
            let html: String
            if request.httpMethod == "POST" {
                html = """
                <div><a class="text-base" href="/manga/valid/">Valid</a><img src="https://cdn.test/valid.jpg"></div>
                <div><a class="text-base" href="/manga/no-image/">No image</a></div>
                <div><a class="text-base" href="/manga/missing-src/">Missing src</a><img></div>
                <div class="flex"><button><svg></svg></button></div>
                """
            } else {
                html = """
                <div id="search-results">
                  <div><a href="/manga/valid/"></a><h1>Valid</h1><img src="https://cdn.test/valid.jpg"></div>
                  <div><a href="/manga/no-title/"></a><img src="https://cdn.test/no-title.jpg"></div>
                  <div><a href="/manga/no-image/"></a><h1>No image</h1></div>
                  <div><a href="/manga/missing-src/"></a><h1>Missing src</h1><img></div>
                </div><div class="flex items-center gap-2"><a><svg></svg></a></div>
                """
            }
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let search = try await runner.getSearchMangaList(query: nil, page: 1, filters: [])
        #expect(search.entries.map(\.key) == ["/manga/valid/", "/manga/missing-src/"])
        #expect(search.entries.last?.cover == nil && search.hasNextPage)
        let listing = try await runner.getMangaList(listing: AidokuRunner.Listing(id: "/latest-update/", name: "Latest Update"), page: 2)
        #expect(listing.entries.map(\.key) == ["/manga/valid/", "/manga/missing-src/"])
        #expect(listing.entries.last?.cover == nil && listing.hasNextPage)
    }

    @Test func homePreservesSiblingHeroGenresAndAllFourUpstreamLayouts() async throws {
        // The public homepage has the genre span outside the title/description anchor.
        // This captures that relationship without depending on its rotating titles.
        let html = """
        <section class="hero-slider"><div class="swiper"><div class="swiper-wrapper"><div class="swiper-slide">
          <div><a href="https://rawkuma.net/manga/hero/"><span>Hero</span><div>Hero description</div></a>
          <div><span><a href="/genre/action/">Action</a><a href="/genre/adventure/">Adventure</a>
          <a href="/genre/fantasy/">Fantasy</a><a href="/genre/school-life/">School Life</a>
          <a href="/genre/seinen/">Seinen</a></span></div></div><img src="https://cdn.test/hero.jpg">
        </div></div></div></section>
        <div class="trending-slider"><div class="swiper"><div class="swiper-wrapper"><div class="swiper-slide">
          <a href="/manga/popular/"><img src="https://cdn.test/popular.jpg"></a><div class="title"><h4>Popular</h4></div>
        </div></div></div></div>
        <div class="project group"><h2> Latest Update <span>ignored badge</span></h2><a href="https://rawkuma.net/latest-update/">More</a>
          <div class="grid"><div><a href="https://rawkuma.net/manga/latest/" title="Latest"><img src="https://cdn.test/latest.jpg"></a>
          <ul><li><a href="https://rawkuma.net/manga/latest/chapter-7/">Chapter 7</a></li></ul></div></div>
        </div>
        <div class="widget_trending_posts"><h3> Ranking <span>ignored badge</span></h3><div class="trending-content"><ul>
          <li><img src="https://cdn.test/ranked.jpg"><h2><a href="/manga/ranked/">Ranked</a></h2></li>
        </ul></div></div>
        """
        let runner = RawkumaSourceRunner(fetch: { request in
            #expect(request.url?.absoluteString == "https://rawkuma.net/")
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let home = try await runner.getHome()
        #expect(home.components.count == 4)
        let components = home.components
        guard components.count == 4 else { return }
        if case let .bigScroller(entries, interval) = components[0].value {
            let hero = try #require(entries.first)
            #expect(entries.count == 1 && interval == 5)
            #expect(hero.key == "/manga/hero/" && hero.title == "Hero")
            #expect(hero.cover == "https://cdn.test/hero.jpg" && hero.description == "Hero description")
            #expect(hero.tags == ["Action", "Adventure", "Fantasy", "School Life", "Seinen"])
        } else { Issue.record("Expected hero big scroller") }
        if case let .scroller(entries, listing) = components[1].value {
            #expect(components[1].title == "Popular Today" && listing == nil)
            #expect(entries.map(\.title) == ["Popular"])
            if case let .manga(manga)? = entries.first?.value { #expect(manga.key == "/manga/popular/") }
            else { Issue.record("Expected popular manga link") }
        } else { Issue.record("Expected popular scroller") }
        if case let .mangaChapterList(pageSize, entries, listing) = components[2].value {
            #expect(components[2].title == "Latest Update" && pageSize == nil)
            #expect(listing?.id == "/latest-update/" && listing?.name == "Latest Update")
            #expect(entries.first?.manga.key == "/manga/latest/" && entries.first?.manga.title == "Latest")
            #expect(entries.first?.chapter.key == "/manga/latest/chapter-7/" && entries.first?.chapter.title == "Chapter 7")
        } else { Issue.record("Expected latest manga/chapter list") }
        if case let .mangaList(ranking, pageSize, entries, listing) = components[3].value {
            #expect(components[3].title == "Ranking" && ranking && pageSize == nil && listing == nil)
            #expect(entries.map(\.title) == ["Ranked"])
        } else { Issue.record("Expected ranked manga list") }
    }

    @Test func missingDetailsKeepCoverAndTitleWhileClearingDescriptionAndTags() async throws {
        let runner = RawkumaSourceRunner(fetch: { request in
            return (Data("<body></body>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let original = AidokuRunner.Manga(sourceKey: "ja.rawkuma", key: "/manga/cat/", title: "Cat",
                                         cover: "https://cdn.test/cat.jpg", description: "old", tags: ["Mature"],
                                         status: .ongoing, contentRating: .nsfw, viewer: .webtoon,
                                         chapters: [AidokuRunner.Chapter(key: "/manga/cat/chapter-1/")])
        let result = try await runner.getMangaUpdate(manga: original, needsDetails: true, needsChapters: false)
        #expect(result.title == original.title && result.cover == original.cover)
        #expect(result.description == nil && result.tags == [])
        #expect(result.contentRating == .safe && result.viewer == .unknown)
        #expect(result.status == .ongoing && result.chapters == original.chapters)
        #expect(result.url?.absoluteString == "https://rawkuma.net/manga/cat/")
    }

    @Test func encodedMangaAndChapterDeepLinksPreserveExactPathAndTrailingSlash() async throws {
        let runner = RawkumaSourceRunner(fetch: { _ in throw URLError(.unsupportedURL) })
        let slug = "magical-%e2%98%85-explorer"
        let manga = try await runner.handleDeepLink(url: "https://rawkuma.net/manga/\(slug)/")
        #expect(manga?.mangaKey == "/manga/\(slug)/" && manga?.chapterKey == nil)
        let chapter = try await runner.handleDeepLink(url: "https://rawkuma.net/manga/\(slug)/chapter-99.128019/")
        #expect(chapter?.mangaKey == "/manga/\(slug)/")
        #expect(chapter?.chapterKey == "/manga/\(slug)/chapter-99.128019/")
    }
}
