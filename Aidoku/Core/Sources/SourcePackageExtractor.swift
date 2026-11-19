import Foundation
import ZIPFoundation

/// Extracts `.aix` source packages with resource and path limits.
///
/// A source package is an untrusted ZIP archive. ZIPFoundation's `unzipItem` checks
/// containment but writes as many bytes as the archive expands to, so a small download
/// could fill the device. This validates every entry before writing anything, counts the
/// bytes actually inflated (declared sizes can be understated), and removes the whole
/// extraction directory when any step fails.
enum SourcePackageExtractor {
    struct Limits: Sendable {
        var maximumEntryCount = 10_000
        var maximumEntryBytes: UInt64 = 128 * 1024 * 1024
        var maximumTotalBytes: UInt64 = 256 * 1024 * 1024

        static let standard = Limits()
    }

    enum Failure: Error, Equatable {
        case destinationExists
        case tooManyEntries
        case entryTooLarge(String)
        case totalTooLarge
        case unsafePath(String)
        case unsupportedEntry(String)
        case checksumMismatch(String)
        case cannotCreateFile(String)
    }

    /// Extracts `archiveURL` into `destination`, which must not exist yet.
    /// On any failure `destination` is removed, so no partial package remains.
    static func extract(_ archiveURL: URL, to destination: URL, limits: Limits = .standard) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        let archive = try Archive(url: archiveURL, accessMode: .read)

        // Validate the whole central directory before touching the disk.
        var entries: [(entry: Entry, path: String)] = []
        var declaredTotal: UInt64 = 0
        for entry in archive {
            guard entries.count < limits.maximumEntryCount else { throw Failure.tooManyEntries }
            guard let path = safeRelativePath(entry.path) else { throw Failure.unsafePath(entry.path) }
            switch entry.type {
            case .file, .directory: break
            case .symlink: throw Failure.unsupportedEntry(entry.path)
            }
            guard entry.uncompressedSize <= limits.maximumEntryBytes else { throw Failure.entryTooLarge(entry.path) }
            let sum = declaredTotal.addingReportingOverflow(entry.uncompressedSize)
            guard !sum.overflow, sum.partialValue <= limits.maximumTotalBytes else { throw Failure.totalTooLarge }
            declaredTotal = sum.partialValue
            entries.append((entry, path))
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var writtenTotal: UInt64 = 0
            for (entry, path) in entries {
                try Task.checkCancellation()
                let url = path.isEmpty ? destination : destination.appendingPathComponent(path)
                let root = destination.standardizedFileURL.path
                let target = url.standardizedFileURL.path
                guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                    throw Failure.unsafePath(entry.path)
                }
                if entry.type == .directory {
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    continue
                }
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
                guard fileManager.createFile(atPath: url.path, contents: nil) else { throw Failure.cannotCreateFile(entry.path) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                var writtenEntry: UInt64 = 0
                let checksum = try archive.extract(entry, consumer: { chunk in
                    let count = UInt64(chunk.count)
                    guard count <= limits.maximumEntryBytes - writtenEntry else { throw Failure.entryTooLarge(entry.path) }
                    guard count <= limits.maximumTotalBytes - writtenTotal else { throw Failure.totalTooLarge }
                    writtenEntry += count
                    writtenTotal += count
                    try handle.write(contentsOf: chunk)
                })
                guard checksum == entry.checksum else { throw Failure.checksumMismatch(entry.path) }
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Normalizes an archive path to a relative path inside the destination, or nil when it
    /// is absolute, escapes with `..`, or contains a NUL. An empty result denotes the root.
    static func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\0") else { return nil }
        // Windows drive prefixes such as `C:` are also absolute.
        if path.count >= 2, path[path.index(after: path.startIndex)] == ":" { return nil }
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !components.contains("..") else { return nil }
        return components.filter { $0 != "." }.joined(separator: "/")
    }
}
