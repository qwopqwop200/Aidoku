import AidokuRunner
import Foundation
import SwiftSoup

/// Swift port of the backed ja.rawkuma v6 Tukutema source.
/// Source: Aidoku-Community/sources, templates/tukutema (MIT / Apache-2.0).
actor RawkumaSourceRunner: NativeSourceRunnerLifecycle {
    typealias Fetch = NativeSourceNetwork.Fetch
    static let base = "https://rawkuma.net"
    let sourceKey: String
    let features = SourceFeatures(providesListings: true, providesHome: true, handlesDeepLinks: true)
    let partialMangaPublisher: SinglePublisher<AidokuRunner.Manga>? = SinglePublisher()
    private let fetch: Fetch

    init(sourceKey: String = "ja.rawkuma", fetch: Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    func restart() async throws { try Task.checkCancellation() }
    func clearCache() async {}

    private func document(_ request: URLRequest) async throws -> Document {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return try SwiftSoup.parse(html, request.url?.absoluteString ?? Self.base)
    }

    private func request(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: URL(string: Self.base))?.absoluteURL,
              url.host == "rawkuma.net", ["http", "https"].contains(url.scheme ?? "") else { throw URLError(.badURL) }
        return URLRequest(url: url)
    }

    static func searchRequest(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) throws -> URLRequest {
        guard page > 0 else { throw URLError(.badURL) }
        var parameters: [(String, String)] = [("page", String(page))]
        if let query { parameters.append(("query", query)) }
        parameters += [("inclusion", "OR"), ("exclusion", "OR")]
        for filter in filters {
            switch filter {
            case .sort(let sort):
                let fields = ["popular", "rating", "updated", "bookmarked", "title"]
                let index = Int(sort.index)
                parameters.append(("orderby", fields.indices.contains(index) ? fields[index] : "popular"))
                parameters.append(("order", sort.ascending ? "asc" : "desc"))
            case let .select(id, value):
                parameters.removeAll { $0.0 == id }
                parameters.append((id, value))
            case let .multiselect(id, included, excluded):
                if !included.isEmpty {
                    parameters.append((id, String(decoding: try JSONEncoder().encode(included), as: UTF8.self)))
                }
                if !excluded.isEmpty {
                    parameters.append((id + "_exclude", String(decoding: try JSONEncoder().encode(excluded), as: UTF8.self)))
                }
            default: break
            }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = parameters.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
                + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: Self.base + "/wp-admin/admin-ajax.php?action=advanced_search")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func key(_ url: String) -> String {
        url.hasPrefix(Self.base) ? String(url.dropFirst(Self.base.count)) : url
    }

    private func attribute(_ element: Element?, _ name: String) throws -> String? {
        guard let element, try element.hasAttr(name) else { return nil }
        return try element.attr(name)
    }

    private func card(_ element: Element, linkSelector: String, titleSelector: String?,
                      requiredSelectors: [String] = []) throws -> AidokuRunner.Manga? {
        for selector in requiredSelectors where try element.select(selector).first() == nil { return nil }
        guard let link = try element.select(linkSelector).first(), let href = try attribute(link, "href") else { return nil }
        let title = try titleSelector.map { try element.select($0).first()?.text() ?? "" } ?? link.text()
        return AidokuRunner.Manga(sourceKey: sourceKey, key: key(href), title: title,
                     cover: try attribute(element.select("img").first(), "src"))
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        let doc = try await document(Self.searchRequest(query: query, page: page, filters: filters))
        let mangas = try doc.select("body > div").array().compactMap {
            try card($0, linkSelector: "a.text-base", titleSelector: nil, requiredSelectors: ["img"])
        }
        return AidokuRunner.MangaPageResult(entries: mangas, hasNextPage: try !doc.select("body > div.flex button > svg").isEmpty())
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        guard page > 0 else { throw URLError(.badURL) }
        let doc = try await document(request(path: listing.id + "?the_page=\(page)"))
        let mangas = try doc.select("#search-results > div").array().compactMap {
            try card($0, linkSelector: "a", titleSelector: "h1", requiredSelectors: ["h1", "img"])
        }
        return AidokuRunner.MangaPageResult(entries: mangas, hasNextPage: try !doc.select("div.flex.items-center.gap-2 > a > svg").isEmpty())
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        var result = manga
        let mangaRequest = try request(path: manga.key)
        let doc = try await document(mangaRequest)
        if needsDetails {
            result.title = try doc.select("h1.text-2xl").first()?.text() ?? result.title
            result.cover = try attribute(doc.select("img.object-cover.wp-post-image").first(), "src") ?? result.cover
            result.description = try doc.select("#tabpanel-description div[itemprop=description]").first()?.text()
            result.url = mangaRequest.url
            result.tags = try doc.select("#tabpanel-description a[itemprop=genre]").array().map { try $0.text() }
            let tags = result.tags ?? []
            result.contentRating = tags.contains(where: { ["Adult", "Hentai", "Mature"].contains($0) }) ? .nsfw
                : (tags.contains("Ecchi") ? .suggestive : .safe)
            let kind = try doc.select("div.space-y-2 > div > h4:contains(Type) + div.inline > p").first()?.text().lowercased()
            switch kind {
            case "manga", "oel", "one-shot": result.viewer = .rightToLeft
            case "manhua", "manhwa": result.viewer = .webtoon
            default: result.viewer = .unknown
            }
            try Task.checkCancellation()
            await partialMangaPublisher?.send(result, to: PartialResultSubscription.id)
        }
        if needsChapters {
            guard let body = doc.body(),
                  let id = try body.className().split(separator: " ").first(where: { $0.hasPrefix("postid-") })?
                    .dropFirst("postid-".count), !id.isEmpty else { throw URLError(.cannotParseResponse) }
            var components = URLComponents(string: Self.base + "/wp-admin/admin-ajax.php")!
            components.queryItems = [URLQueryItem(name: "manga_id", value: String(id)), URLQueryItem(name: "page", value: "1"),
                                     URLQueryItem(name: "action", value: "chapter_list")]
            let chaptersDoc = try await document(URLRequest(url: components.url!))
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            result.chapters = try chaptersDoc.select("#chapter-list > div").array().compactMap { element in
                guard let number = Float(try element.attr("data-chapter-number")),
                      let link = try element.select("a").first(), let href = try attribute(link, "href"),
                      let url = URL(string: href, relativeTo: mangaRequest.url)?.absoluteURL else { return nil }
                let datetime = try attribute(element.select("time").first(), "datetime")
                return AidokuRunner.Chapter(key: key(url.absoluteString), chapterNumber: number,
                               dateUploaded: datetime.flatMap { date.date(from: $0) }, url: url)
            }
        }
        return result
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        var request = try request(path: chapter.key)
        request.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        let doc = try await document(request)
        return try doc.select("section[data-image-data] > img").array().compactMap { element in
            guard let src = try attribute(element, "src"), let url = URL(string: src, relativeTo: request.url)?.absoluteURL else { return nil }
            return AidokuRunner.Page(content: .url(url: url))
        }
    }

    func getHome() async throws -> Home {
        let doc = try await document(request(path: "/"))
        var components: [HomeComponent] = []
        if let hero = try doc.select("section.hero-slider").first() {
            let entries = try hero.select(".swiper > .swiper-wrapper > .swiper-slide").array().compactMap { element -> AidokuRunner.Manga? in
                guard let link = try element.select("a").first(), let href = try attribute(link, "href") else { return nil }
                return AidokuRunner.Manga(sourceKey: sourceKey, key: key(href), title: try link.select("span").first()?.text() ?? "",
                             cover: try attribute(element.select("img").first(), "src"),
                             description: try link.select("div").first()?.text(),
                             tags: try element.select("span > a").array().map { try $0.text() })
            }
            components.append(HomeComponent(title: nil, value: .bigScroller(entries: entries, autoScrollInterval: 5)))
        }
        if let trending = try doc.select(".trending-slider").first() {
            let entries = try trending.select(".swiper > .swiper-wrapper > .swiper-slide").array().compactMap {
                try card($0, linkSelector: "a", titleSelector: ".title > h4")
            }
            components.append(HomeComponent(title: "Popular Today", value: .scroller(entries: entries.map { HomeComponent.Value.Link(title: $0.title, imageUrl: $0.cover, value: .manga($0)) })))
        }
        for list in try doc.select("div.project.group").array() {
            let title = try list.select("h2").first()?.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
            let entries = try list.select(".grid > div").array().compactMap { element -> MangaWithChapter? in
                guard let link = try element.select("a").first(), let href = try attribute(link, "href"),
                      let chapterLink = try element.select("ul > li a").first(),
                      let chapterHref = try attribute(chapterLink, "href") else { return nil }
                let manga = AidokuRunner.Manga(sourceKey: sourceKey, key: key(href), title: try attribute(link, "title") ?? "",
                                  cover: try attribute(element.select("img").first(), "src"))
                return MangaWithChapter(manga: manga, chapter: AidokuRunner.Chapter(key: key(chapterHref), title: try chapterLink.text()))
            }
            let href = try attribute(list.select("h2 + a").first(), "href")
            components.append(HomeComponent(title: title, value: .mangaChapterList(entries: entries,
                listing: href.map { AidokuRunner.Listing(id: key($0), name: title ?? "") })))
        }
        if let ranking = try doc.select(".widget_trending_posts").first() {
            let title = try ranking.select("h3").first()?.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
            let entries = try ranking.select(".trending-content > ul li").array().compactMap { try card($0, linkSelector: "h2 > a", titleSelector: nil) }
            components.append(HomeComponent(title: title, value: .mangaList(ranking: true, entries: entries.map { HomeComponent.Value.Link(title: $0.title, imageUrl: $0.cover, value: .manga($0)) })))
        }
        return Home(components: components)
    }

    func handleDeepLink(url: String) async throws -> DeepLinkResult? {
        guard let incoming = URL(string: url), incoming.host == "rawkuma.net", incoming.user == nil, incoming.password == nil,
              ["http", "https"].contains(incoming.scheme ?? ""), incoming.path.hasPrefix("/manga/") else { return nil }
        // URL.path removes a trailing slash; the source uses that slash in manga/chapter keys.
        guard let path = URLComponents(url: incoming, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        let slashes = path.indices.filter { path[$0] == "/" }
        if slashes.count >= 3, slashes.count > 3 || !path.hasSuffix("/") {
            return DeepLinkResult(mangaKey: String(path[...slashes[2]]), chapterKey: path)
        }
        return DeepLinkResult(mangaKey: path)
    }
}
