import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderUpscaleCanonicalReuseTests {
    private func bytes(_ red: UInt8 = 40) -> [UInt8] {
        (0..<(17 * 29)).flatMap { _ in [red, UInt8(80), UInt8(120), UInt8(255)] }
    }
    private func key(_ pixels: [UInt8], width: Int = 17, height: Int = 29) throws -> ReaderUpscaleCanonicalReuse.Key {
        try pixels.withUnsafeBytes { try #require(ReaderUpscaleCanonicalReuse.key(bytes: $0, width: width, height: height)) }
    }
    private func image(_ red: UInt8 = 40) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(bytes(red)) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(width: 17, height: 29, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 17 * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func onlyExactCanonicalBytesAndDimensionsMatch() throws {
        let cache = ReaderUpscaleCanonicalReuse()
        let original = bytes()
        let output = try image()
        let input = try key(original)
        cache.store(output, for: input)
        #expect(cache.image(for: try key(Array(original))) === output)
        var different = original; different[4] ^= 1
        #expect(cache.image(for: try key(different)) == nil)
        #expect(cache.image(for: try key(original, width: 29, height: 17)) == nil)
    }

    @Test func separateModelOwnedCachesCannotReuseEachOthersResult() throws {
        let firstModelCache = ReaderUpscaleCanonicalReuse()
        let secondModelCache = ReaderUpscaleCanonicalReuse()
        let input = try key(bytes())
        let output = try image()
        firstModelCache.store(output, for: input)
        #expect(secondModelCache.image(for: input) == nil)
        #expect(firstModelCache.image(for: input) === output)
    }

    @Test func visibleUIImageOwnsCGOutputButCacheDoesNot() throws {
        let cache = ReaderUpscaleCanonicalReuse()
        let input = try key(bytes())
        func makeOwner() throws -> UIImage {
            let cg = try image()
            cache.store(cg, for: input)
            return UIImage(cgImage: cg, scale: 3, orientation: .right)
        }
        weak var observed: CGImage?
        weak var observedOwner: UIImage?
        // UIImage.cgImage and framework/test expression temporaries can be
        // autoreleased. Drain the same ordinary ownership boundary before
        // testing whether the weak registry extends decoded-pixel lifetime.
        try autoreleasepool {
            var owner: UIImage? = try makeOwner()
            observedOwner = owner
            observed = owner?.cgImage
            #expect(observed != nil)
            #expect(cache.liveEntryCount == 1)
            withExtendedLifetime(owner) { #expect(cache.image(for: input) != nil) }
            owner = nil
        }
        #expect(observedOwner == nil)
        #expect(observed == nil, "Weak registry must not retain output beyond the owner's autorelease boundary")
        #expect(cache.liveEntryCount == 0)
    }

    @Test func outputCannotRetainModelOwnerThroughCache() throws {
        final class Owner { let cache = ReaderUpscaleCanonicalReuse() }
        var owner: Owner? = Owner()
        weak var observed = owner
        let output = try image()
        owner?.cache.store(output, for: try key(bytes()))
        owner = nil
        #expect(observed == nil)
        withExtendedLifetime(output) { }
    }

    @Test func eightEntriesRemainBoundedWithAllCGOutputsAlive() throws {
        let cache = ReaderUpscaleCanonicalReuse(capacity: 99)
        var outputs: [CGImage] = []
        for red in 0..<12 {
            let output = try image(UInt8(red)); outputs.append(output)
            cache.store(output, for: try key(bytes(UInt8(red))))
        }
        #expect(cache.liveEntryCount == 8)
        #expect(cache.image(for: try key(bytes(0))) == nil)
        #expect(cache.image(for: try key(bytes(11))) === outputs[11])
        withExtendedLifetime(outputs) { }
    }

    @Test func invalidByteCountsOverflowAndCancelledHashAreMisses() async throws {
        let data = bytes()
        data.withUnsafeBytes {
            #expect(ReaderUpscaleCanonicalReuse.key(bytes: $0, width: 17, height: 28) == nil)
            #expect(ReaderUpscaleCanonicalReuse.key(bytes: $0, width: Int.max, height: 2) == nil)
            #expect(ReaderUpscaleCanonicalReuse.key(bytes: $0, width: 0, height: 29) == nil)
        }
        let task = Task { data.withUnsafeBytes { ReaderUpscaleCanonicalReuse.key(bytes: $0, width: 17, height: 29) } }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func hashWorkCapRejectsAnOtherwiseValidCanonicalBuffer() {
        // One bounded 16MiB+4 byte array, no CGContext/CoreML allocation.
        let size = ReaderUpscaleCanonicalReuse.maximumHashBytes + 4
        let excessive = [UInt8](repeating: 255, count: size)
        excessive.withUnsafeBytes {
            #expect(ReaderUpscaleCanonicalReuse.key(bytes: $0, width: 1, height: size / 4) == nil)
        }
    }

    @Test func bundledFilenameAloneDoesNotEnableModelCache() async throws {
        let catalog = await ModelManager.shared.bundledModels()
        let trusted = try #require(catalog.first { $0.file == "SwinUNetV3Art2x.mlpackage" })
        #expect(ModelManager.matchesExactReuseCatalog(trusted, catalog: catalog))
        var missingResource = trusted; missingResource.bundledResource = nil
        var wrongSHA = trusted; wrongSHA.sha256 = String(repeating: "0", count: 64)
        var wrongConfig = trusted; wrongConfig.config = [:]
        var wrongType = trusted; wrongType.type = "image"
        for altered in [missingResource, wrongSHA, wrongConfig, wrongType] {
            #expect(!ModelManager.matchesExactReuseCatalog(altered, catalog: catalog))
        }
    }
}
