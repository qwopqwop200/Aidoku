import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

/// Share-extension inbox: durable batches, partial-share safety, poison-batch recovery and memory bounds.
@MainActor
struct SharedImageInboxTests {
    private func provider(file: URL, name: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(file, false, nil)
            return nil
        }
        return provider
    }

    @Test func sharedImagesSurviveRelaunchInOrderAndBecomeReadableChapter() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var urls: [URL] = []
        for (index, color) in [UIColor.red, .blue].enumerated() {
            let url = root.appendingPathComponent("\(index).png")
            let data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
            }
            try data.write(to: url)
            urls.append(url)
        }
        let inboxRoot = root.appendingPathComponent("inbox")
        let images = urls.map { provider(file: $0, name: "Shared page") }
        // Social apps can share a caption and a link together with the actual images.
        try await SharedImageInbox(root: inboxRoot).enqueue(providers:
            [NSItemProvider(object: "caption" as NSString), images[0],
             NSItemProvider(object: NSURL(string: "https://example.com/post")!), images[1]])
        let reopenedInbox = SharedImageInbox(root: inboxRoot)
        let batches = try reopenedInbox.pendingBatches()
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.images.count == 2)
        for (source, saved) in zip(urls, batch.images) {
            #expect(try Data(contentsOf: source) == Data(contentsOf: saved))
        }
        let prepared = await LocalFileManager.shared.prepareImageImport(from: batch.images, name: batch.title)
        let info = try #require(prepared)
        #expect(LocalFileManager.shared.readPages(from: info.url).count == 2)
        try reopenedInbox.remove(batch)
        #expect(try reopenedInbox.pendingBatches().isEmpty)
    }

    @Test func failedShareDoesNotPublishPartialBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedImageInbox(root: root)
        await #expect(throws: (any Error).self) {
            try await inbox.enqueue(providers: [NSItemProvider(object: "not an image" as NSString)])
        }
        #expect(try inbox.pendingBatches().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func corruptBatchIsDiscardedWithoutBlockingValidBatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt", isDirectory: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))
        try makeBatch(in: root, name: "missing")
        try FileManager.default.removeItem(at: missing.appendingPathComponent("00000001.image"))
        try makeBatch(in: root, name: "valid")
        try Data([1]).write(to: root.appendingPathComponent("stray-file"))
        let batches = try SharedImageInbox(root: root).pendingBatches()
        #expect(batches.map(\.directory.lastPathComponent) == ["valid"])
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func failingBatchIsDiscardedAfterBoundedAttemptsWithoutBlockingOthers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBatch(in: root, name: "a-failing")
        try makeBatch(in: root, name: "b-valid")
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

    @Test func decodedImageObjectIsWrittenWithinPixelBudget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let bounded = root.appendingPathComponent("bounded")
        try SharedImageInbox.storeSharedItem(image, error: nil, at: bounded, maxPixels: 5_000)
        let source = try #require(CGImageSourceCreateWithURL(bounded as CFURL, nil))
        let stored = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(stored.width * stored.height <= 5_000)
        #expect(stored.width > stored.height)
    }

    // MARK: - Helpers

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBatch(in root: URL, name: String) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"title":"\#(name)","files":["00000001.image"]}"#.utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        try Data([1]).write(to: directory.appendingPathComponent("00000001.image"))
    }
}
