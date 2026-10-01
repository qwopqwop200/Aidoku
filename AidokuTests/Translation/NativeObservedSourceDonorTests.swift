import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

private final class NativeObservedSourceDonorFixtureBundle: NSObject {}

@Suite(.serialized)
struct NativeObservedSourceDonorTests {
    @Test func foreignBoundsDoNotChangeNeighboringCaptionTexture() throws {
        let url = try #require(Bundle(for: NativeObservedSourceDonorFixtureBundle.self)
            .url(forResource: "NativeObservedSourceDonorCase", withExtension: "json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let originalBase64 = try #require(fixture["originalRGBA"] as? String)
        let expectedBase64 = try #require(fixture["expectedRGBA"] as? String)
        let original = try #require(Data(base64Encoded: originalBase64))
        let expected = try #require(Data(base64Encoded: expectedBase64))
        let originalHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let expectedHash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        try #require(originalHash == "f3b67312e684aa77839508d2609c6b9ae44423735e636e22b6d2d4fdde1b91de")
        try #require(expectedHash == "fa7b1dab1730f932c5ce47b67ade7b63e0b2b2fe70beebe6aa21fce3ff5b6343")
        var pixels = NativeRestorationPixels(width: 142, height: 347)
        pixels.rgba = Array(original)
        try #require(pixels.rgba.count == pixels.count * 4 && expected.count == pixels.rgba.count)
        let sample = try #require(fixture["palette"] as? [String: Any])
        let palette = try #require(NativeRestorationPixels.palette(sample))
        let captured = try #require(fixture["options"] as? [String: Any])
        func rects(_ name: String) throws -> [CGRect] {
            let values = try #require(captured[name] as? [[Double]])
            return try values.map { r in
                try #require(r.count == 4 && r.allSatisfy(\.isFinite))
                return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            }
        }
        var options = NativeObservedRestoreOptions()
        options.vertical = true
        options.auxiliary = try rects("auxiliary")
        options.inferredRubyExclusions = try rects("inferredRubyExclusions")
        options.excluded = options.inferredRubyExclusions
        let strict = try #require(NativeRestorationPixels.exactObservedRestore(pixels,
            box: CGRect(x: 24, y: 24, width: 83.99999999999999, height: 260), palette: palette, options: options))
        let strictHash = SHA256.hash(data: Data(strict.rgba)).map { String(format: "%02x", $0) }.joined()
        #expect(strictHash == "ef2fe61bb08b794f8fdaf5335204b03aac4475fbed2b69206aec23d31d724b47",
                "The default strict low-level contract remains byte-for-byte unchanged")
        options.excludedDonorPolicy = .observedSource
        let result = try #require(NativeRestorationPixels.exactObservedRestore(pixels,
            box: CGRect(x: 24, y: 24, width: 83.99999999999999, height: 260), palette: palette, options: options))
        #expect(result.surfaceQuality?["reason"] as? String == "exemplar-texture")
        let alphaUnchanged = stride(from: 3, to: result.rgba.count, by: 4).allSatisfy { result.rgba[$0] == strict.rgba[$0] }
        #expect(alphaUnchanged, "Color donors cannot change the strict paint mask")
        let expectedBytes = Array(expected)
        var changed = 0
        for pixel in 0..<pixels.count {
            let offset = pixel * 4
            for channel in 0..<4 where result.rgba[offset + channel] != expectedBytes[offset + channel] {
                changed += 1
                break
            }
        }
        // Boolean comparison avoids dumping two full raster arrays on failure.
        let exact = result.rgba == expectedBytes
        #expect(exact, "Captured texture reconstruction differs at \(changed) pixels")
        #expect(options.excluded.flatMap { pixels.indices($0) }.allSatisfy { result.rgba[$0 * 4 + 3] == 0 },
                "Hard foreign exclusions remain unpainted")
        #expect(result.surfaceQuality?["samples"] as? Int == 207)
        let sourceUnchanged = pixels.rgba == Array(original)
        #expect(sourceUnchanged)
    }

    @Test(arguments: ["foreign-ink", "overlapping-ink", "foreign-art"])
    func sourceDonorsKeepInkArtMarginsAndStrictPaintMask(_ condition: String) throws {
        var pixels = NativeRestorationPixels(width: 64, height: 64)
        for i in 0..<pixels.count { pixels.paint(i, .init([245, 245, 245])) }
        for band in [20...26, 30...36, 40...46] { for y in band {
            for x in 12...15 { pixels.paint(y * 64 + x, .init([10, 10, 10])) }
        } }
        let overlap = condition == "overlapping-ink"
        if !overlap {
            let foreignColor = NativeRestorationRGB(condition == "foreign-art" ? [220, 20, 70] : [10, 10, 10])
            for y in 20...40 { for x in 48...50 { pixels.paint(y * 64 + x, foreignColor) } }
        }
        let original = pixels.rgba
        let box = CGRect(x: 8, y: 12, width: 12, height: 36)
        let foreign = overlap ? CGRect(x: 14, y: 20, width: 2, height: 27) : CGRect(x: 48, y: 10, width: 16, height: 44)
        let palette = NativeRestorationPixels.Palette(foreground: .init([10, 10, 10]), background: .init([245, 245, 245]))
        var options = NativeObservedRestoreOptions(); options.excluded = [foreign]
        let strict = try #require(NativeObservedRestoreState(pixels, box: box, palette: palette, options: options))
        options.excludedDonorPolicy = .observedSource
        let sampled = try #require(NativeObservedRestoreState(pixels, box: box, palette: palette, options: options))
        try #require(strict.establishMask() && sampled.establishMask())
        let sourceDonors = try #require(sampled.sourceDonorBlocked)
        let sourceForbidden = try #require(sampled.sourceDonorForbidden)
        #expect(sourceDonors[30 * 64 + (overlap ? 23 : 40)] == 1,
                "Actual foreign ink or colored art keeps its eight-pixel donor margin")
        #expect(sourceForbidden[30 * 64 + (overlap ? 15 : 49)] == 1)
        #expect(sourceForbidden[30 * 64 + (overlap ? 23 : 40)] == 1,
                "Exemplar donor footprints also exclude the eight-pixel foreign-ink margin")
        if !overlap {
            #expect(sourceDonors[11 * 64 + 41] == 0, "Observed clear backing outside the ink margin remains available")
            #expect(sourceForbidden[14 * 64 + 60] == 0, "A broad OCR bound alone cannot label clear source backing as ink")
        }
        let identicalProtection = sampled.mask == strict.mask && sampled.protectedInk == strict.protectedInk &&
            sampled.donorBlocked == strict.donorBlocked && sampled.frameInk == strict.frameInk
        #expect(identicalProtection, "Sampling policy cannot change strict ownership, growth or protection")
        #expect(pixels.indices(foreign).allSatisfy {
            sampled.protectedInk[$0] == 1 && sampled.donorBlocked[$0] == 1 && sampled.mask[$0] == 0
        })
        let sourceUnchanged = pixels.rgba == original
        #expect(sourceUnchanged)
    }

    @Test func emptyExclusionsKeepAdditionalDonorStorageUnallocated() throws {
        var pixels = NativeRestorationPixels(width: 64, height: 64)
        for i in 0..<pixels.count { pixels.paint(i, .init([245, 245, 245])) }
        for band in [20...26, 30...36, 40...46] { for y in band {
            for x in 12...15 { pixels.paint(y * 64 + x, .init([10, 10, 10])) }
        } }
        var options = NativeObservedRestoreOptions(); options.excludedDonorPolicy = .observedSource
        let palette = NativeRestorationPixels.Palette(foreground: .init([10, 10, 10]), background: .init([245, 245, 245]))
        let state = try #require(NativeObservedRestoreState(pixels, box: CGRect(x: 8, y: 12, width: 12, height: 36),
                                                           palette: palette, options: options))
        try #require(state.establishMask())
        #expect(state.sourceDonorBlocked == nil && state.sourceDonorForbidden == nil)
    }
}
