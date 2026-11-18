import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct NativePrimaryWindowAndPageStageTests {
    @Test func orderedFeaturesMatchReplicatedScalarWindows() throws {
        // Frozen scalar rows cover a one-pixel image axis, a duplicate 9-pixel
        // sampling window, and a horizontal reduction across a strip boundary.
        let fixtures: [(Int, Int, Double, [String])] = [
            (1, 41, 260, ["f3c561ff0a70a08ceb3a9c80040d24cae58426da2f6f98ae34ee490f6c0220ba",
                "da7126730f5ec42bf316bfafbb3db51131ae83c766160fdd166303ee6ddbed80"]),
            (25, 17, 36, ["ecf700caec6bdfb458f89a1cc8868268515f04447ec8739149c6ce536479e498",
                "6a7e76b6accf1945c289cdc465bb0cca67aefcf325a8cf944a4983aa8dc6be04"]),
            (2057, 7, 260, ["9ec6cdc0dfc502b2b376c113e761767813bdd13a04716321e712b5f3cfd947e7",
                "c3f866c1e39ccfa95eb759cbaa1f1b1d0f44d142edd617e89d127aad3282c1a3"])
        ]
        for (width, height, font, hashes) in fixtures {
            let pixels = width * height
            let rgb = (0..<(pixels * 3)).map { UInt8(truncatingIfNeeded: $0 * 37 + ($0 % 17) * 231) }
            let mask = (0..<pixels).map { $0 % 13 < 7 ? UInt8(255) : 0 }
            let coarse = (0..<(pixels * 4)).map { Float($0 % 97) / 97 }
            let full = (0..<(pixels * 27)).map { Float($0 % 101) / 101 }
            let points = [[CGPoint.zero, CGPoint(x: width - 1, y: 0), CGPoint(x: width - 1, y: height - 1)]]
            let input = NativePixelRFFeatures.Input(width: width, height: height, rgb: rgb, nativeMask: mask,
                polygons: points, fontPixels: font, coarseRF: coarse, fullRF: full)
            for (index, includeFullRF) in [false, true].enumerated() {
                let matrix = try NativePixelRFFeatures.extract(input, includeFullRF: includeFullRF)
                let digest = matrix.values.withUnsafeBytes { buffer in
                    var sha = SHA256()
                    sha.update(bufferPointer: buffer)
                    return sha.finalize().map { String(format: "%02x", $0) }.joined()
                }
                #expect(digest == hashes[index])
            }
        }
    }

    @Test func independentStagesRespectPhoneAndCropBudgets() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        func admitted(_ pixels: Int, cores: Int = 4, ram: UInt64 = 7, available: UInt64 = 2) -> Bool {
            NativeSourceOwnerMeasurements.allowsIndependentPageStages(largestCrop: pixels, processors: cores,
                physicalMemory: ram * gib, availableMemory: available * gib)
        }
        #expect(admitted(750_000))
        #expect(!admitted(750_001))
        #expect(!admitted(0))
        #expect(!admitted(20_000, cores: 3))
        #expect(!admitted(20_000, ram: 6))
        #expect(!admitted(20_000, available: 1))
    }

    @Test func resultAndErrorOrderFollowStyleThenBody() throws {
        let values = try NativeSourceOwnerMeasurements.pair({ 17 }, { 23 })
        #expect(values.0 == 17)
        #expect(values.1 == 23)
        enum Failure: Error { case style, body }
        #expect(throws: Failure.style) {
            try NativeSourceOwnerMeasurements.pair({ () throws -> Int in throw Failure.style },
                                                    { () throws -> Int in throw Failure.body })
        }
    }
}
