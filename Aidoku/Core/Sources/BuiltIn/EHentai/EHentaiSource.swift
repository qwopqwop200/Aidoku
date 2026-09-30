// Native port of Aidoku-Community/sources multi.ehentai v2 (MIT OR Apache-2.0).
import AidokuRunner
import Foundation
import SwiftSoup

actor EHentaiSourceRunner: AidokuRunner.NativeSourceRunnerLifecycle {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sourceKey: String
    nonisolated let partialHomePublisher: AidokuRunner.SinglePublisher<AidokuRunner.Home>? = AidokuRunner.SinglePublisher()
    let features = AidokuRunner.SourceFeatures(providesListings: true, providesHome: true, dynamicListings: true,
                                  providesImageRequests: true, handlesDeepLinks: true)
    private let fetch: Fetch
    private let preference: @Sendable (String) -> String?
    private let listPreference: @Sendable (String) -> [String]
    private let setPreference: @Sendable (String, String?) -> Void
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    enum Failure: Error { case accessDenied, noPages, invalidGallery, invalidImage, resourceLimit }

    init(sourceKey: String = "multi.ehentai", fetch: @escaping Fetch = { try await EHentaiSourceRunner.fetchSourceRequest($0) },
         preference: (@Sendable (String) -> String?)? = nil,
         listPreference: (@Sendable (String) -> [String])? = nil,
         setPreference: (@Sendable (String, String?) -> Void)? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch
        self.preference = preference ?? { UserDefaults.standard.string(forKey: "\(sourceKey).\($0)") }
        self.listPreference = listPreference ?? { UserDefaults.standard.stringArray(forKey: "\(sourceKey).\($0)") ?? [] }
        self.setPreference = setPreference ?? { key, value in
            if let value { UserDefaults.standard.set(value, forKey: "\(sourceKey).\(key)") }
            else { UserDefaults.standard.removeObject(forKey: "\(sourceKey).\(key)") }
        }
    }

    nonisolated private static func fetchSourceRequest(_ original: URLRequest) async throws -> (Data, URLResponse) {
        let request = if let url = original.url { await AidokuRunner.Source.modify(url: url, request: original) } else { original }
        let (data, response) = try await SourceNetwork.shared.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, CloudflareHandler.shared.shouldHandle(response: http, data: data) {
            do { return try await CloudflareHandler.shared.handle(request: request) }
            catch is CloudflareHandler.HandleError { return (data, response) }
        }
        return (data, response)
    }

    func restart() async throws { try Task.checkCancellation() }
    func clearCache() async {
        for listing in ["search", "latest", "popular", "watched"] { setPreference("cursor_\(listing)", nil) }
    }
    private var domain: String { preference("domain") == "exhentai.org" ? "exhentai.org" : "e-hentai.org" }
    private var base: String { "https://\(domain)" }
    private var japanese: Bool { preference("titlePreference") == "japanese" }
    private var loggedIn: Bool { !(preference("ipb_member_id") ?? "").isEmpty && !(preference("ipb_pass_hash") ?? "").isEmpty }
    private var blocklist: [String] {
        listPreference("blocklist").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }
    private var language: String? {
        let languages = ["ja": "japanese", "en": "english", "zh": "chinese", "nl": "dutch", "fr": "french", "de": "german",
                         "hu": "hungarian", "it": "italian", "ko": "korean", "pl": "polish", "pt-BR": "portuguese", "ru": "russian",
                         "es": "spanish", "th": "thai", "vi": "vietnamese"]
        return preference("language").flatMap { languages[$0] }
    }
    private func cookies(includeIgneous: Bool = true) -> String {
        var parts = ["nw=1"]
        for name in ["ipb_member_id", "ipb_pass_hash"] + (includeIgneous ? ["igneous"] : []) {
            if let value = preference(name), !value.isEmpty,
               !value.contains(";"), !value.contains("\n"), !value.contains("\r") { parts.append("\(name)=\(value)") }
        }
        return parts.joined(separator: "; ")
    }
    private func rewrite(_ string: String) throws -> String {
        guard var components = URLComponents(string: string), let host = components.host,
              ["e-hentai.org", "exhentai.org"].contains(host.lowercased()),
              components.scheme == "https" || components.scheme == "http" else { throw URLError(.badURL) }
        components.host = domain
        components.scheme = "https"
        components.user = nil
        components.password = nil
        components.port = nil
        guard let value = components.string else { throw URLError(.badURL) }
        return value
    }
    private func request(_ string: String, includeIgneous: Bool = true) throws -> URLRequest {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(base, forHTTPHeaderField: "Referer")
        // Account cookies belong to the authenticated site, not arbitrary image CDN hosts.
        if ["e-hentai.org", "exhentai.org", "api.e-hentai.org"].contains(url.host?.lowercased() ?? "") {
            request.setValue(cookies(includeIgneous: includeIgneous), forHTTPHeaderField: "Cookie")
        }
        return request
    }
    private func refreshIgneous(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse, http.url?.host == "exhentai.org",
              let header = http.value(forHTTPHeaderField: "Set-Cookie") else { return }
        for part in header.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.hasPrefix("igneous=") {
                let value = part.dropFirst(8).split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                if !value.isEmpty { setPreference("igneous", value) }
                return
            }
        }
    }
    private func data(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        refreshIgneous(response)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard data.count <= 20_000_000 else { throw Failure.resourceLimit }
        return data
    }
    private func document(_ data: Data, url: String) throws -> Document {
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try SwiftSoup.parse(text, url)
    }
    private func html(_ url: String) async throws -> Document {
        let doc = try document(await data(request(url)), url: url)
        guard URL(string: url)?.host == "exhentai.org", try doc.select("body div").first() == nil else { return doc }
        do { _ = try await data(request("https://exhentai.org", includeIgneous: false)) }
        catch { try Task.checkCancellation() }
        let retry = try document(await data(request(url)), url: url)
        guard try retry.select("body div").first() != nil else { throw Failure.accessDenied }
        return retry
    }
    private func page(_ parsed: (items: [EHGalleryItem], hasNext: Bool, lastGID: String?)) -> AidokuRunner.MangaPageResult {
        AidokuRunner.MangaPageResult(entries: parsed.items.filter { !$0.blocked(by: blocklist) }
            .map { $0.manga(sourceKey: sourceKey, japanese: japanese, basic: true) }, hasNextPage: parsed.hasNext)
    }
    private func url(base: String, path: String, query: [URLQueryItem]) throws -> String {
        guard var components = URLComponents(string: base + path) else { throw URLError(.badURL) }
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let string = components.string else { throw URLError(.badURL) }
        return string
    }

    func getListings() -> [AidokuRunner.Listing] {
        var result = loggedIn ? [AidokuRunner.Listing(id: "watched", name: "Watched")] : []
        result += [("latest", "Latest"), ("popular", "Popular"), ("top_yesterday", "Top Yesterday"), ("top_month", "Top Month"),
                   ("top_year", "Top Year"), ("top_all", "Top All Time")].map { AidokuRunner.Listing(id: $0.0, name: $0.1) }
        return result
    }
    func getMangaList(listing: AidokuRunner.Listing, page number: Int) async throws -> AidokuRunner.MangaPageResult {
        guard number > 0 else { throw URLError(.badURL) }
        let tops = ["top_yesterday": 15, "top_month": 13, "top_year": 12, "top_all": 11]
        if let top = tops[listing.id] {
            let url = try url(base: "https://e-hentai.org", path: "/toplist.php", query: [.init(name: "tl", value: String(top)),
                                                                                       .init(name: "p", value: String(number - 1))])
            return try page(EHentaiParser.list(await html(url), toplist: true))
        }
        guard ["latest", "popular", "watched"].contains(listing.id) else { throw AidokuRunner.SourceError.unimplemented }
        if number == 1 { setPreference("cursor_\(listing.id)", nil) }
        var query: [URLQueryItem] = []
        if let language {
            query += [.init(name: "advsearch", value: "1"), .init(name: "f_apply", value: "Apply Filter"),
                      .init(name: "f_search", value: "language:\(language)$")]
        }
        if number > 1, let cursor = preference("cursor_\(listing.id)"), !cursor.isEmpty { query.append(.init(name: "next", value: cursor)) }
        let path = listing.id == "latest" ? "/" : "/\(listing.id)"
        let string = try url(base: base, path: path, query: listing.id == "popular" ? [] : query)
        let parsed = try EHentaiParser.list(await html(string))
        if let gid = parsed.lastGID { setPreference("cursor_\(listing.id)", gid) }
        return page(parsed)
    }

    func getSearchMangaList(query original: String?, page number: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        guard number > 0 else { throw URLError(.badURL) }
        let raw = (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcut = EHentaiParser.galleryIDToken(raw).map { "\(base)/g/\($0.gid)/\($0.token)/" }
            ?? EHentaiParser.quickIDToken(raw).map { "\(base)/g/\($0.gid)/\($0.token)/" }
        if let shortcut {
            let item = try EHentaiParser.detail(await html(shortcut), url: shortcut)
            return AidokuRunner.MangaPageResult(entries: [item.manga(sourceKey: sourceKey, japanese: japanese)], hasNextPage: false)
        }
        var query = original ?? "", sort = 0
        var parameters = [URLQueryItem(name: "f_apply", value: "Apply Filter")]
        let categoryFlags = [("f_doujinshi", 2), ("f_manga", 4), ("f_artistcg", 8), ("f_gamecg", 16), ("f_western", 512),
                             ("f_non-h", 256), ("f_imageset", 32), ("f_cosplay", 64), ("f_asianporn", 128), ("f_misc", 1)]
        var categoryMask = 0, categoriesFiltered = false, rating = 0
        var minimumPages: String?, maximumPages: String?, tags: String?, disableCustom: [String] = []
        for filter in filters {
            switch filter {
            case .sort(let value): sort = Int(value.index)
            case let .multiselect(id, included, _):
                if id == "categories" {
                    categoriesFiltered = true
                    for included in included { categoryMask |= categoryFlags.first { $0.0 == included }?.1 ?? 0 }
                } else if id == "disable_custom" { disableCustom = included }
            case let .select(id, value):
                if id == "min_rating" { rating = Int(value) ?? 0 }
                else if id == "genre", !value.isEmpty { query += " \"\(value)$\"" }
                else if id == "expunged", value == "on" { parameters.append(.init(name: "f_sh", value: "on")) }
            case let .text(id, value) where !value.isEmpty:
                switch id {
                case "tags": tags = value
                case "author": query += " ~artist:\"\(value)$\" ~group:\"\(value)$\""
                case "artist", "group": query += " \(id):\"\(value)$\""
                case "min_pages": minimumPages = value
                case "max_pages": maximumPages = value
                default: break
                }
            default: break
            }
        }
        if let tags {
            for tag in tags.split(separator: ",") {
                let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if tag.isEmpty { continue }
                let prefix = tag.hasPrefix("-") ? "-" : tag.hasPrefix("~") ? "~" : ""
                let name = prefix.isEmpty ? tag : String(tag.drop(while: { String($0) == prefix })).trimmingCharacters(in: .whitespacesAndNewlines)
                query += " \(prefix)\"\(name)$\""
            }
        }
        let toplistQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language { query += " language:\"\(language)$\"" }
        if !query.isEmpty { parameters.append(.init(name: "f_search", value: query.trimmingCharacters(in: .whitespacesAndNewlines))) }
        if categoriesFiltered && categoryMask != 1023 {
            parameters += categoryFlags.map { .init(name: $0.0, value: categoryMask & $0.1 != 0 ? "1" : "0") }
        }
        if rating > 0 { parameters += [.init(name: "f_sr", value: "on"), .init(name: "f_srdd", value: String(rating))] }
        parameters += disableCustom.filter { ["f_sfl", "f_sfu", "f_sft"].contains($0) }.map { .init(name: $0, value: "on") }
        if let minimumPages { parameters += [.init(name: "f_sp", value: "on"), .init(name: "f_spf", value: minimumPages)] }
        if let maximumPages { parameters += [.init(name: "f_sp", value: "on"), .init(name: "f_spt", value: maximumPages)] }
        let top = [2: 15, 3: 13, 4: 12, 5: 11][sort]
        if let top {
            var query = [URLQueryItem(name: "tl", value: String(top)), .init(name: "p", value: String(number - 1))]
            if !toplistQuery.isEmpty { query += [.init(name: "f_apply", value: "Apply Filter"), .init(name: "f_search", value: toplistQuery)] }
            let string = try url(base: "https://e-hentai.org", path: "/toplist.php", query: query)
            return try page(EHentaiParser.list(await html(string), toplist: true))
        }
        if number == 1 { setPreference("cursor_search", nil) }
        else if let cursor = preference("cursor_search"), !cursor.isEmpty { parameters.append(.init(name: "next", value: cursor)) }
        if sort == 1 { parameters.insert(contentsOf: [.init(name: "f_srdd", value: "5"), .init(name: "f_sr", value: "on")], at: 0) }
        let string = try url(base: base, path: "/", query: parameters)
        let parsed = try EHentaiParser.list(await html(string))
        if let gid = parsed.lastGID { setPreference("cursor_search", gid) }
        return page(parsed)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        guard EHentaiParser.galleryIDToken(manga.key) != nil else { throw Failure.invalidGallery }
        let string = try rewrite(manga.key)
        let gallery = try EHentaiParser.detail(await html(string), url: string)
        var result = needsDetails ? manga.copy(from: gallery.manga(sourceKey: sourceKey, japanese: japanese)) : manga
        if needsChapters {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            result.chapters = [AidokuRunner.Chapter(key: manga.key, title: gallery.item.category.isEmpty ? nil : gallery.item.category,
                                       chapterNumber: 1, dateUploaded: formatter.date(from: gallery.posted),
                                       scanlators: gallery.language.isEmpty ? nil : [gallery.language + (gallery.translated ? " (Translated)" : "")],
                                       url: URL(string: string))]
        }
        return result
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        guard EHentaiParser.galleryIDToken(chapter.key) != nil else { throw Failure.invalidGallery }
        var next: String? = try rewrite(chapter.key), visited = Set<String>(), viewers: [String] = []
        while let string = next {
            try Task.checkCancellation()
            guard visited.count < 1000, visited.insert(string).inserted else { throw Failure.resourceLimit }
            let document = try await html(string)
            for link in try document.select("#gdt a").array() { viewers.append(try rewrite(link.attr("abs:href"))) }
            guard viewers.count <= 100_000 else { throw Failure.resourceLimit }
            let candidate = try document.select("a[onclick='return false']").array().first { try $0.text() == ">" }
            next = try candidate.map { try rewrite($0.attr("abs:href")) }
        }
        guard let first = viewers.first, let firstURL = URLComponents(string: first) else { throw Failure.noPages }
        var components = firstURL; components.fragment = nil
        let firstDoc: Document?
        do { firstDoc = try await html(components.string ?? first) }
        catch { try Task.checkCancellation(); firstDoc = nil }
        let mpv = try firstDoc.flatMap { try EHentaiParser.mpv($0) }
        let showkey = mpv == nil ? try firstDoc.flatMap { try EHentaiParser.showkey($0) } ?? "" : ""
        let mpvGID = components.path.split(separator: "/").dropLast().last.map(String.init) ?? ""
        return viewers.enumerated().map { index, viewer in
            var context: AidokuRunner.PageContext = ["viewer_url": viewer]
            if let mpv {
                context["mode"] = "mpv"; context["mpvkey"] = mpv.key; context["gid"] = mpvGID; context["page"] = String(index + 1)
                if index < mpv.imageKeys.count { context["imgkey"] = mpv.imageKeys[index] }
            } else {
                context["mode"] = "showpage"; context["showkey"] = showkey
                if let parsed = EHentaiParser.viewer(viewer) {
                    context["imgkey"] = parsed.imgkey; context["gid"] = parsed.gid; context["page"] = String(parsed.page)
                }
            }
            return AidokuRunner.Page(content: .url(url: URL(string: viewer)!, context: context))
        }
    }

    private func apiImage(_ context: AidokuRunner.PageContext, nl: String? = nil) async throws -> (url: String, nl: String?)? {
        guard let gid = context["gid"].flatMap(UInt64.init), let imgkey = context["imgkey"], !imgkey.isEmpty else { return nil }
        let mpv = context["mode"] == "mpv"
        let keyName = mpv ? "mpvkey" : "showkey"
        guard let key = context[keyName], !key.isEmpty else { return nil }
        var request = try request("https://api.e-hentai.org/api.php")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": mpv ? "imagedispatch" : "showpage", "gid": gid,
                                                                       "imgkey": imgkey, "page": Int(context["page"] ?? "1") ?? 1,
                                                                       keyName: key, "nl": nl ?? ""])
        do {
            guard let object = try JSONSerialization.jsonObject(with: await data(request)) as? [String: Any] else { return nil }
            if mpv { return (object["i"] as? String).map { ($0, object["s"] as? String) } }
            guard let image = object["i3"] as? String, let src = try SwiftSoup.parseBodyFragment(image).select("img").first()?.attr("src") else { return nil }
            let nl = (object["i6"] as? String).flatMap { EHentaiParser.between($0, start: "nl('", end: "'") }
            return (src, nl)
        } catch { try Task.checkCancellation(); return nil }
    }
    func getImageRequest(url: String, context: AidokuRunner.PageContext?) async throws -> URLRequest {
        if let context {
            let viewer = try rewrite(context["viewer_url"] ?? url)
            if let image = try await apiImage(context) {
                if !image.url.contains("509") { return try request(image.url) }
                if let nl = image.nl, let retry = try await apiImage(context, nl: nl) { return try request(retry.url) }
            }
            do {
                let document = try await html(viewer)
                let image = try EHentaiParser.attribute(document, "#img", "src")
                if !image.isEmpty && !image.contains("509") { return try request(image) }
                if let nl = try EHentaiParser.nl(document), var components = URLComponents(string: viewer) {
                    components.queryItems = (components.queryItems ?? []) + [.init(name: "nl", value: nl)]
                    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                    let retry = try await html(components.string ?? viewer)
                    let image = try EHentaiParser.attribute(retry, "#img", "src")
                    if !image.isEmpty { return try request(image) }
                }
            } catch { try Task.checkCancellation() }
            throw Failure.invalidImage
        }
        return try request(url)
    }
    func handleDeepLink(url: String) throws -> AidokuRunner.DeepLinkResult? {
        guard EHentaiParser.galleryIDToken(url) != nil else { return nil }
        return AidokuRunner.DeepLinkResult(mangaKey: EHentaiParser.normalize(try rewrite(url)))
    }

    func getHome() async throws -> AidokuRunner.Home {
        try Task.checkCancellation()
        let identifiers = ["top_yesterday", "top_month", "top_year"] + (loggedIn ? ["watched"] : []) + ["popular", "latest"]
        let titles = ["top_yesterday": "Top Yesterday", "top_month": "Top Month", "top_year": "Top Year", "watched": "Watched",
                      "popular": "Popular", "latest": "Latest"]
        var requests: [(String, String)] = []
        for identifier in identifiers {
            let string: String
            if let top = ["top_yesterday": 15, "top_month": 13, "top_year": 12][identifier] {
                string = "https://e-hentai.org/toplist.php?tl=\(top)&p=0"
            } else {
                var query: [URLQueryItem] = []
                if let language, identifier != "popular" {
                    query = [.init(name: "advsearch", value: "1"), .init(name: "f_apply", value: "Apply Filter"),
                             .init(name: "f_search", value: "language:\(language)$")]
                }
                string = try url(base: base, path: identifier == "latest" ? "/" : "/\(identifier)", query: query)
            }
            requests.append((identifier, string))
        }
        let subscription = AidokuRunner.PartialResultSubscription.id
        var components = identifiers.map { identifier in
            let value: AidokuRunner.HomeComponent.Value = identifier == "top_yesterday" ? .bigScroller(entries: [])
                : identifier.hasPrefix("top_") ? .mangaList(entries: []) : .scroller(entries: [])
            return AidokuRunner.HomeComponent(title: titles[identifier], value: value)
        }
        await partialHomePublisher?.send(AidokuRunner.Home(components: components), to: subscription)
        let fetch = fetch
        let transport = try requests.map { ($0.0, try request($0.1)) }
        try await withThrowingTaskGroup(of: (String, Data?, URLResponse?).self) { group in
            for (identifier, request) in transport {
                group.addTask {
                    do {
                        let (data, response) = try await fetch(request)
                        try Task.checkCancellation()
                        guard data.count <= 20_000_000, let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else { return (identifier, nil, response) }
                        return (identifier, data, response)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch { try Task.checkCancellation(); return (identifier, nil, nil) }
                }
            }
            for try await (identifier, data, response) in group {
                try Task.checkCancellation()
                if let response { refreshIgneous(response) }
                guard let data, let index = identifiers.firstIndex(of: identifier),
                      let string = requests.first(where: { $0.0 == identifier })?.1 else { continue }
                let top = identifier.hasPrefix("top_")
                let parsed: (items: [EHGalleryItem], hasNext: Bool, lastGID: String?)
                do {
                    parsed = try EHentaiParser.list(document(data, url: string), toplist: top,
                                                  limit: identifier == "top_yesterday" ? 10 : top ? 25 : nil)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    continue
                }
                guard !parsed.items.isEmpty else { continue }
                let mangas = parsed.items.filter { !$0.blocked(by: blocklist) }.map {
                    $0.manga(sourceKey: sourceKey, japanese: japanese, basic: !top)
                }
                let title = titles[identifier] ?? identifier
                let listing = AidokuRunner.Listing(id: identifier, name: title)
                let links = mangas.map { AidokuRunner.HomeComponent.Value.Link(title: $0.title, imageUrl: $0.cover, value: .manga($0)) }
                let value: AidokuRunner.HomeComponent.Value = identifier == "top_yesterday" ? .bigScroller(entries: mangas, autoScrollInterval: 6)
                    : top ? .mangaList(ranking: true, pageSize: 5, entries: links, listing: listing) : .scroller(entries: links, listing: listing)
                components[index] = AidokuRunner.HomeComponent(title: title, value: value)
                await partialHomePublisher?.send(AidokuRunner.Home(components: components), to: subscription)
            }
        }
        return AidokuRunner.Home(components: components)
    }
}
