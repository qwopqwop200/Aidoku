import CryptoKit
import Foundation

/// Capture local file revisions once while loading a chapter, never in the hot
/// translation-key getter. Archive entries share one metadata lookup per archive.
enum ReaderLocalPageIdentity {
    static func prepare(_ pages: [Page]) async -> [Page] {
        var revisions: [URL: String] = [:]
        return pages.map { page in
            guard page.imageContentIdentity == nil,
                  let address = page.zipURL ?? page.imageURL,
                  let url = URL(string: address), url.isFileURL else { return page }
            let revision: String
            if let cached = revisions[url] {
                revision = cached
            } else {
                revision = fileRevision(url)
                revisions[url] = revision
            }
            var prepared = page
            // Archive entry names remain distinct even when every page shares
            // the same archive inode, timestamps and length.
            let parts = ["reader-local-file-v1", address, page.zipURL == nil ? "" : page.imageURL ?? "", revision]
            let data = (try? JSONEncoder().encode(parts)) ?? Data()
            prepared.imageContentIdentity = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return prepared
        }
    }

    static func fileRevision(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            // A missing/unreadable replacement must not hydrate old pixels or
            // translated text merely because it occupies the same pathname.
            return "unavailable-" + UUID().uuidString
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970.description ?? ""
        return [size.stringValue, modified.timeIntervalSince1970.description, created, inode].joined(separator: "|")
    }
}
