//
//  SourceActor.swift
//  Aidoku
//
//  Created by Skitty on 2/21/22.
//

import Foundation
import Wasm3

actor SourceActor {

    unowned let source: Source
    private var initializationTask: Task<Void, Error>?

    enum SourceError: Error {
        case missingValue
    }

    init(source: Source) {
        self.source = source
    }

    func initialize() async throws {
        if let initializationTask { return try await initializationTask.value }
        let source = source // Keep the module alive while user-agent acquisition suspends.
        let task = Task {
            let userAgent = await UserAgentProvider.shared.getUserAgent()
            source.netModule.userAgent = userAgent
            let initialize: Function
            do {
                initialize = try source.globalStore.vm.findFunction(name: "initialize")
            } catch Wasm3Error.functionLookupFailed {
                return // Legacy sources may omit the optional initialization hook.
            } catch Wasm3Error.missingFunction {
                return
            }
            try initialize.call()
        }
        initializationTask = task
        try await task.value
    }

    func getMangaList(filters: [FilterBase], page: Int = 1) async throws -> MangaPageResult {
        try await initialize()
        let filterDescriptor = source.globalStore.storeStdValue(filters)

        let pageResultDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_manga_list")
            .call(filterDescriptor, Int32(page))) ?? -1

        let result = source.globalStore.readStdValue(pageResultDescriptor) as? MangaPageResult ?? MangaPageResult(manga: [], hasNextPage: false)
        source.globalStore.removeStdValue(pageResultDescriptor)
        source.globalStore.removeStdValue(filterDescriptor)

        return result
    }

    func getMangaListing(listing: Listing, page: Int = 1) async throws -> MangaPageResult {
        try await initialize()
        let listingDescriptor = source.globalStore.storeStdValue(listing)

        let pageResultDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_manga_listing")
            .call(listingDescriptor, Int32(page))) ?? -1

        let result = source.globalStore.readStdValue(pageResultDescriptor) as? MangaPageResult ?? MangaPageResult(manga: [], hasNextPage: false)
        source.globalStore.removeStdValue(pageResultDescriptor)
        source.globalStore.removeStdValue(listingDescriptor)

        return result
    }

    func getMangaDetails(manga: Manga) async throws -> Manga {
        try await initialize()
        let mangaDescriptor = source.globalStore.storeStdValue(manga)

        let resultMangaDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_manga_details")
            .call(mangaDescriptor)) ?? -1

        let manga = source.globalStore.readStdValue(resultMangaDescriptor) as? Manga
        source.globalStore.removeStdValue(resultMangaDescriptor)
        source.globalStore.removeStdValue(mangaDescriptor)

        guard let manga = manga else { throw SourceError.missingValue }

        return manga
    }

    func getChapterList(manga: Manga) async throws -> [Chapter] {
        try await initialize()
        let mangaDescriptor = source.globalStore.storeStdValue(manga)

        source.globalStore.chapterCounter = 0
        source.globalStore.currentManga = manga.id

        let chapterListDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_chapter_list").call(mangaDescriptor)) ?? -1

        source.globalStore.chapterCounter = 0

        let chapters = source.globalStore.readStdValue(chapterListDescriptor) as? [Chapter] ?? []
        source.globalStore.removeStdValue(chapterListDescriptor)
        source.globalStore.removeStdValue(mangaDescriptor)

        for i in 0..<chapters.count {
            chapters[i].mangaId = manga.id
        }

        return chapters
    }

    func getPageList(chapter: Chapter) async throws -> [Page] {
        try await initialize()
        let chapterDescriptor = source.globalStore.storeStdValue(chapter)

        let pageListDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "get_page_list")
            .call(chapterDescriptor)) ?? -1

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
        try await initialize()
        source.globalStore.requestsPointer += 1
        var request = WasmRequestObject(id: source.globalStore.requestsPointer)
        guard !url.isEmpty else { return request }

        request.URL = url

        // add cloudflare headers
        request.headers["User-Agent"] = await UserAgentProvider.shared.getUserAgent()
        if let url = URL(string: url),
           let cookies = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.requestCookies(for: url) ?? [])["Cookie"] {
            request.headers["Cookie"] = cookies
        }
        source.globalStore.requests[request.id] = request

        try? source.globalStore.vm.findFunction(name: "modify_image_request").call(Int32(request.id))

        guard let request = source.globalStore.requests[request.id] else { throw SourceError.missingValue }

        source.globalStore.requests.removeValue(forKey: request.id)

        return request
    }

    func handleUrl(url: String) async throws -> DeepLink {
        try await initialize()
        let urlDescriptor = source.globalStore.storeStdValue(url)

        let deepLinkDescriptor: Int32 = (try? source.globalStore.vm.findFunction(name: "handle_url").call(urlDescriptor)) ?? -1

        let deepLink = source.globalStore.readStdValue(deepLinkDescriptor) as? DeepLink
        source.globalStore.removeStdValue(deepLinkDescriptor)
        source.globalStore.removeStdValue(urlDescriptor)

        guard let deepLink = deepLink else { throw SourceError.missingValue }

        if let manga = deepLink.manga {
            deepLink.chapter?.mangaId = manga.id
        }

        return deepLink
    }

    func handleNotification(notification: String) async throws {
        try await initialize()
        let notificationDescriptor = source.globalStore.storeStdValue(notification)

        try? source.globalStore.vm.findFunction(name: "handle_notification").call(notificationDescriptor)

        source.globalStore.removeStdValue(notificationDescriptor)
    }
}
