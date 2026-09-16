import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Prefer file/data handoff; decode only when the host exposes a UIImage object.
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
        // Hosts can include captions and links alongside the selected image.
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !providers.isEmpty, providers.count <= 1000 else { throw InboxError.invalidImages }
        let id = UUID().uuidString
        let staging = root.appendingPathComponent("." + id, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var files: [String] = []
        for (index, provider) in providers.enumerated() {
            let filename = String(format: "%08d", index + 1) + ".image"
            let destination = staging.appendingPathComponent(filename)
            try await Self.copyImage(from: provider, to: destination)
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

    private static func copyImage(from provider: NSItemProvider, to destination: URL) async throws {
        var types = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: .image) == true }
        if !types.contains(UTType.image.identifier) { types.append(UTType.image.identifier) }
        var lastError: Error = InboxError.invalidImages
        for type in types {
            for representation in 0..<3 {
                try? FileManager.default.removeItem(at: destination)
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let complete: (Any?, Error?) -> Void = { item, error in
                            do {
                                if let url = item as? URL {
                                    let access = url.startAccessingSecurityScopedResource()
                                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                                    try FileManager.default.copyItem(at: url, to: destination)
                                } else if let data = item as? Data {
                                    try data.write(to: destination, options: .atomic)
                                } else if let image = item as? UIImage, let data = image.pngData() {
                                    try data.write(to: destination, options: .atomic)
                                } else { throw error ?? InboxError.invalidImages }
                                guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                                      CGImageSourceGetCount(source) > 0 else { throw InboxError.invalidImages }
                                continuation.resume()
                            } catch { continuation.resume(throwing: error) }
                        }
                        switch representation {
                        case 0: provider.loadFileRepresentation(forTypeIdentifier: type) { complete($0, $1) }
                        case 1: provider.loadDataRepresentation(forTypeIdentifier: type) { complete($0, $1) }
                        default: provider.loadItem(forTypeIdentifier: type, options: nil) { complete($0, $1) }
                        }
                    }
                    return
                } catch { lastError = error }
            }
        }
        throw lastError
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
