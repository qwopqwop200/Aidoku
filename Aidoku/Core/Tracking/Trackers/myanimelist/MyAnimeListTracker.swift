//
//  MyAnimeListTracker.swift
//  Aidoku
//
//  Created by Skitty on 6/16/22.
//

import AidokuRunner
import AuthenticationServices
import Foundation

/// MyAnimeList tracker for Aidoku.
final class MyAnimeListTracker: OAuthTracker {
    let id = "myanimelist"
    let name = "MyAnimeList"
    let icon = PlatformImage(named: "mal")

    let api: MyAnimeListApi

    init(api: MyAnimeListApi = MyAnimeListApi()) {
        self.api = api
    }

    let callbackHost = "myanimelist-auth"
    var oauthClient: OAuthClient { api.oauth }

    func getTrackerInfo() -> TrackerInfo {
        .init(supportedStatuses: TrackStatus.defaultStatuses, scoreType: .tenPoint)
    }

    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? {
        guard let id = Int(trackId) else {
            throw MyAnimeListTrackerError.invalidId
        }
        // set status to reading if status doesn't already exist
        let manga = try await api.getMangaWithStatus(id: id)
        if manga.myListStatus == nil {
            try await api.updateMangaStatus(
                id: id,
                status: MyAnimeListMangaStatus(
                    numChaptersRead: highestChapterRead.flatMap { Int(exactly: floor($0)) },
                    startDate: earliestReadDate?.dateString(format: "yyyy-MM-dd"),
                    status: highestChapterRead != nil ? "reading" : "plan_to_read",
                )
            )
        }
        return nil
    }

    func update(trackId: String, update: TrackUpdate) async throws {
        guard let id = Int(trackId) else {
            throw MyAnimeListTrackerError.invalidId
        }
        let status = MyAnimeListMangaStatus(
            isRereading: update.status != nil ? update.status?.rawValue == TrackStatus.rereading.rawValue : nil,
            numVolumesRead: update.lastReadVolume,
            numChaptersRead: update.lastReadChapter.flatMap { Int(exactly: floor($0)) },
            startDate: update.startReadDate?.dateString(format: "yyyy-MM-dd"),
            finishDate: update.finishReadDate?.dateString(format: "yyyy-MM-dd"),
            status: update.status != nil ? getStatusString(status: update.status!) : nil,
            score: update.score
        )
        try await api.updateMangaStatus(id: id, status: status)
    }

    func getState(trackId: String) async throws -> TrackState {
        guard let id = Int(trackId) else {
            throw MyAnimeListTrackerError.invalidId
        }
        let manga = try await api.getMangaWithStatus(id: id)
        guard let status = manga.myListStatus else { return TrackState() }
        return TrackState(
            score: status.score,
            status: status.isRereading == true ? .rereading : getStatus(statusString: status.status ?? ""),
            lastReadChapter: status.numChaptersRead != nil ? Float(status.numChaptersRead!) : nil,
            lastReadVolume: status.numVolumesRead,
            totalChapters: manga.numChapters == 0 ? nil : manga.numChapters,
            totalVolumes: manga.numVolumes == 0 ? nil : manga.numVolumes,
            startReadDate: status.startDate?.date(format: "yyyy-MM-dd"),
            finishReadDate: status.finishDate?.date(format: "yyyy-MM-dd")
        )
    }

    func getUrl(trackId: String) -> URL? {
        URL(string: "https://myanimelist.net/manga/\(trackId)")
    }

    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] {
        try await search(title: manga.title, includeNsfw: includeNsfw)
    }

    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] {
        try await api.search(query: title, includeNsfw: includeNsfw).data.map { result in
            let manga = result.node
            return TrackSearchItem(
                id: String(manga.id),
                title: manga.title,
                coverUrl: manga.mainPicture?.large,
                description: manga.synopsis,
                status: getPublishingStatus(statusString: manga.status ?? ""),
                type: getMediaType(typeString: manga.mediaType ?? ""),
                tracked: manga.myListStatus != nil
            )
        }
    }

    func handleAuthenticationCallback(url: URL) async {
        if let authCode = url.queryParameters?["code"] {
            _ = await api.oauth.getAccessToken(authCode: authCode)
        }
    }
}

private extension MyAnimeListTracker {
    func getStatus(statusString: String) -> TrackStatus? {
        switch statusString {
            case "reading": return .reading
            case "plan_to_read": return .planning
            case "completed": return .completed
            case "on_hold": return .paused
            case "dropped": return .dropped
            default: return nil
        }
    }

    func getStatusString(status: TrackStatus) -> String? {
        switch status.rawValue {
            case 1: return "reading"
            case 2: return "plan_to_read"
            case 3: return "completed"
            case 4: return "on_hold"
            case 5: return "dropped"
            default: return nil
        }
    }

    func getPublishingStatus(statusString: String) -> PublishingStatus {
        switch statusString {
            case "currently_publishing": return .ongoing
            case "finished": return .completed
            case "not_yet_published": return .notPublished
            default: return .ongoing
        }
    }

    func getMediaType(typeString: String) -> MediaType {
        switch typeString {
            case "unknown": return .unknown
            case "manga": return .manga
            case "novel": return .novel
            case "light_novel": return .novel
            case "manhwa": return .manhwa
            case "manhua": return .manhua
            case "oel": return .oel
            case "one_shot": return .oneShot
            case "doujinshi": return .manga
            default: return .manga
        }
    }
}

enum MyAnimeListTrackerError: Error {
    case invalidId
}
