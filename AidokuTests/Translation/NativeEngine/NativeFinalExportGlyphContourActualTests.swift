import CryptoKit
import Foundation
import Testing
@testable import Aidoku

private final class NativeGlyphOutlineAAFixtureBundle: NSObject {}

@Suite @MainActor struct NativeFinalExportGlyphContourActualTests {
    private struct Record: Decodable {
        let name: String
        let offset: Int
        let length: Int
        let width: Int
        let height: Int
        let RGBA8SHA256: String
    }
    private struct Metadata: Decodable {
        let fillRGB: [Double]
        let outlineRGB: [Double]
        let records: [Record]
    }
    private struct Fixture {
        let width: Int
        let height: Int
        let fill: [Double]
        let outline: [Double]
        let reference: [UInt8]
        let actual: [UInt8]
        let wrongStrokeFirst: [UInt8]
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture() throws -> Fixture {
        let bundle = Bundle(for: NativeGlyphOutlineAAFixtureBundle.self)
        let binaryURL = try #require(bundle.url(forResource: "NativeGlyphOutlineAA", withExtension: "bin"))
        let metadataURL = try #require(bundle.url(forResource: "NativeGlyphOutlineAA", withExtension: "json"))
        let data = try Data(contentsOf: binaryURL)
        let metadataData = try Data(contentsOf: metadataURL)
        try #require(data.count == 418_176)
        try #require(hash(data) == "66a673099e45e3146295f6d47034019469750a76bdcbdf31acab14122c3720d6")
        try #require(hash(metadataData) == "08a7ed0685cbcb86412bc57cfc848be41f5e63de4794a5be33e7e5e5155bc923")
        let metadata = try JSONDecoder().decode(Metadata.self, from: metadataData)
        try #require(metadata.records.count == 3)
        let first = try #require(metadata.records.first)
        try #require(first.width > 0 && first.height > 0 && first.width <= 262_144 / first.height)
        var decoded: [String: [UInt8]] = [:]
        for record in metadata.records {
            try #require(record.width == first.width && record.height == first.height)
            try #require(record.length == first.width * first.height * 4)
            try #require(record.offset >= 0 && record.length <= data.count && record.offset <= data.count - record.length)
            let pixels = data.subdata(in: record.offset..<(record.offset + record.length))
            try #require(hash(pixels) == record.RGBA8SHA256)
            try #require(decoded[record.name] == nil)
            decoded[record.name] = Array(pixels)
        }
        return Fixture(width: first.width, height: first.height, fill: metadata.fillRGB, outline: metadata.outlineRGB,
            reference: try #require(decoded["frozen26"]), actual: try #require(decoded["native26"]),
            wrongStrokeFirst: try #require(decoded["incorrectStrokeFirst24"]))
    }

    @Test func measuredSubpixelCaptionContoursRetainFillAreaAndCoverage() throws {
        let sample = try fixture()
        let result = NativeFinalExportGlyphContourAcceptance.evaluate(
            reference: sample.reference, actual: sample.actual, width: sample.width, height: sample.height,
            foreground: sample.fill, outline: sample.outline)
        let evidence = try #require(result)
        #expect(evidence.referenceFillPixels == 2860)
        #expect(evidence.actualFillPixels == 2870)
        #expect(evidence.relativeAreaDifference < 0.004)
        #expect(evidence.relativeCoverageDifference < 0.0001)
    }

    @Test func actualPreviousStrokeFirstBugCannotPassAsAntialiasing() throws {
        let sample = try fixture()
        let accepted = NativeFinalExportGlyphContourAcceptance.evaluate(
            reference: sample.reference, actual: sample.wrongStrokeFirst, width: sample.width, height: sample.height,
            foreground: sample.fill, outline: sample.outline) != nil
        // This is the earlier actual render, whose fill area was 88% too large.
        // Even with unchanged text/style metadata, its raster must be rejected.
        #expect(!accepted)
    }

    @Test func missingGlyphCannotPassWithUnchangedPaletteAndMetadata() throws {
        let sample = try fixture()
        var missingGlyph = sample.actual
        // Erase the first character's measured crop with its opaque background.
        // Its original source coordinates live only in this immutable fixture;
        // the generic certificate receives no page ID, text or exemption flag.
        for y in 0..<sample.height {
            for x in 0..<90 {
                let offset = (y * sample.width + x) * 4
                missingGlyph[offset] = 255; missingGlyph[offset + 1] = 255
                missingGlyph[offset + 2] = 255; missingGlyph[offset + 3] = 255
            }
        }
        let accepted = NativeFinalExportGlyphContourAcceptance.evaluate(
            reference: sample.reference, actual: missingGlyph, width: sample.width, height: sample.height,
            foreground: sample.fill, outline: sample.outline) != nil
        #expect(!accepted)
    }
}
