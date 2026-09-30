import AidokuRunner
import Foundation

/// Native implementation of the recovered multi.hitomi version 2 adapter.
/// Package metadata, filters and settings remain authoritative in Source.
actor HitomiSourceRunner: AidokuRunner.NativeSourceRunnerLifecycle {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sourceKey: String
    let features = AidokuRunner.SourceFeatures(providesListings: true, providesImageRequests: true, handlesDeepLinks: true)
    private let fetch: Fetch
    private let preference: @Sendable (String) -> String?
    private let search: HitomiSearch
    private var galleryCache: (id: Int64, gallery: HitomiGallery, date: Date)?
    private var ggCache: (state: HitomiGGState, date: Date)?
    private var cacheGeneration: UInt64 = 0
    private static let base = "https://hitomi.la"
    private static let ltn = "https://ltn.gold-usergeneratedcontent.net"

    init(
        sourceKey: String = "multi.hitomi",
        fetch: @escaping Fetch = { try await HitomiSourceRunner.fetchSourceRequest($0) },
        preference: (@Sendable (String) -> String?)? = nil
    ) {
        self.sourceKey = sourceKey
        self.fetch = fetch
        self.preference = preference ?? { UserDefaults.standard.string(forKey: "\(sourceKey).\($0)") }
        search = HitomiSearch(fetch: fetch)
    }

    nonisolated private static func fetchSourceRequest(_ original: URLRequest) async throws -> (Data, URLResponse) {
        let request = if let url = original.url {
            await AidokuRunner.Source.modify(url: url, request: original)
        } else { original }
        let (data, response) = try await SourceNetwork.shared.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse,
           CloudflareHandler.shared.shouldHandle(response: http, data: data) {
            do { return try await CloudflareHandler.shared.handle(request: request) }
            catch is CloudflareHandler.HandleError { return (data, response) }
        }
        return (data, response)
    }

    func restart() async throws {
        try Task.checkCancellation()
        await clearCache()
        try Task.checkCancellation()
    }

    func clearCache() async {
        cacheGeneration &+= 1
        galleryCache = nil
        ggCache = nil
        await search.clearCache()
    }

    private var language: String { HitomiSearch.language(code: preference("language") ?? "All") }
    private var japaneseTitle: Bool { preference("titlePreference") == "japanese" }

    private func request(_ string: String) throws -> URLRequest {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        return request
    }

    private func body(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func cachedGallery(_ id: Int64) -> HitomiGallery? {
        guard let cache = galleryCache, cache.id == id, (0..<60).contains(Date().timeIntervalSince(cache.date)) else { return nil }
        return cache.gallery
    }

    private func decodeGallery(_ data: Data) throws -> HitomiGallery {
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try JSONDecoder().decode(HitomiGallery.self, from: HitomiGGState.galleryJSON(text))
    }

    private func gallery(_ id: Int64) async throws -> HitomiGallery {
        try Task.checkCancellation()
        if let cached = cachedGallery(id) { return cached }
        let generation = cacheGeneration
        let gallery = try decodeGallery(await body(request("\(Self.ltn)/galleries/\(id).js")))
        try Task.checkCancellation()
        if generation == cacheGeneration { galleryCache = (id, gallery, Date()) }
        return gallery
    }

    /// Bounded fan-out preserves index order; failed individual galleries are skipped, like the SDK source.
    private func mangas(_ ids: [Int64]) async throws -> [AidokuRunner.Manga] {
        let requests = try ids.map { try request("\(Self.ltn)/galleries/\($0).js") }
        let fetch = fetch
        let japanese = japaneseTitle
        let key = sourceKey
        var output: [(Int, AidokuRunner.Manga)] = []
        for start in stride(from: 0, to: requests.count, by: 25) {
            try Task.checkCancellation()
            let end = min(start + 25, requests.count)
            try await withThrowingTaskGroup(of: (Int, AidokuRunner.Manga)?.self) { group in
                for index in start..<end {
                    let request = requests[index]
                    group.addTask {
                        do {
                            let (data, response) = try await fetch(request)
                            try Task.checkCancellation()
                            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                                  let text = String(data: data, encoding: .utf8) else { return nil }
                            let gallery = try JSONDecoder().decode(HitomiGallery.self, from: HitomiGGState.galleryJSON(text))
                            return (index, gallery.manga(sourceKey: key, japanese: japanese))
                        } catch {
                            if error is CancellationError { throw error }
                            try Task.checkCancellation()
                            return nil
                        }
                    }
                }
                for try await result in group { if let result { output.append(result) } }
            }
        }
        try Task.checkCancellation()
        return output.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        try Task.checkCancellation()
        guard page >= 1 else { throw URLError(.badURL) }
        let period = ["popular_today": "today", "popular_week": "week", "popular_month": "month", "popular_year": "year"]
        let path = period[listing.id].map { "popular/\($0)" } ?? "index"
        let result = try await search.nozomiPage(url: URL(string: "\(Self.ltn)/\(path)-\(language).nozomi")!, page: page)
        return try await AidokuRunner.MangaPageResult(entries: mangas(result.ids), hasNextPage: result.hasNext)
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        try Task.checkCancellation()
        guard page >= 1 else { throw URLError(.badURL) }
        let raw = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int64(raw) ?? Self.galleryID(raw) {
            do {
                let item = try await gallery(id)
                try Task.checkCancellation()
                return AidokuRunner.MangaPageResult(entries: [item.manga(sourceKey: sourceKey, japanese: japaneseTitle)], hasNextPage: false)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        var positives: [String] = []
        var negatives: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace).map({ $0.lowercased() }) {
            if token.hasPrefix("-") {
                if token.count > 1 { negatives.append(String(token.dropFirst())) }
            } else { positives.append(token) }
        }
        var sort = 0
        var type: String?
        var author: String?
        func normalized(_ string: String) -> String { string.lowercased().replacingOccurrences(of: " ", with: "_") }
        for filter in filters {
            switch filter {
            case .sort(let value): sort = (0...5).contains(Int(value.index)) ? Int(value.index) : 0
            case let .text(id, value) where !value.isEmpty:
                if id == "author" { author = normalized(value) }
                else if id == "artist" || id == "group" { positives.append("\(id):\(normalized(value))") }
            case let .select(id, value):
                if id == "type", !value.isEmpty { type = value }
                if id == "genre" {
                    let prefix = value.contains("♀") ? "female" : value.contains("♂") ? "male" : "tag"
                    let tag = value.replacingOccurrences(of: "♀", with: "").replacingOccurrences(of: "♂", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    positives.append("\(prefix):\(normalized(tag))")
                }
            default: break
            }
        }
        let lang = language
        if lang != "all", sort == 0, !(positives + negatives).contains(where: { $0.hasPrefix("language:") }) {
            positives.append("language:\(lang)")
        }
        if lang != "all", positives.contains(where: {
            !$0.hasPrefix("language:") && HitomiSearch.nozomiURL(query: $0, language: lang) != nil
        }) { positives.removeAll { $0 == "language:\(lang)" } }
        var positiveResults: [[Int64]] = []
        for term in positives {
            if term.contains(":"), HitomiSearch.nozomiURL(query: term, language: lang) != nil {
                positiveResults.append((try await optionalIDs(term: term, language: lang)) ?? [])
                try Task.checkCancellation()
            } else {
                positiveResults.append(try await ids(term: term, language: lang))
            }
        }
        if let author {
            let artist = try await optionalIDs(term: "artist:\(author)", language: lang)
            let group = try await optionalIDs(term: "group:\(author)", language: lang)
            try Task.checkCancellation()
            guard artist != nil || group != nil else { throw URLError(.resourceUnavailable) }
            positiveResults.append(Array(Set((artist ?? []) + (group ?? []))).sorted())
        }
        var negativeIDs = Set<Int64>()
        for term in negatives {
            if let result = try await optionalIDs(term: term, language: lang) { negativeIDs.formUnion(result) }
            try Task.checkCancellation()
        }
        let sortNames = ["index", "published", "today", "week", "month", "year"]
        var result: [Int64]
        if (positives.isEmpty && author == nil) || sort != 0 {
            result = try await search.allNozomi(url: URL(string: "\(Self.ltn)/\(sort == 0 ? "" : "popular/")\(sortNames[sort])-\(lang).nozomi")!)
        } else { result = [] }
        // Preserve the recovered adapter's empty-base replacement semantics and index ordering.
        for ids in positiveResults {
            if result.isEmpty { result = ids }
            else { let allowed = Set(ids); result.removeAll { !allowed.contains($0) } }
        }
        if let type, let url = HitomiSearch.nozomiURL(query: "type:\(type)", language: lang),
           let typeIDs = try? await search.allNozomi(url: url) {
            let allowed = Set(typeIDs)
            result.removeAll { !allowed.contains($0) }
        }
        try Task.checkCancellation()
        result.removeAll { negativeIDs.contains($0) }
        guard page <= Int.max / 25 else { throw URLError(.badURL) }
        let start = (page - 1) * 25
        let end = min(start + 25, result.count)
        let selected = start < result.count ? Array(result[start..<end]) : []
        return try await AidokuRunner.MangaPageResult(entries: mangas(selected), hasNextPage: end < result.count)
    }

    private func optionalIDs(term: String, language: String) async throws -> [Int64]? {
        do { return try await ids(term: term, language: language) }
        catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return nil
        }
    }

    private func ids(term: String, language: String) async throws -> [Int64] {
        if term.contains(":") {
            guard let url = HitomiSearch.nozomiURL(query: term, language: language) else { throw URLError(.badURL) }
            return try await search.allNozomi(url: url)
        }
        return try await search.plainText(term)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        try Task.checkCancellation()
        guard let id = Int64(manga.key) else { throw URLError(.badURL) }
        let item = try await gallery(id)
        var result = needsDetails ? manga.copy(from: item.manga(sourceKey: sourceKey, japanese: japaneseTitle)) : manga
        if needsChapters {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            result.chapters = [AidokuRunner.Chapter(key: manga.key, chapterNumber: 1, dateUploaded: formatter.date(from: String(item.date.prefix(10))),
                                       scanlators: item.language.flatMap { $0.isEmpty ? nil : [$0] },
                                       url: URL(string: "\(Self.base)/reader/\(id).html"))]
        }
        try Task.checkCancellation()
        return result
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        try Task.checkCancellation()
        guard let id = Int64(chapter.key) else { throw URLError(.badURL) }
        let generation = cacheGeneration
        let cachedRouting = ggCache.flatMap { (0...60).contains(Date().timeIntervalSince($0.date)) ? $0.state : nil }
        let needsGG = cachedRouting == nil
        let item: HitomiGallery
        let gg: HitomiGGState
        if cachedGallery(id) == nil, needsGG {
            async let galleryData = body(request("\(Self.ltn)/galleries/\(id).js"))
            async let routingData = body(request("\(Self.ltn)/gg.js"))
            item = try decodeGallery(await galleryData)
            let data = try await routingData
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            let state = try HitomiGGState.parse(text)
            try Task.checkCancellation()
            gg = state
            if generation == cacheGeneration {
                ggCache = (state, Date())
                galleryCache = (id, item, Date())
            }
        } else {
            item = try await gallery(id)
            if let cachedRouting {
                gg = cachedRouting
            } else {
                let data = try await body(request("\(Self.ltn)/gg.js"))
                guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                let state = try HitomiGGState.parse(text)
                try Task.checkCancellation()
                gg = state
                if generation == cacheGeneration { ggCache = (state, Date()) }
            }
        }
        let pages = try item.files.map { file in
            try Task.checkCancellation()
            guard let url = gg.imageURL(hash: file.hash, extension: file.isGIF ? "webp" : "avif") else { throw URLError(.badURL) }
            return AidokuRunner.Page(content: .url(url: url, context: ["referer": "\(Self.base)/reader/\(id).html"]))
        }
        try Task.checkCancellation()
        return pages
    }

    func getImageRequest(url: String, context: AidokuRunner.PageContext?) throws -> URLRequest {
        try Task.checkCancellation()
        var request = try request(url)
        request.setValue(context?["referer"] ?? Self.base + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.base, forHTTPHeaderField: "Origin")
        request.setValue("image/webp,image/avif,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    func handleDeepLink(url: String) throws -> AidokuRunner.DeepLinkResult? {
        try Task.checkCancellation()
        return HitomiGGState.galleryID(url: url).map { AidokuRunner.DeepLinkResult(mangaKey: String($0)) }
    }

    static func galleryID(_ string: String) -> Int64? {
        HitomiGGState.galleryID(url: string)
    }
}
