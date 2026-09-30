import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

struct NativeImageCodecAuditTests {
    @Test func aesCounterCarryAcrossFull128BitBoundaryMatchesOpenSSL() {
        // openssl enc -aes-256-ctr, key bytes 00...1f, counter ffff...fffe.
        // Four blocks cross the full 128-bit wrap; outer XOR/base64 was produced in Python.
        let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let encoded = "zc_Nys_Hz8rKm8-bnczHnGHo5xf5TVmRKEtqDDwG9t5FhuYYTbE3igSTHmcCjV2_p8AE5CpGzIKv8Zhr0n92ifJcdqhOtJnnq6ub"
        #expect(SoraRawImageCodec.decryptPath(encoded, uuid: key)
                == "chapter/日本語/001.webp?x=123456789012345678901234567890")
    }

    @Test func completePixelReferencesIncludeQuarterTurnsAndRemainders() throws {
        // Independent Python hashlib/Mulberry32 reference moves source pixels FORWARD
        // clockwise into destination tiles. Fixed hashes cover every RGBA pixel.
        for (width, height, seed, expected) in [
            (16, 16, "audit", "50d8d2a84eb221e583a0bc661c457eb107e595e2ab9e1b0965a5940b63e75778"),
            (17, 19, "audit", "f61e45898b3d8a31e993cbe2a414e8569d51ca823a916d168aa58c419c602e6e"),
            (24, 16, "日本語", "4c7914f049b9985450a8552ecd2371dc47eba0dbad7ca1aa68b6f38f0160cda6")
        ] {
            let input = try fixture(width: width, height: height)
            let output = try #require(SoraRawImageCodec.unscramble(input, seed: seed)?.cgImage)
            let data = try #require(output.dataProvider?.data) as Data
            var packed = Data()
            for row in 0..<height {
                packed.append(data[(row * output.bytesPerRow)..<(row * output.bytesPerRow + width * 4)])
            }
            #expect(SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined() == expected)
        }
    }

    @Test func unevenSlicesReassembleEveryOriginalRowExactlyOnce() throws {
        let image = try fixture(width: 8, height: 19)
        var rows: [UInt8] = []
        var totalHeight = 0
        for index in 0..<7 {
            let slice = try #require(SoraRawImageCodec.slice(image, slice: index, slices: 7)?.cgImage)
            let data = try #require(slice.dataProvider?.data) as Data
            totalHeight += slice.height
            for row in 0..<slice.height { rows.append(data[row * slice.bytesPerRow + 1]) }
        }
        #expect(totalHeight == 19)
        #expect(rows == (0..<19).map(UInt8.init))
    }

    @Test func identityOrderPreservesRasterOrientation() throws {
        let image = try fixture(width: 4, height: 6)
        let original = try #require(image.cgImage?.dataProvider?.data) as Data
        let decoded = try MangarawJPImageCodec.unscramble(image, key: "061a071a041a05")
        let cgImage = try #require(decoded.cgImage)
        let data = try #require(cgImage.dataProvider?.data) as Data
        var packed = Data()
        for row in 0..<6 { packed.append(data[(row * cgImage.bytesPerRow)..<(row * cgImage.bytesPerRow + 16)]) }
        #expect(packed == original)
    }

    @Test func malformedUnicodeOrderKeyThrowsInsteadOfIndexingCharacters() {
        #expect(throws: (any Error).self) { try SpoilerPlusImageCodec.order("é") }
        #expect(throws: (any Error).self) { try SpoilerPlusImageCodec.order("aéa") }
    }

    private func fixture(width: Int, height: Int) throws -> UIImage {
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
