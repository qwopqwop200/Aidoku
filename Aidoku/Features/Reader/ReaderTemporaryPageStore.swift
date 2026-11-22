//
//  ReaderTemporaryPageStore.swift
//  Aidoku
//
//  Created by skitty on 8/23/26.
//

import AidokuRunner
import CryptoKit
import Foundation
import Nuke
import UIKit
import ZIPFoundation

actor ReaderTemporaryPageStore {
    static let sessionsDirectory = FileManager.default.cachesDirectory
        .appendingPathComponent("ReaderSessions", isDirectory: true)

    private let directory: URL

    private struct ArchiveEntryKey: Hashable {
        let archiveURL: URL
        let path: String
        let revision: String
    }

    private var extractedArchiveEntries: [ArchiveEntryKey: URL] = [:]
    private var openArchive: IndexedArchive?
    private static let maxBufferedEntryBytes = 8 * 1024 * 1024
    private var lastEncodedPage: (key: ArchiveEntryKey, data: Data)?
    private var archiveDecodedSizes: [ArchiveEntryKey: UInt64] = [:]
    private var archiveObservers: [NSObjectProtocol] = []

    struct ArchiveImageSource: Sendable {
        let request: ImageRequest
        let decodedBytes: @Sendable () async throws -> UInt64
    }

    // ZIPFoundation's path subscript rescans headers each time; advance one cursor on demand instead.
    private final class IndexedArchive {
        let archive: Archive
        let revision: String
        private var remaining: AnyIterator<Entry>?
        // Keep only recent headers (they can be large) plus all names for exact and alias lookups.
        private static let headerLimit = 512
        private var headers: [Entry] = []
        private var names: [String] = []
        private var positions: [String: Int] = [:]

        init(url: URL, revision: String) throws {
            let archive = try Archive(url: url, accessMode: .read)
            self.archive = archive
            self.revision = revision
            remaining = archive.makeIterator()
        }

        func entry(at path: String) -> Entry? {
            if let position = positions[path] { return existingEntry(at: position) }
            while let iterator = remaining {
                guard !Task.isCancelled else { return nil }
                guard let entry = iterator.next() else {
                    remaining = nil
                    break
                }
                let name = entry.path
                if positions[name] == nil {
                    let position = names.count
                    positions[name] = position
                    names.append(name)
                    if headers.count < Self.headerLimit {
                        headers.append(entry)
                    } else {
                        headers[position % Self.headerLimit] = entry
                    }
                    if name == path { return entry }
                }
            }
            let target = path.lowercased()
            return names.firstIndex { $0.matchesArchivePath(lowercased: target) }.flatMap { existingEntry(at: $0) }
        }

        private func existingEntry(at position: Int) -> Entry? {
            if position >= names.count - headers.count { return headers[position % Self.headerLimit] }
            return archive[names[position]]
        }
    }

    init() {
        directory = Self.sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory.createDirectory()
    }

    deinit {
        archiveObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Identify the encoded bytes before writing, so a failed write cannot share an identity.
    func prepareRawPage(_ page: Page, pageIndex: Int) -> Page {
        Self.prepareRawPage(page, pageIndex: pageIndex, directory: directory)
    }

    /// Content identity without creating an unowned temporary directory.
    nonisolated static func prepareInMemoryPage(_ page: Page, pageIndex: Int) async -> Page {
        prepareRawPage(page, pageIndex: pageIndex, directory: nil)
    }

    private nonisolated static func prepareRawPage(_ page: Page, pageIndex: Int, directory: URL?) -> Page {
        guard let image = page.image else { return page }
        var prepared = page
        prepared.index = pageIndex
        // Fail closed with a per-page identity when the image cannot be encoded.
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
                // Keep the original image and digest when the write fails.
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
            guard !Task.isCancelled, let image = page.image else { return nil }
            let sealed = page.translationSplitSource?.sealPNG(from: image)
            guard let data = sealed?.data ?? image.pngData(), !Task.isCancelled else { return nil }
            // Name by source digest so a new crop never replaces a file still in use.
            let stem = "\((chapterKey + "-split").hashValue)-\(pageIndex * 2 + offset)"
            let named = sealed.map { stem + "-" + $0.filenameDigest } ?? stem
            let url = directory.appendingPathComponent(named + ".png")
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            var stored = page
            stored.image = nil
            stored.imageURL = url.absoluteString
            stored.translationSplitSource = sealed?.source
            result.append(stored)
        }
        return result
    }

    // Nuke gets the encoded bytes and coalesces matching display and translation requests.
    func archiveImageSource(from url: URL, path: String) -> ArchiveImageSource? {
        guard !Task.isCancelled, directory.exists, url.isFileURL,
              LocalFileManager.allowedImageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        let key = ArchiveEntryKey(archiveURL: url, path: path, revision: ReaderLocalPageIdentity.fileRevision(url))
        if let existing = extractedArchiveEntries[key], existing.exists { return nil }
        guard let (_, entry) = try? indexedEntry(for: key), entry.type == .file, entry.uncompressedSize > 0,
              entry.uncompressedSize <= UInt64(Self.maxBufferedEntryBytes) else { return nil }
        let parts = [directory.lastPathComponent, url.absoluteString, key.revision, path]
        let id = "reader-archive-v1-" + parts.map { "\($0.utf8.count):\($0)" }.joined()
        let read: @Sendable () async throws -> Data = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.encodedPage(for: key)
        }
        let request = ImageRequest(id: id, data: read, options: [.disableDiskCache])
        return ArchiveImageSource(request: request) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.decodedPageBytes(for: key)
        }
    }

    private func indexedEntry(for key: ArchiveEntryKey) throws -> (Archive, Entry)? {
        if openArchive?.archive.url != key.archiveURL || openArchive?.revision != key.revision {
            openArchive = try IndexedArchive(url: key.archiveURL, revision: key.revision)
            if archiveObservers.isEmpty {
                archiveObservers = [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                        Task { await self?.releaseArchiveMemory() }
                    }
                }
            }
        }
        guard let openArchive, let entry = openArchive.entry(at: key.path) else { return nil }
        return (openArchive.archive, entry)
    }

    private func validateArchiveRevision(_ key: ArchiveEntryKey) throws {
        try Task.checkCancellation()
        guard directory.exists, ReaderLocalPageIdentity.fileRevision(key.archiveURL) == key.revision else { throw URLError(.resourceUnavailable) }
    }

    private func decodedPageBytes(for key: ArchiveEntryKey) throws -> UInt64 {
        if let size = archiveDecodedSizes[key] {
            try validateArchiveRevision(key)
            return size
        }
        let size = TranslationImageWorkBudget.decodedBytes(in: try encodedPage(for: key))
        archiveDecodedSizes[key] = size
        return size
    }

    private func encodedPage(for key: ArchiveEntryKey) throws -> Data {
        try validateArchiveRevision(key)
        if let lastEncodedPage, lastEncodedPage.key == key { return lastEncodedPage.data }
        guard let (archive, entry) = try indexedEntry(for: key), entry.type == .file,
              entry.uncompressedSize <= UInt64(Self.maxBufferedEntryBytes) else { throw URLError(.cannotDecodeContentData) }
        let size = Int(entry.uncompressedSize)
        var data = Data()
        let compressed = entry.isCompressed
        if compressed { data.reserveCapacity(size) }
        let bufferSize = compressed ? 64 * 1024 : max(1, size)
        _ = try archive.extract(entry, bufferSize: bufferSize, skipCRC32: true) { chunk in
            try Task.checkCancellation()
            guard chunk.count <= size - data.count else { throw URLError(.cannotDecodeContentData) }
            if compressed { data.append(chunk) } else { data = chunk }
        }
        try Task.checkCancellation()
        guard data.count == size else { throw URLError(.cannotDecodeContentData) }
        lastEncodedPage = (key, data)
        return data
    }

    func storeArchiveEntry(
        from archiveURL: URL,
        path: String
    ) -> URL? {
        guard !Task.isCancelled else { return nil }
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
            guard let (archive, entry) = try indexedEntry(for: key), !Task.isCancelled else { return nil }

            // set 250mb limit per page
            let maxPageSize = 250 * 1024 * 1024
            guard entry.uncompressedSize <= maxPageSize else {
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.uncompressedSize), countStyle: .file)
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

    private func releaseArchiveMemory() {
        lastEncodedPage = nil
        archiveDecodedSizes.removeAll()
        openArchive = nil
    }

    func removeAll() {
        releaseArchiveMemory()
        archiveObservers.forEach(NotificationCenter.default.removeObserver)
        archiveObservers.removeAll()
        extractedArchiveEntries.removeAll()
        directory.removeItem()
    }

    static func removeAllSessions() {
        sessionsDirectory.removeItem()
    }
}
