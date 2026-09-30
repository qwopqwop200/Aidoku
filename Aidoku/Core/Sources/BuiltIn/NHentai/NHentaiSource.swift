import AidokuRunner
import Foundation

/// Native port of the recovered v17 API-v2 adapter. The package's metadata, filters, settings
/// and patched autocomplete configuration stay authoritative; no package executable is loaded.
actor NHentaiSourceRunner: NativeSourceRunnerLifecycle {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sourceKey: String
    nonisolated let partialHomePublisher: SinglePublisher<Home>? = SinglePublisher()
    let features = SourceFeatures(providesListings: true, providesHome: true, providesImageRequests: true, handlesDeepLinks: true)
    private let fetch: Fetch
    private let preference: @Sendable (String) -> String?
    private let stringListPreference: @Sendable (String) -> [String]
    private let boolPreference: @Sendable (String) -> Bool
    private var cache: (key: String, gallery: NHentaiGallery)?
    private var cacheGeneration = UUID()
    private static let base = "https://nhentai.net"
    private static let api = base + "/api/v2"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) GSA/300.0.598994205 Mobile/15E148 Safari/604"

    init(
        sourceKey: String = "multi.nhentai",
        fetch: @escaping Fetch = { try await NHentaiSourceRunner.fetchSourceRequest($0) },
        preference: (@Sendable (String) -> String?)? = nil,
        stringListPreference: (@Sendable (String) -> [String])? = nil,
        boolPreference: (@Sendable (String) -> Bool)? = nil
    ) {
        self.sourceKey = sourceKey
        self.fetch = fetch
        self.preference = preference ?? { UserDefaults.standard.string(forKey: "\(sourceKey).\($0)") }
        self.stringListPreference = stringListPreference ?? { UserDefaults.standard.stringArray(forKey: "\(sourceKey).\($0)") ?? [] }
        self.boolPreference = boolPreference ?? { UserDefaults.standard.bool(forKey: "\(sourceKey).\($0)") }
    }

    nonisolated private static func fetchSourceRequest(_ original: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = original.url else { throw URLError(.badURL) }
        let request = await AidokuRunner.Source.modify(url: url, request: original)
        let (data, response) = try await SourceNetwork.shared.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, CloudflareHandler.shared.shouldHandle(response: http, data: data) {
            return try await CloudflareHandler.shared.handle(request: request)
        }
        return (data, response)
    }

    func restart() async throws {
        try Task.checkCancellation()
        cacheGeneration = UUID()
        cache = nil
    }
    func clearCache() async {
        cacheGeneration = UUID()
        cache = nil
    }

    private var japanese: Bool { preference("titlePreference") == "japanese" }
    private var language: String? {
        switch preference("language") {
        case "en": "english"
        case "ja": "japanese"
        case "zh": "chinese"
        default: nil
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private func gallery(_ key: String) async throws -> NHentaiGallery {
        guard Int32(key) != nil else { throw URLError(.badURL) }
        return try await decode(NHentaiGallery.self, request: request(URL(string: "\(Self.api)/galleries/\(key)")!))
    }

    func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        guard page >= 1, page <= Int(Int32.max) else { throw URLError(.badURL) }
        if let query, let id = Int32(query) {
            let item = try await gallery(String(id))
            return AidokuRunner.MangaPageResult(entries: [item.manga(sourceKey: sourceKey, japanese: japanese)], hasNextPage: false)
        }
        var parts: [String] = query.map { [$0] } ?? []
        var sort = "date"
        for filter in filters {
            switch filter {
            case let .text(id, value):
                switch id {
                case "author": parts.append(value)
                case "artist": parts.append("artist:\(value)")
                case "groups": parts.append("group:\(value)")
                default: break
                }
            case .sort(let value):
                let sorts = ["date", "popular-today", "popular-week", "popular"]
                sort = sorts.indices.contains(Int(value.index)) ? sorts[Int(value.index)] : "date"
            case let .multiselect(id, included, excluded) where id == "tags":
                parts += included.map { "tag:\"\($0)\"" }
                parts += excluded.map { "-tag:\"\($0)\"" }
            case let .select(id, value) where id == "genre": parts.append("tag:\"\(value)\"")
            default: break
            }
        }
        if let language { parts.append("language:\(language)") }
        parts += stringListPreference("blocklist").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }.map { "-tag:\"\($0)\"" }
        var components = URLComponents(string: Self.api + "/search")!
        // Match encodeURIComponent used by the original adapter, including literal spaces and '+'.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let combined = parts.isEmpty ? " " : parts.joined(separator: " ")
        guard let encoded = combined.addingPercentEncoding(withAllowedCharacters: allowed) else { throw URLError(.badURL) }
        components.percentEncodedQuery = "query=\(encoded)&page=\(page)&sort=\(sort)"
        guard let url = components.url else { throw URLError(.badURL) }
        let response = try await decode(NHentaiSearchResponse.self, request: request(url))
        return AidokuRunner.MangaPageResult(entries: response.result.map { $0.manga(sourceKey: sourceKey, japanese: japanese) }, hasNextPage: page < response.numPages)
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        let names = ["latest", "popular-today", "popular-week", "popular"]
        guard let index = names.firstIndex(of: listing.id) else { throw SourceError.unimplemented }
        return try await getSearchMangaList(query: nil, page: page, filters: [.sort(.init(id: "sort", index: index, ascending: false))])
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        try Task.checkCancellation()
        guard needsDetails || needsChapters else { return manga }
        let generation = cacheGeneration
        let item = try await gallery(manga.key)
        var result = needsDetails ? manga.copy(from: item.manga(sourceKey: sourceKey, japanese: japanese)) : manga
        if needsChapters {
            let languages = item.tags.filter { $0.type == "language" && $0.name != "translated" && $0.name != "rewrite" }.map(\.name)
            result.chapters = [AidokuRunner.Chapter(
                key: result.key, chapterNumber: 1, dateUploaded: Date(timeIntervalSince1970: TimeInterval(item.uploadDate)),
                scanlators: languages.isEmpty ? nil : [languages.joined(separator: ", ")], url: URL(string: "\(Self.base)/g/\(result.key)")
            )]
        }
        if generation == cacheGeneration { cache = (result.key, item) }
        return result
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        try Task.checkCancellation()
        let item: NHentaiGallery
        if let cache, cache.key == chapter.key { item = cache.gallery }
        else { item = try await gallery(chapter.key) }
        return try item.pages.map {
            guard let url = URL(string: NHentaiImageURL.make($0.path, cover: false)) else { throw URLError(.badURL) }
            return AidokuRunner.Page(content: .url(url: url))
        }
    }

    func getImageRequest(url: String, context: PageContext?) throws -> URLRequest {
        guard let url = URL(string: url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw URLError(.badURL)
        }
        return request(url)
    }

    func handleDeepLink(url: String) throws -> DeepLinkResult? {
        guard let url = URL(string: url), url.scheme == "https", url.host?.lowercased() == "nhentai.net" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "g", Int32(parts[1]) != nil else { return nil }
        return DeepLinkResult(mangaKey: String(parts[1]))
    }

    func getHome() async throws -> Home {
        try Task.checkCancellation()
        let specs = [("popular-today", "Popular Today"), ("popular-week", "Popular This Week"),
                     ("popular", "Popular All Time"), ("latest", "Latest")]
        let listKind: ListingKind = boolPreference("isListView") ? .list : .default
        let subscription = PartialResultSubscription.id
        var components = [
            HomeComponent(title: specs[0].1, value: .bigScroller(entries: [])),
            HomeComponent(title: specs[1].1, value: .mangaList(entries: [])),
            HomeComponent(title: specs[2].1, value: .mangaList(entries: [])),
            HomeComponent(title: specs[3].1, value: .scroller(entries: []))
        ]
        await partialHomePublisher?.send(Home(components: components), to: subscription)
        try await withThrowingTaskGroup(of: (Int, [AidokuRunner.Manga]).self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    let result = try await self.getMangaList(listing: AidokuRunner.Listing(id: spec.0, name: spec.1), page: 1)
                    return (index, result.entries)
                }
            }
            for try await (index, entries) in group {
                try Task.checkCancellation()
                guard !entries.isEmpty else { continue }
                let spec = specs[index]
                let listing = AidokuRunner.Listing(id: spec.0, name: spec.1, kind: listKind)
                let links = entries.map { HomeComponent.Value.Link(title: $0.title, imageUrl: $0.cover, value: .manga($0)) }
                let value: HomeComponent.Value
                if index == 0 { value = .bigScroller(entries: entries, autoScrollInterval: 8) }
                else if index == 3 { value = .scroller(entries: links, listing: listing) }
                else { value = .mangaList(ranking: true, pageSize: 3, entries: links, listing: listing) }
                components[index] = HomeComponent(title: spec.1, value: value)
                await partialHomePublisher?.send(Home(components: components), to: subscription)
            }
        }
        return Home(components: components)
    }
}
