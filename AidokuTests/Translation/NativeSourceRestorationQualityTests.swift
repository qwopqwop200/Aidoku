import Compression
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

private final class NativeSourceRestorationQualityFixtureBundle: NSObject {}

/// The same independent source/artwork/ruby masks as the three historical JS
/// regressions, applied to production native samplers and restoration kernels.
@Suite(.serialized)
struct NativeSourceRestorationQualityTests {
    private typealias Payload = [String: Any]
    private enum Failure: Error { case fixture }

    private struct Fixture {
        let values: Payload
        let raw: [String: [UInt8]]
        var width: Int { (values["width"] ?? values["w"]) as? Int ?? 0 }
        var height: Int { (values["height"] ?? values["h"]) as? Int ?? 0 }
        var vertical: Bool { values["vertical"] as? Bool ?? false }
        var pixels: NativeRestorationPixels {
            var result = NativeRestorationPixels(width: width, height: height)
            result.rgba = raw["rgba"] ?? []
            return result
        }
    }

    private func fixture(_ kind: String) throws -> Fixture {
        let bundle = Bundle(for: NativeSourceRestorationQualityFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "NativeSourceRestorationQualityFixtures", withExtension: "bin"))
        let packed = try Data(contentsOf: url)
        #expect(hash(packed) == "dea594b1b8dca352830a53e31f364197514ada6eca4e14f2dd3c7fc5ed7c40c2")
        guard packed.count > 8 else { throw Failure.fixture }
        let count = packed.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard count > 0, count < 8 * 1_024 * 1_024 else { throw Failure.fixture }
        var decoded = [UInt8](repeating: 0, count: Int(count))
        let written = decoded.withUnsafeMutableBytes { destination in packed.withUnsafeBytes { source in
            compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, Int(count),
                source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 8), packed.count - 8, nil, COMPRESSION_ZLIB)
        } }
        guard written == decoded.count,
              let manifest = try JSONSerialization.jsonObject(with: Data(decoded)) as? Payload,
              manifest["version"] as? Int == 1, let cases = manifest["cases"] as? [Payload], cases.count == 3,
              let record = cases.first(where: { $0["kind"] as? String == kind }),
              let values = record["fixture"] as? Payload, let encoded = record["raw"] as? [String: String],
              let hashes = record["rawSHA256"] as? [String: String] else { throw Failure.fixture }
        var raw: [String: [UInt8]] = [:]
        for (key, value) in encoded {
            let bytes = try #require(Data(base64Encoded: value))
            #expect(hash(bytes) == hashes[key], "Immutable fixture bytes: \(key)")
            raw[key] = Array(bytes)
        }
        let result = Fixture(values: values, raw: raw)
        guard result.width > 0, result.height > 0, result.width * result.height <= 262_144,
              raw["rgba"]?.count == result.width * result.height * 4 else { throw Failure.fixture }
        for key in ["ink", "ruby", "protected"] where raw[key] != nil {
            #expect(raw[key]?.count == result.width * result.height)
        }
        return result
    }

    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func numbers(_ value: Any?) -> [Double] { (value as? [NSNumber])?.map(\.doubleValue) ?? [] }
    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private func colorDelta(_ first: [UInt8], _ second: [UInt8], at index: Int) -> Int {
        (0..<3).map { abs(Int(first[index * 4 + $0]) - Int(second[index * 4 + $0])) }.max() ?? 0
    }

    @Test func slantedLetteringErasurePreservesEveryAnnotatedArtworkPixel() throws {
        let fixture = try fixture("artwork"), page = fixture.pixels, original = page.rgba
        let box = numbers(fixture.values["box"]), angle = number(fixture.values["angle"])
        let image = try #require(page.image())
        let cosine = cos(angle), sine = sin(angle), centerX = box[0] + box[2] / 2, centerY = box[1] + box[3] / 2
        let corners = [[-1.0, -1.0], [1, -1], [1, 1], [-1, 1]].map { point in
            [centerX + point[0] * box[2] / 2 * cosine - point[1] * box[3] / 2 * sine,
             centerY + point[0] * box[2] / 2 * sine + point[1] * box[3] / 2 * cosine]
        }
        let left = max(0, corners.map { $0[0] }.min()!), top = max(0, corners.map { $0[1] }.min()!)
        let right = min(Double(page.width), corners.map { $0[0] }.max()!)
        let bottom = min(Double(page.height), corners.map { $0[1] }.max()!)
        let bounds = fixture.values["bounds"].map(numbers) ??
            [left / Double(page.width), top / Double(page.height), (right - left) / Double(page.width), (bottom - top) / Double(page.height)]
        let sampler = NativeSourceColorSamplingStage(image: image, enabled: true)
        let palette = sampler.sample(bounds: bounds).flatMap(NativeRestorationPixels.palette)
        let result = try #require(NativeSlantedRestoration.restore(page, box: box, angle: angle,
            palette: palette, vertical: fixture.vertical))
        let ink = try #require(fixture.raw["ink"]), protected = try #require(fixture.raw["protected"])
        var inkCount = 0, remaining = 0, protectedCount = 0, changed = 0
        for index in 0..<page.count {
            let delta = colorDelta(result.pixels.rgba, original, at: index)
            if ink[index] != 0 {
                inkCount += 1
                if result.pixels.rgba[index * 4 + 3] < 250 || delta < 5 { remaining += 1 }
            }
            if protected[index] != 0 {
                protectedCount += 1
                if result.pixels.rgba[index * 4 + 3] != 0, delta > 3 { changed += 1 }
            }
        }
        #expect(inkCount > 50 && protectedCount > 1_000)
        #expect(Double(remaining) / Double(inkCount) <= 0.005, "Annotated source ink remains: \(remaining)/\(inkCount)")
        #expect(changed == 0, "Protected illustration changed in \(changed) pixels")
        #expect(page.rgba == original)
    }

    @Test func slantedBodyAndRubyHaveZeroObservedResidue() throws {
        let fixture = try fixture("ruby"), page = fixture.pixels, original = page.rgba
        let descriptor = try #require(fixture.values["palette"] as? Payload)
        let palette = try #require(NativeRestorationPixels.palette(descriptor))
        var options = NativeSlantedGeometry.Options()
        options.auxiliary = (fixture.values["auxiliary"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []
        options.auxiliaryPolygons = (fixture.values["auxiliaryPolygons"] as? [[[NSNumber]]])?.map { $0.map { $0.map(\.doubleValue) } } ?? []
        options.inferRuby = fixture.values["infer"] as? Bool ?? false
        let result = try #require(NativeSlantedRestoration.restore(page, box: numbers(fixture.values["box"]),
            angle: number(fixture.values["angle"]), palette: palette, vertical: fixture.vertical, options: options))
        let ink = try #require(fixture.raw["ink"]), ruby = try #require(fixture.raw["ruby"])
        let protected = try #require(fixture.raw["protected"]), background = numbers(descriptor["background"])
        var bodyCount = 0, bodyRemaining = 0, rubyCount = 0, rubyRemaining = 0, protectedCount = 0, changed = 0
        for index in 0..<page.count {
            let delta = colorDelta(result.pixels.rgba, original, at: index)
            let erased = result.pixels.rgba[index * 4 + 3] >= 250 && delta > 10
            let visible = (0..<3).map { abs(background[$0] - Double(original[index * 4 + $0])) }.max()! > 24
            if ink[index] != 0, visible { bodyCount += 1; if !erased { bodyRemaining += 1 } }
            if ruby[index] != 0, visible { rubyCount += 1; if !erased { rubyRemaining += 1 } }
            if protected[index] != 0 {
                protectedCount += 1
                if result.pixels.rgba[index * 4 + 3] != 0, delta > 3 { changed += 1 }
            }
        }
        #expect(bodyCount > 20 && rubyCount > 0 && protectedCount > 1_000)
        #expect(changed == 0, "Protected drawing changed in \(changed) pixels")
        #expect(bodyRemaining == 0, "Source residue \(bodyRemaining)/\(bodyCount)")
        #expect(rubyRemaining == 0, "Ruby residue \(rubyRemaining)/\(rubyCount)")
        #expect(page.rgba == original)
    }

    @Test func independentObservedInkRestoresWhenDisplayPaletteRejectsItsHalo() throws {
        let fixture = try fixture("owned"), page = fixture.pixels, original = page.rgba
        let box = numbers(fixture.values["b"])
        let frame = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        let image = try #require(page.image())
        let sampler = NativeSourceColorSamplingStage(image: image, enabled: true)
        let actual = try #require(sampler.sample(bounds: box.enumerated().map {
            $0.element / Double($0.offset.isMultiple(of: 2) ? page.width : page.height)
        }))
        let observed = try #require(actual["sourceInk"] as? Payload)
        #expect(observed["foreground"] != nil && observed["background"] != nil)
        var options = NativeObservedRestoreOptions()
        options.readabilityGate = true; options.vertical = fixture.vertical; options.sampleScale = number(fixture.values["scale"])
        let integrated = NativeRestorationPixels.exactObservedRestore(page, box: frame,
            palette: NativeRestorationPixels.palette(actual), options: options)
        #expect(integrated != nil, "The integrated native sampler must retain usable source erasure evidence")
        var display = try #require(fixture.values["displayPalette"] as? Payload)
        let sourceInk = try #require(fixture.values["sourceInk"] as? Payload)
        display["sourceInk"] = sourceInk
        let serialized = try JSONSerialization.data(withJSONObject: display, options: [.sortedKeys])
        let restored = try #require(NativeRestorationPixels.exactObservedRestore(page, box: frame,
            palette: NativeRestorationPixels.palette(display), options: options))
        let reference = try #require(NativeRestorationPixels.exactObservedRestore(page, box: frame,
            palette: NativeRestorationPixels.palette(sourceInk), options: options))
        #expect(restored.rgba == reference.rgba, "The independent observed-ink mask and background must remain identical")
        #expect(try JSONSerialization.data(withJSONObject: display, options: [.sortedKeys]) == serialized)
        #expect(page.rgba == original)
    }
}
