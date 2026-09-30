import Foundation
import UIKit

/// Native port of ja.mangarawjp v2's XOR order-key decoding and Canvas tile copying.
/// Aidoku-Community/sources sources/ja.mangarawjp/src/lib.rs (MIT OR Apache-2.0).
enum MangarawJPImageCodec {
    enum CodecError: Error, Equatable {
        case invalidOrderKey
        case invalidGrid
        case invalidImage
    }

    struct Tile: Equatable {
        let source: CGRect
        let destination: CGRect
    }

    static func decodeOrder(_ key: String) throws -> [Int] {
        try Task.checkCancellation()
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty, bytes.count <= 65_536 else { throw CodecError.invalidOrderKey }
        let mask = "mangarawjp.tv".utf8.reduce(UInt8(0), ^)
        var decoded = [UInt8]()
        decoded.reserveCapacity((bytes.count + 1) / 2)
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let first = digit(bytes[index]) else { throw CodecError.invalidOrderKey }
            let encoded: UInt8
            if index + 1 < bytes.count {
                guard let second = digit(bytes[index + 1]) else { throw CodecError.invalidOrderKey }
                encoded = first * 16 + second
            } else { encoded = first } // Rust chunks(2) accepts a final single hex digit.
            decoded.append(encoded ^ mask)
        }
        guard let text = String(bytes: decoded, encoding: .utf8) else { throw CodecError.invalidOrderKey }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 4096 else { throw CodecError.invalidGrid }
        return parts
    }

    static func tilePlan(order: [Int], width: Int, height: Int) throws -> [Tile] {
        try Task.checkCancellation()
        guard width > 0, height > 0, !order.isEmpty, order.count <= 4096 else { throw CodecError.invalidGrid }
        let cols = Int(Double(order.count).squareRoot())
        // Fail closed on malformed server data rather than divide by zero or copy outside the page.
        guard cols > 0, cols * cols == order.count, Set(order).count == order.count,
              order.allSatisfy({ (0..<order.count).contains($0) }) else { throw CodecError.invalidGrid }
        // Rust Canvas coordinates are f32, including the tile-position multiplication.
        let unitWidth = Float(width) / Float(cols)
        let unitHeight = Float(height) / Float(cols)
        return order.enumerated().map { index, position in
            Tile(source: CGRect(x: CGFloat(Float(position % cols) * unitWidth), y: CGFloat(Float(position / cols) * unitHeight),
                                width: CGFloat(unitWidth), height: CGFloat(unitHeight)),
                 destination: CGRect(x: CGFloat(Float(index % cols) * unitWidth), y: CGFloat(Float(index / cols) * unitHeight),
                                     width: CGFloat(unitWidth), height: CGFloat(unitHeight)))
        }
    }

    static func decode(_ image: UIImage, key: String) throws -> UIImage {
        try unscramble(image, key: key)
    }

    static func unscramble(_ image: UIImage, key: String) throws -> UIImage {
        try Task.checkCancellation()
        guard image.imageOrientation == .up, let cgImage = image.cgImage else { throw CodecError.invalidImage }
        let width = cgImage.width, height = cgImage.height
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount > 0, pixelCount <= 32 * 1024 * 1024 else { throw CodecError.invalidImage }
        let tiles = try tilePlan(order: decodeOrder(key), width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw CodecError.invalidImage }
        for tile in tiles {
            try Task.checkCancellation()
            guard let source = cgImage.cropping(to: tile.source) else { throw CodecError.invalidImage }
            // Canvas.copy_image crops in top-origin image coordinates, then adjusts the
            // destination for Core Graphics. Keep its default interpolation/blending,
            // including the crop-and-scale behavior at fractional tile boundaries.
            let destination = CGRect(x: tile.destination.minX,
                                     y: CGFloat(height) - tile.destination.minY - tile.destination.height,
                                     width: tile.destination.width, height: tile.destination.height)
            context.draw(source, in: destination)
        }
        guard let output = context.makeImage() else { throw CodecError.invalidImage }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }
}
