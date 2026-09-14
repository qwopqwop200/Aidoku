import Foundation

enum ReaderTranslationCacheCodec {
    private static let magic = Data("ATZ1".utf8)

    static func isPacked(_ data: Data) -> Bool { data.starts(with: magic) }

    static func pack(_ data: Data) -> Data {
        guard data.count >= 512, !isPacked(data),
              let compressed = try? (data as NSData).compressed(using: .lzfse) as Data,
              compressed.count + magic.count < data.count else { return data }
        return magic + compressed
    }

    static func unpack(_ data: Data) throws -> Data {
        guard isPacked(data) else { return data } // Existing v1 JSON remains readable.
        return try (Data(data.dropFirst(magic.count)) as NSData).decompressed(using: .lzfse) as Data
    }

}
