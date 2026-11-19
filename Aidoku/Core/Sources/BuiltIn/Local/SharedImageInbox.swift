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
                                // Release ImageIO/UIKit temporaries per image; share extensions are
                                // limited to roughly 120 MB.
                                try autoreleasepool { try storeSharedItem(item, error: error, at: destination) }
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

    /// Image containers the app imports directly. Their original bytes are copied as-is, so the
    /// extension never decodes them; anything else ImageIO can read is downsampled and re-encoded.
    static let passthroughTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier, UTType.tiff.identifier,
        UTType.bmp.identifier, UTType.heic.identifier, UTType.heif.identifier,
        "org.webmproject.webp", "public.avif", "public.avci"
    ]
    /// Pixel budget for images that must be re-encoded in the extension (16 MP is 64 MB as RGBA).
    static let maxTranscodePixels = 16_000_000

    /// Writes one provider item to `destination` without decoding it whenever possible.
    static func storeSharedItem(
        _ item: Any?, error: Error?, at destination: URL, maxPixels: Int = maxTranscodePixels
    ) throws {
        if let url = item as? URL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: destination)
        } else if let data = item as? Data {
            try data.write(to: destination, options: .atomic)
        } else if let image = item as? UIImage {
            // The host already decoded this image; stream it to disk instead of building PNG data.
            try writeImage(image, to: destination, maxPixels: maxPixels)
            return
        } else {
            throw error ?? InboxError.invalidImages
        }
        try normalizeStoredImage(at: destination, maxPixels: maxPixels)
    }

    /// Keeps supported files byte-for-byte; re-encodes other readable formats as bounded PNG.
    private static func normalizeStoredImage(at url: URL, maxPixels: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?
        else { throw InboxError.invalidImages }
        if passthroughTypes.contains(type) { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { throw InboxError.invalidImages }
        let scale = min(1, (Double(maxPixels) / (width * height)).squareRoot())
        let maxSide = max(1, Int((max(width, height) * scale).rounded(.down)))
        // Thumbnail decoding allocates only the downsampled bitmap and applies EXIF orientation.
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ] as CFDictionary) else { throw InboxError.invalidImages }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePNG(thumbnail, to: temporary)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private static func writeImage(_ image: UIImage, to url: URL, maxPixels: Int) throws {
        guard let cgImage = image.cgImage else {
            // CIImage-backed images have no bitmap to stream; this is the only full encode.
            guard let data = image.pngData() else { throw InboxError.invalidImages }
            try data.write(to: url, options: .atomic)
            return
        }
        let pixels = Double(cgImage.width) * Double(cgImage.height)
        guard pixels > 0 else { throw InboxError.invalidImages }
        guard pixels > Double(maxPixels) || image.imageOrientation != .up else {
            try writePNG(cgImage, to: url)
            return
        }
        // The source bitmap is already resident; drawing allocates only the bounded target and
        // bakes in the orientation, which PNG files do not reliably carry.
        let scale = min(1, (Double(maxPixels) / pixels).squareRoot())
        let pointScale = max(image.scale, 1)
        let size = CGSize(
            width: max(1, (image.size.width * pointScale * scale).rounded(.down)),
            height: max(1, (image.size.height * pointScale * scale).rounded(.down))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let bitmap = rendered.cgImage else { throw InboxError.invalidImages }
        try writePNG(bitmap, to: url)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw InboxError.invalidImages }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw InboxError.invalidImages }
    }

    /// Imports tried this many times are dropped so a bad share is never retried forever.
    static let maxImportAttempts = 3
    /// The extension is killed (e.g. by its memory limit) without running its staging cleanup.
    static let staleStagingAge: TimeInterval = 60 * 60
    private static let attemptsFile = ".attempts"

    func pendingBatches(now: Date = Date()) throws -> [Batch] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        removeStaleStaging(now: now)
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ).sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }.compactMap { directory in
            // Batches are published by an atomic rename, so an unreadable one can never
            // become valid. Discard it instead of failing (and alerting) on every launch.
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            guard let batch = Self.batch(at: directory) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return batch
        }
    }

    private static func batch(at directory: URL) -> Batch? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let size = (try? manifestURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.files.isEmpty, manifest.files.allSatisfy({
                  !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\")
              }) else { return nil }
        let images = manifest.files.map { directory.appendingPathComponent($0) }
        guard images.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return Batch(directory: directory, title: manifest.title, images: images)
    }

    func remove(_ batch: Batch) throws {
        try FileManager.default.removeItem(at: batch.directory)
    }

    func failedAttempts(_ batch: Batch) -> Int {
        let url = batch.directory.appendingPathComponent(Self.attemptsFile)
        guard let data = try? Data(contentsOf: url), data.count < 32,
              let count = Int(String(decoding: data, as: UTF8.self)) else { return 0 }
        return max(0, count)
    }

    /// Counts a failed import. Returns true when the batch was discarded because it reached
    /// `maxImportAttempts` (or its counter cannot be persisted, which would allow endless retries).
    @discardableResult
    func recordFailedAttempt(_ batch: Batch) -> Bool {
        let count = failedAttempts(batch) + 1
        if count < Self.maxImportAttempts,
           (try? Data(String(count).utf8).write(to: batch.directory.appendingPathComponent(Self.attemptsFile), options: .atomic)) != nil {
            return false
        }
        try? FileManager.default.removeItem(at: batch.directory)
        return true
    }

    /// Removes half-written staging directories left behind by an extension that was terminated.
    private func removeStaleStaging(now: Date) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".") {
            guard let values = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else { continue }
            let date = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
            if now.timeIntervalSince(date) > Self.staleStagingAge {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
