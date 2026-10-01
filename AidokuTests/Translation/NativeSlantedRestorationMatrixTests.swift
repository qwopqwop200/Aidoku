import Foundation
import Testing
@testable import Aidoku

/// Full artwork (44), ruby (202), dense (4) and outline (2) matrices.
/// Every count/threshold is from the unchanged historical quality scripts.
@Suite(.serialized)
struct NativeSlantedRestorationMatrixTests {
    private typealias F = NativeSourceRestorationMatrixFixtures

    @Test func convexPenetrationControls() {
        func card(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ angle: Double = 0) -> [[Double]] {
            NativeSlantedGeometry.rotatedCard(cx: x, cy: y, width: w, height: h, angle: angle)
        }
        let obstacle = card(50, 50, 100, 100), near = card(3, 50, 4, 4), deep = card(50, 50, 4, 4)
        #expect(NativeSlantedGeometry.convexDepth(near, obstacle) == 5)
        #expect(NativeSlantedGeometry.convexDepth(deep, obstacle) == 52)
        #expect(NativeSlantedGeometry.convexDepth(obstacle, deep) == 52)
        #expect(NativeSlantedGeometry.convexDepth(card(102, 50, 4, 4), obstacle) == 0)
        #expect(NativeSlantedGeometry.convexDepth(card(104, 50, 4, 4), obstacle) == 0)
        #expect(abs(NativeSlantedGeometry.convexDepth(card(50, 50, 100, 100, 0.7), card(50, 50, 4, 4, 0.7)) - 52) < 1e-9)
    }

    @Test(arguments: [-80.0, -55, -20, 20, 55, 80], [false, true])
    func syntheticSlantedInkPreservesCrossingRule(_ degrees: Double, _ colored: Bool) throws {
        try autoreleasepool {
            let bg: [UInt8] = colored ? [244, 176, 65] : [255, 255, 255]
            let fg: [UInt8] = colored ? [255, 255, 249] : [12, 12, 12]
            let angle = degrees * .pi / 180, cosine = cos(angle), sine = sin(angle)
            var page = NativeRestorationPixels(width: 320, height: 320), clean = page.rgba, ink: [Int] = [], art: [Int] = []
            for y in 0..<320 { for x in 0..<320 {
                let dx = Double(x) + 0.5 - 160, dy = Double(y) + 0.5 - 160
                let u = dx * cosine + dy * sine, v = -dx * sine + dy * cosine
                let border = abs(v - 27) < 1.5 && abs(u) < 145
                var letter = false
                for k in 0..<5 {
                    let gx = u - Double(-112 + k * 45)
                    if gx >= 0 && gx < 24 && v >= -20 && v < 18 && (gx < 5 || gx >= 19 || abs(v) < 3) { letter = true }
                }
                let i = y * 320 + x, backing = border ? fg : bg, color = letter ? fg : backing
                for c in 0..<3 { clean[i * 4 + c] = backing[c]; page.rgba[i * 4 + c] = color[c] }
                clean[i * 4 + 3] = 255; page.rgba[i * 4 + 3] = 255
                if letter { ink.append(i) }; if border { art.append(i) }
            } }
            let original = page.rgba
            let palette = NativeRestorationPixels.palette(["foreground": fg.map(Int.init), "background": bg.map(Int.init),
                "confidence": ["foreground": 1.0]])
            let result = try #require(NativeSlantedRestoration.restore(page, box: [30, 130, 260, 60], angle: angle,
                palette: palette, vertical: false))
            var residual = 0, error = 0
            for i in ink {
                let painted = result.pixels.rgba[i * 4 + 3] != 0
                if !painted { residual += 1 }
                let actual = painted ? result.pixels.rgba : original
                for c in 0..<3 { error += abs(Int(actual[i * 4 + c]) - Int(clean[i * 4 + c])) }
            }
            #expect(Double(residual) / Double(ink.count) < 0.01)
            #expect(Double(error) / Double(ink.count * 3) < 4)
            #expect(art.allSatisfy { result.pixels.rgba[$0 * 4 + 3] == 0 }, "Crossing illustration rule cannot receive paint")
            #expect(page.rgba == original)
        }
    }

    @Test func invalidAndOverBudgetSlantedGeometry() {
        let large = NativeRestorationPixels(width: 513, height: 513)
        #expect(NativeSlantedRestoration.restore(large, box: [10, 10, 100, 50], angle: 0.3, palette: nil) == nil)
        let small = NativeRestorationPixels(width: 5, height: 5)
        #expect(NativeSlantedRestoration.restore(small, box: [0, 0, .nan, 5], angle: 0.3, palette: nil) == nil)
    }

    @Test func glyphFootprintAndContrastControls() {
        var proof = NativeSlantedRestoration.ProofRaster(width: 50, height: 50, box: [5, 5, 40, 40],
            safe: [UInt8](repeating: 1, count: 2_500), luminance: [UInt8](repeating: 255, count: 2_500), auxiliary: [])
        var audit = NativeSlantedInkSafety.Audit()
        #expect(NativeSlantedInkSafety.inkFits(proof: proof, rects: [[5, 5, 20, 20]], scale: 1, foreground: [10, 10, 10], audit: &audit))
        proof.safe[12 * 50 + 11] = 0
        #expect(!NativeSlantedInkSafety.inkFits(proof: proof, rects: [[5, 5, 20, 20]], scale: 1, foreground: [10, 10, 10], audit: &audit))
        #expect(!NativeSlantedInkSafety.inkFits(proof: proof, rects: [[22, 22, 30, 30]], scale: 1, foreground: [250, 250, 250], audit: &audit))
    }

    private func samplingBounds(_ f: F.Fixture) -> [Double] {
        if let bounds = f.values["bounds"] { return F.numbers(bounds) }
        let box = F.numbers(f.values["box"]), angle = F.number(f.values["angle"])
        let c = cos(angle), s = sin(angle), cx = box[0] + box[2] / 2, cy = box[1] + box[3] / 2
        let points = [[-1.0, -1.0], [1, -1], [1, 1], [-1, 1]].map { p in
            [cx + p[0] * box[2] / 2 * c - p[1] * box[3] / 2 * s,
             cy + p[0] * box[2] / 2 * s + p[1] * box[3] / 2 * c]
        }
        let left = max(0, points.map { $0[0] }.min()!), top = max(0, points.map { $0[1] }.min()!)
        let right = min(Double(f.width), points.map { $0[0] }.max()!), bottom = min(Double(f.height), points.map { $0[1] }.max()!)
        return [left / Double(f.width), top / Double(f.height), (right - left) / Double(f.width), (bottom - top) / Double(f.height)]
    }

    @Test(arguments: 0..<24)
    func realArtworkHasNoDamageOrMissingOwnedInk(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("slanted-artwork-pixels", index, count: 24)
            let page = try f.pixels(), original = page.rgba, ink = try f.raw("ink"), protected = try f.raw("protected")
            let (_, palette) = try F.sampler(page, bounds: samplingBounds(f))
            let output = try #require(F.slanted(page, fixture: f, palette: palette), "\(f.id): recoverable lettering must apply").pixels
            var inkCount = 0, remaining = 0, protectedCount = 0, changed = 0
            for i in 0..<page.count {
                let delta = F.delta(output.rgba, original, i)
                if ink[i] != 0 { inkCount += 1; if output.rgba[i * 4 + 3] < 250 || delta < 5 { remaining += 1 } }
                if protected[i] != 0 {
                    protectedCount += 1
                    if output.rgba[i * 4 + 3] != 0 && delta > 3 { changed += 1 }
                }
            }
            #expect(inkCount > 50 && protectedCount > 1_000, "\(f.id): independent masks")
            #expect(Double(remaining) / Double(inkCount) <= 0.005, "\(f.id): remaining annotated ink \(remaining)/\(inkCount)")
            #expect(changed == 0, "\(f.id): protected illustration changed in \(changed) pixels")
            #expect(page.rgba == original)
        }
    }

    @Test(arguments: 0..<5)
    func unsupportedBackingRetainsSource(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("slanted-artwork-rejections", index, count: 5), page = try f.pixels(), original = page.rgba
            let (_, palette) = try F.sampler(page, bounds: samplingBounds(f))
            let result = F.slanted(page, fixture: f, palette: palette)
            let rejected = result == nil
            let method = result?.pixels.method ?? "none"
            let painted = result?.pixels.paintedCount ?? 0
            #expect(rejected, "\(f.id): reviewed rejection; method=\(method), painted=\(painted)")
            #expect(page.rgba == original)
        }
    }

    @Test func allTwoHundredRubyCapturesAndAggregateAcceptance() throws {
        var accepted = 0, retained = 0
        for index in 0..<200 {
            let applied = try autoreleasepool {
                let f = try F.load("slanted-ruby-pixels", index, count: 200), page = try f.pixels(), original = page.rgba
                let palette = try #require(f.values["palette"] as? F.Payload), background = F.numbers(palette["background"])
                let result = F.slanted(page, fixture: f, palette: palette)
                #expect(page.rgba == original, "\(f.id): immutable original")
                guard let output = result?.pixels else {
                    #expect(f.values["sourceName"] as? String == "comic-0474", "\(f.id): reviewed clear lettering must apply")
                    return false
                }
                let ink = try f.raw("ink"), ruby = try f.raw("ruby"), protected = try f.raw("protected")
                var count = 0, left = 0, rubyCount = 0, rubyLeft = 0, art = 0, changed = 0, backgroundError = 0.0
                for i in 0..<page.count {
                    let delta = F.delta(output.rgba, original, i), erased = output.rgba[i * 4 + 3] >= 250 && delta > 10
                    let visible = (0..<3).map { abs(background[$0] - Double(original[i * 4 + $0])) }.max()! > 24
                    if ink[i] != 0 && visible {
                        count += 1; if !erased { left += 1 }
                        if f.values["synthetic"] as? Bool == true {
                            let actual = output.rgba[i * 4 + 3] != 0 ? output.rgba : original
                            for c in 0..<3 { backgroundError += abs(Double(actual[i * 4 + c]) - background[c]) }
                        }
                    }
                    if ruby[i] != 0 && visible { rubyCount += 1; if !erased { rubyLeft += 1 } }
                    if protected[i] != 0 { art += 1; if output.rgba[i * 4 + 3] != 0 && delta > 3 { changed += 1 } }
                }
                #expect(count > 20 && rubyCount > 0 && art > 1_000, "\(f.id): independent masks")
                #expect(changed == 0, "\(f.id): protected drawing changed \(changed)")
                #expect(left == 0, "\(f.id): source residue \(left)/\(count)")
                #expect(rubyLeft == 0, "\(f.id): ruby residue \(rubyLeft)/\(rubyCount)")
                if f.values["synthetic"] as? Bool == true { #expect(backgroundError / Double(count * 3) <= 3, "\(f.id): clean background") }
                return true
            }
            if applied { accepted += 1 } else { retained += 1 }
        }
        #expect(accepted >= 197, "Accepted \(accepted) of 200 immutable ruby fixtures")
        #expect(retained <= 3)
    }

    @Test func inferredRubyCannotClaimNeighborOwnership() throws {
        try autoreleasepool {
            let f = try F.load("slanted-ruby-pixels", 76, count: 200)
            #expect(f.values["id"] as? String == "ruby-07-+25")
            let page = try f.pixels(), original = page.rgba, mask = try f.raw("ruby")
            var options = NativeSlantedGeometry.Options()
            options.inferRuby = true
            options.inferredRubyExclusions = (f.values["referenceRuby"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []
            let result = try #require(NativeSlantedRestoration.restore(page, box: F.numbers(f.values["box"]),
                angle: F.number(f.values["angle"]), palette: (f.values["palette"] as? F.Payload).flatMap(NativeRestorationPixels.palette),
                vertical: true, options: options))
            #expect(result.proof.auxiliary.isEmpty)
            let surviving = (0..<page.count).filter { mask[$0] != 0 && result.pixels.rgba[$0 * 4 + 3] == 0 }.count
            #expect(surviving > 50, "Neighbor lettering must survive missing-ruby inference")
            #expect(page.rgba == original)
        }
    }

    @Test func obliqueRubyUsesRetainedOCRQuad() throws {
        let f = try F.load("slanted-ruby-pixels", 197, count: 200)
        #expect(f.values["id"] as? String == "ruby-19-+45")
        let geometry = NativeSlantedGeometry.localGeometry(box: F.numbers(f.values["box"]), angle: F.number(f.values["angle"]),
            vertical: true, options: F.slantedOptions(f))
        let first = try #require(geometry.auxiliary.first)
        #expect(abs(first[2] - 15) < 0.001 && abs(first[3] - 45) < 0.001)
    }

    @Test(arguments: 0..<4)
    func denseRecoveryPreservesReviewedOwnedFootprint(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("slanted-dense-recovery-guard", index, count: 4), page = try f.pixels(), original = page.rgba
            let expected = try #require(f.values["expectedRestored"] as? Bool)
            let output = F.slanted(page, fixture: f, palette: f.values["palette"] as? F.Payload)
            #expect((output != nil) == expected, "\(f.id): dense masks cannot recruit neighbor lettering")
            if let output {
                #expect(output.pixels.method == f.values["expectedMethod"] as? String, "\(f.id): established restoration method")
                try NativeSlantedSourceSemanticAnnotations.verifyDenseLogo(original: original, restored: output.pixels.rgba)
                #expect(!output.proof.safe.isEmpty && !output.proof.luminance.isEmpty)
            }
            #expect(page.rgba == original)
        }
    }

    @Test(arguments: 0..<2)
    func nativeOutlineCapturesRemoveWholeSilhouette(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("slanted-native-outlines", index, count: 2), page = try f.pixels(), original = page.rgba
            #expect(F.hash(Data(original)) == f.values["sha256"] as? String)
            let output = try #require(F.slanted(page, fixture: f, palette: f.values["palette"] as? F.Payload), "\(f.id)").pixels
            try NativeSlantedOutlineSemanticAnnotations.verify(index, original: original, restored: output.rgba)
            var paintedBoundary = 0
            for y in 0..<page.height { for x in 0..<page.width where x < 2 || y < 2 || x >= page.width - 2 || y >= page.height - 2 {
                if output.rgba[(y * page.width + x) * 4 + 3] != 0 { paintedBoundary += 1 }
            } }
            #expect(paintedBoundary == 0, "\(f.id): retain crop boundary")
            #expect(page.rgba == original)
        }
    }
}
