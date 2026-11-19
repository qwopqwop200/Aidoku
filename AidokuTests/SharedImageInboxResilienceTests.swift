import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

/// Share-extension memory bounds and inbox recovery, using only images generated in code.
struct SharedImageInboxResilienceTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func syntheticImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        return try #require(context.makeImage())
    }

    private func encode(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func imageInfo(at url: URL) throws -> (type: String, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return (type, width, height)
    }

    private func makeBatch(in root: URL, name: String, valid: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"title":"\#(name)","files":["00000001.image"]}"#.utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        if valid { try Data([1]).write(to: directory.appendingPathComponent("00000001.image")) }
        return directory
    }

    // MARK: - Conversion without full decode

    @Test func supportedDataAndFilesAreCopiedByteForByte() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try syntheticImage(width: 64, height: 48)
        for type in [UTType.jpeg.identifier, UTType.png.identifier] {
            let original = try encode(image, type: type)
            let fromData = root.appendingPathComponent(UUID().uuidString)
            try SharedImageInbox.storeSharedItem(original, error: nil, at: fromData, maxPixels: 10)
            #expect(try Data(contentsOf: fromData) == original)

            let file = root.appendingPathComponent(UUID().uuidString)
            try original.write(to: file)
            let fromFile = root.appendingPathComponent(UUID().uuidString)
            // A tiny budget proves supported files are never decoded or downsampled.
            try SharedImageInbox.storeSharedItem(file, error: nil, at: fromFile, maxPixels: 10)
            #expect(try Data(contentsOf: fromFile) == original)
        }
    }

    @Test func unsupportedFormatIsDownsampledToBoundedPNG() throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let readable = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        let candidates = ["public.jpeg-2000", "com.truevision.tga-image", "com.ilm.openexr-image", "com.microsoft.ico"]
        guard let type = candidates.first(where: {
            writable.contains($0) && readable.contains($0) && !SharedImageInbox.passthroughTypes.contains($0)
        }) else {
            Issue.record("ImageIO offers no writable non-passthrough format: \(writable)")
            return
        }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try encode(try syntheticImage(width: 200, height: 100), type: type)
        let destination = root.appendingPathComponent("00000001.image")
        try SharedImageInbox.storeSharedItem(original, error: nil, at: destination, maxPixels: 5_000)
        let info = try imageInfo(at: destination)
        #expect(info.type == UTType.png.identifier)
        #expect(info.width * info.height <= 5_000)
        #expect(info.width > info.height)
        // No temporary files are left next to the converted image.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["00000001.image"])
    }

    @Test func decodedImageObjectIsWrittenWithinPixelBudget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIImage(cgImage: try syntheticImage(width: 200, height: 100))
        let small = root.appendingPathComponent("small")
        try SharedImageInbox.storeSharedItem(image, error: nil, at: small)
        let smallInfo = try imageInfo(at: small)
        #expect(smallInfo.type == UTType.png.identifier)
        #expect(smallInfo.width == 200 && smallInfo.height == 100)

        let bounded = root.appendingPathComponent("bounded")
        try SharedImageInbox.storeSharedItem(image, error: nil, at: bounded, maxPixels: 5_000)
        let boundedInfo = try imageInfo(at: bounded)
        #expect(boundedInfo.width * boundedInfo.height <= 5_000)
        #expect(boundedInfo.width > boundedInfo.height)
    }

    @Test func decodedImageOrientationIsBakedIn() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIImage(cgImage: try syntheticImage(width: 200, height: 100), scale: 1, orientation: .right)
        let destination = root.appendingPathComponent("rotated")
        try SharedImageInbox.storeSharedItem(image, error: nil, at: destination)
        let info = try imageInfo(at: destination)
        #expect(info.width == 100 && info.height == 200)
    }

    @Test func unreadableItemsAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("broken")
        #expect(throws: (any Error).self) {
            try SharedImageInbox.storeSharedItem(Data("not an image".utf8), error: nil, at: destination)
        }
        #expect(throws: (any Error).self) {
            try SharedImageInbox.storeSharedItem("caption" as NSString, error: nil, at: root.appendingPathComponent("text"))
        }
    }

    // MARK: - Batch recovery

    @Test func failingBatchIsDiscardedAfterBoundedAttemptsWithoutBlockingOthers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeBatch(in: root, name: "a-failing")
        _ = try makeBatch(in: root, name: "b-valid")
        let inbox = SharedImageInbox(root: root)
        var rounds = 0
        // Simulate repeated launches where the first batch always fails to import.
        while let failing = try inbox.pendingBatches().first(where: { $0.title == "a-failing" }) {
            rounds += 1
            #expect(rounds <= SharedImageInbox.maxImportAttempts)
            guard rounds <= SharedImageInbox.maxImportAttempts else { break }
            #expect(inbox.failedAttempts(failing) == rounds - 1)
            let discarded = inbox.recordFailedAttempt(failing)
            #expect(discarded == (rounds == SharedImageInbox.maxImportAttempts))
            #expect(try inbox.pendingBatches().contains { $0.title == "b-valid" })
        }
        #expect(rounds == SharedImageInbox.maxImportAttempts)
        #expect(try inbox.pendingBatches().map(\.title) == ["b-valid"])
    }

    @Test func attemptCounterDoesNotInvalidateBatch() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeBatch(in: root, name: "retry")
        let inbox = SharedImageInbox(root: root)
        let batch = try #require(try inbox.pendingBatches().first)
        #expect(!inbox.recordFailedAttempt(batch))
        let reloaded = try #require(try inbox.pendingBatches().first)
        #expect(reloaded.images == batch.images)
        #expect(inbox.failedAttempts(reloaded) == 1)
    }

    @Test func corruptAttemptCounterIsTreatedAsZero() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeBatch(in: root, name: "garbled")
        try Data(repeating: 0xFF, count: 4096).write(to: directory.appendingPathComponent(".attempts"))
        let inbox = SharedImageInbox(root: root)
        let batch = try #require(try inbox.pendingBatches().first)
        #expect(inbox.failedAttempts(batch) == 0)
        #expect(!inbox.recordFailedAttempt(batch))
        #expect(inbox.failedAttempts(batch) == 1)
    }

    @Test func staleHalfWrittenStagingIsRemovedButFreshStagingIsKept() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // An extension killed mid-share leaves a hidden staging directory without a manifest.
        let staging = root.appendingPathComponent("." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: staging.appendingPathComponent("00000001.image"))
        _ = try makeBatch(in: root, name: "valid")
        let inbox = SharedImageInbox(root: root)

        #expect(try inbox.pendingBatches().map(\.title) == ["valid"])
        #expect(FileManager.default.fileExists(atPath: staging.path))

        let later = Date().addingTimeInterval(SharedImageInbox.staleStagingAge + 60)
        #expect(try inbox.pendingBatches(now: later).map(\.title) == ["valid"])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func halfWrittenPublishedBatchIsDiscardedWithoutBlockingLaterBatch() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeBatch(in: root, name: "a-missing-image", valid: false)
        let empty = root.appendingPathComponent("b-no-manifest", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = try makeBatch(in: root, name: "c-valid")
        let inbox = SharedImageInbox(root: root)
        #expect(try inbox.pendingBatches().map(\.title) == ["c-valid"])
        #expect(try inbox.pendingBatches().map(\.title) == ["c-valid"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["c-valid"])
    }
}
