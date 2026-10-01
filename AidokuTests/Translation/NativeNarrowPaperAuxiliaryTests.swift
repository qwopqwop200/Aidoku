import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

private final class NativeNarrowPaperAuxiliaryFixtureBundle: NSObject {}

@Suite(.serialized)
@MainActor
struct NativeNarrowPaperAuxiliaryTests {
    private let box = CGRect(x: 24, y: 23.865420560747665, width: 33, height: 84.52336448598132)
    private let duplicate = CGRect(x: 33.20772058823525, y: 33.29863876472979, width: 15.735294117647072, height: 68.33341121495326)

    private func source() throws -> NativeRestorationPixels {
        let bundle = Bundle(for: NativeNarrowPaperAuxiliaryFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "SmallBalloonRestorationOriginal", withExtension: "bin"))
        let image = try #require(UIImage(data: Data(contentsOf: url))?.cgImage)
        let reader = NativeSourcePixelReader(image: image)
        defer { reader.release() }
        var pixels = NativeRestorationPixels(width: 81, height: 133)
        pixels.rgba = try reader.read(x: 965, y: 92, sourceWidth: 81, sourceHeight: 133.75, width: 81, height: 133)
        try #require(SHA256.hash(data: Data(pixels.rgba)).map { String(format: "%02x", $0) }.joined() == "b4bfb6e29a1e4090bcdc2a7d88e2597f5c25b69aa21f7c9f7ead92fe7b02f18a")
        return pixels
    }

    private func options(auxiliary: [CGRect]) throws -> NativeObservedRestoreOptions {
        var options = NativeObservedRestoreOptions()
        options.vertical = true
        options.auxiliary = auxiliary
        options.excluded = [CGRect(x: -6, y: 59.663551401869164, width: 41, height: 108.38878504672898)]
        let quad = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let ownership: NativeObservedGlyphOwnership = try #require(NativeObservedGlyphOwnership.make(width: 81, height: 133,
            box: box, polygon: quad, auxiliary: auxiliary))
        options.glyphOwnership = ownership
        return options
    }

    @Test func duplicateBodyAuxiliaryRetainsObservedLetteringAndEntireBalloonContour() throws {
        let original = try source(), options = try options(auxiliary: [duplicate])
        let repaired = try #require(NativeRestorationPixels.narrowPaperGlyphs(original, box: box, palette: nil, options: options))
        let baseline = try #require(NativeRestorationPixels.narrowPaperGlyphs(original, box: box, palette: nil,
            options: try self.options(auxiliary: [])))
        let matchesIndependentBodyRepair = repaired.rgba == baseline.rgba && repaired.layoutSafe == baseline.layoutSafe
        #expect(matchesIndependentBodyRepair)
        #expect(repaired.erasureComplete && repaired.glyphsVerified && repaired.sourceErasureVerified == true)
        // Reviewed source-only component rectangles: チ, long mark, and three dots.
        // Every other non-paper pixel includes balloon rims and neighboring text.
        let letters = [CGRect(x: 31, y: 34, width: 20, height: 20), CGRect(x: 38, y: 58, width: 5, height: 20),
                       CGRect(x: 38, y: 82, width: 5, height: 6), CGRect(x: 38, y: 90, width: 5, height: 5),
                       CGRect(x: 38, y: 98, width: 5, height: 6)]
        var owned = 0, protected = 0
        for i in 0..<original.count where original.color(i).minimum < 230 {
            if letters.contains(where: { $0.contains(CGPoint(x: i % original.width, y: i / original.width)) }) {
                owned += 1
                #expect(repaired.rgba[i * 4 + 3] == 255 && repaired.color(i).minimum >= 248)
            } else {
                protected += 1
                #expect(repaired.rgba[i * 4 + 3] == 0, "No balloon contour or neighboring ink may be painted")
            }
        }
        #expect(owned == 313 && protected > 673)
        let sourceUnchanged = original.rgba == (try source()).rgba
        #expect(sourceUnchanged)
    }

    @Test(arguments: ["external", "bbox-only", "unresolved", "frame", "missing-quad", "stale-auxiliary"])
    func unprovenAuxiliaryStillRejects(_ condition: String) throws {
        var original = try source()
        var options = try options(auxiliary: [duplicate])
        switch condition {
        case "external": options = try self.options(auxiliary: [CGRect(x: 5, y: 85, width: 8, height: 8)])
        case "bbox-only":
            options.auxiliary = [CGRect(x: 25, y: 99, width: 3, height: 4)]
            let ownership: NativeObservedGlyphOwnership = try #require(NativeObservedGlyphOwnership.make(width: 81, height: 133, box: box,
                polygon: [CGPoint(x: 24, y: box.minY), CGPoint(x: 40, y: box.minY),
                          CGPoint(x: 57, y: box.maxY), CGPoint(x: 41, y: box.maxY)], auxiliary: options.auxiliary))
            #expect(!ownership.certifiesRedundantAuxiliary(options.auxiliary))
            options.glyphOwnership = ownership
        case "unresolved":
            for y in 70..<73 { for x in 34..<36 { original.paint(y * original.width + x, .init([180, 180, 180])) } }
        case "frame":
            for y in 30..<106 { for x in 34..<36 { original.paint(y * original.width + x, .init([20, 20, 20])) } }
        case "missing-quad": options.glyphOwnership = nil
        case "stale-auxiliary": options.auxiliary = [CGRect(x: 5, y: 85, width: 8, height: 8)]
        default: break
        }
        let input = original.rgba
        #expect(NativeRestorationPixels.narrowPaperGlyphs(original, box: box, palette: nil, options: options) == nil)
        let sourceUnchanged = original.rgba == input
        #expect(sourceUnchanged)
    }
}
