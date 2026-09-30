import Foundation
import Testing
import UIKit
@testable import Aidoku

struct SoraRawImageCodecTests {
    @Test func authenticEncryptedPathAndMalformedPayloads() {
        let uuid = "003a8cfd16281b2b1d255d06524d8639ac1f7497533220824247f76eba48aeb9"
        #expect(SoraRawImageCodec.decryptPath("UQajtZjw1-nFt7IgA1ot0f9ahvQL5noTTVZv-2P0EASrNeOXH94Kyw", uuid: uuid)
                == "c722455/001_25706548.jpg")
        #expect(SoraRawImageCodec.decryptPath("QUJD", uuid: uuid) == nil)
        #expect(SoraRawImageCodec.decryptPath("UQajtZjw1-nFt7IgA1ot0f9a", uuid: "00ff") == nil)
        #expect(SoraRawImageCodec.decodeBase64("QUJD") == [65, 66, 67])
        #expect(SoraRawImageCodec.decodeBase64(" Q\nUJD= ") == [65, 66, 67])
        #expect(SoraRawImageCodec.decodeBase64("*") == nil)
        #expect(SoraRawImageCodec.deobfuscate("dB1XKg97VUQNA05dAhAxSWNeCHw") == #"[{"id":1,"order":1}]"#)
        #expect(SoraRawImageCodec.deobfuscate("*") == nil)
    }

    @Test func authenticNonSquarePlanPreservesDimensionsAndPermutation() throws {
        let tiles = try #require(SoraRawImageCodec.scramblePlan(width: 1125, height: 1600, seed: "843507"))
        #expect(tiles.map(\.source) == [
            12, 43, 32, 35, 49, 45, 22, 37, 16, 4, 56, 59, 25, 63, 23, 6, 2, 33, 60, 19, 44, 54,
            61, 39, 11, 36, 9, 24, 42, 62, 13, 29, 28, 34, 3, 0, 58, 30, 7, 15, 51, 41, 1, 57, 10,
            47, 21, 55, 40, 52, 20, 27, 50, 53, 46, 14, 8, 26, 18, 48, 17, 31, 38, 5
        ])
        #expect(tiles.map(\.turns) == [
            0, 2, 0, 2, 2, 2, 2, 2, 0, 0, 2, 2, 0, 2, 2, 2, 2, 0, 0, 2, 0, 0, 2, 0, 2, 0, 2, 2, 2,
            2, 2, 0, 2, 0, 0, 0, 0, 0, 2, 0, 2, 0, 2, 2, 0, 0, 2, 2, 0, 2, 2, 2, 2, 2, 0, 0, 0, 0,
            2, 0, 2, 2, 2, 0
        ])
        #expect(Set(tiles.map(\.source)).count == 64)
        for tile in tiles {
            #expect(tile.width == tiles[tile.source].width)
            #expect(tile.height == tiles[tile.source].height)
        }
        #expect(SoraRawImageCodec.scramblePlan(width: 7, height: 1600, seed: "843507") == nil)
    }

    @Test func authenticSquarePlanAndClockwisePixels() throws {
        let tiles = try #require(SoraRawImageCodec.scramblePlan(width: 64, height: 64, seed: "1"))
        #expect(tiles.map(\.source) == [
            10, 27, 57, 4, 1, 49, 22, 32, 62, 52, 17, 5, 51, 28, 45, 0, 53, 30, 44, 12, 43, 42, 46,
            59, 40, 39, 50, 37, 41, 19, 7, 3, 29, 11, 35, 48, 26, 55, 23, 36, 21, 33, 18, 24, 61,
            6, 16, 63, 15, 2, 54, 58, 38, 31, 34, 47, 60, 20, 13, 14, 56, 25, 9, 8
        ])
        #expect(tiles.map(\.turns) == [
            1, 3, 2, 0, 1, 1, 2, 1, 0, 3, 2, 0, 0, 2, 2, 3, 1, 0, 2, 1, 1, 3, 2, 2, 1, 3, 0, 2, 2,
            2, 3, 0, 0, 1, 1, 3, 1, 2, 1, 1, 2, 0, 3, 1, 1, 0, 1, 1, 2, 0, 0, 2, 0, 3, 1, 1, 2, 1,
            2, 0, 1, 3, 0, 0
        ])
        var rgba: [UInt8] = []
        for y in 0..<64 { for x in 0..<64 { rgba += [UInt8(x), UInt8(y), 0, 255] } }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                            .union(.byteOrder32Big), provider: provider,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let restored = try #require(SoraRawImageCodec.unscramble(UIImage(cgImage: image), seed: "1"))
        let data = try #require(restored.cgImage?.dataProvider?.data)
        let pixels = try #require(CFDataGetBytePtr(data))
        // Destination tile zero restores source tile 10 with one clockwise quarter turn.
        #expect(Array(UnsafeBufferPointer(start: pixels, count: 4)) == [16, 15, 0, 255])
        #expect(Array(UnsafeBufferPointer(start: pixels + 7 * 4, count: 4)) == [16, 8, 0, 255])
        #expect(restored.cgImage?.width == 64)
        #expect(restored.cgImage?.height == 64)
    }
}
