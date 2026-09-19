import Foundation

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

    static func repack(_ data: Data) throws -> Data {
        guard !data.starts(with: zlibMagic) else { return data }
        let candidate = pack(try unpack(data))
        return candidate.count < data.count ? candidate : data
    }

}

/// One lossless source/geometry payload shared by OCR and every translation variant.
/// Request identities are interned once per page instead of once per text region.
struct ReaderTranslationRegionArchive {
    let base: Data
    let variant: Data

    private struct Variant: Codable {
        let version: Int
        let translations: [String?]
        let keys: [TranslationCacheKey]
        let references: [Int?]
        let segments: [String?]

        private enum CodingKeys: String, CodingKey {
            case version = "v", translations = "t", keys = "k", references = "r", segments = "s"
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
            return ReaderTranslationStoredRegion(region)
        }
        base = ReaderTranslationCacheCodec.packSharedBase(try encoder.encode(source))
        // Empty arrays are the canonical all-nil representation for OCR-only pages.
        let translations = regions.map(\.translation)
        variant = ReaderTranslationCacheCodec.pack(try encoder.encode(Variant(
            version: 1,
            translations: translations.allSatisfy { $0 == nil } ? [] : translations,
            keys: keys,
            references: keys.isEmpty ? [] : references,
            segments: keys.isEmpty ? [] : segments
        )))
    }

    static func restore(base: Data, variant: Data) throws -> Data {
        try JSONEncoder().encode(regions(base: base, variant: variant).map(ReaderTranslationStoredRegion.init))
    }

    static func regions(base: Data, variant: Data) throws -> [ReaderTranslationRegion] {
        do {
            let decoder = JSONDecoder()
            var regions = try decoder.decode([ReaderTranslationStoredRegion].self,
                from: ReaderTranslationCacheCodec.unpack(base)).map(\.region)
            let values = try decoder.decode(Variant.self, from: ReaderTranslationCacheCodec.unpack(variant))
            guard values.version == 1,
                  values.translations.isEmpty || values.translations.count == regions.count,
                  (values.references.isEmpty && values.segments.isEmpty && values.keys.isEmpty) ||
                    (values.references.count == regions.count && values.segments.count == regions.count)
            else { throw corrupt() }
            for index in regions.indices {
                if !values.translations.isEmpty { regions[index].translation = values.translations[index] }
                if !values.references.isEmpty {
                    if let reference = values.references[index] {
                        guard values.keys.indices.contains(reference), let segment = values.segments[index] else { throw corrupt() }
                        regions[index].translationReuseIdentity = .init(cacheKey: values.keys[reference], segmentID: segment)
                    } else if values.segments[index] != nil { throw corrupt() }
                }
            }
            return regions
        } catch {
            // Corrupt compressed bases and invalid references follow the same cache-miss path.
            throw corrupt()
        }
    }

    private static func corrupt() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid shared region archive"))
    }
}
