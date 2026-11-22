import Foundation
import zlib

enum ReaderTranslationCacheCodec {
    private static let magic = Data("ATZ1".utf8)
    private static let zlibMagic = Data("ATZ2".utf8)

    static func isPacked(_ data: Data) -> Bool { data.starts(with: magic) || data.starts(with: zlibMagic) }

    static func pack(_ data: Data) -> Data {
        guard !isPacked(data) else { return data }
        let legacy = packSharedBase(data)
        guard data.count >= 128,
              let compressed = try? (data as NSData).compressed(using: .zlib) as Data,
              compressed.count + zlibMagic.count < legacy.count else { return legacy }
        return zlibMagic + compressed
    }

    // Shared-base IDs hash these bytes, so their encoding must stay canonical.
    static func packSharedBase(_ data: Data) -> Data {
        guard data.count >= 512, !isPacked(data),
              let compressed = try? (data as NSData).compressed(using: .lzfse) as Data,
              compressed.count + magic.count < data.count else { return data }
        return magic + compressed
    }

    static func unpack(_ data: Data) throws -> Data {
        guard isPacked(data) else { return data } // Existing v1 JSON remains readable.
        let algorithm: NSData.CompressionAlgorithm = data.starts(with: zlibMagic) ? .zlib : .lzfse
        // Decompress straight from the stored bytes instead of copying the compressed body first.
        return try data.dropFirst(magic.count).withUnsafeBytes { bytes in
            // libz inflates the same raw deflate stream about 4x faster than NSData (page JPEG: 9 ms -> 2 ms).
            if algorithm == .zlib { return try inflateRaw(bytes) }
            guard let base = bytes.baseAddress else { return try (Data() as NSData).decompressed(using: algorithm) as Data }
            return try NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: bytes.count, freeWhenDone: false)
                .decompressed(using: algorithm) as Data
        }
    }

    /// Raw deflate (RFC 1951), the stream NSData's `.zlib` writes and reads.
    static func inflateRaw(_ input: UnsafeRawBufferPointer) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(4_096, input.count * 2))
        var produced = 0
        var status = Z_OK
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        while status != Z_STREAM_END {
            if produced == output.count { output.count *= 2 }
            status = output.withUnsafeMutableBytes { buffer -> Int32 in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress.map { $0 + produced }
                stream.avail_out = uInt(buffer.count - produced)
                let result = inflate(&stream, Z_NO_FLUSH)
                produced = buffer.count - Int(stream.avail_out)
                return result
            }
            // Z_BUF_ERROR with output space left means the stream is truncated.
            guard status == Z_OK || status == Z_STREAM_END || (status == Z_BUF_ERROR && produced == output.count) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        output.count = produced
        return output
    }

    static func repack(_ data: Data) throws -> Data {
        guard !data.starts(with: zlibMagic) else { return data }
        let candidate = pack(try unpack(data))
        return candidate.count < data.count ? candidate : data
    }
}

/// A source/geometry base shared by every translation variant, with interned request identities.
struct ReaderTranslationRegionArchive {
    let base: Data
    let variant: Data
    struct Record: Sendable {
        let regions: [ReaderTranslationRegion]
        // Expanded archive size used only to bound retained disk-read results.
        var decodedByteCount = 0
    }

    private struct Variant: Codable {
        let version: Int
        let translations: [String?]
        let keys: [TranslationCacheKey]
        let references: [Int?]
        let segments: [String?]
        let recoveryFailures: [String?]?
        let keptSFX: [Bool]?

        private enum CodingKeys: String, CodingKey {
            case version = "v", translations = "t", keys = "k", references = "r", segments = "s", recoveryFailures = "f", keptSFX = "x"
        }
    }

    init(_ regions: [ReaderTranslationRegion]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var keys: [TranslationCacheKey] = []
        var indices: [TranslationCacheKey: Int] = [:]
        var references: [Int?] = []
        var segments: [String?] = []
        let source = regions.map { value in
            if let identity = value.translationReuseIdentity {
                if indices[identity.cacheKey] == nil {
                    indices[identity.cacheKey] = keys.count
                    keys.append(identity.cacheKey)
                }
                references.append(indices[identity.cacheKey])
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
            keptSFX: keptSFX.contains(true) ? keptSFX : nil
        )))
    }

    static func restore(base: Data, variant: Data) throws -> Data {
        try JSONEncoder().encode(record(base: base, variant: variant).regions.map(ReaderTranslationStoredRegion.init))
    }

    static func record(legacy: Data) throws -> Record {
        let raw = try ReaderTranslationCacheCodec.unpack(legacy)
        let decoded = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: raw)
        return .init(regions: decoded.map(\.region), decodedByteCount: raw.count)
    }

    /// A malformed region variant invalidates the whole record.
    static func record(base: Data, variant: Data) throws -> Record {
        do {
            let decoder = JSONDecoder()
            let rawBase = try ReaderTranslationCacheCodec.unpack(base)
            var regions = try decoder.decode([ReaderTranslationStoredRegion].self, from: rawBase).map(\.region)
            let rawVariant = try ReaderTranslationCacheCodec.unpack(variant)
            let values = try decoder.decode(Variant.self, from: rawVariant)
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
            return .init(regions: regions, decodedByteCount: rawBase.count + rawVariant.count)
        } catch {
            throw corrupt()
        }
    }

    private static func corrupt() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid shared region archive"))
    }
}
