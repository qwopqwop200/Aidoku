import CoreGraphics
import Foundation

// Focused standalone compilation excludes the shared builder's entire producer
// graph. This shim is ONLY its four-field data carrier, not a mask algorithm.
// The adapter, factory raster/DB restore, RF contract, source decoder and opacity
// verifier below are the real production sources. Do not define this flag in app.
#if OWNED_GLYPH_ADAPTER_STANDALONE
enum NativeMainAOTRemovalMaskBuilder {
    struct SourceProbability {
        let original: CGImage
        let width: Int
        let height: Int
        let values: [Float]
    }
}
#endif

@main enum NativeOwnedGlyphRFBoundaryAdapterTests {
    typealias Adapter = NativeOwnedGlyphRFBoundaryAdapter
    typealias Caller = NativeMainRemovalSourceFactory.NativeCurrentMaskCaller
    typealias Probability = NativeMainAOTRemovalMaskBuilder.SourceProbability

    static func image(alpha: UInt8 = 255) -> CGImage {
        let w = 128, h = 96
        var rgba = [UInt8](repeating: 220, count: w * h * 4)
        for k in 0..<w * h { rgba[k * 4 + 3] = 255 }
        for y in 44..<56 { for x in 74..<78 {
            let k = y * w + x
            for c in 0..<3 { rgba[k * 4 + c] = 20 }
        } }
        // This pixel is within the padded ROI but outside the glyph.
        rgba[(40 * w + 70) * 4 + 3] = alpha
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func region(classID: Int = 0, query: Int = 7, confidence: Double = 0.9,
                       bounds: CGRect = CGRect(x: 0.5, y: 0.35, width: 0.25, height: 0.4)) -> Ensemble100RFRegion {
        .init(queryID: query, classID: classID, confidence: confidence, bounds: bounds, exterior: [], holes: [])
    }

    struct Fixture {
        let original: CGImage
        var source: Caller.Source
        var owners: [Caller.Owner]
        var mask = [UInt8](repeating: 0, count: 128 * 96)
        var hard = [UInt8](repeating: 0, count: 128 * 96)
        var balloon = [UInt8](repeating: 0, count: 128 * 96)
        var probability: Probability?
        var regions = [region()]
        var records: [[String: Any]] = [["index": 0, "fontAuthority": "explicit-original-pixel-source-measurement"]]
        var factoryAudit: [String: Any] = ["base": [["owner": "owned-column", "backgroundRGB": [220.0, 220, 220]]]]

        init(alpha: UInt8 = 255) throws {
            original = image(alpha: alpha)
            let decoded = try NativeRFDETRSourceImage.decode(original)
            source = .init(width: decoded.width, height: decoded.height, rgb: Array(decoded.rgb), revision: decoded.identity)
            owners = [.init(id: "owned-column", polygon: [CGPoint(x: 66, y: 36), CGPoint(x: 88, y: 36),
                CGPoint(x: 88, y: 68), CGPoint(x: 66, y: 68)], fontPixels: 16, translated: true, balloon: true)]
            var values = [Float](repeating: 0, count: 128 * 96)
            for y in 44..<56 { for x in 74..<78 {
                let k = y * 128 + x
                mask[k] = 1; values[k] = 0.9
                if x == 75 { balloon[k] = 1 }
            } }
            probability = .init(original: original, width: 128, height: 96, values: values)
        }

        func run(enabled: Bool = true) throws -> Adapter.Result {
            try Adapter.evaluate(source: source, owners: owners, factoryMask: mask, factoryAudit: factoryAudit,
                records: records, rfRegions: regions, original: original, probability: probability,
                hardProtection: hard, balloonBoundary: balloon, enabled: enabled)
        }
    }

    static func main() throws {
        let fixture = try Fixture()
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejected(_ edit: (inout Fixture) -> Void) throws -> Bool {
            var test = fixture
            edit(&test)
            return try test.run().pageExemptions.isEmpty
        }
        let accepted = try fixture.run()
        let expected = Set((44..<56).map { $0 * 128 + 75 })
        check(accepted.pageExemptions == expected, "nonzero ROI offset maps exact original page indices")
        let owners = accepted.audit["owners"] as! [[String: Any]]
        check(owners[0]["roi"] as? [Int] == [52, 22, 50, 60], "bounded padded complete ROI")
        check(owners[0]["rfTextQuery"] as? Int == 7, "actual class0 RF query binding")
        check(accepted.audit["roiWorkPixels"] as? Int == 3000, "ROI work audit")
        check(accepted.pageExemptions.allSatisfy { fixture.mask[$0] != 0 && fixture.hard[$0] == 0 }, "factory/keepout invariant")
        check(try fixture.run(enabled: false).pageExemptions.isEmpty, "default flag can disable bridge")
        check(try rejected { $0.regions = [region(classID: 1)] }, "SFX1 is not TEXT canonical1")
        check(try rejected { $0.regions = [region(classID: 2)] }, "balloon body never text authority")
        check(try rejected { $0.regions = [region(classID: 3)] }, "frame never text authority")
        check(try rejected { $0.regions.append(region(query: 8)) }, "two RF query nominations abstain")
        check(try rejected { $0.regions.append(region()) }, "duplicate-query nominations abstain")
        check(try rejected { $0.regions = [region(confidence: .nan)] }, "nonfinite RF confidence")
        check(try rejected { $0.regions = [region(confidence: 0.54)] }, "weak RF nomination")
        check(try rejected { $0.regions = [region(bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))] }, "no owner overlap")
        check(try rejected { $0.regions = [region(bounds: CGRect(x: 0.5, y: 0.35, width: 2, height: 0.4))] }, "invalid normalized RF geometry")
        check(try rejected { $0.hard[44 * 128 + 75] = 1 }, "independent hard/RF overlap veto")
        check(try rejected { $0.mask = [UInt8](repeating: 0, count: 128 * 96) }, "RF bounds cannot generate erasure")
        check(try rejected { $0.probability = nil }, "missing DB retains base")
        let otherImage = image()
        check(try rejected { test in
            test.probability = .init(original: otherImage, width: 128, height: 96, values: test.probability!.values)
        }, "identical pixels with different CG provenance abstain")
        check(try rejected { test in
            test.probability = .init(original: test.original, width: Int.max, height: 2, values: [])
        }, "malformed probability dimensions cannot overflow")
        check(try rejected { test in
            var values = test.probability!.values; values[0] = .nan
            test.probability = .init(original: test.original, width: 128, height: 96, values: values)
        }, "invalid DB rejected before sampling")
        check(try rejected { $0.records[0]["fontAuthority"] = "source-extent-fallback-not-measured-font" }, "fallback font has no authority")
        check(try rejected { $0.records[0]["index"] = 1 }, "record must match owner index")
        check(try rejected { $0.factoryAudit = [:] }, "missing source palette")
        check(try rejected { $0.factoryAudit = ["base": [["owner": "foreign", "backgroundRGB": [220.0, 220, 220]]]] }, "foreign palette")
        check(try rejected { $0.factoryAudit = ["base": [
            ["owner": "owned-column", "backgroundRGB": [220.0, 220, 220]],
            ["owner": "owned-column", "backgroundRGB": [220.0, 220, 220]]]] }, "ambiguous palette")
        check(try Fixture(alpha: 254).run().pageExemptions.isEmpty, "almost-opaque RGBA ROI rejected")

        // Exact parity with the real factory's two-pass Float bilinear restore,
        // including corners, clamping and an asymmetric low-resolution DB grid.
        let values: [Float] = [0.1, 0.65, 0.92, 0.83, 0.03, 0.47]
        let grid = Probability(original: fixture.original, width: 3, height: 2, values: values)
        let restored = try Caller.restore(.init(width: 3, height: 2, values: values,
            sourceRevision: fixture.source.revision, revision: "synthetic-grid"), width: 128, height: 96)
        var same = true
        for y in 0..<96 { for x in 0..<128 {
            if Adapter.sampleProbability(grid, sourceX: x, sourceY: y, width: 128, height: 96) != restored[y * 128 + x] {
                same = false
            }
        } }
        check(same, "all 12288 DB samples match current production restore exactly")
        var invalid = fixture
        invalid.hard.removeLast()
        do { _ = try invalid.run(); preconditionFailure("bad hard mask accepted") }
        catch Adapter.Failure.invalidPageEvidence { checks += 1 }
        check(fixture.mask.filter { $0 != 0 }.count == 48, "original factory mask unchanged")
        print("{\"checks\":\(checks),\"failed\":0,\"dbSamplesCompared\":12288,\"modelCalls\":0,\"providerCalls\":0}")
    }
}
