import AidokuRunner
import Foundation
import SwiftSoup

/// Native port of ja.rawdevart v3's SPA JSON protocol.
actor RawdevartSourceRunner: AidokuRunner.Runner {
    nonisolated let partialMangaPublisher: SinglePublisher<AidokuRunner.Manga>? = .init()
    let sourceKey: String
    let fetch: NativeSourceNetwork.Fetch
    let features = SourceFeatures(providesListings: true, dynamicFilters: true, providesImageRequests: true, handlesDeepLinks: true)
    static let base = "https://rawdevart.art"

    init(sourceKey: String = "ja.rawdevart", fetch: NativeSourceNetwork.Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    private func json<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = URLRequest(url: try GroupASourceSupport.url(Self.base, path: path, query: query))
        return try JSONDecoder().decode(T.self, from: await GroupASourceSupport.data(request, fetch: fetch))
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        if let query {
            let response: ListResponse = try await json("/spa/search", query: [.init(name: "query", value: query), .init(name: "page", value: String(page))])
            return response.mangaPage(sourceKey: sourceKey)
        }
        var genre = "all"
        var items: [URLQueryItem] = []
        for filter in filters {
            switch filter {
            case .select(let id, let value) where !value.isEmpty:
                if id == "genre" { genre = value }
                if id == "status" { items.append(.init(name: "status", value: value)) }
            case .sort(let value):
                let sorts = ["", "most_viewed", "most_viewed_today"]
                if sorts.indices.contains(Int(value.index)), value.index > 0 { items.append(.init(name: "sort", value: sorts[Int(value.index)])) }
            default: break
            }
        }
        items.append(.init(name: "page", value: String(page)))
        let response: ListResponse = try await json("/spa/genre/" + genre, query: items)
        return response.mangaPage(sourceKey: sourceKey)
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        let path = ["popular", "trending"].contains(listing.id) ? "/spa/genre/all" : "/spa/latest-manga"
        var query: [URLQueryItem] = [.init(name: "page", value: String(page))]
        if listing.id == "popular" { query.append(.init(name: "sort", value: "most_viewed")) }
        if listing.id == "trending" { query.append(.init(name: "sort", value: "most_viewed_today")) }
        let response: ListResponse = try await json(path, query: query)
        return response.mangaPage(sourceKey: sourceKey)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        let response: DetailResponse = try await json("/spa/manga/" + manga.key)
        var result = manga
        if needsDetails, let detail = response.detail {
            if let title = detail.manga_name { result.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let cover = detail.manga_cover_img_full ?? detail.manga_cover_img { result.cover = cover }
            result.url = URL(string: Self.base + "/g/ne" + manga.key)
            if let description = detail.manga_description {
                let text = try SwiftSoup.parseBodyFragment(description).text().trimmingCharacters(in: .whitespacesAndNewlines)
                result.description = text.isEmpty ? nil : text
            } else { result.description = nil }
            let authors = (response.authors ?? []).compactMap(\.author_name).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let tags = (response.tags ?? []).compactMap(\.tag_name).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            result.authors = authors.isEmpty ? nil : authors
            result.tags = tags.isEmpty ? nil : tags
            let explicit = ["adult", "hentai", "loli", "lolicon", "mature", "shotacon", "smut"]
            result.contentRating = tags.contains { explicit.contains($0.lowercased()) } ? .nsfw : tags.contains { $0.lowercased() == "ecchi" } ? .suggestive : .safe
            result.status = detail.manga_status.map { $0 ? .completed : .ongoing } ?? .unknown
            result.viewer = .rightToLeft
            if needsChapters {
                try Task.checkCancellation()
                await partialMangaPublisher?.send(result, to: PartialResultSubscription.id)
            }
        }
        if needsChapters {
            result.chapters = (response.chapters ?? []).compactMap { chapter in
                guard let number = chapter.chapter_number else { return nil }
                let key = Self.chapterKey(number)
                let title = chapter.chapter_title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(key: key, title: title?.isEmpty == false ? title : nil, chapterNumber: number,
                    dateUploaded: chapter.chapter_date_published.flatMap(Self.date),
                    url: URL(string: Self.base + "/read/ne\(manga.key)/chapter-\(key)"))
            }
        }
        return result
    }

    static func chapterKey(_ number: Float) -> String {
        number.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", number) : String(number)
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let response: PagesResponse = try await json("/spa/manga/\(manga.key)/\(chapter.key)")
        guard let detail = response.chapter_detail else { throw SourceError.message("Chapter not found") }
        let server = detail.server.flatMap { $0.isEmpty ? nil : $0 } ?? detail.slaves?.first ?? Self.base + "/"
        let doc = try SwiftSoup.parseBodyFragment(detail.chapter_content ?? "")
        return try doc.select(".chapter-img img").array().compactMap { image in
            let src = try image.hasAttr("data-src") ? image.attr("data-src") : image.attr("src")
            guard !src.isEmpty else { return nil }
            let value = src.hasPrefix("http") ? src : server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + src.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme) else { return nil }
            return .init(content: .url(url: url))
        }
    }

    func getSearchFilters() async throws -> [AidokuRunner.Filter] {
        let response: ListResponse = try await json("/spa/genre/all")
        guard let options = response.genreOpt else { return [] }
        let doc = try SwiftSoup.parseBodyFragment(options)
        var names = ["All"]
        var ids = ["all"]
        for option in try doc.select("option").array() {
            let path = try option.attr("value").split(separator: "/")
            guard path.count > 1 else { continue }
            let key = path[1].drop { $0.isLetter }
            let name = try option.text()
            if !key.isEmpty, !name.isEmpty { ids.append(String(key)); names.append(name) }
        }
        return [.init(id: "genre", title: "Genre", value: .select(.init(isGenre: true, options: names, ids: ids)))]
    }

    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        try GroupASourceSupport.imageRequest(url, base: Self.base)
    }

    func handleDeepLink(url: String) async throws -> DeepLinkResult? {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host == "rawdevart.art", url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let key = String(parts[1].drop { $0.isLetter })
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if parts.count == 2, parts[0] == "g" { return .init(mangaKey: key) }
        if parts.count == 3, ["read", "reader"].contains(parts[0]) {
            let chapter = parts[2].hasPrefix("chapter-") ? String(parts[2].dropFirst(8)) : parts[2]
            guard !chapter.isEmpty else { return nil }
            return .init(mangaKey: key, chapterKey: chapter)
        }
        return nil
    }

    struct ListResponse: Decodable {
        let manga_list: [Entry]
        let pagi: Pagination?
        let genreOpt: String?
        func mangaPage(sourceKey: String) -> AidokuRunner.MangaPageResult {
            .init(entries: manga_list.map { .init(sourceKey: sourceKey, key: String($0.manga_id),
                title: $0.manga_name.trimmingCharacters(in: .whitespacesAndNewlines),
                cover: $0.manga_cover_img_full ?? $0.manga_cover_img,
                url: URL(string: RawdevartSourceRunner.base + "/g/ne" + String($0.manga_id))) },
                hasNextPage: (pagi?.button?.next ?? 0) != 0)
        }
    }
    struct Entry: Decodable { let manga_id: Int64; let manga_name: String; let manga_cover_img: String?; let manga_cover_img_full: String? }
    struct Pagination: Decodable { let button: Button? }
    struct Button: Decodable { let next: Int }
    struct DetailResponse: Decodable { let detail: Detail?; let authors: [Author]?; let tags: [Tag]?; let chapters: [Chapter]? }
    struct Detail: Decodable { let manga_name: String?; let manga_description: String?; let manga_status: Bool?; let manga_cover_img: String?; let manga_cover_img_full: String? }
    struct Author: Decodable { let author_name: String? }
    struct Tag: Decodable { let tag_name: String? }
    struct Chapter: Decodable { let chapter_number: Float?; let chapter_title: String?; let chapter_date_published: String? }
    struct PagesResponse: Decodable { let chapter_detail: PageDetail? }
    struct PageDetail: Decodable { let chapter_content: String?; let server: String?; let slaves: [String]? }
}
