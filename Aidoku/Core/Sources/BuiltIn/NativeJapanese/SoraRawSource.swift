import AidokuRunner
import Foundation
import SwiftSoup

/// Port of Aidoku-Community/sources ja.soraraw v5 (MIT OR Apache-2.0).
actor SoraRawSourceRunner: NativeSourceRunnerLifecycle {
    let sourceKey: String
    let partialMangaPublisher: AidokuRunner.SinglePublisher<AidokuRunner.Manga>? = .init()
    let features = AidokuRunner.SourceFeatures(providesListings: true, dynamicFilters: true, processesPages: true, handlesDeepLinks: true)
    private let fetch: NativeSourceNetwork.Fetch
    private let base = "https://soraraw.com"
    private var images: [Int32: AidokuRunner.PlatformImage] = [:]
    private var nextImage: Int32 = 1

    init(sourceKey: String = "ja.soraraw", fetch: NativeSourceNetwork.Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }
    func restart() async throws { try Task.checkCancellation(); images.removeAll() }
    func clearCache() async { images.removeAll() }
    func store<T: Sendable>(value: T) throws -> Int32 {
        guard let image = value as? AidokuRunner.PlatformImage, nextImage < Int32.max else { throw AidokuRunner.SourceError.unimplemented }
        let id = nextImage
        nextImage += 1
        images[id] = image
        return id
    }
    func remove(value: Int32) { images[value] = nil }

    private func response(_ url: String, range: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if range { request.setValue("bytes=0-16383", forHTTPHeaderField: "Range") }
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
    private func data(_ url: String, range: Bool = false) async throws -> Data {
        let (data, response) = try await response(url, range: range)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
    private func json(_ url: String) async throws -> [String: Any] {
        try Self.object(await data(url))
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return result
    }
    private func nextData(_ url: String) async throws -> [String: Any] {
        let html = try await data(url)
        let document = try SwiftSoup.parse(String(decoding: html, as: UTF8.self), url)
        guard let script = try document.select("script#__NEXT_DATA__").first() else { throw URLError(.cannotParseResponse) }
        let object = try Self.object(Data(try script.html().utf8))
        guard let props = object["props"] as? [String: Any], let page = props["pageProps"] as? [String: Any],
              let data = page["data"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return data
    }
    private func manga(_ item: [String: Any], catalogue: Bool = false) throws -> AidokuRunner.Manga {
        guard let name = item["name"] as? String, let slug = item["slug"] as? String else { throw URLError(.cannotParseResponse) }
        let image = item[catalogue ? "img" : "image"] as? String
        let thumbnail = item["thumbnail"] as? String
        let cover = thumbnail.flatMap { $0.isEmpty ? nil : $0 } ?? image.flatMap { $0.isEmpty ? nil : "https://i.mangaraw.lat/" + $0 }
        let authors = (item["author"] as? String)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return AidokuRunner.Manga(sourceKey: sourceKey, key: slug, title: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     cover: cover, authors: authors?.isEmpty == false ? authors : nil,
                     url: URL(string: base + "/manga/" + slug), status: Self.status(item["type"] as? String),
                     contentRating: Self.rating(item["is_adult"] as? String))
    }
    private static func status(_ value: String?) -> AidokuRunner.PublishingStatus {
        switch value { case "complete": .completed; case "incomplete": .ongoing; default: .unknown }
    }
    private static func rating(_ value: String?) -> AidokuRunner.ContentRating {
        switch value { case "yes": .nsfw; case "no": .safe; default: .unknown }
    }
    private func list(_ path: String, page: Int) async throws -> AidokuRunner.MangaPageResult {
        let result = try await nextData(base + path + (page > 1 ? "/page/\(page)" : ""))
        let pagination = result["pagination"] as? [String: Any]
        let next = (pagination?["current_page"] as? Int ?? 0) < (pagination?["total_page"] as? Int ?? 0)
        return AidokuRunner.MangaPageResult(entries: try (result["results"] as? [[String: Any]] ?? []).map { try manga($0) }, hasNextPage: next)
    }
    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        let period: String
        switch listing.id {
            case "rising": period = "rising"
            case "trending": period = "last30Days"
            case "lifetime": period = "lifetime"
            default: return try await list("/newest", page: page)
        }
        let result = try await json(base + "/top/\(period).json")
        guard let entries = result["mangas"] as? [[String: Any]], !entries.isEmpty else { throw URLError(.cannotParseResponse) }
        return AidokuRunner.MangaPageResult(entries: try entries.map { try manga($0) }, hasNextPage: false)
    }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        var author: String?
        var genre: String?
        for filter in filters {
            if case let .text(id, value) = filter, id == "author", !value.isEmpty { author = value }
            if case let .select(id, value) = filter, id == "genre", !value.isEmpty { genre = value }
        }
        if query != nil || author != nil {
            var mangas: [AidokuRunner.Manga] = []
            for index in 1...40 {
                let (data, response) = try await response(base + "/mangas_\(index).json")
                guard (200..<300).contains(response.statusCode) else {
                    if index == 1 { throw URLError(.badServerResponse) }
                    break
                }
                let catalogue: [String: Any]
                do { catalogue = try Self.object(data) }
                catch {
                    if index == 1 { throw error }
                    break
                }
                for item in catalogue["list"] as? [[String: Any]] ?? [] {
                    let matchesQuery = query.map { needle in
                        ["name", "alt_names", "author"].contains { (item[$0] as? String).map { Self.containsASCIICaseInsensitive($0, needle: needle) } ?? false }
                    } ?? true
                    let matchesAuthor = author.map { needle in
                        (item["author"] as? String).map { Self.containsASCIICaseInsensitive($0, needle: needle) } ?? false
                    } ?? true
                    if matchesQuery && matchesAuthor { mangas.append(try manga(item, catalogue: true)) }
                    if mangas.count >= 50 { return AidokuRunner.MangaPageResult(entries: mangas, hasNextPage: false) }
                }
            }
            return AidokuRunner.MangaPageResult(entries: mangas, hasNextPage: false)
        }
        return try await list(genre.map { "/genre/" + $0 } ?? "/newest", page: page)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        let url = base + "/manga/" + manga.key
        let page = try await nextData(url)
        guard let details = page["manga"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var result = manga
        if needsDetails {
            let parsed = try self.manga(details)
            result.title = parsed.title; result.cover = parsed.cover; result.authors = parsed.authors
            result.url = parsed.url; result.status = parsed.status; result.contentRating = parsed.contentRating
            let genres = details["genres"] as? [[String: Any]] ?? []
            let tags = genres.compactMap { $0["name"] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            result.tags = tags.isEmpty ? nil : tags
            result.viewer = genres.contains { item in
                let slug = item["slug"] as? String ?? ""
                return slug == "kaigai-manga" || slug.contains("webtoon")
            } ? .webtoon : .rightToLeft
            result.description = Self.description(details)
            if needsChapters {
                try Task.checkCancellation()
                await partialMangaPublisher?.send(result, to: PartialResultSubscription.id)
            }
        }
        if needsChapters {
            guard let id = (details["id"] as? NSNumber)?.int64Value, let slug = details["slug"] as? String else {
                throw URLError(.cannotParseResponse)
            }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            result.chapters = try (details["chapters"] as? [[String: Any]] ?? []).map { item in
                guard let chapterID = item["id"] as? Int, let path = item["path"] as? String else { throw URLError(.cannotParseResponse) }
                let suffix = path.hasPrefix(slug + "-") ? String(path.dropFirst(slug.count + 1)) : path
                let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AidokuRunner.Chapter(key: "\(id)/\(chapterID)", title: title?.isEmpty == false ? title : nil,
                               chapterNumber: Self.number(item["name"]), dateUploaded: (item["published_at"] as? String).flatMap { formatter.date(from: $0) },
                               url: URL(string: base + "/manga/" + slug + "/" + suffix))
            }
        }
        return result
    }
    private static func containsASCIICaseInsensitive(_ value: String, needle: String) -> Bool {
        func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
        let haystack = Array(value.utf8).map(lower)
        let search = Array(needle.utf8).map(lower)
        guard !search.isEmpty else { return true }
        guard search.count <= haystack.count else { return false }
        return (0...(haystack.count - search.count)).contains { index in
            haystack[index..<(index + search.count)].elementsEqual(search)
        }
    }
    private static func number(_ value: Any?) -> Float? {
        if let value = value as? NSNumber { return value.floatValue }
        return (value as? String).flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    private static func description(_ details: [String: Any]) -> String? {
        func clean(_ text: String) -> String { (try? SwiftSoup.parseBodyFragment(text).text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text }
        if let text = details["description"] as? String, !clean(text).isEmpty { return clean(text) }
        guard let content = details["content"] as? String, let object = try? Self.object(Data(content.utf8)) else { return nil }
        let texts = (object["blocks"] as? [[String: Any]] ?? []).compactMap { ($0["data"] as? [String: Any])?["text"] as? String }.map(clean).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let ids = chapter.key.split(separator: "/")
        guard ids.count == 2, let chapterID = Int64(ids[1]), let url = chapter.url else { throw URLError(.badURL) }
        let page = try await nextData(url.absoluteString)
        guard let details = page["chapter"] as? [String: Any], let uuid = details["uuid"] as? String,
              let host = details["_b"] as? String else { throw URLError(.cannotParseResponse) }
        let payload = try await json("https://api.mangarawgo.site/\(ids[0])/\(chapterID).json")
        guard let encoded = payload["d"] as? String, let decoded = SoraRawImageCodec.deobfuscate(encoded),
              let entries = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [[String: Any]], !entries.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let scrambled = details["mode"] as? String == "canva2"
        var ordered: [(Float, URL)] = []
        for entry in entries {
            guard let order = Self.number(entry["order"]), let encoded = entry["b"] as? String,
                  let path = SoraRawImageCodec.decryptPath(encoded, uuid: uuid), let url = URL(string: host + "/" + path) else {
                throw URLError(.cannotParseResponse)
            }
            ordered.append((order, url))
        }
        var pages: [AidokuRunner.Page] = []
        for (_, url) in ordered.sorted(by: { $0.0 < $1.0 }) {
            try Task.checkCancellation()
            if scrambled { pages.append(AidokuRunner.Page(content: .url(url: url, context: ["seed": "\(chapterID)"]))); continue }
            let count = ordered.count <= 4 ? await sliceCount(url: url) : 1
            try Task.checkCancellation()
            if count == 1 { pages.append(AidokuRunner.Page(content: .url(url: url))) }
            else {
                for slice in 0..<count { pages.append(AidokuRunner.Page(content: .url(url: url, context: ["slice": "\(slice)", "slices": "\(count)"]))) }
            }
        }
        return pages
    }
    private func sliceCount(url: URL) async -> Int {
        guard let data = try? await data(url.absoluteString, range: true),
              let size = SoraRawImageCodec.headerSize(data) else { return 1 }
        return SoraRawImageCodec.stackedPageCount(width: size.width, height: size.height)
    }
    func processPageImage(response: AidokuRunner.Response, context: AidokuRunner.PageContext?) throws -> AidokuRunner.PlatformImage? {
        try Task.checkCancellation()
        guard let image = images[response.image] else { throw AidokuRunner.SourceError.unimplemented }
        if let seed = context?["seed"] { return SoraRawImageCodec.unscramble(image, seed: seed) ?? image }
        if let value = context?["slice"], let total = context?["slices"], let slice = Int(value), let slices = Int(total) {
            return SoraRawImageCodec.slice(image, slice: slice, slices: slices) ?? image
        }
        return image
    }
    func getSearchFilters() async throws -> [AidokuRunner.Filter] {
        let body = try await data(base + "/genres.json")
        guard let genres = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var names = ["All"]; var ids = [""]
        for genre in genres.prefix(100) {
            guard let name = genre["name"] as? String, let slug = genre["slug"] as? String, !slug.isEmpty else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.append(trimmed); ids.append(slug) }
        }
        return [AidokuRunner.Filter(id: "genre", title: "Genre", value: .select(AidokuRunner.SelectFilter(isGenre: true, options: names, ids: ids)))]
    }
    func handleDeepLink(url: String) async throws -> AidokuRunner.DeepLinkResult? {
        guard let link = URL(string: url), link.host == "soraraw.com", link.scheme == "https" else { return nil }
        let parts = link.path.split(separator: "/")
        guard parts.count == 2 || parts.count == 3, parts.first == "manga" else { return nil }
        let slug = String(parts[1])
        if parts.count == 2 { return AidokuRunner.DeepLinkResult(mangaKey: slug) }
        let data = try await nextData(base + link.path)
        guard let chapter = data["chapter"] as? [String: Any], let mangaID = chapter["manga_id"] as? Int,
              let chapterID = chapter["id"] as? Int else { return nil }
        return AidokuRunner.DeepLinkResult(mangaKey: slug, chapterKey: "\(mangaID)/\(chapterID)")
    }
}
