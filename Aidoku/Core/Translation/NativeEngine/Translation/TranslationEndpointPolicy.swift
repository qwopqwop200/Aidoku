// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum TranslationEndpointPolicy {
    private static let maximumURLBytes = 2_048

    static func endpoint(for configuration: RemoteTranslationConfiguration) throws -> URL {
        let rawValue = configuration.baseURL
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= maximumURLBytes,
              !rawValue.contains(where: { $0.isWhitespace }),
              !rawValue.contains("\\")
        else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider URL is blank, too long, or contains whitespace"
            )
        }

        guard var components = URLComponents(string: rawValue),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              !rawHost.isEmpty
        else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider URL requires a scheme and host"
            )
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider URL cannot contain credentials, a query, or a fragment"
            )
        }

        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        components.scheme = scheme
        components.host = host
        if components.port == 443, scheme == "https" {
            components.port = nil
        } else if components.port == 80, scheme == "http" {
            components.port = nil
        }

        switch scheme {
        case "https":
            break
        case "http":
            let rawLoopbackHost = rawAuthorityHost(rawValue)?.lowercased()
            guard configuration.provider == .custom,
                  configuration.allowsInsecureLocalhostForDevelopment,
                  rawLoopbackHost == "localhost" ||
                    rawLoopbackHost == "127.0.0.1" ||
                    rawLoopbackHost == "[::1]",
                  isCanonicalLoopbackHost(host)
            else {
                throw RemoteTranslationError.insecureEndpoint
            }
        default:
            throw RemoteTranslationError.insecureEndpoint
        }

        let decodedSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !decodedSegments.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider URL path cannot contain traversal segments"
            )
        }
        let encodedPath = components.percentEncodedPath.lowercased()
        guard !encodedPath.contains("%2f"),
              !encodedPath.contains("%5c"),
              !encodedPath.contains("%00")
        else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider URL path contains an unsafe encoded separator"
            )
        }

        let expectedSuffix: [String]
        let oppositeSuffix: [String]
        switch configuration.apiProtocol {
        case .responses:
            expectedSuffix = ["responses"]
            oppositeSuffix = ["chat", "completions"]
        case .chatCompletions:
            expectedSuffix = ["chat", "completions"]
            oppositeSuffix = ["responses"]
        }

        if hasSuffix(decodedSegments, oppositeSuffix) {
            throw RemoteTranslationError.invalidConfiguration(
                "provider URL endpoint does not match the selected protocol"
            )
        }

        var resultSegments = decodedSegments
        if !hasSuffix(resultSegments, expectedSuffix) {
            if resultSegments.isEmpty {
                resultSegments.append("v1")
            }
            resultSegments.append(contentsOf: expectedSuffix)
        }
        components.path = "/" + resultSegments.joined(separator: "/")
        components.percentEncodedQuery = nil

        guard let endpoint = components.url,
              endpoint.host != nil
        else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider endpoint could not be constructed"
            )
        }
        return endpoint
    }

    static func requiresLocalNetworkPermission(
        for configuration: RemoteTranslationConfiguration
    ) -> Bool {
        guard configuration.provider == .custom,
              let host = try? endpoint(for: configuration).host
        else {
            return false
        }
        return isPotentialLocalNetworkHost(host)
    }

    private static func hasSuffix(_ value: [String], _ suffix: [String]) -> Bool {
        guard value.count >= suffix.count else { return false }
        return value.suffix(suffix.count).elementsEqual(
            suffix,
            by: { $0.caseInsensitiveCompare($1) == .orderedSame }
        )
    }

    private static func isCanonicalLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" ||
            host == "::1" || host == "[::1]"
    }

    private static func isPotentialLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" ||
            normalized.hasSuffix(".local") ||
            normalized.hasSuffix(".home.arpa")
        {
            return true
        }
        if !normalized.contains(".") && !normalized.contains(":") {
            return true
        }

        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            return octets[0] == 10 ||
                octets[0] == 127 ||
                (octets[0] == 169 && octets[1] == 254) ||
                (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168)
        }

        if normalized == "::1" ||
            normalized.hasPrefix("fc") ||
            normalized.hasPrefix("fd")
        {
            return true
        }
        if let firstGroup = normalized.split(separator: ":").first,
           let value = UInt16(firstGroup, radix: 16)
        {
            return value & 0xffc0 == 0xfe80
        }
        return false
    }

    private static func rawAuthorityHost(_ value: String) -> String? {
        guard let schemeRange = value.range(of: "://") else { return nil }
        let remainder = value[schemeRange.upperBound...]
        let authorityEnd = remainder.firstIndex {
            $0 == "/" || $0 == "?" || $0 == "#"
        } ?? remainder.endIndex
        let authority = remainder[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if authority.first == "[" {
            guard let closing = authority.firstIndex(of: "]") else { return nil }
            return String(authority[...closing])
        }
        return String(authority.split(separator: ":", maxSplits: 1)[0])
    }
}
