//
//  ReaderTemporaryPageStore.swift
//  Aidoku
//
//  Created by skitty on 8/23/26.
//

import AidokuRunner
import CryptoKit
import Foundation
import ZIPFoundation

actor ReaderTemporaryPageStore {
    private static let sessionsDirectory = FileManager.default.cachesDirectory
        .appendingPathComponent("ReaderSessions", isDirectory: true)

    private let directory: URL

    private struct ArchiveEntryKey: Hashable {
        let archiveURL: URL
        let path: String
        let revision: String
    }

    private var extractedArchiveEntries: [ArchiveEntryKey: URL] = [:]

    init() {
        directory = Self.sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory.createDirectory()
    }

    /// Identify the encoded bytes before writing: a failed write must not make
    /// distinct raw source pages share an empty-URL translation identity.
    func prepareRawPage(_ page: Page, pageIndex: Int) -> Page {
        Self.prepareRawPage(page, pageIndex: pageIndex, directory: directory)
    }

    /// The optional-store reader path still needs content identity, but need not
    /// create a temporary directory with no reader owner to remove it.
    nonisolated static func prepareInMemoryPage(_ page: Page, pageIndex: Int) async -> Page {
        prepareRawPage(page, pageIndex: pageIndex, directory: nil)
    }

    private nonisolated static func prepareRawPage(_ page: Page, pageIndex: Int, directory: URL?) -> Page {
        guard let image = page.image else { return page }
        var prepared = page
        prepared.index = pageIndex
        // An image that cannot encode cannot provide a persistent content hash.
        // Fail closed with a per-page identity rather than reuse another image.
        prepared.imageContentIdentity = "reader-unencodable-image-v1-" + UUID().uuidString
        guard !Task.isCancelled else { return prepared }
        return autoreleasepool {
            guard let data = image.pngData() else { return prepared }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            prepared.imageContentIdentity = "reader-image-png-v1-" + digest
            guard !Task.isCancelled, let directory else { return prepared }
            let url = directory.appendingPathComponent(digest).appendingPathExtension("png")
            do {
                try data.write(to: url, options: .atomic)
                prepared.image = nil
                prepared.imageURL = url.absoluteString
            } catch {
                // Keep the original image and its digest when storage is full
                // or this reader's temporary directory was removed.
            }
            return prepared
        }
    }

    func store(
        _ image: PlatformImage,
        chapterKey: String,
        pageIndex: Int
    ) -> URL? {
        guard let data = image.pngData() else {
            return nil
        }

        let fileExtension = "png"
        let filename = "\(chapterKey.hashValue)-\(pageIndex).\(fileExtension)"
        let url = directory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Keep split ordering/crop metadata without retaining decoded page pixels.
    func storeSplitPages(_ pages: [Page], chapterKey: String, pageIndex: Int) -> [Page]? {
        var result: [Page] = []
        for (offset, page) in pages.enumerated() {
            guard !Task.isCancelled, let image = page.image,
                  let url = store(image, chapterKey: chapterKey + "-split", pageIndex: pageIndex * 2 + offset) else { return nil }
            var stored = page
            stored.image = nil
            stored.imageURL = url.absoluteString
            result.append(stored)
        }
        return result
    }

    func storeArchiveEntry(
        from archiveURL: URL,
        path: String
    ) -> URL? {
        let key = ArchiveEntryKey(archiveURL: archiveURL, path: path,
                                  revision: ReaderLocalPageIdentity.fileRevision(archiveURL))

        if let cachedURL = extractedArchiveEntries[key], cachedURL.exists {
            return cachedURL
        }

        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let fileURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            let archive = try Archive(url: archiveURL, accessMode: .read)
            guard let entry = archive.entry(at: path) else {
                return nil
            }

            // set 250mb limit per page
            let maxPageSize = 250 * 1024 * 1024
            guard entry.uncompressedSize <= maxPageSize else {
                let size = ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)
                LogManager.logger.error("Skipping oversized archive entry: \(path) (\(size))")
                return nil
            }

            _ = try archive.extract(entry, to: fileURL, skipCRC32: true)
            extractedArchiveEntries[key] = fileURL

            return fileURL
        } catch {
            LogManager.logger.error("Failed to extract archive entry \(path): \(error)")
            fileURL.removeItem()
            return nil
        }
    }

    func removeAll() {
        directory.removeItem()
    }

    static func removeAllSessions() {
        sessionsDirectory.removeItem()
    }
}
