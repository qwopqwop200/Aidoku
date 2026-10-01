import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderRenderCacheIdentityAuditTests {
    @Test func changedTranslationCannotReplayPreviousViewportBitmap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let old = ReaderTranslationRegion(id: "same-region", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                          source: "original", translation: "old translation")
        let revised = ReaderTranslationRegion(id: old.id, rect: old.rect, source: old.source, translation: "revised translation")
        let oldKey = ReaderTranslationRenderCache.snapshotKey(renderKey: "same-geometry", regions: [old])
        let newKey = ReaderTranslationRenderCache.snapshotKey(renderKey: "same-geometry", regions: [revised])
        let image = try makeImage(stride: 8, padding: 0)
        await cache.store(image, key: oldKey, pageIdentity: "same-page", diskGeneration: await disk.currentGeneration())
        #expect(cache.cachedImage(for: oldKey) === image)
        #expect(cache.cachedImage(for: newKey) == nil)
        #expect(oldKey == ReaderTranslationRenderCache.snapshotKey(renderKey: "same-geometry", regions: [old]))
        #expect(oldKey != ReaderTranslationRenderCache.snapshotKey(renderKey: "different-geometry", regions: [old]))
    }

    @Test func sourceDigestIgnoresStrideAndInvisiblePadding() throws {
        let tight = try makeImage(stride: 8, padding: 0)
        let padded = try makeImage(stride: 16, padding: 113)
        let otherPadding = try makeImage(stride: 16, padding: 239)
        let digest = try #require(ReaderTranslationRenderAsset.digestSource(tight))
        #expect(ReaderTranslationRenderAsset.digestSource(padded) == digest)
        #expect(ReaderTranslationRenderAsset.digestSource(otherPadding) == digest)
        let changed = try makeImage(stride: 16, padding: 113, pixel: 90)
        #expect(ReaderTranslationRenderAsset.digestSource(changed) != digest)
    }

    @Test func sourceDigestIncludesColorDecodeMapping() throws {
        let regular = try makeImage(stride: 8, padding: 0)
        let inverted = try makeImage(stride: 8, padding: 0, inverted: true)
        #expect(ReaderTranslationRenderAsset.digestSource(regular) != ReaderTranslationRenderAsset.digestSource(inverted))
    }

    @Test func concurrentIdentityStoresKeepTheirLatestLiveEntry() async throws {
        let cache = ReaderTranslationImageIdentityCache<Int>(capacity: 2)
        let image = try makeImage(stride: 8, padding: 0)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for value in 0..<200 { cache.store(worker * 200 + value, for: image) }
                }
            }
        }
        // Old sentinels remove asynchronously. Their delayed cleanup must never
        // remove the final entry for an image that is still alive.
        try await Task.sleep(for: .milliseconds(30))
        #expect(cache.value(for: image) != nil)
        #expect(cache.count == 1)
    }

    private func makeImage(stride: Int, padding: UInt8, pixel: UInt8 = 30, inverted: Bool = false) throws -> UIImage {
        var bytes = [UInt8](repeating: padding, count: stride * 2)
        for row in 0..<2 {
            for column in 0..<2 {
                let offset = row * stride + column * 4
                bytes.replaceSubrange(offset..<(offset + 4), with: [pixel, 50, 70, 255])
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let decode: [CGFloat] = inverted ? [1, 0, 1, 0, 1, 0] : [0, 1, 0, 1, 0, 1]
        let image = decode.withUnsafeBufferPointer {
            CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: inverted ? $0.baseAddress : nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return UIImage(cgImage: try #require(image))
    }
}
