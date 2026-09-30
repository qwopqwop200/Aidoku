// Native port of Aidoku-Community/sources ja.rawotaku v2 and its MangaReader template.
// Copyright Aidoku community source contributors. MIT license; see Docs/NativeSource-MIT.txt.
import AidokuRunner
import Foundation
import SwiftSoup
import UIKit

/// Native port of recovered ja.rawotaku v2 and its MangaReader template.
actor RawOtakuSourceRunner: NativeSourceRunnerLifecycle {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let features = SourceFeatures(
        providesListings: true, providesHome: true, processesPages: true,
        providesImageRequests: true, handlesDeepLinks: true
    )
    let sourceKey: String
    private let fetch: Fetch
    private var images: [Int32: UIImage] = [:]
    private var nextImage: Int32 = 0
    static let base = "https://rawotaku.com"

    init(sourceKey: String = "ja.rawotaku", fetch: Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }

    func restart() async throws { try Task.checkCancellation(); await clearCache() }
    func clearCache() async { images.removeAll() }

    private func request(_ path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: URL(string: Self.base))?.absoluteURL else { throw URLError(.badURL) }
        return URLRequest(url: url)
    }

    private func data(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw SourceError.networkError
        }
        return data
    }

    private func html(_ path: String) async throws -> Document {
        let request = try request(path)
        let bytes = try await data(request)
        guard let text = String(data: bytes, encoding: .utf8) else { throw SourceError.htmlError }
        return try SwiftSoup.parse(text, request.url?.absoluteString ?? Self.base)
    }

    func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        let document = try await html(Self.searchPath(query: query, page: page, filters: filters))
        let entries = try document.select(".manga_list-sbs .manga-poster").array().compactMap { element -> AidokuRunner.Manga? in
            guard element.hasAttr("href"), let image = try element.select("img").first(), image.hasAttr("alt") else { return nil }
            return .init(sourceKey: sourceKey, key: Self.pathKey(try element.attr("href")), title: try image.attr("alt"), cover: try Self.imageURL(image))
        }
        return .init(entries: entries, hasNextPage: try document.select("ul.pagination > li.active + li").first() != nil)
    }

    static func searchPath(query: String?, page: Int, filters: [FilterValue]) -> String {
        var components = URLComponents()
        components.path = query == nil ? "/filter" : ""
        if let query {
            components.queryItems = [.init(name: "q", value: query), .init(name: "p", value: String(page))]
        } else {
            var values = ["type": "all", "status": "all", "language": "all", "sort": "default"]
            for filter in filters {
                switch filter {
                    case .sort(let sort):
                        let sorts = ["default", "latest-update", "most-viewed", "title-az", "title-za"]
                        values["sort"] = sorts.indices.contains(Int(sort.index)) ? sorts[Int(sort.index)] : "default"
                    case .select(let id, let value): values[id] = value
                    case .multiselect(_, let included, _): values["genres"] = included.joined(separator: ",")
                    default: break
                }
            }
            components.queryItems = [.init(name: "p", value: String(page))] + values.keys.sorted().map { .init(name: $0, value: values[$0]) }
        }
        // URLComponents query encoding leaves '+' literal; servers decode it as a space.
        return (components.string ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        var components = URLComponents()
        components.path = "/" + listing.id
        components.queryItems = [.init(name: "p", value: String(page))]
        let document = try await html(components.string ?? "/")
        return .init(entries: try parseList(document), hasNextPage: try document.select("a.page-link[title=Next]").first() != nil)
    }

    private func parseList(_ element: Element) throws -> [AidokuRunner.Manga] {
        try element.select(".item").array().compactMap { item in
            guard let link = try item.select("a.manga-poster").first(), link.hasAttr("href"),
                  let name = try item.select(".manga-name").first() else { return nil }
            return .init(sourceKey: sourceKey, key: Self.pathKey(try link.attr("href")), title: try name.text(),
                         cover: try item.select(".manga-poster img").first().flatMap { try Self.imageURL($0) })
        }
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        let document = try await html(manga.key)
        var result = manga
        if needsDetails {
            guard let details = try document.select("#ani_detail").first() else {
                throw SourceError.message("Unable to find manga details")
            }
            result.url = URL(string: Self.base + manga.key)
            if let title = try details.select(".manga_name, .manga-name").first() { result.title = try title.ownText() }
            result.cover = try details.select("img").first().flatMap { try Self.imageURL($0) }
            let authorItems = try details.select(".anisc-info > .item:contains(Author), .anisc-info > .item:contains(著者)")
            result.authors = nil
            result.artists = nil
            if !authorItems.isEmpty() {
                let text = try authorItems.text()
                var authors: [String] = []
                var artists: [String] = []
                for link in try authorItems.select("a").array() {
                    let name = try link.ownText()
                    if text.contains(name + " (Art)") { artists.append(name.replacingOccurrences(of: ",", with: "")) }
                    else { authors.append(name.replacingOccurrences(of: ",", with: "")) }
                }
                result.authors = authors
                result.artists = artists
            }
            result.description = try details.select(".description").first()?.ownText()
            result.tags = try details.select(".genres > a").array().map { try $0.ownText() }
            let status = try details.select(".anisc-info > .item:contains(Status) .name, .anisc-info > .item:contains(地位) .name").first()?.text()
            switch status?.lowercased() {
                case "ongoing", "publishing", "releasing": result.status = .ongoing
                case "completed", "finished": result.status = .completed
                case "on-hiatus", "on hiatus": result.status = .hiatus
                case "canceled", "discontinued": result.status = .cancelled
                default: result.status = .unknown
            }
            let type = try details.select(".anisc-info > .item:contains(タイプ) .name").first()?.text()
            let tags = result.tags ?? []
            result.contentRating = tags.contains("Hentai") || tags.contains("エロい") ? .nsfw
                : (tags.contains("Ecchi") ? .suggestive : (type == "オトナコミック" ? .nsfw : .safe))
            let viewerType = try details.select(".anisc-info > .item:contains(Type) .name").first()?.text().lowercased()
            result.viewer = ["manhwa", "manhua"].contains(viewerType ?? "") ? .webtoon : (viewerType == "comic" ? .leftToRight : .rightToLeft)
        }
        if needsChapters { result.chapters = try Self.parseChapters(document) }
        return result
    }

    static func parseChapters(_ document: Document) throws -> [AidokuRunner.Chapter] {
        let chapters = try document.select("#ja-chaps > li").array().compactMap { element -> AidokuRunner.Chapter? in
            guard let link = try element.select("a").first(), link.hasAttr("href") else { return nil }
            let absolute = try link.attr("abs:href")
            guard absolute.hasPrefix(base) else { return nil }
            var key = String(absolute.dropFirst(base.count))
            if element.hasAttr("data-id") { key += "#" + (try element.attr("data-id")) }
            let name = try link.select(".name").first()?.text()
            let number = name?.firstIndex(of: ":").flatMap { colon in
                Float(name![..<colon].filter { $0.isASCII && ($0.isNumber || $0 == ".") })
            }
            return .init(key: key, title: nil, chapterNumber: number, url: URL(string: absolute), language: "ja")
        }
        return chapters.enumerated().sorted {
            let lhs = $0.element.chapterNumber ?? -1
            let rhs = $1.element.chapterNumber ?? -1
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
    }

    func getPageList(manga _: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let fragment = chapter.key.lastIndex(of: "#")
        let id: String
        let chapterPath: String
        if let fragment {
            id = String(chapter.key[chapter.key.index(after: fragment)...])
            chapterPath = String(chapter.key[..<fragment])
        } else {
            chapterPath = chapter.key
            let document = try await html(chapterPath)
            if let url = try request(chapterPath).url, let chapter = try Self.readerChapter(document, url: url) {
                id = chapter.id
            } else {
                guard let element = try document.select("div[data-reading-id]").first() else {
                    throw SourceError.message("Unable to retrieve chapter id")
                }
                id = try element.attr("data-reading-id")
            }
        }
        var components = URLComponents()
        components.path = "/json/chapter"
        components.queryItems = [.init(name: "id", value: id), .init(name: "mode", value: "vertical")]
        var request = try request(components.string ?? "")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue(Self.base + chapterPath, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let object = try JSONSerialization.jsonObject(with: await data(request)) as? [String: Any]
        let document = try SwiftSoup.parseBodyFragment(object?["html"] as? String ?? "", Self.base)
        let urls = try document.select(".container-reader-chapter > div > img").array().compactMap { try Self.imageURL($0) }
        var pages: [AidokuRunner.Page] = []
        for string in urls {
            guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            var count = 1
            if urls.count <= 4 {
                var header = URLRequest(url: url)
                header.setValue("bytes=0-16383", forHTTPHeaderField: "Range")
                if let bytes = try? await data(header), let size = Self.jpegSize(bytes) {
                    count = Self.sliceCount(width: size.width, height: size.height)
                }
                try Task.checkCancellation()
            }
            if count < 2 { pages.append(.init(content: .url(url: url))) }
            else {
                for index in 0..<count {
                    pages.append(.init(content: .url(url: url, context: ["slice": String(index), "slices": String(count)])))
                }
            }
        }
        return pages
    }

    static func sliceCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        let pages = Float(height) / (Float(width) * 1.42)
        guard pages.isFinite, pages < 65 else { return 1 }
        let rounded = Int(pages + 0.5)
        guard (2...64).contains(rounded) else { return 1 }
        let neighbour = pages < Float(rounded) ? rounded - 1 : rounded + 1
        for count in [rounded, neighbour] where (2...64).contains(count) && height % count == 0 { return count }
        return rounded
    }

    static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        func length(_ index: Int) -> Int? {
            guard index >= 0, index + 1 < bytes.count else { return nil }
            return Int(bytes[index]) * 256 + Int(bytes[index + 1])
        }
        var index = 2
        while index + 1 < bytes.count, bytes[index] == 0xff {
            let marker = bytes[index + 1]
            if marker == 0xff { index += 1 }
            else if marker == 1 || (0xd0...0xd9).contains(marker) { index += 2 }
            else if [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].contains(marker) {
                guard let height = length(index + 5), let width = length(index + 7) else { return nil }
                return (width, height)
            } else {
                guard let segment = length(index + 2), segment >= 2 else { return nil }
                index += 2 + segment
            }
        }
        return nil
    }

    func getHome() async throws -> Home {
        let document = try await html("/home")
        var components: [HomeComponent] = []
        let slides = try document.select("#slider .deslide-item:not(.swiper-slide-duplicate)")
        if !slides.isEmpty() {
            let entries = try slides.array().compactMap { element -> AidokuRunner.Manga? in
                guard let link = try element.select(".desi-head-title a").first(),
                      link.hasAttr("href"), link.hasAttr("title") else { return nil }
                return .init(sourceKey: sourceKey, key: Self.pathKey(try link.attr("href")), title: try link.attr("title"),
                             cover: try element.select(".deslide-poster img").first().flatMap { try Self.imageURL($0) },
                             description: try element.select(".sc-detail > .scd-item").first()?.text(),
                             tags: try element.select(".sc-detail > .scd-genres > span").array().map { try $0.text() })
            }
            components.append(.init(title: nil, value: .bigScroller(entries: entries, autoScrollInterval: 5)))
        }
        for selector in ["#manga-trending", "#manga-featured"] {
            if let section = try document.select(selector).first() { components.append(try parseSwiper(section)) }
        }
        if let section = try document.select("#main-content").first() {
            let entries = try section.select(".item").array().prefix(10).compactMap { element -> MangaWithChapter? in
                guard let link = try element.select("a.manga-poster").first(), link.hasAttr("href"),
                      let title = try element.select(".manga-name").first(),
                      let chapter = try element.select(".fd-list .chapter a").first(), chapter.hasAttr("href") else { return nil }
                let manga = AidokuRunner.Manga(
                    sourceKey: sourceKey, key: Self.pathKey(try link.attr("href")), title: try title.text(),
                    cover: try element.select(".manga-poster img").first().flatMap { try Self.imageURL($0) }
                )
                let number = Float(try chapter.text().filter { $0.isASCII && ($0.isNumber || $0 == ".") })
                return .init(manga: manga, chapter: .init(key: Self.pathKey(try chapter.attr("href")), chapterNumber: number))
            }
            components.append(.init(title: try section.select(".cat-heading").first()?.text(),
                                    value: .mangaChapterList(entries: entries)))
        }
        for section in try document.select("#main-sidebar > section").array() {
            let ranked = try section.select("#chart-today").first() != nil
            let selector = ranked ? "#chart-today .featured-block-ul > ul > li" : ".featured-block-ul > ul > li"
            let items = try section.select(selector)
            guard !items.isEmpty() else { continue }
            let entries = try items.array().compactMap { element -> HomeComponent.Value.Link? in
                guard let link = try element.select("a.manga-poster").first(),
                      let title = try element.select(".manga-name").first() else { return nil }
                let absolute = try link.attr("abs:href")
                guard absolute.hasPrefix(Self.base) else { return nil }
                return AidokuRunner.Manga(
                    sourceKey: sourceKey, key: Self.pathKey(absolute), title: try title.text(),
                    cover: try element.select(".manga-poster img").first().flatMap { try Self.imageURL($0) }
                ).intoLink()
            }
            components.append(.init(title: try section.select(".cat-heading").first()?.text(),
                                    value: .mangaList(ranking: ranked, pageSize: 5, entries: entries)))
        }
        if let section = try document.select("#main-wrapper > div.container > div > section").first() {
            components.append(try parseSwiper(section))
        }
        return .init(components: components)
    }

    private func parseSwiper(_ section: Element) throws -> HomeComponent {
        let entries = try section.select(".swiper-slide").array().compactMap { element -> HomeComponent.Value.Link? in
            guard let link = try element.select(".manga-poster a").first(), link.hasAttr("href"),
                  let title = try element.select(".anime-name, .manga-name").first() else { return nil }
            return AidokuRunner.Manga(
                sourceKey: sourceKey, key: Self.pathKey(try link.attr("href")), title: try title.text(),
                cover: try element.select(".manga-poster img").first().flatMap { try Self.imageURL($0) }
            ).intoLink()
        }
        return .init(title: try section.select(".cat-heading").first()?.text(), value: .scroller(entries: entries))
    }

    func getImageRequest(url: String, context _: PageContext?) async throws -> URLRequest {
        var request = try request(url)
        request.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        return request
    }

    func store<T: Sendable>(value: T) async throws -> Int32 {
        guard let image = value as? UIImage else { throw SourceError.deserializeError }
        guard nextImage < Int32.max else { throw SourceError.deserializeError }
        nextImage += 1
        images[nextImage] = image
        return nextImage
    }

    func remove(value: Int32) async throws { images.removeValue(forKey: value) }

    func processPageImage(response: AidokuRunner.Response, context: PageContext?) async throws -> UIImage? {
        guard let image = images[response.image] else { throw SourceError.deserializeError }
        guard let context, let slice = context["slice"].flatMap(Int.init), let slices = context["slices"].flatMap(Int.init),
              slices >= 2, slice >= 0, slice < slices, let cgImage = image.cgImage else { return image }
        let top = cgImage.height * slice / slices
        let bottom = cgImage.height * (slice + 1) / slices
        guard bottom > top, let crop = cgImage.cropping(to: CGRect(x: 0, y: CGFloat(top), width: CGFloat(cgImage.width), height: CGFloat(bottom - top))) else { return image }
        return UIImage(cgImage: crop, scale: image.scale, orientation: image.imageOrientation)
    }

    func handleDeepLink(url: String) async throws -> DeepLinkResult? {
        guard url.hasPrefix(Self.base), let parsed = URL(string: url), parsed.host == "rawotaku.com" else { return nil }
        try Task.checkCancellation()
        let path = String(url.dropFirst(Self.base.count))
        if parsed.path.hasPrefix("/read/"), parsed.pathComponents.count > 3 {
            let document = try await html(url)
            guard let mangaLink = try document.select("a.hr-manga[href]").first(),
                  let mangaURL = URL(string: try mangaLink.attr("abs:href")), mangaURL.host == parsed.host else { return nil }
            // Use the same HTML attributes as search/details, preserving installed keys.
            // The reader's data-reading-id may refer to a legacy English chapter even
            // on a Japanese URL; the matching Japanese list item has the correct id.
            if let chapter = try Self.readerChapter(document, url: parsed) {
                return .init(mangaKey: Self.pathKey(try mangaLink.attr("href")),
                             chapterKey: chapter.key + "#" + chapter.id)
            }
            return nil
        }
        return .init(mangaKey: path)
    }

    private static func readerChapter(_ document: Document, url: URL) throws -> (key: String, id: String)? {
        for item in try document.select("#ja-chapters > li, #ja-chaps > li").array() {
            guard let link = try item.select("a[href]").first(),
                  let chapterURL = URL(string: try link.attr("abs:href")),
                  chapterURL.host == url.host, chapterURL.path == url.path else { continue }
            let id = try item.attr("data-id")
            guard !id.isEmpty else { continue }
            return (pathKey(try link.attr("abs:href")), id)
        }
        return nil
    }

    private static func pathKey(_ string: String) -> String { string.hasPrefix(base) ? String(string.dropFirst(base.count)) : string }
    private static func imageURL(_ element: Element) throws -> String? {
        for key in ["data-lazy-src", "data-src", "data-url", "src"] where element.hasAttr(key) {
            let absolute = try element.attr("abs:" + key)
            if !absolute.isEmpty { return absolute }
        }
        return element.hasAttr("data-url") ? try element.attr("data-url") : nil
    }
}
