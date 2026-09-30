import AidokuRunner
import Foundation
import SwiftSoup

/// ko.yomii v7 recovered from the backed module's static data and control flow.
/// Provenance and selector offsets are recorded in Docs/NativeYomiiRecovery.md.
actor YomiiSourceRunner: AidokuRunner.Runner {
    typealias Fetch = NativeSourceNetwork.Fetch
    let sourceKey: String
    let features = AidokuRunner.SourceFeatures(providesListings: true, providesHome: true, providesImageRequests: true, handlesDeepLinks: true)
    private let fetch: Fetch
    static let base = URL(string: "https://11toon.com")!
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
    enum Failure: Error { case malformedResponse, unsupportedListing, invalidKey, missingImages, excessivePagination }

    init(sourceKey: String = "ko.yomii", fetch: Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    static func request(path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw URLError(.badURL) }
        return imageRequest(url: url, method: method)
    }

    static func imageRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
        return request
    }

    private func data(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private func document(_ request: URLRequest) async throws -> Document {
        let data = try await data(request)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.malformedResponse }
        return try SwiftSoup.parse(text, request.url?.absoluteString ?? Self.base.absoluteString)
    }

    static func listingItems(_ id: String) throws -> [URLQueryItem] {
        switch id {
        case "latest": return [.init(name: "bo_table", value: "toon_c"), .init(name: "type", value: "upd")]
        case "popular": return [.init(name: "bo_table", value: "toon_c"), .init(name: "tablename", value: "인기만화")]
        case "daily100": return [.init(name: "bo_table", value: "toon_c"), .init(name: "tablename", value: "매일 추천 100"), .init(name: "type", value: "today")]
        case "completed": return [.init(name: "bo_table", value: "toon_c"), .init(name: "is_over", value: "1"), .init(name: "tablename", value: "완결만화")]
        default: throw Failure.unsupportedListing
        }
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        var items = try Self.listingItems(listing.id)
        items.append(.init(name: "page", value: String(max(page, 1))))
        let document = try await document(Self.request(path: "bbs/board.php", query: items))
        return try AidokuRunner.MangaPageResult(entries: Self.cards(document, sourceKey: sourceKey, completed: listing.id == "completed"),
                                   hasNextPage: !document.select("a.pg_next").isEmpty())
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        if let query, !query.isEmpty {
            if page > 1 { return AidokuRunner.MangaPageResult(entries: [], hasNextPage: false) }
            let response = try await data(Self.request(path: "bbs/ajax.search.php", query: [.init(name: "search_key", value: query.trimmingCharacters(in: .whitespacesAndNewlines))]))
            // Backed func124 resets hidden genre/sort filters for a nonempty text query.
            return AidokuRunner.MangaPageResult(entries: try Self.searchMangas(response, sourceKey: sourceKey, filters: []), hasNextPage: false)
        }
        let sort = filters.compactMap { filter -> Int? in if case let .sort(value) = filter, value.id == "sort" { Int(value.index) } else { nil } }.last ?? 0
        let genre = filters.compactMap { filter -> String? in if case let .select(id, value) = filter, id == "genre", !value.isEmpty { value } else { nil } }.last
        var items = try Self.listingItems(sort == 1 ? "popular" : "latest")
        if sort != 1 { items.append(.init(name: "tablename", value: "최신만화")) }
        if sort != 1, let genre { items.append(.init(name: "sca", value: genre)) }
        items.append(.init(name: "page", value: String(max(page, 1))))
        let document = try await document(Self.request(path: "bbs/board.php", query: items))
        var entries = try Self.cards(document, sourceKey: sourceKey)
        if sort == 1, let genre { entries.removeAll { !($0.tags?.contains(genre) ?? false) } }
        return try AidokuRunner.MangaPageResult(entries: entries, hasNextPage: !document.select("a.pg_next").isEmpty())
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        guard Self.numericKey(manga.key) else { throw Failure.invalidKey }
        let items: [URLQueryItem] = [.init(name: "bo_table", value: "toons"), .init(name: "is", value: manga.key)]
        let document = try await document(Self.request(path: "bbs/board.php", query: items))
        var result = manga
        if needsDetails { result = try Self.details(document, manga: manga) }
        if needsChapters {
            var chapters = try Self.chapters(document, mangaKey: manga.key)
            let pageCount = try Self.chapterPageCount(document)
            // Backed contract has maximumParallelRequests=5; keep native fan-out bounded.
            let fetch = fetch
            for start in stride(from: 2, through: pageCount, by: 5) {
                try Task.checkCancellation()
                let end = min(start + 4, pageCount)
                var batch: [(Int, [AidokuRunner.Chapter])] = []
                try await withThrowingTaskGroup(of: (Int, [AidokuRunner.Chapter]).self) { group in
                    for page in start...end {
                        let request = try Self.request(path: "bbs/board.php", query: items + [.init(name: "page", value: String(page))])
                        let key = manga.key
                        group.addTask {
                            try Task.checkCancellation()
                            let (data, response) = try await fetch(request)
                            try Task.checkCancellation()
                            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                                  let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
                            let document = try SwiftSoup.parse(text, request.url!.absoluteString)
                            return (page, try Self.chapters(document, mangaKey: key))
                        }
                    }
                    for try await result in group { batch.append(result) }
                }
                chapters += batch.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
            result.chapters = chapters
        }
        return result
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        guard Self.numericKey(manga.key), Self.numericKey(chapter.key) else { throw Failure.invalidKey }
        let request = try Self.request(path: "bbs/board.php", query: [
            .init(name: "bo_table", value: "toons"), .init(name: "wr_id", value: chapter.key), .init(name: "is", value: manga.key)
        ])
        let document = try await document(request)
        let primary = try Self.scriptImages(document, marker: "var img_list = [")
        let alternate = try Self.scriptImages(document, marker: "var img_list_2 = [")
        var usePrimary = !primary.isEmpty
        if usePrimary {
            for index in [0, primary.count / 2, primary.count - 1] {
                do {
                    let (_, response) = try await fetch(Self.imageRequest(url: primary[index], method: "HEAD"))
                    try Task.checkCancellation()
                    if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) { usePrimary = false; break }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    usePrimary = false
                    break
                }
            }
        }
        let images = usePrimary || alternate.isEmpty ? primary : alternate
        guard !images.isEmpty else { throw Failure.missingImages }
        return images.map { AidokuRunner.Page(content: .url(url: $0)) }
    }

    func getImageRequest(url: String, context: AidokuRunner.PageContext?) throws -> URLRequest {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        return Self.imageRequest(url: url)
    }

    func handleDeepLink(url: String) throws -> AidokuRunner.DeepLinkResult? {
        guard let url = URL(string: url), let host = url.host, host.range(of: #"^11toon[0-9]*\.com$"#, options: .regularExpression) != nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let mangaKey = parts.queryItems?.first { $0.name == "is" }?.value
        let chapterKey = parts.queryItems?.first { $0.name == "wr_id" }?.value
        guard let mangaKey, Self.numericKey(mangaKey) else { return nil }
        return AidokuRunner.DeepLinkResult(mangaKey: mangaKey, chapterKey: chapterKey.flatMap { Self.numericKey($0) ? $0 : nil })
    }

    func getHome() async throws -> AidokuRunner.Home {
        let daily = try await getMangaList(listing: .init(id: "daily100", name: "매일 추천 100"), page: 1)
        var components: [AidokuRunner.HomeComponent] = [.init(title: "오늘의 추천", subtitle: "매일 새롭게 고른 작품",
                                                   value: .bigScroller(entries: Array(daily.entries.prefix(8)), autoScrollInterval: 6))]
        for (id, name) in [("latest", "최신만화"), ("popular", "인기만화"), ("completed", "완결만화")] {
            let listing = AidokuRunner.Listing(id: id, name: name)
            let mangas = try await getMangaList(listing: listing, page: 1)
            let links = Array(mangas.entries.prefix(20)).map { $0.intoLink() }
            if id == "completed" {
                components.append(.init(title: "정주행하기 좋은 완결작", subtitle: "끝까지 한 번에",
                                        value: .scroller(entries: links, listing: listing)))
            } else {
                components.append(.init(title: id == "popular" ? "지금 인기 있는 만화" : "방금 올라온 만화",
                                        subtitle: id == "popular" ? "실시간 인기 순위" : "최신 업데이트",
                                        value: .mangaList(ranking: id == "popular", pageSize: 5, entries: links, listing: listing)))
            }
        }
        return AidokuRunner.Home(components: components)
    }

    static func numericKey(_ key: String) -> Bool { !key.isEmpty && key.utf8.allSatisfy { (48...57).contains($0) } }

    static func tags(_ text: String) -> [String] { text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }

    static func rating(_ tags: [String]) -> AidokuRunner.ContentRating { tags.contains("17") || tags.contains("성인") ? .suggestive : .safe }

    static func mangaURL(_ key: String) -> URL? {
        (try? request(path: "bbs/board.php", query: [.init(name: "bo_table", value: "toons"), .init(name: "is", value: key)]))?.url
    }

    /// Backed func58 uses https for protocol-relative URLs and the fixed source base for root paths.
    static func imageURLString(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if value.hasPrefix("//") { return "https:" + value }
        if value.hasPrefix("/") { return base.absoluteString + value }
        return value
    }

    static func styleURL(_ text: String) -> String? {
        guard let start = text.range(of: "url("), let end = text[start.upperBound...].firstIndex(of: ")") else { return nil }
        return imageURLString(String(text[start.upperBound..<end]))
    }

    static func cards(_ document: Document, sourceKey: String, completed: Bool = false) throws -> [AidokuRunner.Manga] {
        try document.select("#free-genre-list > li[data-id], #comic-top100-rank > li[data-id]").array().compactMap { item in
            let key = try item.attr("data-id")
            let title = try item.select(".homelist-title").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !title.isEmpty else { return nil }
            let raw = try item.select(".homelist-genre span").first()?.text() ?? ""
            let prefix = String(raw.prefix(while: { !$0.isNumber })).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n("))
            let genres = tags(prefix)
            let cover = try item.select(".homelist-thumb").first().flatMap { try styleURL($0.attr("style")) }
            return AidokuRunner.Manga(sourceKey: sourceKey, key: key, title: title, cover: cover, url: mangaURL(key), tags: genres,
                         status: completed ? .completed : .unknown, contentRating: rating(genres), viewer: .rightToLeft)
        }
    }

    static func details(_ document: Document, manga: AidokuRunner.Manga) throws -> AidokuRunner.Manga {
        var manga = manga
        if let title = try document.select("#cover-info h2.title").first()?.text() { manga.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let cover = try document.select("#cover-info img.banner").first()?.attr("abs:src"), !cover.isEmpty { manga.cover = cover }
        if let genres = try document.select("#cover-info .genre .genre-link").first()?.text() { manga.tags = tags(genres) }
        manga.contentRating = rating(manga.tags ?? [])
        if let description = try document.select("#cover-info .content .genre-link").first()?.text() { manga.description = description }
        for publisher in try document.select("#cover-info .publisher").array() {
            let text = try publisher.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("작가"), let colon = text.firstIndex(of: ":") {
                let author = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !author.isEmpty { manga.authors = [author] }
                break
            }
        }
        manga.url = mangaURL(manga.key)
        manga.viewer = .rightToLeft
        if manga.status == .unknown { manga.status = .ongoing }
        return manga
    }

    static func digits(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let value = String(text[range.upperBound...].prefix(while: { $0.isASCII && $0.isNumber }))
        return value.isEmpty ? nil : value
    }

    static func chapters(_ document: Document, mangaKey: String) throws -> [AidokuRunner.Chapter] {
        try document.select("button.episode").array().compactMap { item in
            guard let key = try digits(after: "wr_id=", in: item.attr("onclick")) else { return nil }
            let title = try item.select(".episode-title").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let thumbnail = try item.select(".episode-banner").first().flatMap { try styleURL($0.attr("style")) }
            let url = try request(path: "bbs/board.php", query: [.init(name: "bo_table", value: "toons"), .init(name: "wr_id", value: key), .init(name: "is", value: mangaKey)]).url
            return AidokuRunner.Chapter(key: key, title: title?.isEmpty == true ? nil : title, url: url, language: "ko", thumbnail: thumbnail)
        }
    }

    static func chapterPageCount(_ document: Document) throws -> Int {
        let pages = try document.select("a.pg_page").array().compactMap { try digits(after: "page=", in: $0.attr("href")).flatMap(Int.init) }
        let count = max(pages.max() ?? 1, 1)
        guard count <= 10_000 else { throw Failure.excessivePagination }
        return count
    }

    /// Decode string literals as data, without executing scripts or evaluating expressions.
    static func scriptImages(_ document: Document, marker: String) throws -> [URL] {
        for script in try document.select("script").array() {
            let text = script.data()
            guard let start = text.range(of: marker), let end = text[start.upperBound...].range(of: "];") else { continue }
            let payload = text[start.upperBound..<end.lowerBound]
            let images = payload.split(separator: ",").compactMap { token -> URL? in
                let value = imageURLString(String(token))
                guard value.hasPrefix("http"), let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") else { return nil }
                return url
            }
            if !images.isEmpty { return images }
        }
        return []
    }

    static func searchMangas(_ data: Data, sourceKey: String, filters: [AidokuRunner.FilterValue]) throws -> [AidokuRunner.Manga] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let items = (object as? [[String: Any]]) ?? (object as? [String: Any])?["list"] as? [[String: Any]] else {
            throw Failure.malformedResponse
        }
        let genre = filters.compactMap { filter -> String? in if case let .select(id, value) = filter, id == "genre", !value.isEmpty { value } else { nil } }.last
        let sort = filters.compactMap { filter -> Int? in if case let .sort(value) = filter, value.id == "sort" { Int(value.index) } else { nil } }.last ?? 0
        let ascending = filters.compactMap { filter -> Bool? in if case let .sort(value) = filter, value.id == "sort" { value.ascending } else { nil } }.last ?? false
        func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
        let selected = items.filter { item in
            guard !string(item["wr_id"]).isEmpty, !string(item["wr_subject"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return genre == nil || tags(string(item["ca_name"])).contains(genre!)
        }.sorted { left, right in
            if sort == 1 {
                let left = UInt64(string(left["num"])) ?? 0
                let right = UInt64(string(right["num"])) ?? 0
                return ascending ? left < right : left > right
            }
            let left = string(left["wr_datetime"])
            let right = string(right["wr_datetime"])
            return ascending ? left < right : left > right
        }
        return selected.map { item in
            let key = string(item["wr_id"])
            let genres = tags(string(item["ca_name"]))
            let author = string(item["wr_6"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = string(item["wr_content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return AidokuRunner.Manga(sourceKey: sourceKey, key: key, title: string(item["wr_subject"]).trimmingCharacters(in: .whitespacesAndNewlines),
                         cover: "https://11toon8.com/data/toon_category/\(key).webp", authors: author.isEmpty ? nil : [author],
                         description: content.isEmpty ? nil : content, url: mangaURL(key), tags: genres,
                         contentRating: rating(genres), viewer: .rightToLeft)
        }
    }
}
