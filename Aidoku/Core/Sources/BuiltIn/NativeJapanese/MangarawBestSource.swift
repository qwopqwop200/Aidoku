import AidokuRunner
import Foundation
import SwiftSoup

/// Native port of Aidoku-Community/sources ja.mangarawbest v2.
actor MangarawBestSourceRunner: AidokuRunner.Runner {
    nonisolated let partialMangaPublisher: SinglePublisher<AidokuRunner.Manga>? = .init()
    let sourceKey: String
    let fetch: NativeSourceNetwork.Fetch
    let features = SourceFeatures(providesListings: true, providesImageRequests: true, handlesDeepLinks: true)
    static let base = "https://mangaraw.best"
    static let sorts = ["-updated_at", "-created_at", "created_at", "-views", "-views_day", "-views_week", "name", "-name"]

    init(sourceKey: String = "ja.mangarawbest", fetch: NativeSourceNetwork.Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        var items: [URLQueryItem] = []
        var sort = Self.sorts[0]
        var searchType = "name"
        for filter in filters {
            switch filter {
            case .sort(let value):
                if Self.sorts.indices.contains(Int(value.index)) { sort = Self.sorts[Int(value.index)] }
            case .select(let id, let value): if id == "search_type" { searchType = value }
            case .multiselect(let id, let included, let excluded):
                if id == "status", !included.isEmpty { items.append(.init(name: "filter[status]", value: included.joined(separator: ","))) }
                if id == "genre" {
                    if !included.isEmpty { items.append(.init(name: "filter[accept_genres]", value: included.joined(separator: ","))) }
                    if !excluded.isEmpty { items.append(.init(name: "filter[reject_genres]", value: excluded.joined(separator: ","))) }
                }
            default: break
            }
        }
        items += [.init(name: "sort", value: sort), .init(name: "page", value: String(page))]
        if let query { items.append(.init(name: "filter[\(searchType)]", value: query.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return try await listing(items, page: page)
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        let sort = ["views": "-views", "views_week": "-views_week", "created_at": "-created_at"][listing.id] ?? Self.sorts[0]
        return try await self.listing([.init(name: "sort", value: sort), .init(name: "page", value: String(page))], page: page)
    }

    private func listing(_ items: [URLQueryItem], page: Int) async throws -> AidokuRunner.MangaPageResult {
        let doc = try await GroupASourceSupport.html(GroupASourceSupport.url(Self.base, path: "/manga-list", query: items), fetch: fetch)
        return try Self.parseListing(doc, sourceKey: sourceKey, page: page)
    }

    static func parseListing(_ doc: Document, sourceKey: String, page: Int) throws -> AidokuRunner.MangaPageResult {
        let entries = try doc.select(".manga-vertical").array().compactMap { element -> AidokuRunner.Manga? in
            guard let link = try element.select("a[href^='/raw/']").first() else { return nil }
            let href = try link.attr("href")
            guard let key = href.dropFirst("/raw/".count).split(separator: "/").first, !key.isEmpty,
                  let title = GroupASourceSupport.text(element, ".post-title a") ?? (try? link.attr("title")), !title.isEmpty else { return nil }
            let cover = GroupASourceSupport.attr(element, "img.cover", "abs:data-src") ?? GroupASourceSupport.attr(element, "img.cover", "abs:src")
            return .init(sourceKey: sourceKey, key: String(key), title: title, cover: cover, url: URL(string: Self.base + "/raw/" + String(key)))
        }
        let href = GroupASourceSupport.attr(doc, "a.paging_prevnext.next", "abs:href")
        let last = href.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "page" }?.value }.flatMap(Int.init) ?? 0
        return .init(entries: entries, hasNextPage: page < last)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        let url = try GroupASourceSupport.url(Self.base, path: "/raw/" + manga.key)
        let doc = try await GroupASourceSupport.html(url, fetch: fetch)
        var result = manga
        if needsDetails {
            result.title = GroupASourceSupport.text(doc, "main h1") ?? result.title
            result.cover = GroupASourceSupport.attr(doc, ".cover-frame img", "abs:src")
            result.description = GroupASourceSupport.text(doc, ".manga-pilot .manga-pilot")
            result.url = url
            var tags: [String] = []
            for element in try doc.select("span.flex-wrap.gap-1 a[href*='/genre/']").array() {
                var tag = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if tag.hasSuffix(" raw") { tag = String(tag.dropLast(4)).trimmingCharacters(in: .whitespaces) }
                if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
            }
            result.tags = tags.isEmpty ? nil : tags
            result.contentRating = GroupASourceSupport.rating(tags)
            let status = GroupASourceSupport.attr(doc, "a[href*='status']", "href")?.split(separator: "=").last
            let label = GroupASourceSupport.text(doc, "a[href*='status']")
            // The stable filter value takes precedence over translated display labels.
            if status == "1" { result.status = .completed }
            else if status == "2" { result.status = .ongoing }
            else if ["完了", "完結"].contains(label) { result.status = .completed }
            else if label == "進行中" { result.status = .ongoing }
            else { result.status = .unknown }
            result.updateStrategy = result.status == .completed ? .never : .always
            result.viewer = .rightToLeft
            if needsChapters {
                try Task.checkCancellation()
                await partialMangaPublisher?.send(result, to: PartialResultSubscription.id)
            }
        }
        if needsChapters { result.chapters = try Self.parseChapters(doc) }
        return result
    }

    static func parseChapters(_ doc: Document, now: Date = Date()) throws -> [AidokuRunner.Chapter] {
        try doc.select("#chapterList ul a").array().compactMap { element in
            let href = try element.attr("href")
            guard let key = href.split(separator: "/").last, !key.isEmpty else { return nil }
            let title = GroupASourceSupport.text(element, "span.text-ellipsis")
            let plain = title?.range(of: #"^第[0-9.]+話$"#, options: .regularExpression) != nil
            let date = GroupASourceSupport.text(element, "span.timeago").flatMap { Self.relativeDate($0, now: now) }
            return .init(key: String(key), title: plain ? nil : title, chapterNumber: title.flatMap(Self.chapterNumber),
                dateUploaded: date, url: URL(string: href, relativeTo: URL(string: Self.base))?.absoluteURL)
        }
    }

    static func chapterNumber(_ title: String) -> Float? {
        let start: String.Index
        if let marker = title.firstIndex(of: "第") {
            start = title.index(after: marker)
        } else if let digit = title.firstIndex(where: { $0.isASCII && $0.isNumber }) {
            start = digit
        } else { return nil }
        var number = String(title[start...].prefix { ($0.isASCII && $0.isNumber) || $0 == "." })
        while number.hasSuffix(".") { number.removeLast() }
        return Float(number)
    }

    static func relativeDate(_ value: String, now: Date) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix("前") else { return nil }
        let text = String(value.dropLast())
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let count = Double(digits) else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let seconds: [String: Double] = ["秒": 1, "分": 60, "時間": 3600, "日": 86400, "週間": 604800,
            "ヶ月": 2592000, "ヵ月": 2592000, "カ月": 2592000, "か月": 2592000, "年": 31536000]
        return seconds[unit].map { now.addingTimeInterval(-count * $0) }
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let doc = try await GroupASourceSupport.html(GroupASourceSupport.url(Self.base, path: "/raw/\(manga.key)/\(chapter.key)"), fetch: fetch)
        let server = UserDefaults.standard.string(forKey: sourceKey + ".imageServer") ?? "1"
        return try doc.select("img.chapter-image").array().compactMap { image in
            let original = try image.hasAttr("data-original") ? image.attr("data-original") : image.attr("abs:src")
            let value: String
            if server == "2" {
                value = "https://i0.wp.com/" + original.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            } else if server == "3" {
                var parts = URLComponents(string: "https://external-content.duckduckgo.com/iu/")!
                parts.queryItems = [.init(name: "u", value: original)]
                parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                value = parts.url!.absoluteString
            } else { value = original }
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme) else { return nil }
            return .init(content: .url(url: url))
        }
    }

    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        try GroupASourceSupport.imageRequest(url, base: Self.base)
    }

    func handleDeepLink(url: String) async throws -> DeepLinkResult? {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()),
              ["mangaraw.best", "www.mangaraw.best"].contains(url.host?.lowercased()) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "raw" else { return nil }
        if parts.count >= 3 { return .init(mangaKey: parts[1], chapterKey: parts[2]) }
        return .init(mangaKey: parts[1])
    }
}
