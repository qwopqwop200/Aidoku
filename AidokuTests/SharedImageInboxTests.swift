import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

@MainActor
struct SharedImageInboxTests {
    @Test func acceptsObjectAndDataRepresentationsAfterBrokenPreferredType() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 16)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 16))
        }
        let data = try #require(image.pngData())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(Data("broken preferred representation".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let inbox = SharedImageInbox(root: root)
        try await inbox.enqueue(providers: [provider, NSItemProvider(object: image)])
        let batch = try #require(inbox.pendingBatches().first)
        #expect(batch.images.count == 2)
        for url in batch.images { #expect(UIImage(contentsOfFile: url.path) != nil) }
        let prepared = await LocalFileManager.shared.prepareImageImport(from: batch.images, name: "Object images")
        #expect(prepared?.pageCount == 2)
    }

    @Test func embeddedExtensionAcceptsImagesWithCaptionsAndLinks() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let bundle = try #require(Bundle(url: plugins.appendingPathComponent("AidokuShare.appex")))
        let configuration = try #require(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        let attributes = try #require(configuration["NSExtensionAttributes"] as? [String: Any])
        let rule = NSPredicate(format: try #require(attributes["NSExtensionActivationRule"] as? String))
        for (types, expected) in [
            ([["public.png"]], true),
            ([["public.plain-text"], ["public.jpeg"], ["public.url"]], true),
            ([["public.url"]], false),
            ([["public.plain-text"]], false),
            ([], false)
        ] {
            let input: [String: Any] = ["extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]]
            #expect(rule.evaluate(with: input) == expected)
        }
    }

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
        do {
            try await inbox.enqueue(providers: [NSItemProvider(object: "not an image" as NSString)])
            Issue.record("Non-image share must fail")
        } catch {}
        #expect(try inbox.pendingBatches().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
