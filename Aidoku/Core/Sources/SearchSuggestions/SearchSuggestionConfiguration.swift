import Foundation

/// Optional source-owned HTTP suggestions, independent of the source runner ABI.
struct SearchSuggestionConfiguration: Decodable, Sendable {
    enum Format: String, Decodable, Sendable {
        case objects, strings, tuples, openSearch
    }

    enum QueryMode: String, Decodable, Sendable {
        case query, token
    }

    struct JSONRequestBody: Decodable, Sendable {
        let queryField: String
        var namespaceField: String?
        var limitField: String?
        var limit: Int?
    }

    struct ObjectFields: Decodable, Sendable {
        let text: String
        var namespace: String?
        var count: String?
    }

    let urlTemplate: String
    let format: Format
    var namespaceURLTemplate: String?
    var queryMode: QueryMode?
    var defaultNamespace: String?
    var namespaces: [String]?
    var tokenSpaceReplacement: String?
    var queryCharacterReplacements: [String: String]?
    var lowercaseQuery: Bool?
    var headers: [String: String]?
    var minimumQueryLength: Int?
    var requestNamespaceMappings: [String: String]?
    var responseNamespaceMappings: [String: String]?
    var quoteTokens: Bool?
    var hideCounts: Bool?
    var jsonRequestBody: JSONRequestBody?
    var objectFields: ObjectFields?
    var minimumRequestIntervalMilliseconds: Int?

    static func load(sourceURL: URL?) -> Self? {
        struct Manifest: Decodable {
            struct Configuration: Decodable {
                let searchSuggestions: SearchSuggestionConfiguration?
            }
            let config: Configuration?
        }
        guard let sourceURL, sourceURL.isFileURL,
              let data = try? Data(contentsOf: sourceURL.appendingPathComponent("source.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest.config?.searchSuggestions
    }

    func request(for query: SearchSuggestionQuery) -> URLRequest? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        let term = lowercaseQuery == true ? query.term.lowercased() : query.term
        let path = term.map { character in
            encode(queryCharacterReplacements?[String(character)] ?? String(character))
        }.joined(separator: "/")
        let sourceNamespace = query.namespace ?? defaultNamespace ?? ""
        let namespace = requestNamespaceMappings?[sourceNamespace] ?? sourceNamespace
        if let namespaces, !sourceNamespace.isEmpty, !namespaces.contains(sourceNamespace) { return nil }
        // A namespace by itself requests its root index, without an empty path segment.
        let requestTemplate = query.term.isEmpty && query.namespace != nil
            ? namespaceURLTemplate ?? urlTemplate.replacingOccurrences(of: "/{queryPath}", with: "")
            : urlTemplate
        let address = requestTemplate
            .replacingOccurrences(of: "{query}", with: encode(term))
            .replacingOccurrences(of: "{queryPath}", with: path)
            .replacingOccurrences(of: "{namespace}", with: encode(namespace))
        let template = requestTemplate
            .replacingOccurrences(of: "{query}", with: "placeholder")
            .replacingOccurrences(of: "{queryPath}", with: "placeholder")
            .replacingOccurrences(of: "{namespace}", with: "placeholder")
        guard let url = URL(string: address), let base = URL(string: template),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              host == base.host, url.user == nil, url.password == nil,
              !address.contains("{"), !address.contains("}")
        else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = jsonRequestBody {
            var values: [String: Any] = [:]
            if !term.isEmpty { values[body.queryField] = term }
            if let field = body.namespaceField, !namespace.isEmpty { values[field] = namespace }
            if let field = body.limitField { values[field] = max(1, min(50, body.limit ?? 10)) }
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return nil }
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
