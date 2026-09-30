import Foundation
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

@MainActor
struct ReaderTemporaryIdentityTests {
    private func page(color: UIColor = .red) -> Page {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        return Page(sourceId: "raw-image-source", chapterId: "chapter", image: image)
    }

    @Test func reopenedTemporarySessionRestoresSavedTranslation() async throws {
        let firstStore = ReaderTemporaryPageStore()
        let secondStore = ReaderTemporaryPageStore()
        let source = page()
        let first = await firstStore.prepareRawPage(source, pageIndex: 2)
        let reopened = await secondStore.prepareRawPage(source, pageIndex: 2)
        #expect(first.imageURL != reopened.imageURL)
        #expect(first.image == nil)
        #expect(reopened.image == nil)
        #expect(first.index == 2)
        #expect(first.translationCacheKey == reopened.translationCacheKey)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let regions = [ReaderTranslationRegion(id: "saved", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                              source: "Original", translation: "저장된 번역")]
        let writer = ReaderTranslationDiskCache(directory: directory)
        try await writer.storeRegions(regions,
            for: ReaderTranslationCacheIdentity.translation(page: first.translationCacheKey, settings: settings),
            kind: .translation, generation: 0)
        let reader = ReaderTranslationDiskCache(directory: directory)
        #expect(try await reader.translatedRegions(page: reopened.translationCacheKey, settings: settings) == regions)
        await firstStore.removeAll()
        await secondStore.removeAll()
    }

    @Test func failedWriteKeepsImageAndSameContentIdentityWithoutAliasingDifferentPixels() async {
        let failedStore = ReaderTemporaryPageStore()
        await failedStore.removeAll() // Reliably force writes to a missing parent directory.
        let successfulStore = ReaderTemporaryPageStore()
        let source = page()
        let failed = await failedStore.prepareRawPage(source, pageIndex: 3)
        let written = await successfulStore.prepareRawPage(source, pageIndex: 3)
        let changed = await failedStore.prepareRawPage(page(color: .blue), pageIndex: 3)
        #expect(failed.image === source.image)
        #expect(failed.imageURL == nil)
        #expect(failed.index == 3)
        #expect(failed.imageContentIdentity == written.imageContentIdentity)
        #expect(failed.translationCacheKey == written.translationCacheKey)
        #expect(failed.translationCacheKey != changed.translationCacheKey)
        await successfulStore.removeAll()
    }

    @Test func missingStoreStillPreservesContentAndPagePosition() async {
        let source = page()
        let first = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 0)
        let same = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 0)
        let next = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 1)
        let different = await ReaderTemporaryPageStore.prepareInMemoryPage(page(color: .blue), pageIndex: 0)
        #expect(first.image === source.image)
        #expect(first.imageURL == nil)
        #expect(first.translationCacheKey == same.translationCacheKey)
        #expect(first.translationCacheKey != next.translationCacheKey)
        #expect(first.translationCacheKey != different.translationCacheKey)
        var contextual = first
        contextual.context = ["variant": "other"]
        #expect(contextual.translationCacheKey != first.translationCacheKey)
    }

    @Test func unencodableImagesFailClosedInsteadOfSharingEmptyURLKey() async {
        let source = Page(sourceId: "raw-image-source", chapterId: "chapter", image: UIImage())
        #expect(source.image?.pngData() == nil)
        let first = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 0)
        let second = await ReaderTemporaryPageStore.prepareInMemoryPage(source, pageIndex: 0)
        #expect(first.image != nil)
        #expect(first.translationCacheKey != second.translationCacheKey)
    }

    @Test func replacingArchiveAtSamePathDoesNotReturnPreviouslyExtractedPixels() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        func writeArchive(_ bytes: Data) throws {
            let archive = try Archive(url: url, accessMode: .create)
            try archive.addEntry(with: "1.png", type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        let firstBytes = Data("first image".utf8)
        let secondBytes = Data("other image".utf8)
        try writeArchive(firstBytes)
        let store = ReaderTemporaryPageStore()
        let first = try #require(await store.storeArchiveEntry(from: url, path: "1.png"))
        let unchanged = try #require(await store.storeArchiveEntry(from: url, path: "1.png"))
        #expect(first == unchanged)
        #expect(try Data(contentsOf: first) == firstBytes)
        try FileManager.default.removeItem(at: url)
        try writeArchive(secondBytes)
        let replaced = try #require(await store.storeArchiveEntry(from: url, path: "1.png"))
        #expect(replaced != first)
        #expect(try Data(contentsOf: replaced) == secondBytes)
        await store.removeAll()
    }
}
