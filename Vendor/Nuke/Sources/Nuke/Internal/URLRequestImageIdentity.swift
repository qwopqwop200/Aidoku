// The MIT License (MIT)
// Copyright (c) 2015-2026 Alexander Grebenyuk (github.com/kean).
// Local Aidoku correction: namespace cache and original-data coalescing together.

import CryptoKit
import Foundation

enum URLRequestImageIdentity {
    static func make(_ request: URLRequest) -> String? {
        guard let url = request.url?.absoluteString else { return nil }
        let method = request.httpMethod ?? "GET"
        let fields = request.allHTTPHeaderFields ?? [:]
        let normalized: [(String, String)] = fields.map { ($0.key.lowercased(), $0.value) }
        let headers = normalized.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        let body = request.httpBody
        let hasStream = request.httpBodyStream != nil
        // Retain established URL-only keys for the normal headerless GET path.
        guard method != "GET" || !headers.isEmpty || body != nil || hasStream else { return url }
        var digest = SHA256()
        func append(_ value: String) {
            let data = Data(value.utf8)
            digest.update(data: Data("\(data.count):".utf8))
            digest.update(data: data)
        }
        append(url)
        append(method)
        append(String(headers.count))
        for (name, value) in headers { append(name); append(value) }
        if hasStream {
            // Streams cannot be inspected without consuming them. A new request
            // gets an isolated identity; copies of that ImageRequest retain it.
            append("stream")
            append(UUID().uuidString)
        } else if let body {
            append("body")
            append(String(body.count))
            digest.update(data: body)
        } else {
            append("no-body")
        }
        return "aidoku-urlrequest-v1-" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
