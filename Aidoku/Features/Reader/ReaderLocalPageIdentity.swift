import CryptoKit
import Foundation

/// Capture local file revisions once per chapter load (one lookup per archive), not in the hot key getter.
enum ReaderLocalPageIdentity {
    static func prepare(_ pages: [Page]) async -> [Page] {
        var revisions: [URL: String] = [:]
        return pages.map { page in
            guard page.imageContentIdentity == nil,
                  let address = page.zipURL ?? page.imageURL,
                  let url = URL(string: address), url.isFileURL else { return page }
            let revision = revisions[url] ?? fileRevision(url)
            revisions[url] = revision
            var prepared = page
            // Entry names keep pages distinct within one archive.
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
            // An unreadable replacement must never reuse old pixels or translations for the same path.
            return "unavailable-" + UUID().uuidString
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970.description ?? ""
        return [size.stringValue, modified.timeIntervalSince1970.description, created, inode].joined(separator: "|")
    }
}
