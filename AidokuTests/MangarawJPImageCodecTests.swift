import Foundation
import Testing
import UIKit
@testable import Aidoku

struct MangarawJPImageCodecTests {
    @Test func recoveredXORConstantDecodesFixedVectors() throws {
        // Independent fixed vectors: UTF8("mangarawjp.tv") XOR reduction == 0x36.
        #expect(try MangarawJPImageCodec.decodeOrder("061a071a041a05") == [0, 1, 2, 3])
        #expect(try MangarawJPImageCodec.decodeOrder("051a041a071a06") == [3, 2, 1, 0])
        #expect(try MangarawJPImageCodec.decodeOrder("6") == [0])
        #expect(throws: MangarawJPImageCodec.CodecError.self) { try MangarawJPImageCodec.decodeOrder("zz") }
        #expect(throws: MangarawJPImageCodec.CodecError.self) { try MangarawJPImageCodec.decodeOrder("") }
    }

    @Test func gridPreservesFractionalTileEdgesAndRejectsMalformedOrders() throws {
        let tiles = try MangarawJPImageCodec.tilePlan(order: [3, 2, 1, 0], width: 5, height: 7)
        #expect(tiles[0].source == CGRect(x: 2.5, y: 3.5, width: 2.5, height: 3.5))
        #expect(tiles[3].destination.maxX == 5 && tiles[3].destination.maxY == 7)
        for order in [[], [0, 1, 2], [0, 0, 2, 3], [-1, 1, 2, 3], [0, 1, 2, 4]] {
            #expect(throws: MangarawJPImageCodec.CodecError.self) {
                try MangarawJPImageCodec.tilePlan(order: order, width: 4, height: 4)
            }
        }
    }

    @Test func decodedOrderMovesActualPixelsWithoutChangingScale() throws {
        // Four distinct RGBA pixels establish tile movement, rather than only checking a plan.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let image = UIImage(cgImage: cgImage, scale: 2, orientation: .up)
        let decoded = try MangarawJPImageCodec.unscramble(image, key: "051a041a071a06")
        #expect(decoded.scale == 2)
        let output = try #require(decoded.cgImage?.dataProvider?.data)
        let bytes = Array(output as Data)
        let row = decoded.cgImage!.bytesPerRow
        #expect(Array(bytes[0..<4]) == [255, 255, 255, 255])
        #expect(Array(bytes[4..<8]) == [0, 0, 255, 255])
        #expect(Array(bytes[row..<(row + 4)]) == [0, 255, 0, 255])
        #expect(Array(bytes[(row + 4)..<(row + 8)]) == [255, 0, 0, 255])
    }
}
