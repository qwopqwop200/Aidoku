// Native port of Aidoku-Community/sources ja.senmanga v2, revision 897b8f2102b48c722f438c10373d1cb5e10876cb.
// Copyright 2025 Aidoku community source contributors. MIT license; see Docs/NativeSource-MIT.txt.
import AidokuRunner
import Foundation

actor SenMangaSourceRunner: AidokuRunner.Runner {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let features = AidokuRunner.SourceFeatures(handlesDeepLinks: true, handlesMigration: true)
    private let sourceKey: String
    private let fetch: Fetch
    private static let base = URL(string: "https://raw.senmanga.com")!

    init(sourceKey: String = "ja.senmanga", fetch: Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    private func endpoint(_ components: [String], query: [URLQueryItem] = []) throws -> URL {
        var url = Self.base.appendingPathComponent("api")
        for component in components {
            guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else {
                throw URLError(.badURL)
            }
            url.appendPathComponent(component)
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            parts.queryItems = query
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let result = parts.url else { throw URLError(.badURL) }
        return result
    }

    private func object<T: Decodable & Sendable>(_ type: T.Type, at url: URL) async throws -> T {
        try Task.checkCancellation()
        let (data, response) = try await fetch(URLRequest(url: url))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        guard page > 0 else { throw URLError(.badURL) }
        var parameters = [URLQueryItem(name: "page", value: String(page))]
        if let query { parameters.append(URLQueryItem(name: "query", value: query)) }
        let order = ["popular", "title", "updated", "rating"]
        for filter in filters {
            switch filter {
            case .sort(let value) where order.indices.contains(Int(value.index)):
                parameters.append(URLQueryItem(name: "order", value: order[Int(value.index)]))
            case let .select(id, value) where !value.isEmpty:
                parameters.append(URLQueryItem(name: id, value: value))
            default: break
            }
        }
        let result = try await object(Directory.self, at: endpoint(["directory"], query: parameters))
        let entries = result.series.map {
            AidokuRunner.Manga(sourceKey: sourceKey, key: $0.slug, title: $0.title, cover: $0.cover,
                  url: Self.base.appendingPathComponent("manga").appendingPathComponent($0.slug), status: Self.status($0.status))
        }
        let hasNext = result.currentPage.flatMap { current in result.totalPages.map { current < $0 } } ?? false
        return AidokuRunner.MangaPageResult(entries: entries, hasNextPage: hasNext)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        guard needsDetails || needsChapters else { return manga }
        let details = try await object(Details.self, at: endpoint(["manga", manga.key]))
        var result = manga
        if needsDetails {
            let tags = (details.genre ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let nsfw: Set<String> = ["Adult", "Smut", "Lolicon", "Shotacon", "Yaoi", "Yuri"]
            result.contentRating = tags.contains(where: nsfw.contains) ? .nsfw
                : tags.contains(where: { ["Ecchi", "Mature"].contains($0) }) ? .suggestive : .safe
            result.viewer = ["Manhwa", "Manhua"].contains(details.type ?? "") ? .webtoon : .rightToLeft
            if let status = details.status { result.status = Self.status(status) }
            result.title = details.title
            result.cover = details.cover
            result.description = details.description
            result.tags = tags
            result.url = Self.base.appendingPathComponent("manga").appendingPathComponent(manga.key)
        }
        if needsChapters {
            result.chapters = details.chapterList.map { chapter in
                let repeatedNumber = chapter.number.map {
                    chapter.title?.replacingOccurrences(of: "^Chapter", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == $0
                } ?? false
                let date = chapter.datetime.flatMap(Self.date)
                return AidokuRunner.Chapter(key: chapter.url, title: repeatedNumber ? nil : chapter.title,
                               chapterNumber: chapter.number.flatMap(Float.init), dateUploaded: date,
                               url: chapter.full_url.flatMap { URL(string: $0, relativeTo: Self.base)?.absoluteURL })
            }
        }
        return result
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let result = try await object(Read.self, at: endpoint(["read", manga.key, chapter.key]))
        guard !result.pages.isEmpty else { throw URLError(.cannotDecodeContentData) }
        return try result.pages.map {
            guard let url = URL(string: $0), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw URLError(.badURL)
            }
            return AidokuRunner.Page(content: .url(url: url, context: nil))
        }
    }

    func handleDeepLink(url: String) throws -> AidokuRunner.DeepLinkResult? {
        guard let url = URL(string: url), url.scheme == "https", url.host?.lowercased() == Self.base.host,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard (2...3).contains(parts.count), parts[0] == "manga", !parts[1].isEmpty else { return nil }
        if parts.count == 3 {
            guard parts[2].hasPrefix("chapter-"), parts[2].count > 8 else { return nil }
            return AidokuRunner.DeepLinkResult(mangaKey: parts[1], chapterKey: String(parts[2].dropFirst(8)))
        }
        return AidokuRunner.DeepLinkResult(mangaKey: parts[1])
    }

    func handleMigration(kind: AidokuRunner.KeyKind, mangaKey: String, chapterKey: String?) async throws -> String {
        let key = mangaKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if kind == .manga { return key }
        guard let chapterKey else { throw URLError(.badURL) }
        let number = chapterKey.split(separator: "/").last.map(String.init) ?? ""
        let details = try await object(Details.self, at: endpoint(["manga", key]))
        guard let chapter = details.chapterList.first(where: { $0.number == number }) else {
            throw URLError(.resourceUnavailable)
        }
        return chapter.url
    }

    private static func status(_ value: String?) -> AidokuRunner.PublishingStatus {
        switch value {
        case "Ongoing": .ongoing
        case "Completed": .completed
        case "Cancelled": .cancelled
        case "Hiatus": .hiatus
        default: .unknown
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private struct Directory: Decodable, Sendable {
        let currentPage: Int?
        let totalPages: Int?
        let series: [Entry]
        private enum CodingKeys: CodingKey { case currentPage, totalPages, series }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentPage = try container.decodeIfPresent(Int.self, forKey: .currentPage)
            totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
            series = try container.decodeIfPresent([Entry].self, forKey: .series) ?? []
        }
    }
    private struct Entry: Decodable, Sendable {
        let title: String
        let slug: String
        let cover: String?
        let status: String?
    }
    private struct Details: Decodable, Sendable {
        let title: String
        let cover: String?
        let genre: String?
        let type: String?
        let status: String?
        let description: String?
        let chapterList: [EntryChapter]
        private enum CodingKeys: CodingKey { case title, cover, genre, type, status, description, chapterList }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            cover = try container.decodeIfPresent(String.self, forKey: .cover)
            genre = try container.decodeIfPresent(String.self, forKey: .genre)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            chapterList = try container.decodeIfPresent([EntryChapter].self, forKey: .chapterList) ?? []
        }
    }
    private struct EntryChapter: Decodable, Sendable {
        let title: String?
        let number: String?
        let url: String
        let full_url: String?
        let datetime: String?
    }
    private struct Read: Decodable, Sendable {
        let pages: [String]
        private enum CodingKeys: CodingKey { case pages }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pages = try container.decodeIfPresent([String].self, forKey: .pages) ?? []
        }
    }
}
