//
//  Dictionary.swift
//  Aidoku
//
//  Created by Skitty on 6/17/22.
//

import Foundation

extension Dictionary {
    func percentEncoded() -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return map { key, value in
            let escapedKey = "\(key)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let escapedValue = "\(value)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return escapedKey + "=" + escapedValue
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }

    func compactMapKeys<T>(_ transform: ((Key) throws -> T?)) rethrows -> [T: Value] {
        try self.reduce(into: [T: Value]()) { result, x in
            if let key = try transform(x.key) {
                result[key] = x.value
            }
        }
    }
}
