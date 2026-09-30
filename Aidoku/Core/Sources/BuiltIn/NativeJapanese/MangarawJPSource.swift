import AidokuRunner
import Foundation
import SwiftSoup
import UIKit

/// Native port of ja.mangarawjp v2, including its image-order context.
actor MangarawJPSourceRunner: NativeSourceRunnerLifecycle {
    nonisolated let partialMangaPublisher: SinglePublisher<AidokuRunner.Manga>? = .init()
    let sourceKey: String
    let fetch: NativeSourceNetwork.Fetch
    let features = SourceFeatures(processesPages: true, providesImageRequests: true, handlesDeepLinks: true)
    static let base = "https://mangarawjp.tv"
    private var images: [Int32: UIImage] = [:]
    private var nextImage: Int64 = 1

    init(sourceKey: String = "ja.mangarawjp", fetch: NativeSourceNetwork.Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    static func cleanTitle(_ value: String) -> String {
        for suffix in [" Raw Free", " Raw free", " raw free"] where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        let url: URL
        if let query, !query.isEmpty {
            url = try GroupASourceSupport.url(Self.base, path: "/", query: [.init(name: "s", value: query), .init(name: "page", value: String(page))])
        } else {
            let sort = filters.compactMap { filter -> Int? in if case .sort(let value) = filter { return Int(value.index) }; return nil }.first ?? 0
            url = try GroupASourceSupport.url(Self.base, path: sort == 1 ? "/ranking/\(page)/" : "/page/\(page)/")
        }
        return try Self.parseListing(await GroupASourceSupport.html(url, fetch: fetch), sourceKey: sourceKey)
    }

    static func parseListing(_ doc: Document, sourceKey: String) throws -> AidokuRunner.MangaPageResult {
        guard let list = try doc.select(".post-list").first() else { throw SourceError.message("Manga list not found") }
        let entries = try list.select("a").array().compactMap { element -> AidokuRunner.Manga? in
            let value = try element.attr("abs:href")
            guard let url = URL(string: value), url.host == "mangarawjp.tv", let title = GroupASourceSupport.text(element, "h3") else { return nil }
            return .init(sourceKey: sourceKey, key: URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path, title: Self.cleanTitle(title),
                cover: GroupASourceSupport.attr(element, "img", "abs:data-src"), url: url)
        }
        return .init(entries: entries, hasNextPage: !entries.isEmpty)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        let url = try GroupASourceSupport.url(Self.base, path: manga.key)
        let doc = try await GroupASourceSupport.html(url, fetch: fetch)
        var result = manga
        if needsDetails {
            result.title = Self.cleanTitle(GroupASourceSupport.text(doc, "h1") ?? result.title)
            result.cover = GroupASourceSupport.attr(doc, ".post-cover > img", "abs:src")
            let texts = try doc.select(".page-h p").array().map { try $0.ownText() }
            result.description = texts.isEmpty ? nil : texts.joined(separator: "\n ")
            result.url = url
            let tags = try doc.select(".category-warp > a, .tag-list > a").array().map { try $0.text() }
            result.tags = Array(Set(tags)).sorted()
            result.contentRating = tags.contains(where: { $0 == "オトナ" || $0.contains("エロ") }) ? .nsfw : tags.contains("Ecchi") ? .suggestive : .safe
            result.viewer = .rightToLeft
            if needsChapters {
                try Task.checkCancellation()
                await partialMangaPublisher?.send(result, to: PartialResultSubscription.id)
            }
        }
        if needsChapters {
            result.chapters = try doc.select(".ch-list li a").array().compactMap { element in
                guard let url = URL(string: try element.attr("abs:href")), url.host == "mangarawjp.tv" else { return nil }
                return .init(key: URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path, chapterNumber: GroupASourceSupport.number(try element.text(), japaneseOnly: true), url: url)
            }
        }
        return result
    }

    static func readerIDs(_ doc: Document) throws -> (String, String) {
        let scripts = try doc.select("script").array().map { try $0.data() }.joined(separator: "\n")
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: scripts, range: NSRange(scripts.startIndex..., in: scripts)),
                  let range = Range(match.range(at: 1), in: scripts) else { return nil }
            return String(scripts[range])
        }
        guard let manga = capture(#"window\.MangaId\s*=\s*([0-9]+)"#),
              let chapter = capture(#"window\.CNumber\s*=\s*([0-9]+(?:\.[0-9]+)?)"#) else {
            throw SourceError.message("Reader identifiers not found")
        }
        return (manga, chapter)
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let url = try GroupASourceSupport.url(Self.base, path: chapter.key)
        let ids = try Self.readerIDs(await GroupASourceSupport.html(url, fetch: fetch))
        var request = URLRequest(url: try GroupASourceSupport.url(Self.base, path: "/api/v1/get/c"))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"m\":\(ids.0),\"n\":\(ids.1)}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        let result = try JSONDecoder().decode(ChapterResponse.self, from: await GroupASourceSupport.data(request, fetch: fetch))
        return try result.e.map { path in
            guard let url = URL(string: "https://img-cdn.stackpathcdn.app" + path) else { throw SourceError.message("Invalid image URL") }
            return .init(content: .url(url: url, context: ["key": result.c]))
        }
    }

    private struct ChapterResponse: Decodable {
        let e: [String]
        let c: String

        private enum CodingKeys: String, CodingKey { case e, c }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Upstream serde defaults apply only when a field is absent, not explicit null.
            e = container.contains(.e) ? try container.decode([String].self, forKey: .e) : []
            c = container.contains(.c) ? try container.decode(String.self, forKey: .c) : ""
        }
    }

    func store<T: Sendable>(value: T) throws -> Int32 {
        try Task.checkCancellation()
        let image: UIImage?
        if let value = value as? UIImage { image = value }
        else if let value = value as? Data { image = UIImage(data: value) }
        else { image = nil }
        guard let image else { throw SourceError.message("Unsupported native image") }
        try Task.checkCancellation()
        guard nextImage <= Int64(Int32.max) else { throw SourceError.message("Native image handle exhausted") }
        let key = Int32(nextImage)
        nextImage += 1
        images[key] = image
        do {
            try Task.checkCancellation()
        } catch {
            images.removeValue(forKey: key)
            throw error
        }
        return key
    }

    func remove(value: Int32) { images.removeValue(forKey: value) }

    func clearCache() async { images.removeAll() }

    func restart() async throws {
        try Task.checkCancellation()
        images.removeAll()
    }

    func processPageImage(response: AidokuRunner.Response, context: PageContext?) throws -> PlatformImage? {
        try Task.checkCancellation()
        guard let image = images[response.image] else { throw SourceError.message("Missing native image") }
        guard let key = context?["key"], !key.isEmpty else { return image }
        let result = try MangarawJPImageCodec.decode(image, key: key)
        try Task.checkCancellation()
        return result
    }

    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        try GroupASourceSupport.imageRequest(url, base: Self.base)
    }

    func handleDeepLink(url: String) async throws -> DeepLinkResult? {
        guard let url = URL(string: url), url.host == "mangarawjp.tv" else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "manga-raw" else { return nil }
        if parts.count > 2 { return .init(mangaKey: "/\(parts[0])/\(parts[1])/", chapterKey: path) }
        return .init(mangaKey: path)
    }
}
