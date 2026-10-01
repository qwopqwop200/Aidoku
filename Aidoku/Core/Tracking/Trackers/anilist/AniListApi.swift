//
//  AniListApi.swift
//  Aidoku
//
//  Created by Koding Dev on 19/7/2022.
//

import UIKit

actor AniListApi {
    private let encoder = JSONEncoder()

    nonisolated let oauth: OAuthClient
    private let session: URLSession
    private var scoreType: (generation: UUID, value: String)?

    init(
        // Registered under Skitty's AniList account
        oauth: OAuthClient = OAuthClient(id: "anilist", clientId: "8912", baseUrl: "https://anilist.co/api/v2/oauth"),
        session: URLSession = .shared
    ) {
        self.oauth = oauth
        self.session = session
    }
}

// MARK: - Data
extension AniListApi {
    func search(query: String, nsfw: Bool = true) async throws -> ALPage? {
        let response: GraphQLResponse<AniListSearchResponse> = try await request(
            GraphQLVariableQuery(
                query: nsfw ? AniListQueries.searchQueryNsfw : AniListQueries.searchQuery,
                variables: AniListSearchVars(search: query)
            )
        )
        return response.data?.Page
    }

    func getMedia(id: Int) async -> Media? {
        let response: GraphQLResponse<AniListMediaStatusResponse>? = try? await request(
            GraphQLVariableQuery(query: AniListQueries.mediaQuery, variables: AniListMediaStatusVars(id: id))
        )
        return response?.data?.Media
    }

    func getMediaState(id: Int) async -> Media? {
        let response: GraphQLResponse<AniListMediaStatusResponse>? = try? await request(
            GraphQLVariableQuery(query: AniListQueries.mediaStatusQuery, variables: AniListMediaStatusVars(id: id))
        )
        return response?.data?.Media
    }

    @discardableResult
    func update(media: Int, update: TrackUpdate) async throws -> GraphQLResponse<AniListUpdateResponse> {
        try await request(
            GraphQLVariableQuery(
                query: AniListQueries.updateMediaQuery,
                variables: AniListUpdateMediaVars(
                    id: media,
                    status: update.status != nil ? getStatusString(status: update.status!) : nil,
                    progress: update.lastReadChapter.flatMap { Int(exactly: $0.rounded(.towardZero)) },
                    volumes: update.lastReadVolume,
                    score: update.score,
                    startedAt: encodeDate(update.startReadDate),
                    completedAt: encodeDate(update.finishReadDate)
                )
            )
        )
    }

    func getUser() async -> User? {
        let response: GraphQLResponse<AniListViewerResponse>? = try? await request(
            GraphQLQuery(query: AniListQueries.viewerQuery)
        )
        return response?.data?.Viewer
    }

    private func request<T: Codable & Sendable, D: Encodable>(_ data: D) async throws -> GraphQLResponse<T> {
        let url = URL(string: "https://graphql.anilist.co")!
        var request = await oauth.authorizedRequest(for: url)

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(data)

        guard let issued = OAuthClient.generation(for: request), await oauth.accountGeneration == issued else {
            throw CancellationError()
        }
        let response: GraphQLResponse<T> = try await session.object(from: request)
        guard !Task.isCancelled, await oauth.accountGeneration == issued else { throw CancellationError() }
        // check if token is invalid
        if response.errors?.contains(where: { $0.status == 400 }) ?? false {
            // don't show the relogin alert if we're not logged in in the first place
            if TrackerManager.anilist.isLoggedIn {
                await oauth.showReloginAlert(trackerName: "AniList")
            }
        }

        if response.errors?.isEmpty == false { throw URLError(.badServerResponse) }
        return response
    }

    func getStoreType() async -> String {
        if await oauth.tokens == nil { await oauth.loadTokens() }
        let generation = await oauth.accountGeneration
        if let scoreType, scoreType.generation == generation {
            return scoreType.value
        }
        let user = await getUser()
        guard !Task.isCancelled, await oauth.accountGeneration == generation else { return "POINT_10" }
        if let value = user?.mediaListOptions?.scoreFormat {
            scoreType = (generation, value)
            return value
        }
        return "POINT_10"
    }
}

private extension AniListApi {
    func encodeDate(_ value: Date?) -> AniListDate? {
        if let date = value {
            if date == Date(timeIntervalSince1970: 0) {
                return AniListDate(year: 0, month: 0, day: 0)
            }
            let components = Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: date)
            return AniListDate(year: components.year, month: components.month, day: components.day)
        }
        return nil
    }

    func getStatusString(status: TrackStatus) -> String? {
        switch status {
            case .reading: return "CURRENT"
            case .planning: return "PLANNING"
            case .completed: return "COMPLETED"
            case .dropped: return "DROPPED"
            case .paused: return "PAUSED"
            case .rereading: return "REPEATING"
            default: return nil
        }
    }
}
