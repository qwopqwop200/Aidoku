import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        try await SharedImageInbox(root: inboxRoot).enqueue(providers: urls.map { provider(file: $0, name: "Shared page") })
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
        do {
            try await inbox.enqueue(providers: [NSItemProvider(object: "not an image" as NSString)])
            Issue.record("Non-image share must fail")
        } catch {}
        #expect(try inbox.pendingBatches().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
