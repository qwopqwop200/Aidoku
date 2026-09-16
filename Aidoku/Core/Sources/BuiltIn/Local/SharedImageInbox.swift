import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disk-only handoff: the extension never decodes full-size photos or touches the app database.
struct SharedImageInbox {
    enum InboxError: Error { case unavailable, invalidImages }

    struct Batch {
        let directory: URL
        let title: String
        let images: [URL]
    }

    private struct Manifest: Codable {
        let title: String
        let files: [String]
    }

    let root: URL

    static func live() throws -> Self {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "SHARED_IMAGE_APP_GROUP") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { throw InboxError.unavailable }
        return Self(root: container.appendingPathComponent("SharedImages", isDirectory: true))
    }

    func enqueue(providers: [NSItemProvider]) async throws {
        guard !providers.isEmpty else { throw InboxError.invalidImages }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = root.appendingPathComponent("." + id, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var files: [String] = []
        for (index, provider) in providers.enumerated() {
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { throw InboxError.invalidImages }
            let ext = UTType(type)?.preferredFilenameExtension ?? "image"
            let filename = String(format: "%08d", index + 1) + "." + ext
            let destination = staging.appendingPathComponent(filename)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? InboxError.invalidImages)
                        return
                    }
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                              CGImageSourceGetCount(source) > 0 else { throw InboxError.invalidImages }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            files.append(filename)
        }
        let suggestedName = providers.first?.suggestedName ?? NSLocalizedString("FORMAT_IMAGE", comment: "")
        let base = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
        let title = String(base.prefix(100)) + " " + id.prefix(8)
        let manifest = Manifest(title: title, files: files)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        // The app sees only complete batches, even when sharing and foregrounding overlap.
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(id, isDirectory: true))
    }

    func pendingBatches() throws -> [Batch] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ).sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }.map { directory in
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            guard !manifest.files.isEmpty, manifest.files.allSatisfy({
                !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\")
            }) else { throw InboxError.invalidImages }
            return Batch(directory: directory, title: manifest.title, images: manifest.files.map { directory.appendingPathComponent($0) })
        }
    }

    func remove(_ batch: Batch) throws {
        try FileManager.default.removeItem(at: batch.directory)
    }
}
