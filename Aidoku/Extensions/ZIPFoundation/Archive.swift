//
//  Archive.swift
//  Aidoku
//
//  Created by Pietro Baiguini on 8/9/26.
//

import Foundation
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

enum ArchiveEntryReadError: Error {
    case entryTooLarge
}

extension Archive {
    /// Extracts an entry into memory, refusing entries larger than `limit` bytes.
    ///
    /// The declared size is checked first, and the streamed byte count is checked again,
    /// because a malformed or hostile archive can understate its uncompressed size.
    func extractData(_ entry: Entry, limit: Int) throws -> Data {
        guard limit >= 0, entry.uncompressedSize <= UInt64(limit) else { throw ArchiveEntryReadError.entryTooLarge }
        var data = Data()
        _ = try extract(entry, consumer: { chunk in
            guard chunk.count <= limit - data.count else { throw ArchiveEntryReadError.entryTooLarge }
            data.append(chunk)
        })
        return data
    }
}
