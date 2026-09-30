import Foundation

/// Native response classification and replay policy. Browser verification is still
/// required when the server does not accept an existing clearance cookie.
enum CloudflareResponsePolicy {
    static func isChallenge(response: HTTPURLResponse, data: Data) -> Bool {
        // Cloudflare documents this header for all Challenge Page response types.
        if response.value(forHTTPHeaderField: "cf-mitigated")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "challenge" {
            return true
        }
        let server = response.value(forHTTPHeaderField: "Server")?.lowercased()
        guard ["cloudflare", "cloudflare-nginx"].contains(server),
              [403, 503].contains(response.statusCode),
              let html = String(data: data, encoding: .utf8) else { return false }
        // Support older challenge responses without treating ordinary CDN 403s as captchas.
        let legacyID = #"\bid\s*=\s*["']challenge-error-(?:title|text)["']"#
        return html.range(of: legacyID, options: [.regularExpression, .caseInsensitive]) != nil
            || (html.contains("/cdn-cgi/challenge-platform/") && html.contains("_cf_chl_opt"))
    }

    static func mayRetryCachedClearance(_ request: URLRequest) -> Bool {
        ["GET", "HEAD"].contains((request.httpMethod ?? "GET").uppercased())
            && request.httpBody == nil && request.httpBodyStream == nil
    }

    /// Replace only clearance, leaving source-provided cookies and other headers intact.
    static func request(_ request: URLRequest, applying clearance: HTTPCookie) -> URLRequest {
        var updated = request
        var fields = (request.value(forHTTPHeaderField: "Cookie") ?? "")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.split(separator: "=", maxSplits: 1).first != "cf_clearance" }
        fields.append("cf_clearance=\(clearance.value)")
        updated.setValue(fields.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        return updated
    }

    static func clearance(in request: URLRequest) -> String? {
        (request.value(forHTTPHeaderField: "Cookie") ?? "")
            .split(separator: ";").compactMap { field -> String? in
                let pair = field.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                guard pair.count == 2, pair[0] == "cf_clearance" else { return nil }
                return String(pair[1])
            }.first
    }

    static func cookie(_ cookie: HTTPCookie, appliesTo url: URL, now: Date = Date()) -> Bool {
        !SourceLoginBrowserPolicy.cookies([cookie], for: url, now: now).isEmpty
    }

    /// Foundation applies domain, path and secure rules before this expiry check.
    static func usableClearance(for url: URL, storage: HTTPCookieStorage = .shared, now: Date = Date()) -> HTTPCookie? {
        SourceLoginBrowserPolicy.cookies(storage.requestCookies(for: url) ?? [], for: url, now: now).first {
            $0.name == "cf_clearance" && !$0.value.isEmpty
        }
    }

    /// Verification can refresh Cloudflare state, but cannot export provider credentials.
    /// A persistent WebKit snapshot may contain an older session than native networking.
    static func commitVerificationCookies(_ cookies: [HTTPCookie], for url: URL,
                                          storage: HTTPCookieStorage = .shared, now: Date = Date()) {
        let allowedNames: Set<String> = ["cf_clearance", "__cf_bm", "_cfuvid"]
        let verification = SourceLoginBrowserPolicy.cookies(cookies, for: url, now: now).filter {
            allowedNames.contains($0.name) && !$0.value.isEmpty
        }
        storage.setCookies(verification, for: url, mainDocumentURL: url)
    }

    /// A verification navigation must not replay the source's POST or upload body.
    static func browserRequest(for request: URLRequest) -> URLRequest {
        var navigation = request
        navigation.httpMethod = "GET"
        navigation.httpBody = nil
        navigation.httpBodyStream = nil
        for header in ["Content-Length", "Content-Type", "Transfer-Encoding"] {
            navigation.setValue(nil, forHTTPHeaderField: header)
        }
        return navigation
    }
}
