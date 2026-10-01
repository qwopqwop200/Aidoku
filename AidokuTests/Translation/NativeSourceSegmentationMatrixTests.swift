import Foundation
import Testing
@testable import Aidoku

/// All 147 cases and original thresholds from source-inpainting-segmentation.cjs.
/// The archive contains immutable original records; only one is inflated per trial.
@Suite(.serialized)
struct NativeSourceSegmentationMatrixTests {
    private typealias F = NativeSourceRestorationMatrixFixtures

    @Test(arguments: 0..<120)
    func groundTruthInkAndBackground(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("source-inpainting-segmentation", index, count: 120)
            let page = try f.pixels(), original = page.rgba, clean = try f.raw("clean"), labels = try f.raw("labels")
            #expect(F.hash(Data(original)) == f.values["pixelSHA256"] as? String, "\(f.id)")
            let budget = NativeSourceColorSamplingStage.Budget(pixels: 393_216, detailPixels: 98_304)
            let (_, palette) = try F.sampler(page, bounds: F.bounds(f), budget: budget)
            let color = palette.flatMap { NativeObservedSourcePalette.sourceDisplayInk(sample: $0) }
            let foreground = F.numbers(f.values["foreground"])
            let colorError = color.map { zip($0, foreground).map { abs($0 - $1) }.max() ?? 255 } ?? 255
            let output = F.restore(page, fixture: f, palette: palette)
            var ink = 0, erased = 0, error = 0, outside = 0, outsideError = 0, paintedBorder = 0
            for i in 0..<page.count {
                let painted = output?.rgba[i * 4 + 3] == 255
                if labels[i] >= 32 && F.delta(original, clean, i) >= 12 {
                    ink += 1
                    if painted { erased += 1 }
                    let actual = painted ? output!.rgba : original
                    for c in 0..<3 { error += abs(Int(actual[i * 4 + c]) - Int(clean[i * 4 + c])) }
                }
                if painted && labels[i] == 0 {
                    outside += 1
                    for c in 0..<3 { outsideError += abs(Int(output!.rgba[i * 4 + c]) - Int(clean[i * 4 + c])) }
                }
                let x = i % page.width, y = i / page.width
                if painted && (x < 8 || y < 8 || x >= page.width - 8 || y >= page.height - 8) { paintedBorder += 1 }
            }
            #expect(colorError <= 25, "\(f.id): color error \(colorError)")
            #expect(ink > 0)
            #expect(Double(erased) / Double(ink) >= 0.99, "\(f.id): ink coverage \(erased)/\(ink)")
            #expect(Double(error) / Double(ink * 3) <= 5, "\(f.id): background error")
            #expect(Double(outsideError) / Double(max(1, outside * 3)) <= 2, "\(f.id): outside background error")
            #expect(paintedBorder == 0, "\(f.id): crop boundary")
            #expect(page.rgba == original)
            #expect(F.hash(Data(page.rgba)) == f.values["pixelSHA256"] as? String)
            #expect(budget.pixels >= 0 && budget.detailPixels >= 0)
        }
    }

    @Test(arguments: 0..<7)
    func independentOwnedInkSurvivesDisplayRoleRejection(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("source-inpainting-owned-ink", index, count: 7)
            let page = try f.pixels(), original = page.rgba
            let (_, actual) = try F.sampler(page, bounds: F.bounds(f))
            let evidence = try #require(actual?["sourceInk"] as? F.Payload, "\(f.id): independent evidence")
            #expect(evidence["foreground"] != nil && evidence["background"] != nil)
            #expect(F.restore(page, fixture: f, palette: actual) != nil, "\(f.id): integrated sampler restoration")
            var palette = try #require(f.values["displayPalette"] as? F.Payload)
            let source = try #require(f.values["sourceInk"] as? F.Payload)
            palette["sourceInk"] = source
            let serialized = try JSONSerialization.data(withJSONObject: palette, options: .sortedKeys)
            let output = try #require(F.restore(page, fixture: f, palette: palette), "\(f.id)")
            let reference = try #require(F.restore(page, fixture: f, palette: source), "\(f.id)")
            #expect(output.rgba == reference.rgba, "\(f.id): same independently validated mask and background")
            #expect(try JSONSerialization.data(withJSONObject: palette, options: .sortedKeys) == serialized)
            #expect(page.rgba == original)
        }
    }

    @Test(arguments: 0..<6)
    func reviewedArtGuards(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("source-inpainting-art-guard", index, count: 6)
            let page = try f.pixels(), original = page.rgba
            let expected = try #require(f.values["expectAccepted"] as? Bool)
            let result = F.restore(page, fixture: f, palette: f.values["palette"] as? F.Payload)
            #expect((result != nil) == expected, "\(f.id): reviewed artwork admission")
            let protected = f.values["protectedPixels"] as? [Int] ?? []
            if !protected.isEmpty {
                let output = try #require(result, "\(f.id): protected contour requires an accepted result")
                #expect(protected.allSatisfy { output.rgba[$0 * 4 + 3] == 0 }, "\(f.id): balloon contour")
            }
            #expect(page.rgba == original)
        }
    }

    @Test func nativeWidthGradientFringe() throws {
        try autoreleasepool {
            let f = try F.load("source-inpainting-gradient-fringe", 0, count: 1)
            let page = try f.pixels(), original = page.rgba
            let output = try #require(F.restore(page, fixture: f, palette: f.values["palette"] as? F.Payload))
            let probes = try #require(f.values["probes"] as? [F.Payload]), tolerance = F.number(f.values["tolerance"])
            for probe in probes {
                let p = try #require(probe["pixel"] as? [Int]), r = try #require(probe["reference"] as? [Int])
                let i = p[1] * page.width + p[0], j = r[1] * page.width + r[0]
                #expect(output.rgba[i * 4 + 3] == 255, "Source fringe is covered")
                for c in 0..<3 {
                    #expect(abs(Double(output.rgba[i * 4 + c]) - Double(original[j * 4 + c])) <= tolerance,
                        "Source halo does not lighten the reconstructed sky")
                }
            }
            #expect(page.rgba == original)
        }
    }

    @Test(arguments: 0..<13)
    func expandedEnvironmentColorsAndSurface(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("source-inpainting-expanded-environments", index, count: 13)
            let page = try f.pixels(), original = page.rgba
            #expect(F.hash(Data(original)) == f.values["pixelSHA256"] as? String)
            let budget = NativeSourceColorSamplingStage.Budget(pixels: 393_216, detailPixels: 98_304)
            // Preserve the original reviewed color labels and original area
            // filter. NativeSourceSamplingContractCapture separately checks the
            // actual iOS Canvas/native transport on the same immutable source.
            let (sampler, palette) = try F.sampler(page, bounds: F.bounds(f), budget: budget, sampling: .areaCoverage)
            if f.values["expectedColor"] != nil {
                let color = try #require(palette.flatMap { NativeObservedSourcePalette.sourceDisplayInk(sample: $0) }, "\(f.id)")
                let expected = F.numbers(f.values["expectedColor"]), tolerance = F.number(f.values["colorTolerance"])
                #expect(color.count == 3 && expected.count == 3)
                let colorMatches = zip(color, expected).allSatisfy { abs($0 - $1) <= tolerance }
                #expect(colorMatches, "\(f.id): source color=\(color), reference=\(expected), tolerance=\(tolerance)")
            }
            if let expected = f.values["expectAccepted"] as? Bool {
                let output = F.restore(page, fixture: f, palette: palette)
                #expect((output != nil) == expected, "\(f.id): reviewed surface admission")
                if let reason = f.values["expectedSurface"] as? String {
                    #expect(output?.surfaceQuality?["reason"] as? String == reason, "\(f.id): pattern must not become a flat fill")
                }
                let protected = f.values["protectedPixels"] as? [Int] ?? []
                #expect(protected.allSatisfy { (output?.rgba[$0 * 4 + 3] ?? 0) == 0 }, "\(f.id): original contour")
            }
            #expect(page.rgba == original)
            #expect(budget.pixels >= 0 && budget.detailPixels >= 0 && sampler.stats.pixels <= 393_216)
        }
    }
}
