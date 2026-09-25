//
//  OAuthClient.swift
//  Aidoku
//
//  Created by Koding Dev on 19/7/2022.
//

import CryptoKit
import UIKit

actor OAuthClient {
    let id: String
    let clientId: String
    let clientSecret: String?
    let baseUrl: String
    let challengeMethod: OAuthCodeChallengeMethod

    enum OAuthCodeChallengeMethod: String {
        case none
        case plain
        case s256 = "S256"
    }

    var codeVerifier = ""
    private(set) var tokens: OAuthResponse?
    private(set) var accountGeneration = UUID()
    private var refresh: (id: UUID, task: Task<OAuthResponse?, Never>)?
    private nonisolated static let generationProperty = "Aidoku.OAuth.accountGeneration"

    nonisolated static func generation(for request: URLRequest) -> UUID? {
        (URLProtocol.property(forKey: generationProperty, in: request) as? String).flatMap(UUID.init(uuidString:))
    }

    deinit { refresh?.task.cancel() }

    @discardableResult
    func beginAuthentication() -> UUID {
        accountGeneration = UUID()
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).user_id")
        refresh?.task.cancel()
        refresh = nil
        return accountGeneration
    }

    func commitAuthentication(_ response: OAuthResponse?, generation: UUID) -> OAuthResponse? {
        guard !Task.isCancelled, accountGeneration == generation, let response else { return nil }
        tokens = response
        saveTokens()
        UserDefaults.standard.set(response.accessToken, forKey: "Tracker.\(id).token")
        return response
    }

    /// Sharing survives cancellation of one search, but never an account change.
    func refreshTokens(replacingAuthorization: String?,
                       operation: @escaping @Sendable () async -> OAuthResponse?) async -> OAuthResponse? {
        guard !Task.isCancelled else { return nil }
        if tokens == nil { loadTokens() }
        let issued = accountGeneration
        let currentAuthorization = "\(tokens?.tokenType ?? "Bearer") \(tokens?.accessToken ?? "")"
        if let replacingAuthorization, replacingAuthorization != currentAuthorization { return tokens }
        if let refresh {
            let result = await refresh.task.value
            return !Task.isCancelled && accountGeneration == issued ? result : nil
        }
        let id = UUID()
        let task = Task { [weak self] () -> OAuthResponse? in
            let result = await operation()
            return await self?.finishRefresh(result, generation: issued, id: id)
        }
        refresh = (id, task)
        let result = await task.value
        return !Task.isCancelled && accountGeneration == issued ? result : nil
    }

    func cachedUserID() -> String? {
        UserDefaults.standard.string(forKey: "Tracker.\(id).user_id")
    }

    func cacheUserID(_ value: String, generation: UUID) -> String? {
        guard !Task.isCancelled, accountGeneration == generation else { return nil }
        UserDefaults.standard.set(value, forKey: "Tracker.\(id).user_id")
        return value
    }

    private func finishRefresh(_ result: OAuthResponse?, generation: UUID, id: UUID) -> OAuthResponse? {
        guard !Task.isCancelled, accountGeneration == generation else { return nil }
        if let result { tokens = result; saveTokens() }
        if refresh?.id == id { refresh = nil }
        return result
    }

    init(
        id: String,
        clientId: String,
        clientSecret: String? = nil,
        baseUrl: String,
        challengeMethod: OAuthCodeChallengeMethod = .plain
    ) {
        self.id = id
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.baseUrl = baseUrl
        self.challengeMethod = challengeMethod
    }

    func getAuthenticationUrl(
        responseType: String = "code",
        path: String = "/authorize",
        redirectUri: String? = nil,
        extraQueryItems: [String: String]? = nil
    ) -> URL? {
        guard let url = URL(string: baseUrl + path) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: responseType)
        ]
        if let redirectUri {
            queryItems.append(URLQueryItem(name: "redirect_uri", value: redirectUri))
        }
        if challengeMethod != .none {
            queryItems.append(URLQueryItem(name: "code_challenge", value: generatePkceChallenge(method: challengeMethod)))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: challengeMethod.rawValue))
        }
        if let extraQueryItems {
            for (key, value) in extraQueryItems {
                queryItems.append(URLQueryItem(name: key, value: value))
            }
        }
        components?.queryItems = queryItems
        return components?.url
    }
}

// MARK: - Tokens
extension OAuthClient {
    func getAccessToken(authCode: String, redirectUri: String? = nil) async -> OAuthResponse? {
        guard let url = URL(string: baseUrl + "/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var body = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": authCode
        ]
        if challengeMethod != .none {
            body["code_verifier"] = codeVerifier
        }
        if let redirectUri {
            body["redirect_uri"] = redirectUri
        }
        request.httpBody = body.percentEncoded()
        let issued = beginAuthentication()
        let response: OAuthResponse? = try? await URLSession.shared.object(from: request)
        return commitAuthentication(response, generation: issued)
    }

//    func refreshAccessToken(refreshToken: String) async -> OAuthResponse? {
//        guard let url = URL(string: baseUrl + "/token") else { return nil }
//        var request = URLRequest(url: url)
//        request.httpMethod = "POST"
//        request.httpBody = [
//            "grant_type": "refresh_token",
//            "refresh_token": refreshToken
//        ].percentEncoded()
//        tokens = try? await URLSession.shared.object(from: request)
//        return tokens
//    }

    func loadTokens() {
        let loaded: OAuthResponse
        if let data = UserDefaults.standard.data(forKey: "Tracker.\(id).oauth") {
            loaded = (try? JSONDecoder().decode(OAuthResponse.self, from: data)) ?? OAuthResponse()
        } else {
            loaded = OAuthResponse()
        }
        if tokens?.accessToken != loaded.accessToken || tokens?.refreshToken != loaded.refreshToken {
            beginAuthentication()
        }
        tokens = loaded
    }

    func saveTokens() {
        UserDefaults.standard.set(try? JSONEncoder().encode(tokens), forKey: "Tracker.\(id).oauth")
    }

    func setTokens(_ response: OAuthResponse?) {
        beginAuthentication()
        tokens = response
        if response == nil {
            UserDefaults.standard.removeObject(forKey: "Tracker.\(id).oauth")
            UserDefaults.standard.removeObject(forKey: "Tracker.\(id).token")
            UserDefaults.standard.removeObject(forKey: "Tracker.\(id).user_id")
        } else {
            saveTokens()
        }
    }

    func authorizedRequest(for url: URL, additionalHeaders: [String: String]? = nil) -> URLRequest {
        if tokens == nil { loadTokens() }

        let request = NSMutableURLRequest(url: url)
        request.addValue(
            "\(tokens?.tokenType ?? "Bearer") \(tokens?.accessToken ?? "")",
            forHTTPHeaderField: "Authorization"
        )

        // Add any additional headers
        if let additionalHeaders {
            for (key, value) in additionalHeaders {
                request.addValue(value, forHTTPHeaderField: key)
            }
        }

        URLProtocol.setProperty(accountGeneration.uuidString, forKey: Self.generationProperty, in: request)
        return request as URLRequest
    }
}

// MARK: - PKCE
extension OAuthClient {
    func generatePkceVerifier() -> String {
        var octets = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, octets.count, &octets) == errSecSuccess else {
            return ""
        }
        codeVerifier = base64(octets)
        return codeVerifier
    }

    func generatePkceChallenge(method: OAuthCodeChallengeMethod) -> String {
        switch method {
            case .plain:
                return generatePkceVerifier()
            case .s256:
                return generatePkceVerifier()
                   .data(using: .ascii)
                   .map { SHA256.hash(data: $0) }
                   .map { base64($0) } ?? ""
            case .none:
                return ""
        }
    }

    private func base64<S>(_ octets: S) -> String where S: Sequence, UInt8 == S.Element {
        let data = Data(octets)
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension OAuthClient {
    func checkIfReloginNeeded(trackerName: String) async -> Bool {
        if tokens == nil {
            loadTokens()
        }
        guard tokens?.refreshToken != nil else {
            await showReloginAlert(trackerName: trackerName)
            return true
        }
        return false
    }

    func showReloginAlert(trackerName: String) async {
        if tokens == nil {
            loadTokens()
        }
        guard var tokens else { return }
        if !tokens.askedForRefresh {
            tokens.askedForRefresh = true
            self.tokens = tokens
            saveTokens()
            await MainActor.run {
                UIApplication.shared.appDelegate?.presentAlert(
                    title: String(format: NSLocalizedString("%@_TRACKER_LOGIN_NEEDED"), trackerName),
                    message: String(format: NSLocalizedString("%@_TRACKER_LOGIN_NEEDED_TEXT"), trackerName)
                )
            }
        }
    }
}
