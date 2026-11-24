import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stored form of a rendered page: the restored (text-free) background of the regions S7 erased, as JPEG
/// patches, plus the placed text. A page rebuilds as the source raster with the patches drawn over it and
/// the text painted again (S10 only, a few ms), so a row is about 4% of a whole-page JPEG and untouched
/// art stays lossless. Rows written before this format are whole-page JPEGs.
///
/// Layout (little-endian UInt32): "ATP1", width, height, patch count, text byte count,
/// count x (x, y, width, height, byte count), the JPEGs, then the text (zlib JSON).
enum ReaderTranslationPagePatches {
    private static let magic = Data("ATP1".utf8)

    /// One painted item: S9's placement and the block fields S10 reads.
    private struct Text: Codable {
        var placed: PipelinePlacedText
        var style: PipelineStyle?
        var role: PipelineRole

        private enum CodingKeys: String, CodingKey { case placed = "p", style = "s", role = "r" }
    }
    private struct Stored { var width: Int, height: Int, patches: [(rect: CGRect, jpeg: Data)], text: [Text] }

    static func isPatches(_ data: Data) -> Bool { data.starts(with: magic) }
    static func isStoredPage(_ data: Data) -> Bool { isPatches(data) || data.starts(with: [0xFF, 0xD8, 0xFF]) }

    /// The row for a rendered page. Without `background` (the page was not restored in place) the
    /// painted page is stored whole.
    static func encode(_ output: CGImage, background: [PipelineBackgroundPatch]?, blocks: [PipelineBlock],
                       placed: [PipelinePlacedText]) -> Data? {
        let width = output.width, height = output.height
        guard width > 0, height > 0 else { return nil }
        var patches: [(rect: CGRect, jpeg: Data)] = []
        var text = Data()
        if let background {
            for patch in background {
                guard let image = try? PipelinePageRaster.image(Data(patch.rgba), width: Int(patch.rect.width), height: Int(patch.rect.height)),
                      let jpeg = jpegData(image) else { return nil }
                patches.append((patch.rect, jpeg))
            }
            let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = placed.compactMap { item in byID[item.blockID].map { Text(placed: item, style: $0.style, role: $0.role) } }
            guard items.count == placed.count, let json = try? JSONEncoder().encode(items),
                  let packed = try? (json as NSData).compressed(using: .zlib) as Data else { return nil }
            text = packed
        } else {
            guard let jpeg = jpegData(output) else { return nil }
            patches = [(CGRect(x: 0, y: 0, width: width, height: height), jpeg)]
        }
        var row = magic
        for value in [width, height, patches.count, text.count] { append(value, to: &row) }
        for patch in patches {
            for value in [patch.rect.minX, patch.rect.minY, patch.rect.width, patch.rect.height] { append(Int(value), to: &row) }
            append(patch.jpeg.count, to: &row)
        }
        for patch in patches { row.append(patch.jpeg) }
        return row + text
    }

    /// The stored page. Patches need the page's `source`; a whole-page JPEG row does not.
    static func decode(_ data: Data, source: CGImage?) -> CGImage? {
        guard isPatches(data) else { return image(data) }
        guard let source, let stored = parse(data), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = stored.width, height = stored.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // The same draw as PipelineRemovalMask.rgbaBytes, so unpatched pixels equal the rendered page.
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            for patch in stored.patches {
                guard let image = image(patch.jpeg), image.width == Int(patch.rect.width),
                      image.height == Int(patch.rect.height) else { return false }
                var rect = patch.rect
                rect.origin.y = CGFloat(height) - rect.maxY
                context.draw(image, in: rect)
            }
            return true
        }
        guard drawn else { return nil }
        let blocks = stored.text.map { item in
            PipelineBlock(id: item.placed.blockID, lines: [], bounds: item.placed.frame, polygon: [], vertical: item.placed.vertical,
                    readingOrder: 0, sourceText: "", role: item.role, style: item.style)
        }
        return PipelinePainter.paint(pixels: &bytes, width: width, height: height, blocks: blocks, placed: stored.text.map(\.placed))
    }

    // MARK: Bytes

    private static func parse(_ data: Data) -> Stored? {
        let data = Data(data)  // zero-based indices
        func value(_ index: Int) -> Int? {
            let offset = magic.count + index * 4
            guard offset + 4 <= data.count else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard let width = value(0), let height = value(1), let count = value(2), let textBytes = value(3),
              width > 0, height > 0, width <= 16_384, height <= 16_384, count <= 4_096 else { return nil }
        var offset = magic.count + (4 + count * 5) * 4
        var patches: [(rect: CGRect, jpeg: Data)] = []
        for index in 0..<count {
            let field = 4 + index * 5
            guard let x = value(field), let y = value(field + 1), let w = value(field + 2), let h = value(field + 3),
                  let length = value(field + 4), w > 0, h > 0, x + w <= width, y + h <= height,
                  offset + length <= data.count else { return nil }
            patches.append((CGRect(x: x, y: y, width: w, height: h), data.subdata(in: offset..<offset + length)))
            offset += length
        }
        guard offset + textBytes == data.count else { return nil }
        var text: [Text] = []
        if textBytes > 0 {
            guard let json = try? (data.subdata(in: offset..<data.count) as NSData).decompressed(using: .zlib) as Data,
                  let items = try? JSONDecoder().decode([Text].self, from: json) else { return nil }
            text = items
        }
        return Stored(width: width, height: height, patches: patches, text: text)
    }

    private static func append(_ value: Int, to data: inout Data) {
        withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
