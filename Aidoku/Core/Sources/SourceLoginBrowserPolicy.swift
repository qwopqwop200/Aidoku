import Foundation

/// Native credential scope for source login browsers. Web storage remains browser-owned.
enum SourceLoginBrowserPolicy {
    static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs, let scheme = rhs.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == scheme && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    static func cookies(_ cookies: [HTTPCookie], for url: URL, includePath: Bool = true, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return []
        }
        // Cookie paths match the HTTP request path before percent decoding.
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let path = encodedPath.isEmpty ? "/" : encodedPath
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let bareDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesDomain = host == bareDomain || (domain.hasPrefix(".") && host.hasSuffix("." + bareDomain))
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let matchesPath = path == cookiePath || (path.hasPrefix(cookiePath) &&
                (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return matchesDomain && (!includePath || matchesPath) && (!cookie.isSecure || scheme == "https") &&
                (cookie.expiresDate.map { $0 > now } ?? true)
        }.sorted {
            // A dictionary cannot represent duplicate names. Prefer the most specific scope deterministically.
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.value < $1.value
        }
    }

    static func cookieValues(_ cookies: [HTTPCookie], for url: URL, includePath: Bool = true) -> [String: String] {
        var values: [String: String] = [:]
        for cookie in self.cookies(cookies, for: url, includePath: includePath) where values[cookie.name] == nil {
            values[cookie.name] = cookie.value
        }
        return values
    }

    /// Kavita's setup contract uses this exact callback, not any URL sharing the aidoku scheme.
    static func isOIDCCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "aidoku" && url.host?.lowercased() == "oidc-auth" &&
            url.user == nil && url.password == nil && url.port == nil && url.path.isEmpty &&
            url.query == nil && url.fragment == nil
    }
}
