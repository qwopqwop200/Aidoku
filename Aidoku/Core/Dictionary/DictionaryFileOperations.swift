import Foundation
import ZIPFoundation

/// Filesystem and transport validation shared by local and remote dictionary imports.
nonisolated enum DictionaryFileOperations {
    static func remoteURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host?.isEmpty == false else { throw URLError(.badURL) }
        return url
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
    }

    /// Cap response storage while streaming, including servers without Content-Length.
    static func boundedData(for request: URLRequest, session: URLSession = .shared,
                            maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0 else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try validateResponse(response)
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        let transfer = bytes.task
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 64 * 1024))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw CocoaError(.fileReadTooLarge) }
                if data.count.isMultiple(of: 16 * 1024) { try Task.checkCancellation() }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } onCancel: { transfer.cancel() }
    }

    static func validateTitle(_ title: String) throws {
        guard !title.isEmpty, title != ".", title != "..",
              !title.contains("/"), !title.contains("\\"), !title.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    /// The native importer uses the title as a directory and removes it on failure.
    /// Validate before invoking it, while the archive is still read-only.
    static func validateArchive(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["index.json"], entry.type == .file else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let maximumIndexBytes = 16 * 1024 * 1024
        guard entry.uncompressedSize <= maximumIndexBytes else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard chunk.count <= maximumIndexBytes - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
        struct IndexTitle: Decodable { let title: String }
        let index = try JSONDecoder().decode(IndexTitle.self, from: data)
        try validateTitle(index.title)
    }

    /// Stage the entire import first. Failed replacement retains or restores the old dictionary.
    static func install(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default,
        move: ((URL, URL) throws -> Void)? = nil
    ) throws {
        let move = move ?? { try fileManager.moveItem(at: $0, to: $1) }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".import-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".backup-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stage) }
        try fileManager.copyItem(at: source, to: stage)
        let hadExisting = fileManager.fileExists(atPath: destination.path)
        if hadExisting { try move(destination, backup) }
        do {
            try move(stage, destination)
        } catch {
            if hadExisting {
                // If rollback itself fails, leave the backup on disk for recovery.
                try? move(backup, destination)
            }
            throw error
        }
        if hadExisting { try? fileManager.removeItem(at: backup) }
    }
}
