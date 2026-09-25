//
//  ShikimoriApi.swift
//  Aidoku
//
//  Created by Vova Lapskiy on 02.11.2024.
//

import Foundation

actor ShikimoriApi {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let userAgent = "Aidoku"

    // Registered under Skitty's Shikimori account
    nonisolated let oauth = OAuthClient(
        id: "shikimori",
        clientId: "0pRPZsB87w9mp0gQe1HZbSiGt7FfVzJohPGhJKjayW4",
        clientSecret: "42vg9aoyPBnrvFoH1ey2GxbO24eVufOe8D0B6P756e8",
        baseUrl: "https://shikimori.io"
    )
}

extension ShikimoriApi {
    func getAccessToken(authCode: String) async -> OAuthResponse? {
        guard let url = URL(string: oauth.baseUrl + "/oauth/token") else { return nil }
        let boundary = "--" + String(UUID().hashValue)
        var request = URLRequest(url: url)

        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = multipart(params: [
            "grant_type": "authorization_code",
            "client_id": oauth.clientId,
            "client_secret": oauth.clientSecret!,
            "redirect_uri": "aidoku://shikimori-auth",
            "scope": "users_rate",
            "code": authCode
        ], boundary: boundary)
        let issued = await oauth.beginAuthentication()
        let response: OAuthResponse? = try? await URLSession.shared.object(from: request)
        return await oauth.commitAuthentication(response, generation: issued)
    }

    func refreshAccessToken(replacingAuthorization: String? = nil) async -> OAuthResponse? {
        guard let refreshToken = await oauth.tokens?.refreshToken else { return nil }

        guard let url = URL(string: oauth.baseUrl + "/oauth/token") else { return nil }
        var request = URLRequest(url: url)
        let boundary = "--" + String(UUID().hashValue)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpMethod = "POST"
        request.httpBody = multipart(params: [
            "client_id": oauth.clientId,
            "client_secret": oauth.clientSecret!,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ], boundary: boundary)
        let refreshRequest = request
        return await oauth.refreshTokens(replacingAuthorization: replacingAuthorization) {
            try? await URLSession.shared.object(from: refreshRequest)
        }
    }

    // MARK: API Methods - Data

    func search(query: String, censored: Bool = false) async -> GraphQLResponse<ShikimoriMangas>? {
        await requestGraphQL(
            GraphQLVariableQuery(
                query: ShikimoriQueries.searchQuery,
                variables: ShikimoriSearchVars(
                    search: query,
                    censored: censored
                )
            )
        )
    }

    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async -> String? {
        guard let baseURL = URL(string: oauth.baseUrl) else { return nil }
        let issued = OAuthClient.generation(for: await authorizedRequest(for: baseURL))
        var query: [String: String] = [:]
        query["user_rate[user_id]"] = await getUser()
        query["user_rate[target_id]"] = trackId
        query["user_rate[target_type]"] = "Manga"
        query["user_rate[status]"] = highestChapterRead != nil ? "watching" : "planned"
        if let highestChapterRead {
            query["user_rate[chapters]"] = String(highestChapterRead)
        }

        guard var url = URL(string: oauth.baseUrl + "/api/v2/user_rates") else { return nil }
        url.queryParameters = query
        var request = await authorizedRequest(for: url)
        request.httpMethod = "POST"
        guard OAuthClient.generation(for: request) == issued else { return nil }

        guard
            let data = try? await requestData(urlRequest: request),
            let rate = try? decoder.decode(ShikimoriUserRate.self, from: data)
        else { return nil }

        return String(rate.id)
    }

    func update(trackId: String, update: TrackUpdate) async throws {
        var query: [String: String] = [:]
        if let status = update.status {
            query["user_rate[status]"] = getStatusFromTrack(status: status)
        }
        if let score = update.score {
            query["user_rate[score]"] = String(score)
        }
        if let lastReadChapter = update.lastReadChapter {
            query["user_rate[chapters]"] = String(lastReadChapter)
        }
        if let lastReadVolume = update.lastReadVolume {
            query["user_rate[volumes]"] = String(lastReadVolume)
        }

        guard var url = URL(string: oauth.baseUrl + "/api/v2/user_rates/\(trackId)") else { return }
        url.queryParameters = query
        var request = await authorizedRequest(for: url)
        request.httpMethod = "PATCH"

        try await requestData(urlRequest: request)
    }

    func getState(_ trackId: String) async -> TrackState {
        guard
            let url = URL(string: oauth.baseUrl + "/api/v2/user_rates/\(trackId)"),
            let data = try? await requestData(urlRequest: authorizedRequest(for: url)),
            let rate = try? decoder.decode(ShikimoriUserRate.self, from: data)
        else {
            return TrackState()
        }
        return makeState(from: rate)
    }

    func makeState(from rate: ShikimoriUserRate) -> TrackState {
        TrackState(
            score: rate.score,
            status: getStatusFromString(status: rate.status),
            lastReadChapter: Float(rate.chapters),
            lastReadVolume: rate.volumes
        )
    }

    func getMangaIdByRate(trackId: String) async -> String? {
        guard
            let url = URL(string: oauth.baseUrl + "/api/v2/user_rates/\(trackId)"),
            let data = try? await requestData(urlRequest: authorizedRequest(for: url)),
            let rate = try? decoder.decode(ShikimoriUserRate.self, from: data)
        else {
            return nil
        }
        return String(rate.targetId)
    }
}

private extension ShikimoriApi {
    func multipart(params: [String: String], boundary: String) -> Data? {
        var body = ""
        params.forEach {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"\($0.key)\"\r\n"
            body += "\r\n"
            body += $0.value
            body += "\r\n"
        }
        body += "--\(boundary)--"
        return body.data(using: .utf8)
    }

    func getStatusFromTrack(status: TrackStatus) -> String {
        switch status {
            case .completed: return "completed"
            case .dropped: return "dropped"
            case .paused: return "on_hold"
            case .planning: return "planned"
            case .reading: return "watching"
            case .rereading: return "rewatching"
            default: return ""
        }
    }

    func getStatusFromString(status: String?) -> TrackStatus {
        switch status {
            case "completed": return .completed
            case "dropped": return .dropped
            case "on_hold": return .paused
            case "planned": return .planning
            case "watching": return .reading
            case "rewatching": return .rereading
            case nil: return .none
            default: return .planning
        }
    }

    func getUser() async -> String? {
        if let cached = await oauth.cachedUserID() { return cached }
        guard let url = URL(string: oauth.baseUrl + "/api/users/whoami") else { return nil }
        let request = await authorizedRequest(for: url)
        guard let issued = OAuthClient.generation(for: request),
              let data = try? await requestData(urlRequest: request),
              let response = try? decoder.decode(ShikimoriUser.self, from: data) else { return nil }
        return await oauth.cacheUserID(String(response.userId), generation: issued)
    }

    private func requestGraphQL<T: Codable, D: Encodable>(_ data: D) async -> GraphQLResponse<T>? {
        guard let url = URL(string: oauth.baseUrl + "/api/graphql") else { return nil }
        var request = URLRequest(url: url)

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = try? encoder.encode(data)

        return try? await URLSession.shared.object(from: request)
    }

    func authorizedRequest(for url: URL) async -> URLRequest {
        await oauth.authorizedRequest(for: url, additionalHeaders: ["User-Agent": userAgent])
    }

    @discardableResult
    // Internal to allow the original-request account fence to be exercised directly.
    internal func requestData(urlRequest: URLRequest) async throws -> Data {
        let currentGeneration = await oauth.accountGeneration
        let issued = OAuthClient.generation(for: urlRequest) ?? currentGeneration
        guard currentGeneration == issued else { throw CancellationError() }
        var (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard await oauth.accountGeneration == issued else { throw CancellationError() }
        let statusCode = (response as? HTTPURLResponse)?.statusCode

        if await oauth.tokens == nil {
            await oauth.loadTokens()
        }

        let tokenExpired = await oauth.tokens?.expired == true
        guard await oauth.accountGeneration == issued else { throw CancellationError() }

        let succeeded = statusCode.map { (200..<300).contains($0) } ?? false
        // A successful mutation must not be repeated due to local expiry.
        if statusCode == 401 || (tokenExpired && !succeeded) {
            // ensure we have a refresh token, otherwise we need to fully re-auth
            let reloginNeeded = await oauth.checkIfReloginNeeded(trackerName: "Shikimori")
            guard !reloginNeeded else {
                throw URLError(.userAuthenticationRequired)
            }

            // refresh access token
            if await refreshAccessToken(replacingAuthorization: urlRequest.value(forHTTPHeaderField: "Authorization")) != nil {
                // try request again with refreshed token
                let retryUrl = URL(string: oauth.baseUrl + "/oauth/token")!
                let newRequest = await authorizedRequest(for: retryUrl)
                if let newAuthorization = newRequest.value(forHTTPHeaderField: "Authorization") {
                    guard await oauth.accountGeneration == issued else { throw CancellationError() }
                    var retryRequest = urlRequest
                    retryRequest.setValue(newAuthorization, forHTTPHeaderField: "Authorization")
                    retryRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    (data, response) = try await URLSession.shared.data(for: retryRequest)
                }
            }
        }

        guard await oauth.accountGeneration == issued else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
