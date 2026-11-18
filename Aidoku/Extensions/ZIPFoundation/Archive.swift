//
//  Archive.swift
//  Aidoku
//
//  Created by Pietro Baiguini on 8/9/26.
//

import ZIPFoundation

extension Archive {
    /// Looks up an entry by path, tolerating the variations archives use for the same file.
    ///
    /// The subscript requires an exact match, so entries written with a `./` prefix or with
    /// percent-encoded characters (common when file names contain spaces or non-ASCII
    /// characters) fail to resolve. This falls back to a case-insensitive comparison against
    /// both the normalised and the percent-decoded path.
    func entry(at path: String) -> Entry? {
        if let entry = self[path] { return entry }
        let target = path.lowercased()
        return first { $0.path.matchesArchivePath(lowercased: target) }
    }
}

extension String {
    func matchesArchivePath(lowercased target: String) -> Bool {
        let path = hasPrefix("./") ? String(dropFirst(2)) : self
        return path.lowercased() == target || (path.removingPercentEncoding ?? path).lowercased() == target
    }
}
