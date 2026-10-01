import Compression
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

private final class NativeSourceRestorationMatrixBundle: NSObject {}

/// Random-access archive: retain only its small index, decode one original case
/// at a time, and verify both immutable record and expanded pixel/mask hashes.
enum NativeSourceRestorationMatrixFixtures {
    typealias Payload = [String: Any]
    struct Entry: Decodable {
        let collection: String
        let index: Int
        let offset: Int
        let length: Int
        let expandedLength: Int
        let sha256: String
    }
    struct Source: Decodable { let path: String; let sha256: String; let bytes: Int; let records: Int }
    struct Index: Decodable { let schemaVersion: Int; let sourceFiles: [String: Source]; let records: [Entry] }
    struct Archive { let url: URL; let base: UInt64; let index: Index }
    struct Fixture {
        let values: Payload
        let rawHashes: [String: String]
        let rawCounts: [String: Int]
        var id: String { (values["name"] as? String ?? "") + "/" + (values["id"] as? String ?? "") }
        var width: Int { (values["w"] ?? values["width"]) as? Int ?? 0 }
        var height: Int { (values["h"] ?? values["height"]) as? Int ?? 0 }
        var vertical: Bool { values["vertical"] as? Bool ?? false }
        func raw(_ key: String) throws -> [UInt8] {
            let encoded = try #require(values[key] as? String), expected = try #require(rawCounts[key])
            let bytes = try #require(Data(base64Encoded: encoded))
            guard width > 0, height > 0, width <= 262_144 / height else { throw Failure.fixture }
            let scalarMasks = ["ink", "ruby", "protected", "labels"]
            if scalarMasks.contains(key), expected != width * height { throw Failure.fixture }
            if ["rgba", "clean"].contains(key), expected != width * height * 4 { throw Failure.fixture }
            guard bytes.count > 6, expected > 0, expected <= 4 * 262_144,
                  (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0, bytes[1] & 32 == 0 else { throw Failure.fixture }
            let raw = try decompress(Data(bytes.dropFirst(2).dropLast(4)), size: expected)
            try #require(hash(raw) == rawHashes[key], "Original raw bytes changed: \(id)/\(key)")
            return Array(raw)
        }
        func pixels() throws -> NativeRestorationPixels {
            guard width > 0, height > 0, width <= 262_144 / height else { throw Failure.fixture }
            var pixels = NativeRestorationPixels(width: width, height: height)
            pixels.rgba = try raw("rgba")
            guard pixels.rgba.count == pixels.count * 4 else { throw Failure.fixture }
            return pixels
        }
    }
    enum Failure: Error { case fixture }
    private static let archive: Result<Archive, Error> = Result {
        let bundle = Bundle(for: NativeSourceRestorationMatrixBundle.self)
        let url = try #require(bundle.url(forResource: "NativeSourceRestorationQualityMatrix", withExtension: "bin"))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 256 * 1_024), !data.isEmpty { hasher.update(data: data) }
        try #require(hasher.finalize().map { String(format: "%02x", $0) }.joined() ==
            "13e74899cb2a3e6be2d50069804c0c6db15ec8a2701e86c6f76c5d395f7e1dd1")
        try handle.seek(toOffset: 0)
        let header = try #require(try handle.read(upToCount: 16))
        guard header.count == 16, header.prefix(8) == Data("NSRQMX01".utf8) else { throw Failure.fixture }
        let indexLength = header.dropFirst(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard indexLength > 0, indexLength < 512 * 1_024 else { throw Failure.fixture }
        let data = try #require(try handle.read(upToCount: Int(indexLength)))
        guard data.count == Int(indexLength) else { throw Failure.fixture }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.schemaVersion == 1, index.records.count == 394, index.sourceFiles.count == 12 else { throw Failure.fixture }
        return Archive(url: url, base: 16 + indexLength, index: index)
    }
    static func load(_ collection: String, _ index: Int, count: Int) throws -> Fixture {
        let archive = try Self.archive.get()
        #expect(archive.index.sourceFiles[collection]?.records == count)
        let entry = try #require(archive.index.records.first { $0.collection == collection && $0.index == index })
        guard entry.offset >= 0, entry.length > 0, entry.length <= 1_048_576,
              entry.expandedLength > 0, entry.expandedLength <= 1_048_576 else { throw Failure.fixture }
        let handle = try FileHandle(forReadingFrom: archive.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: archive.base + UInt64(entry.offset))
        let compressed = try #require(try handle.read(upToCount: entry.length))
        guard compressed.count == entry.length else { throw Failure.fixture }
        let decoded = try decompress(compressed, size: entry.expandedLength)
        try #require(hash(decoded) == entry.sha256, "Immutable case record changed: \(collection)/\(index)")
        let record = try #require(try JSONSerialization.jsonObject(with: decoded) as? Payload)
        return Fixture(values: try #require(record["fixture"] as? Payload),
            rawHashes: try #require(record["rawSHA256"] as? [String: String]),
            rawCounts: try #require(record["rawByteCounts"] as? [String: Int]))
    }
    private static func decompress(_ bytes: Data, size: Int) throws -> Data {
        var result = [UInt8](repeating: 0, count: size)
        let count = result.withUnsafeMutableBytes { destination in bytes.withUnsafeBytes { source in
            compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
        } }
        guard count == size else { throw Failure.fixture }
        return Data(result)
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func numbers(_ value: Any?) -> [Double] { (value as? [NSNumber])?.map(\.doubleValue) ?? [] }
    static func number(_ value: Any?, _ fallback: Double = 0) -> Double { (value as? NSNumber)?.doubleValue ?? fallback }
    static func rect(_ value: Any?) -> CGRect {
        let a = numbers(value)
        guard a.count == 4 else { return .null }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    static func delta(_ a: [UInt8], _ b: [UInt8], _ index: Int) -> Double {
        let offset: Int = index * 4
        var maximum: Int = 0
        for channel in 0..<3 {
            let first: Int = Int(a[offset + channel])
            let second: Int = Int(b[offset + channel])
            let difference: Int = abs(first - second)
            maximum = max(maximum, difference)
        }
        return Double(maximum)
    }
    static func observedOptions(_ fixture: Fixture) -> NativeObservedRestoreOptions {
        let p = fixture.values["options"] as? Payload ?? [:]
        var options = NativeObservedRestoreOptions()
        options.readabilityGate = p["readabilityGate"] as? Bool ?? true
        options.vertical = p["vertical"] as? Bool ?? fixture.vertical
        options.sampleScale = number(p["sampleScale"] ?? fixture.values["scale"], 1)
        options.leadingRule = p["leadingRule"] as? Bool ?? false
        options.auxiliary = (p["auxiliary"] as? [Any] ?? []).map(rect)
        return options
    }
    static func slantedOptions(_ fixture: Fixture) -> NativeSlantedGeometry.Options {
        let p = fixture.values["options"] as? Payload ?? fixture.values
        var options = NativeSlantedGeometry.Options()
        options.auxiliary = (p["auxiliary"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []
        options.auxiliaryPolygons = (p["auxiliaryPolygons"] as? [[[NSNumber]]])?.map { $0.map { $0.map(\.doubleValue) } } ?? []
        options.inferredRubyExclusions = (p["inferredRubyExclusions"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? []
        options.inferRuby = p["inferRuby"] as? Bool ?? p["infer"] as? Bool ?? false
        return options
    }
    static func restore(_ pixels: NativeRestorationPixels, fixture: Fixture, palette: Payload?) -> NativeRestorationPixels? {
        NativeRestorationPixels.exactObservedRestore(pixels, box: rect(fixture.values["b"]),
            palette: palette.flatMap(NativeRestorationPixels.palette), options: observedOptions(fixture))
    }
    static func slanted(_ pixels: NativeRestorationPixels, fixture: Fixture, palette: Payload?) -> NativeSlantedRestoration.Result? {
        NativeSlantedRestoration.restore(pixels, box: numbers(fixture.values["box"]), angle: number(fixture.values["angle"]),
            palette: palette.flatMap(NativeRestorationPixels.palette), vertical: fixture.vertical, options: slantedOptions(fixture))
    }
    enum Sampling { case native, areaCoverage }
    static func sampler(_ page: NativeRestorationPixels, bounds: [Double], budget: NativeSourceColorSamplingStage.Budget = .init(),
                        sampling: Sampling = .native) throws -> (NativeSourceColorSamplingStage, Payload?) {
        let image = try #require(page.image())
        let reader: (any NativeSourcePixelReading)? = sampling == .areaCoverage ? AreaCoverageReader(page: page) : nil
        let sampler = NativeSourceColorSamplingStage(image: image, enabled: true, budget: budget, pixelReader: reader)
        return (sampler, sampler.sample(bounds: bounds))
    }

    /// Exact source-color-test-harness.cjs resize contract. These reviewed color
    /// labels were exercised with area-averaged inputs, not a platform Canvas
    /// interpolation filter. Actual iOS transport has a separate parity suite.
    private final class AreaCoverageReader: NativeSourcePixelReading {
        let page: NativeRestorationPixels
        init(page: NativeRestorationPixels) { self.page = page }
        func read(x: Double, y: Double, sourceWidth: Double, sourceHeight: Double,
                  width: Int, height: Int) throws -> [UInt8] {
            guard [x, y, sourceWidth, sourceHeight].allSatisfy(\.isFinite), x >= 0, y >= 0,
                  sourceWidth > 0, sourceHeight > 0, x + sourceWidth <= Double(page.width),
                  y + sourceHeight <= Double(page.height), width > 0, height > 0,
                  width <= 24_576 / height else { throw Failure.fixture }
            var result = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                let top = y + Double(row) * sourceHeight / Double(height)
                let bottom = y + Double(row + 1) * sourceHeight / Double(height)
                for column in 0..<width {
                    let left = x + Double(column) * sourceWidth / Double(width)
                    let right = x + Double(column + 1) * sourceWidth / Double(width)
                    var sums = [Double](repeating: 0, count: 4)
                    for sy in Int(floor(top))..<Int(ceil(bottom)) {
                        let dy = min(bottom, Double(sy + 1)) - max(top, Double(sy))
                        for sx in Int(floor(left))..<Int(ceil(right)) {
                            let weight = dy * (min(right, Double(sx + 1)) - max(left, Double(sx)))
                            let source = (sy * page.width + sx) * 4
                            for channel in 0..<4 { sums[channel] += Double(page.rgba[source + channel]) * weight }
                        }
                    }
                    let area = (right - left) * (bottom - top), destination = (row * width + column) * 4
                    for channel in 0..<4 { result[destination + channel] = UInt8(min(255, max(0, floor(sums[channel] / area + 0.5)))) }
                }
            }
            return result
        }
    }
    static func bounds(_ fixture: Fixture) -> [Double] {
        numbers(fixture.values["b"]).enumerated().map { $0.element / Double($0.offset.isMultiple(of: 2) ? fixture.width : fixture.height) }
    }
}
