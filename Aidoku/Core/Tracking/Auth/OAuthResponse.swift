//
//  OAuthResponse.swift
//  Aidoku
//
//  Created by Skitty on 7/22/22.
//

import Foundation

struct OAuthResponse: Sendable, Equatable {
    var tokenType: String?
    var refreshToken: String?
    var accessToken: String?
    var expiresIn: Int?
    var createdAt: Date = Date()

    // indicates if we've alerted the user that they need to re-login
    var askedForRefresh = false

    var expired: Bool {
        Date() > createdAt + TimeInterval(expiresIn ?? 0)
    }
}

extension OAuthResponse: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        createdAt = Self.decodeCreatedAt(from: container) ?? Date()
        askedForRefresh = (try? container.decodeIfPresent(Bool.self, forKey: .askedForRefresh)) ?? false
    }

    /// Local saves store reference-date seconds, while Doorkeeper servers (Shikimori)
    /// send Unix seconds; a string or other shape must not fail the whole login.
    static func decodeCreatedAt(from container: KeyedDecodingContainer<CodingKeys>) -> Date? {
        guard let seconds = try? container.decodeIfPresent(Double.self, forKey: .createdAt),
              seconds.isFinite else { return nil }
        // A current Unix timestamp reads ~31 years ahead as a reference-date value.
        if seconds > Date().timeIntervalSinceReferenceDate + 86_400 {
            return Date(timeIntervalSince1970: seconds)
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case createdAt = "created_at"

        case askedForRefresh = "asked_for_refresh"
    }
}
