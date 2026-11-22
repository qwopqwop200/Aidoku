//
//  SourceActor.swift
//  Aidoku
//
//  Created by Skitty on 2/21/22.
//

import Foundation

// wasm imports block on semaphores (net requests), so run on a dedicated queue instead of the cooperative pool;
// blocked pool threads could starve the Cloudflare handler task that has to signal them
final class SourceExecutor: @unchecked Sendable, SerialExecutor {
    private let queue = DispatchQueue(label: "Aidoku.LegacySource")

    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

actor SourceActor {

    unowned var source: Source
    private let executor = SourceExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    enum SourceError: Error {
        case missingValue
    }

    init(source: Source) {
        self.source = source
    }

    func initialize() throws {
        try source.globalStore.vm.findFunction(name: "initialize").call()
    }

    func getMangaList(filters: [FilterBase], page: Int = 1) -> MangaPageResult {
        let filterDescriptor = source.globalStore.storeStdValue(filters)

        let (std, req) = (source.globalStore.stdDescriptorPointer, source.globalStore.requestsPointer)
        let pageResultDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_manga_list")
            .call(filterDescriptor, Int32(page))) ?? source.globalStore.removeValues(after: std, requests: req)

        let result = source.globalStore.readStdValue(pageResultDescriptor) as? MangaPageResult ?? MangaPageResult(manga: [], hasNextPage: false)
        source.globalStore.removeStdValue(pageResultDescriptor)
        source.globalStore.removeStdValue(filterDescriptor)

        return result
    }

    func getMangaListing(listing: Listing, page: Int = 1) -> MangaPageResult {
        let listingDescriptor = source.globalStore.storeStdValue(listing)

        let (std, req) = (source.globalStore.stdDescriptorPointer, source.globalStore.requestsPointer)
        let pageResultDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_manga_listing")
            .call(listingDescriptor, Int32(page))) ?? source.globalStore.removeValues(after: std, requests: req)

        let result = source.globalStore.readStdValue(pageResultDescriptor) as? MangaPageResult ?? MangaPageResult(manga: [], hasNextPage: false)
        source.globalStore.removeStdValue(pageResultDescriptor)
        source.globalStore.removeStdValue(listingDescriptor)

        return result
    }

    func getMangaDetails(manga: Manga) throws -> Manga {
        let mangaDescriptor = source.globalStore.storeStdValue(manga)

        let (std, req) = (source.globalStore.stdDescriptorPointer, source.globalStore.requestsPointer)
        let resultMangaDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_manga_details")
            .call(mangaDescriptor)) ?? source.globalStore.removeValues(after: std, requests: req)

        let manga = source.globalStore.readStdValue(resultMangaDescriptor) as? Manga
        source.globalStore.removeStdValue(resultMangaDescriptor)
        source.globalStore.removeStdValue(mangaDescriptor)

        guard let manga = manga else { throw SourceError.missingValue }

        return manga
    }

    func getChapterList(manga: Manga) -> [Chapter] {
        let mangaDescriptor = source.globalStore.storeStdValue(manga)

        source.globalStore.chapterCounter = 0
        source.globalStore.currentManga = manga.id

        let (std, req) = (source.globalStore.stdDescriptorPointer, source.globalStore.requestsPointer)
        let chapterListDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_chapter_list").call(mangaDescriptor))
            ?? source.globalStore.removeValues(after: std, requests: req)

        source.globalStore.chapterCounter = 0

        let chapters = source.globalStore.readStdValue(chapterListDescriptor) as? [Chapter] ?? []
        source.globalStore.removeStdValue(chapterListDescriptor)
        source.globalStore.removeStdValue(mangaDescriptor)

        for i in 0..<chapters.count {
            chapters[i].mangaId = manga.id
        }

        return chapters
    }

    func getPageList(chapter: Chapter) -> [Page] {
        let chapterDescriptor = source.globalStore.storeStdValue(chapter)

        let (std, req) = (source.globalStore.stdDescriptorPointer, source.globalStore.requestsPointer)
        let pageListDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_page_list")
            .call(chapterDescriptor)) ?? source.globalStore.removeValues(after: std, requests: req)

        var pages = source.globalStore.readStdValue(pageListDescriptor) as? [Page] ?? []
        source.globalStore.removeStdValue(pageListDescriptor)
        source.globalStore.removeStdValue(chapterDescriptor)

        for i in 0..<pages.count {
            pages[i].chapterId = chapter.id
            pages[i].language = chapter.lang.isEmpty ? source.languages.first?.code : chapter.lang
        }

        return pages
    }

    func getImageRequest(url: String) async throws -> WasmRequestObject {
        source.globalStore.requestsPointer += 1
        var request = WasmRequestObject(id: source.globalStore.requestsPointer)
        guard !url.isEmpty else { return request }

        request.URL = url

        // add cloudflare headers
        request.headers["User-Agent"] = await UserAgentProvider.shared.getUserAgent()
        if let url = URL(string: url),
           let cookies = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.allCookies(for: url) ?? [])["Cookie"] {
            request.headers["Cookie"] = cookies
        }
        source.globalStore.requests[request.id] = request

        try? source.globalStore.vm.findFunction(name: "modify_image_request").call(Int32(request.id))

        guard let request = source.globalStore.requests[request.id] else { throw SourceError.missingValue }

        source.globalStore.requests.removeValue(forKey: request.id)

        return request
    }

    func handleUrl(url: String) throws -> DeepLink {
        let urlDescriptor = source.globalStore.storeStdValue(url)

        let (std, req) = (source.globalStore.stdDescriptorPointer, source.globalStore.requestsPointer)
        let deepLinkDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "handle_url").call(urlDescriptor))
            ?? source.globalStore.removeValues(after: std, requests: req)

        let deepLink = source.globalStore.readStdValue(deepLinkDescriptor) as? DeepLink
        source.globalStore.removeStdValue(deepLinkDescriptor)
        source.globalStore.removeStdValue(urlDescriptor)

        guard let deepLink = deepLink else { throw SourceError.missingValue }

        if let manga = deepLink.manga {
            deepLink.chapter?.mangaId = manga.id
        }

        return deepLink
    }

    func handleNotification(notification: String) {
        let notificationDescriptor = source.globalStore.storeStdValue(notification)

        try? source.globalStore.vm.findFunction(name: "handle_notification").call(notificationDescriptor)

        source.globalStore.removeStdValue(notificationDescriptor)
    }
}
