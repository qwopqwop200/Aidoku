import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

private final class NativeClosedBalloonExclusionBundle: NSObject {}

@Suite struct NativeClosedBalloonExclusionTests {
    private struct Fixture {
        var prepared: NativeSpatialSourceCrop.Prepared
        let item: NativeTranslationLayoutItem
        let palette: NativeRestorationPixels.Palette
        let imageSize: CGSize
    }
    private func fixture() throws -> Fixture {
        let bundle = Bundle(for: NativeClosedBalloonExclusionBundle.self)
        let url = try #require(bundle.url(forResource: "NativeClosedBalloonExclusion", withExtension: "json"))
        let pixelURL = try #require(bundle.url(forResource: "NativeClosedBalloonExclusion", withExtension: "bin"))
        let data = try Data(contentsOf: url), bytes = try Data(contentsOf: pixelURL)
        let object = try JSONSerialization.jsonObject(with: data)
        let value = try #require(object as? [String: Any])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "6748a2fb8ea4038f9a93495da0a85c1aa455abf3cbccd5d1e454965e649cefe3")
        #expect(bytes.count == 142 * 240 * 4)
        let itemObject = try #require(value["item"])
        let itemData = try JSONSerialization.data(withJSONObject: itemObject)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: itemData)
        let sample = try #require(value["palette"] as? [String: Any])
        let palette = try #require(NativeRestorationPixels.palette(sample))
        var pixels = NativeRestorationPixels(width: 142, height: 240)
        pixels.rgba = Array(bytes)
        let exclusions = [CGRect(x: -199, y: -115, width: 800, height: 1081),
            CGRect(x: 150.65598362549787, y: -111.10539591215893, width: 227.34753346555817, height: 269.31409891175014)]
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: pixels,
            crop: CGRect(x: 199, y: 115, width: 142, height: 240), source: CGRect(x: 223, y: 139, width: 94, height: 192),
            box: CGRect(x: 24, y: 24, width: 94, height: 192), auxiliary: [], excluded: exclusions, marks: [],
            leadingRule: false, sx: 1, sy: 1, synthetic: [UInt8](repeating: 0, count: 142 * 240))
        return Fixture(prepared: prepared, item: item, palette: palette, imageSize: CGSize(width: 800, height: 1142))
    }
    private func replacing(_ prepared: NativeSpatialSourceCrop.Prepared, pixels: NativeRestorationPixels? = nil,
                           excluded: [CGRect]? = nil, synthetic: [UInt8]? = nil) -> NativeSpatialSourceCrop.Prepared {
        .init(pixels: pixels ?? prepared.pixels, crop: prepared.crop, source: prepared.source, box: prepared.box,
            auxiliary: prepared.auxiliary, excluded: excluded ?? prepared.excluded, marks: prepared.marks,
            leadingRule: prepared.leadingRule, sx: prepared.sx, sy: prepared.sy, synthetic: synthetic ?? prepared.synthetic)
    }
    private func resolve(_ fixture: Fixture, pixelBudget: Int = 262_144) -> [CGRect] {
        NativeClosedBalloonExclusion.resolve(prepared: fixture.prepared, item: fixture.item,
            palette: fixture.palette, imageSize: fixture.imageSize, pixelBudget: pixelBudget)
    }

    @Test func recordedClosedBalloonResolvesOnlyItsOwnedRectangle() throws {
        let fixture = try fixture(), p = fixture.prepared
        let resolved = resolve(fixture)
        #expect(resolved != p.excluded)
        #expect(resolved.last == p.excluded.last)
        var changedProtection = 0
        for y in 0..<p.pixels.height {
            for x in 0..<p.pixels.width {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let before = p.excluded.contains { $0.contains(point) }
                let after = resolved.contains { $0.contains(point) }
                if after != (before && !p.box.contains(point)) { changedProtection += 1 }
            }
        }
        #expect(changedProtection == 0)
    }

    @Test func actualOwnedRepairStillPassesTheOriginalPixelKernelAndForeignProtection() throws {
        let fixture = try fixture(), p = fixture.prepared, resolved = resolve(fixture)
        var options = NativeObservedRestoreOptions()
        options.chromaticBalloon = true
        let polygon = [CGPoint(x: 24, y: 24), CGPoint(x: 118, y: 24),
            CGPoint(x: 118, y: 216), CGPoint(x: 24, y: 216)]
        let result = NativeRestorationPixels.restore(p.pixels, box: p.box, auxiliary: [], excluded: resolved,
            palette: fixture.palette, vertical: true, polygon: polygon, slanted: false,
            sourceOptions: options, inferredRubyExclusions: p.excluded)
        let repair = try #require(result)
        #expect(repair.sourceErasureVerified == true)
        let foreground = try #require(fixture.palette.verifiedForeground)
        let background = try #require(fixture.palette.verifiedBackground)
        var ownedInk = 0, missingOwnedInk = 0, foreignWrites = 0
        for y in 0..<p.pixels.height {
            for x in 0..<p.pixels.width {
                let index = y * p.pixels.width + x
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !p.box.contains(point), repair.rgba[index * 4 + 3] != 0 { foreignWrites += 1 }
                if p.box.contains(point), p.pixels.color(index).distance(foreground) <= 36 {
                    ownedInk += 1
                    if repair.rgba[index * 4 + 3] == 0 || repair.color(index).distance(background) > 8 { missingOwnedInk += 1 }
                }
            }
        }
        #expect(ownedInk > 0 && missingOwnedInk == 0 && foreignWrites == 0)
    }

    @Test func separateForeignCaptionInsideBalloonRetainsEveryExclusion() throws {
        var fixture = try fixture()
        let p = fixture.prepared
        fixture.prepared = replacing(p, excluded: p.excluded + [CGRect(x: 40, y: 50, width: 8, height: 12)])
        #expect(resolve(fixture) == fixture.prepared.excluded)
    }

    @Test(arguments: ["boundary", "foreign-color", "empty", "transparent"])
    func sourcePixelWitnessRejectsUnownedOrMissingInk(_ kind: String) throws {
        var fixture = try fixture()
        let p = fixture.prepared
        var pixels = p.pixels
        if kind == "empty" {
            for y in 24..<216 { for x in 24..<118 {
                let index = (y * pixels.width + x) * 4
                pixels.rgba.replaceSubrange(index..<(index + 4), with: [255,255,255,255])
            } }
        } else {
            let index = ((kind == "boundary" ? 23 : 50) * pixels.width + 50) * 4
            let color: [UInt8] = kind == "foreign-color" ? [220,20,160,255]
                : kind == "transparent" ? [255,255,255,0] : [35,24,22,255]
            pixels.rgba.replaceSubrange(index..<(index + 4), with: color)
        }
        fixture.prepared = replacing(p, pixels: pixels)
        #expect(resolve(fixture) == p.excluded)
    }


    @Test func boundingBoxDoesNotReplaceOriginalGlyphQuadOwnership() throws {
        let fixture = try fixture(), p = fixture.prepared
        let data = try JSONEncoder().encode(fixture.item)
        let object = try JSONSerialization.jsonObject(with: data)
        var payload = try #require(object as? [String: Any])
        let sourceQuad: [[Double]] = [[270, 139], [317, 235], [270, 331], [223, 235]]
        payload["sourcePolygon"] = sourceQuad.map { [$0[0] / 800, $0[1] / 1142] }
        let skewedData = try JSONSerialization.data(withJSONObject: payload)
        let skewed = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: skewedData)
        let result = NativeClosedBalloonExclusion.resolve(prepared: p, item: skewed,
            palette: fixture.palette, imageSize: fixture.imageSize)
        #expect(result == p.excluded)
    }

    @Test func malformedGeometryAndInsufficientBudgetKeepAllProtection() throws {
        var fixture = try fixture()
        #expect(resolve(fixture, pixelBudget: 142 * 240 - 1) == fixture.prepared.excluded)
        let p = fixture.prepared
        fixture.prepared = replacing(p, excluded: p.excluded + [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)])
        #expect(resolve(fixture).count == fixture.prepared.excluded.count)
        #expect(resolve(fixture).first == p.excluded.first)
    }

    @Test func malformedPixelsAndUnverifiedContourKeepAllProtection() throws {
        var fixture = try fixture()
        let p = fixture.prepared
        var pixels = p.pixels
        pixels.rgba.removeLast()
        fixture.prepared = replacing(p, pixels: pixels)
        #expect(resolve(fixture) == p.excluded)
        fixture.prepared = replacing(p, synthetic: [])
        #expect(resolve(fixture) == p.excluded)
        for marker in [UInt8(1), 2, 255] {
            var synthetic = p.synthetic
            synthetic[0] = marker
            fixture.prepared = replacing(p, synthetic: synthetic)
            #expect(resolve(fixture) == p.excluded)
        }
        let encoded = try JSONEncoder().encode(fixture.item)
        let object = try JSONSerialization.jsonObject(with: encoded)
        var payload = try #require(object as? [String: Any])
        var balloon = try #require(payload["balloonInterior"] as? [String: Any])
        balloon["contourVerified"] = false; payload["balloonInterior"] = balloon
        let unverifiedData = try JSONSerialization.data(withJSONObject: payload)
        let unverified = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: unverifiedData)
        let result = NativeClosedBalloonExclusion.resolve(prepared: p, item: unverified,
            palette: fixture.palette, imageSize: fixture.imageSize)
        #expect(result == p.excluded)
    }

    private func proof(_ fixture: Fixture) throws -> NativeClosedBalloonExclusion.Proof {
        try #require(NativeClosedBalloonExclusion.prove(prepared: fixture.prepared, item: fixture.item,
            palette: fixture.palette, imageSize: fixture.imageSize))
    }
    private func repair(_ fixture: Fixture, proof: NativeClosedBalloonExclusion.Proof) throws -> NativeRestorationPixels {
        let p = fixture.prepared
        var options = NativeObservedRestoreOptions()
        options.chromaticBalloon = true
        options.excludedDonorPolicy = .observedSource
        let polygon = [CGPoint(x: 24, y: 24), CGPoint(x: 118, y: 24),
            CGPoint(x: 118, y: 216), CGPoint(x: 24, y: 216)]
        let result = NativeRestorationPixels.restore(p.pixels, box: p.box, auxiliary: [], excluded: proof.excluded,
            palette: fixture.palette, vertical: true, polygon: polygon, slanted: false,
            sourceOptions: options, inferredRubyExclusions: p.excluded)
        return try #require(result)
    }

    @Test func recordedGrowthUsesUntouchedPaperWithoutExpandingErasure() throws {
        let fixture = try fixture(), p = fixture.prepared, proof = try proof(fixture)
        var repaired = try repair(fixture, proof: proof)
        let rgba = repaired.rgba, originalSafe = try #require(repaired.layoutSafe)
        #expect(repaired.erasureComplete && repaired.glyphsVerified && repaired.sourceErasureVerified == true)
        #expect(proof.excluded == resolve(fixture))
        // Frozen Web's six 24.5pt scalar rectangles, expanded by its existing
        // 0.1em safety margin, mapped to the immutable 142 x 240 source crop.
        let rectangles = [[1,57,49,68], [51,57,49,68], [88,57,51,68],
            [6,111,50,68], [44,111,51,68], [83,111,50,68]]
        var exterior = Set<Int>()
        for rect in rectangles {
            for y in rect[1]..<(rect[1] + rect[3]) { for x in rect[0]..<(rect[0] + rect[2]) {
                if !p.box.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    exterior.insert(y * p.pixels.width + x)
                }
            } }
        }
        #expect(exterior.count == 4_774)
        #expect(exterior.allSatisfy { originalSafe[$0] == 0 && rgba[$0 * 4 + 3] == 0 })
        #expect(proof.certifyLayout(of: &repaired) >= exterior.count)
        let safe = try #require(repaired.layoutSafe)
        #expect(exterior.allSatisfy { safe[$0] == 1 })
        #expect(repaired.rgba == rgba && repaired.erasureComplete && repaired.glyphsVerified)
        #expect(repaired.sourceErasureVerified == true && proof.excluded == resolve(fixture))
        #expect(proof.certifyLayout(of: &repaired) == 0)
        let background = try #require(fixture.palette.verifiedBackground)
        var invalidAdded = 0, foreignWrites = 0
        for y in 0..<p.pixels.height { for x in 0..<p.pixels.width {
            let index = y * p.pixels.width + x
            if safe[index] != 0 && originalSafe[index] == 0 {
                let source = p.pixels.color(index)
                if p.pixels.rgba[index * 4 + 3] != 255 || source.maximum - source.minimum > 6 ||
                    source.distance(background) > 8 || rgba[index * 4 + 3] != 0 { invalidAdded += 1 }
            }
            if !p.box.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)), rgba[index * 4 + 3] != 0 {
                foreignWrites += 1
            }
        } }
        #expect(invalidAdded == 0 && foreignWrites == 0)
    }

    @Test(arguments: ["foreign-ink", "transparent", "chromatic", "gray-paper", "foreign-caption"])
    func layoutPaperRejectsUnmeasuredOrProtectedSource(_ kind: String) throws {
        var fixture = try fixture()
        let p = fixture.prepared, index = 120 * p.pixels.width + 125
        #expect(Array(p.pixels.rgba[(index * 4)..<(index * 4 + 4)]) == [255,255,255,255])
        if kind == "foreign-caption" {
            fixture.prepared = replacing(p, excluded: p.excluded + [CGRect(x: 122, y: 116, width: 8, height: 8)])
        } else {
            var pixels = p.pixels
            let values: [String: [UInt8]] = ["foreign-ink": [35,24,22,255], "transparent": [255,255,255,0],
                "chromatic": [220,20,160,255], "gray-paper": [230,230,230,255]]
            let color = try #require(values[kind])
            pixels.rgba.replaceSubrange((index * 4)..<(index * 4 + 4), with: color)
            fixture.prepared = replacing(p, pixels: pixels)
        }
        let proof = try proof(fixture)
        var repaired = try repair(fixture, proof: proof)
        let rgba = repaired.rgba
        #expect(repaired.sourceErasureVerified == true)
        #expect(proof.certifyLayout(of: &repaired) > 0)
        let safe = try #require(repaired.layoutSafe)
        #expect(safe[index] == 0 && repaired.rgba == rgba && rgba[index * 4 + 3] == 0)
        #expect(safe[120 * p.pixels.width + 120] == 1)
        #expect(proof.excluded == resolve(fixture))
    }

    @Test func verifiedContourStillBoundsIndependentLayoutPaper() throws {
        let original = try fixture(), p = original.prepared
        let encoded = try JSONEncoder().encode(original.item)
        let object = try JSONSerialization.jsonObject(with: encoded)
        var payload = try #require(object as? [String: Any])
        var balloon = try #require(payload["balloonInterior"] as? [String: Any])
        let rect = try #require(balloon["rect"] as? [Double])
        var spans = try #require(balloon["spans"] as? [Double])
        let y = (120.5 + Double(p.crop.minY)) / Double(original.imageSize.height)
        let band = Int(floor((y - rect[1]) / rect[3] * Double(spans.count / 2)))
        // Retain the original glyph rectangle and its full paper moat; exclude
        // the white point at x125 by a measured span, not by a source-color rule.
        spans[band * 2 + 1] = (Double(p.crop.minX) + 119) / Double(original.imageSize.width)
        balloon["spans"] = spans; payload["balloonInterior"] = balloon
        let data = try JSONSerialization.data(withJSONObject: payload)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
        let changed = Fixture(prepared: p, item: item, palette: original.palette, imageSize: original.imageSize)
        let proof = try proof(changed)
        var repaired = try repair(changed, proof: proof)
        let rgba = repaired.rgba
        #expect(proof.certifyLayout(of: &repaired) > 0)
        let safe = try #require(repaired.layoutSafe)
        #expect(safe[120 * p.pixels.width + 125] == 0)
        #expect(safe[120 * p.pixels.width + 118] == 1)
        #expect(repaired.rgba == rgba && proof.excluded == resolve(original))
    }

    @Test func uncertifiedMalformedAndOverBudgetRepairsCannotGainLayoutRoom() throws {
        let fixture = try fixture(), proof = try proof(fixture), original = try repair(fixture, proof: proof)
        for kind in ["erasure", "glyph", "source", "budget", "mask", "pixels"] {
            var repaired = original
            switch kind {
            case "erasure": repaired.erasureComplete = false
            case "glyph": repaired.glyphsVerified = false
            case "source": repaired.sourceErasureVerified = false
            case "mask": repaired.layoutSafe?.removeLast()
            case "pixels": repaired.rgba.removeLast()
            default: break
            }
            let safe = repaired.layoutSafe, rgba = repaired.rgba
            let budget = kind == "budget" ? repaired.count - 1 : 262_144
            #expect(proof.certifyLayout(of: &repaired, pixelBudget: budget) == 0)
            #expect(repaired.layoutSafe == safe && repaired.rgba == rgba)
        }
    }
}
