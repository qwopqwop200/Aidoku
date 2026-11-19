import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Page unscramblers for the Japanese raw sources.
struct NativeImageCodecTests {
    @Test func mangarawJPOrderDecodesAndMovesPixels() throws {
        // UTF8("mangarawjp.tv") XOR reduction == 0x36.
        #expect(try MangarawJPImageCodec.decodeOrder("061a071a041a05") == [0, 1, 2, 3])
        #expect(throws: MangarawJPImageCodec.CodecError.self) { try MangarawJPImageCodec.decodeOrder("zz") }
        for order in [[], [0, 0, 2, 3], [0, 1, 2, 4]] {
            #expect(throws: MangarawJPImageCodec.CodecError.self) {
                try MangarawJPImageCodec.tilePlan(order: order, width: 4, height: 4)
            }
        }
        let decoded = try MangarawJPImageCodec.unscramble(try Self.fixture(width: 2, height: 2), key: "051a041a071a06")
        let image = try #require(decoded.cgImage)
        let bytes = Array(try #require(image.dataProvider?.data) as Data)
        // Reversed order: destination tile 0 holds source tile 3 at (1, 1).
        #expect(Array(bytes[0..<4]) == [1, 1, 4, 255])
        #expect(Array(bytes[(image.bytesPerRow + 4)..<(image.bytesPerRow + 8)]) == [0, 0, 0, 255])
    }

    @Test func soraRawDecryptsAuthenticPathAndRejectsMalformedPayloads() {
        let uuid = "003a8cfd16281b2b1d255d06524d8639ac1f7497533220824247f76eba48aeb9"
        #expect(SoraRawImageCodec.decryptPath("UQajtZjw1-nFt7IgA1ot0f9ahvQL5noTTVZv-2P0EASrNeOXH94Kyw", uuid: uuid)
                == "c722455/001_25706548.jpg")
        #expect(SoraRawImageCodec.decryptPath("QUJD", uuid: uuid) == nil)
        #expect(SoraRawImageCodec.decryptPath("UQajtZjw1-nFt7IgA1ot0f9a", uuid: "00ff") == nil)
        #expect(SoraRawImageCodec.deobfuscate("*") == nil)
    }

    @Test func soraRawUnscrambleMatchesIndependentReference() throws {
        // Independent Python hashlib/Mulberry32 reference, including quarter turns and remainders.
        let input = try Self.fixture(width: 17, height: 19)
        let output = try #require(SoraRawImageCodec.unscramble(input, seed: "audit")?.cgImage)
        let data = try #require(output.dataProvider?.data) as Data
        var packed = Data()
        for row in 0..<19 { packed.append(data[(row * output.bytesPerRow)..<(row * output.bytesPerRow + 17 * 4)]) }
        #expect(SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined()
                == "f61e45898b3d8a31e993cbe2a414e8569d51ca823a916d168aa58c419c602e6e")
    }

    @Test func spoilerPlusOrderRejectsMalformedKeys() throws {
        let mask = "spoilerplus.tv".utf8.reduce(UInt8(0), ^)
        func encode(_ string: String) -> String { string.utf8.map { String(format: "%02x", $0 ^ mask) }.joined() }
        #expect(try SpoilerPlusImageCodec.order(encode("3,2,1,0")) == [3, 2, 1, 0])
        for key in ["xyz", "é", "aéa", encode("0,1,2"), encode("0,0,0,0")] {
            #expect(throws: (any Error).self) { try SpoilerPlusImageCodec.order(key) }
        }
    }

    private static func fixture(width: Int, height: Int) throws -> UIImage {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { pixels += [UInt8(x), UInt8(y), UInt8((x + 3 * y) % 256), 255] }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return UIImage(cgImage: cgImage)
    }
}
