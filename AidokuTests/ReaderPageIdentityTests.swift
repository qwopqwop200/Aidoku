import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

/// Reader page identity and image-cache correctness: replaced content must never
/// reuse old pixels or translations, and persisted keys must stay stable.
@Suite(.serialized) @MainActor
struct ReaderPageIdentityTests {
    private func localPage(_ url: URL, entry: String? = nil) -> Page {
        Page(sourceId: "local-test", chapterId: "chapter", imageURL: entry ?? url.absoluteString,
             zipURL: entry == nil ? nil : url.absoluteString)
    }

    private func rawPage(color: UIColor = .red) -> Page {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        return Page(sourceId: "raw-image-source", chapterId: "chapter", image: image)
    }

    @Test func replacedLocalFileGetsNewTranslationAndPixelIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first image".utf8).write(to: url, options: .atomic)
        let first = await ReaderLocalPageIdentity.prepare([localPage(url)])
        let unchanged = await ReaderLocalPageIdentity.prepare([localPage(url)])
        let firstRequest = await ReaderPageView.imageRequest(url: url)
        #expect(first[0].translationCacheKey == unchanged[0].translationCacheKey)
        #expect(firstRequest.imageID == (await ReaderPageView.imageRequest(url: url)).imageID)
        // Same path, same length, different bytes.
        try Data("other image".utf8).write(to: url, options: .atomic)
        let replacement = await ReaderLocalPageIdentity.prepare([localPage(url)])
        let replacedRequest = await ReaderPageView.imageRequest(url: url)
        #expect(first[0].translationCacheKey != replacement[0].translationCacheKey)
        #expect(firstRequest.imageID != replacedRequest.imageID)
        #expect(replacedRequest.urlRequest?.url == url)
    }

    @Test func archiveReplacementInvalidatesEveryEntryButKeepsEntriesDistinct() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("archive one".utf8).write(to: url, options: .atomic)
        let pages = [localPage(url, entry: "1.png"), localPage(url, entry: "2.png")]
        let original = await ReaderLocalPageIdentity.prepare(pages)
        #expect(original[0].translationCacheKey != original[1].translationCacheKey)
        try Data("archive two".utf8).write(to: url, options: .atomic)
        let updated = await ReaderLocalPageIdentity.prepare(pages)
        #expect(original[0].translationCacheKey != updated[0].translationCacheKey)
        #expect(original[1].translationCacheKey != updated[1].translationCacheKey)
    }

    @Test func temporaryRawPagesKeyByContentAcrossSessions() async {
        let firstStore = ReaderTemporaryPageStore()
        let secondStore = ReaderTemporaryPageStore()
        let source = rawPage()
        let first = await firstStore.prepareRawPage(source, pageIndex: 2)
        let reopened = await secondStore.prepareRawPage(source, pageIndex: 2)
        let different = await firstStore.prepareRawPage(rawPage(color: .blue), pageIndex: 2)
        #expect(first.imageURL != reopened.imageURL)
        #expect(first.translationCacheKey == reopened.translationCacheKey)
        #expect(first.translationCacheKey != different.translationCacheKey)
        await firstStore.removeAll()
        await secondStore.removeAll()
    }

    @Test func unencodableImagesFailClosedInsteadOfSharingEmptyURLKey() async {
        let source = Page(sourceId: "raw-image-source", chapterId: "chapter", image: UIImage())
        let first = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 0)
        let second = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 0)
        #expect(first.image != nil)
        #expect(first.translationCacheKey != second.translationCacheKey)
    }

    /// Persisted cache-key format: changing it orphans every stored base64 page.
    @Test func base64IdentityIsStableAndUsesContentAndProcessingSettings() {
        let first = ReaderImageContentIdentity.base64Key("abc", processorSettingsKey: "plain")
        #expect(first == "reader-base64-v2-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad-plain")
        #expect(first != ReaderImageContentIdentity.base64Key("abd", processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key("abc", processorSettingsKey: "cropped"))
    }

    @Test func base64PagesWithSameChapterAndIndexDoNotReuseOtherContent() async throws {
        let keys = ["Reader.cropBorders", "Reader.downsampleImages"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        for key in keys { UserDefaults.standard.set(false, forKey: key) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let pipeline = ImagePipeline { $0.dataCache = nil; $0.imageCache = Nuke.ImageCache() }
        for (source, width) in [("source-a", 2), ("source-b", 4), ("source-b", 6)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: 3), format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 3))
            }
            let page = Page(sourceId: source, chapterId: "same-chapter", index: 0,
                            base64: try #require(image.pngData()).base64EncodedString())
            let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore(), imagePipeline: pipeline)
            view.isTranslationPreload = true
            #expect(await view.setPage(page))
            #expect(view.imageView.image?.cgImage?.width == width)
            view.releasePageResources()
        }
    }

    private let hash = "f71c81e179c49d058275918fe1699f4427957c295d0ac933b3f36f6e0b6d5a79"

    private func rotatingRemote(epoch: String = "1790658001", shard: Int = 1) -> ImageRequest {
        ImageRequest(urlRequest: URLRequest(
            url: URL(string: "https://a\(shard).gold-usergeneratedcontent.net/\(epoch)/\(0x9a7)/\(hash).avif")!))
    }

    @Test func routingRotationReusesIdentityAndReloadClearsBothKeys() throws {
        var first = rotatingRemote()
        var rotated = rotatingRemote(epoch: "1790744401", shard: 2)
        let transport = rotated.urlRequest
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &first, sourceKey: "multi.hitomi")
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &rotated, sourceKey: "multi.hitomi")
        #expect(first.imageID == rotated.imageID)
        #expect(rotated.urlRequest == transport)
        var otherSource = rotatingRemote()
        let original = otherSource.imageID
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &otherSource, sourceKey: "other")
        #expect(otherSource.imageID == original)

        let cache = try DataCache(name: "reader-reload-original-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline { $0.dataCache = cache; $0.imageCache = Nuke.ImageCache() }
        let plain = ImageRequest(url: URL(string: "https://cache-recovery.invalid/\(UUID())")!)
        var processed = plain
        processed.processors = [ImageProcessors.Resize(size: CGSize(width: 10, height: 10))]
        let image = try #require(rawPage().image)
        pipeline.cache.storeCachedData(Data("bytes".utf8), for: plain)
        pipeline.cache.storeCachedImage(ImageContainer(image: image), for: processed)
        ReaderImageDownloadCache.removeCachedImageAndOriginal(for: processed, pipeline: pipeline)
        #expect(!pipeline.cache.containsCachedImage(for: plain))
        #expect(!pipeline.cache.containsCachedImage(for: processed))
    }
}
