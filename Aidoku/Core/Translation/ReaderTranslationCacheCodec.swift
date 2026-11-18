import Foundation
import Compression

enum ReaderTranslationCacheCodec {
    private static let magic = Data("ATZ1".utf8)
    private static let zlibMagic = Data("ATZ2".utf8)

    static let settledRenderTrailer = Data("AT-render-png-1".utf8)
    private static let binaryPlistHeader = Data("bplist00".utf8)

    static func isSettledRenderArchive(_ data: Data) -> Bool {
        data.starts(with: binaryPlistHeader) && data.suffix(settledRenderTrailer.count) == settledRenderTrailer
    }

    static func isPacked(_ data: Data) -> Bool { data.starts(with: magic) || data.starts(with: zlibMagic) }

    static func pack(_ data: Data) -> Data {
        guard !isPacked(data), !isSettledRenderArchive(data) else { return data }
        let legacy = packSharedBase(data)
        guard data.count >= 128,
              let compressed = try? (data as NSData).compressed(using: .zlib) as Data,
              compressed.count + zlibMagic.count < legacy.count else { return legacy }
        return zlibMagic + compressed
    }

    // Shared-base IDs hash these bytes. Retain their canonical encoding so new
    // variants continue sharing existing bases instead of duplicating them.
    static func packSharedBase(_ data: Data) -> Data {
        guard data.count >= 512, !isPacked(data),
              let compressed = try? (data as NSData).compressed(using: .lzfse) as Data,
              compressed.count + magic.count < data.count else { return data }
        return magic + compressed
    }

    static func unpack(_ data: Data) throws -> Data {
        guard isPacked(data) else { return data } // Existing v1 JSON remains readable.
        let algorithm: NSData.CompressionAlgorithm = data.starts(with: zlibMagic) ? .zlib : .lzfse
        return try (Data(data.dropFirst(magic.count)) as NSData).decompressed(using: algorithm) as Data
    }

    /// Bounded expansion for render assets; old formats and successful bytes are unchanged.
    static func unpack(_ data: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw CocoaError(.fileReadTooLarge) }
        guard isPacked(data) else {
            guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            return data
        }
        let algorithm = data.starts(with: zlibMagic) ? COMPRESSION_ZLIB : COMPRESSION_LZFSE
        let chunkSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: chunkSize, src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { compression_stream_destroy(&stream) }
        return try data.withUnsafeBytes { bytes in
            stream.src_ptr = bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: magic.count)
            stream.src_size = data.count - magic.count
            var result = Data()
            while true {
                try Task.checkCancellation()
                stream.dst_ptr = destination
                stream.dst_size = chunkSize
                let remaining = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                guard produced <= maximumBytes - result.count else { throw CocoaError(.fileReadTooLarge) }
                result.append(destination, count: produced)
                if status == COMPRESSION_STATUS_END { return result }
                guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size < remaining else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }

    static func repack(_ data: Data) throws -> Data {
        guard !data.starts(with: zlibMagic) else { return data }
        let candidate = pack(try unpack(data))
        return candidate.count < data.count ? candidate : data
    }

}

/// Identity of the full processed source used to produce a region record.
/// Decode authenticates the representation, not the caller's actual raster.
struct ReaderTranslationSourceRasterClaim: Codable, Equatable, Sendable {
    private static let currentABI = "processed-source-visible-rows-v2-upright-ocr-v1"
    private let abi: String
    let processedFullSourceSHA256: String

    init?(processedFullSourceSHA256: String) {
        let bytes = processedFullSourceSHA256.utf8
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        abi = Self.currentABI
        self.processedFullSourceSHA256 = processedFullSourceSHA256
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .abi) == Self.currentABI,
              let claim = Self(processedFullSourceSHA256: try values.decode(String.self, forKey: .processedFullSourceSHA256)) else {
            throw DecodingError.dataCorruptedError(forKey: .abi, in: values, debugDescription: "Invalid source-raster claim")
        }
        self = claim
    }

    private enum CodingKeys: String, CodingKey { case abi = "v", processedFullSourceSHA256 = "s" }
}

/// One lossless source/geometry payload shared by OCR and every translation variant.
/// Request identities are interned once per page instead of once per text region.
struct ReaderTranslationRegionArchive {
    let base: Data
    let variant: Data
    struct Record: Sendable {
        let regions: [ReaderTranslationRegion]
        let sourceRasterClaim: ReaderTranslationSourceRasterClaim?
        // Expanded archive size used only to bound retained disk-read results.
        var decodedByteCount = 0
        // Replaying a durable translation must not write its old bytes over a later commit.
        var wasReadFromTranslationCache = false
    }

    private struct Variant: Codable {
        let version: Int
        let translations: [String?]
        let keys: [TranslationCacheKey]
        let references: [Int?]
        let segments: [String?]
        let recoveryFailures: [String?]?
        let keptSFX: [Bool]?
        let sourceRasterClaim: ReaderTranslationSourceRasterClaim?

        private enum CodingKeys: String, CodingKey {
            case version = "v", translations = "t", keys = "k", references = "r", segments = "s", recoveryFailures = "f", keptSFX = "x"
            case sourceRasterClaim = "p"
        }
    }

    init(_ regions: [ReaderTranslationRegion], sourceRasterClaim: ReaderTranslationSourceRasterClaim? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var keys: [TranslationCacheKey] = []
        var indices: [TranslationCacheKey: Int] = [:]
        var references: [Int?] = []
        var segments: [String?] = []
        let source = regions.map { value in
            if let identity = value.translationReuseIdentity {
                let index: Int
                if let existing = indices[identity.cacheKey] {
                    index = existing
                } else {
                    index = keys.count
                    keys.append(identity.cacheKey)
                    indices[identity.cacheKey] = index
                }
                references.append(index)
                segments.append(identity.segmentID)
            } else {
                references.append(nil)
                segments.append(nil)
            }
            var region = value
            region.translation = nil
            region.translationReuseIdentity = nil
            region.translationRecoveryFailure = nil
            region.keepsClassifiedSFXSource = false
            return ReaderTranslationStoredRegion(region)
        }
        base = ReaderTranslationCacheCodec.packSharedBase(try encoder.encode(source))
        // Empty arrays are the canonical all-nil representation for OCR-only pages.
        let translations = regions.map(\.translation)
        let failures = regions.map(\.translationRecoveryFailure)
        let keptSFX = regions.map(\.keepsClassifiedSFXSource)
        variant = ReaderTranslationCacheCodec.pack(try encoder.encode(Variant(
            version: 1,
            translations: translations.allSatisfy { $0 == nil } ? [] : translations,
            keys: keys,
            references: keys.isEmpty ? [] : references,
            segments: keys.isEmpty ? [] : segments,
            recoveryFailures: failures.allSatisfy { $0 == nil } ? nil : failures,
            keptSFX: keptSFX.contains(true) ? keptSFX : nil,
            sourceRasterClaim: sourceRasterClaim
        )))
    }

    static func restore(base: Data, variant: Data) throws -> Data {
        try JSONEncoder().encode(regions(base: base, variant: variant).map(ReaderTranslationStoredRegion.init))
    }

    static func regions(base: Data, variant: Data) throws -> [ReaderTranslationRegion] {
        try record(base: base, variant: variant).regions
    }

    /// A legacy raw array never carries a claim, including an empty row.
    static func record(legacy: Data) throws -> Record {
        let raw = try ReaderTranslationCacheCodec.unpack(legacy)
        let decoded = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: raw)
        return .init(regions: decoded.map(\.region), sourceRasterClaim: nil, decodedByteCount: raw.count)
    }

    /// A malformed claim or region variant invalidates the whole record.
    static func record(base: Data, variant: Data) throws -> Record {
        do {
            let decoder = JSONDecoder()
            var regions: [ReaderTranslationRegion]
            let sourceBytes: Int
            do {
                let raw = try ReaderTranslationCacheCodec.unpack(base)
                sourceBytes = raw.count
                regions = try decoder.decode([ReaderTranslationStoredRegion].self, from: raw).map(\.region)
            }
            let variantBytes: Int
            let values: Variant
            do {
                let raw = try ReaderTranslationCacheCodec.unpack(variant)
                variantBytes = raw.count
                values = try decoder.decode(Variant.self, from: raw)
            }
            guard values.version == 1,
                  values.recoveryFailures.map({ $0.count == regions.count }) ?? true,
                  values.keptSFX.map({ $0.count == regions.count }) ?? true,
                  values.translations.isEmpty || values.translations.count == regions.count,
                  (values.references.isEmpty && values.segments.isEmpty && values.keys.isEmpty) ||
                    (values.references.count == regions.count && values.segments.count == regions.count)
            else { throw corrupt() }
            for index in regions.indices {
                regions[index].translationRecoveryFailure = values.recoveryFailures?[index]
                regions[index].keepsClassifiedSFXSource = values.keptSFX?[index] ?? false
                if !values.translations.isEmpty { regions[index].translation = values.translations[index] }
                if !values.references.isEmpty {
                    if let reference = values.references[index] {
                        guard values.keys.indices.contains(reference), let segment = values.segments[index] else { throw corrupt() }
                        regions[index].translationReuseIdentity = .init(cacheKey: values.keys[reference], segmentID: segment)
                    } else if values.segments[index] != nil { throw corrupt() }
                }
            }
            return .init(regions: regions, sourceRasterClaim: values.sourceRasterClaim, decodedByteCount: sourceBytes + variantBytes)
        } catch {
            // Corrupt compressed bases and invalid references follow the same cache-miss path.
            throw corrupt()
        }
    }

    private static func corrupt() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid shared region archive"))
    }
}
