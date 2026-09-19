//
//  URL.swift
//  Aidoku
//
//  Created by Skitty on 6/17/22.
//

import Foundation

extension URL {
    var queryParameters: [String: String]? {
        get {
            guard
                let components = URLComponents(url: self, resolvingAgainstBaseURL: true),
                let queryItems = components.queryItems
            else { return nil }
            return queryItems.reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value
            }
        }
        set {
            var components = URLComponents(url: self, resolvingAgainstBaseURL: true)
            components?.queryItems = newValue?.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            if let url = components?.url {
                self = url
            }
        }
    }
}

extension URL {
    func toAidokuFileUrl() -> URL? {
        guard scheme == "aidoku-image" else { return nil }
        let documents = FileManager.default.documentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let relativePath = host.map { $0 + self.path } ?? self.path
        let result = documents.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(documents.path + "/") else { return nil }
        return result
    }

    func toAidokuImageUrl() -> URL? {
        guard isFileURL else { return nil }
        let documents = FileManager.default.documentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(documents.path + "/") else { return nil }
        var components = URLComponents()
        components.scheme = "aidoku-image"
        components.host = ""
        components.path = String(file.path.dropFirst(documents.path.count))
        return components.url
    }

}

extension URL {
    var domain: String? {
        let host = if #available(iOS 16.0, macOS 13.0, *) {
            host(percentEncoded: false)
        } else {
            host
        }
        if let host, host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        } else {
            return host
        }
    }

    var percentEncodedPath: String {
        if #available(iOS 16.0, macOS 13.0, *) {
            path(percentEncoded: true)
        } else {
            path
        }
    }
}
