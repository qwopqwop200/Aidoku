import Compression
import Foundation
import Testing
@testable import Aidoku

/// Original pale lettering and protected drawing in the reviewed 134x175 crop.
/// Generated from source RGB and the preexisting 0d22699e ownership footprint;
/// current restoration output is never used to produce these annotations.
enum NativeSlantedSourceSemanticAnnotations {
    static func verifyDenseLogo(original: [UInt8], restored: [UInt8]) throws {
        typealias F = NativeSourceRestorationMatrixFixtures
        try #require(original.count == 134 * 175 * 4 && restored.count == original.count)
        try #require(F.hash(Data(original)) == "5020cb1bb66515f74d3015b2626e8775c5f2231e13a7d42cbb83437e1a54566a")
        let encoded = [
            "eJztmkFyxCAMBCX//9GpyhqQBGxymtFh+pDy5kJbSDIYP48QQgghhBBCCCGEEEII0RczYyv8SnzoYcEUMeug0cLCOlqQVFpYnCSQGp/B1siO19hv392X",
            "CktiWDjXwrpYeA8Ld35e2LRgSowMZZcI1OKUFW9eAvOiRGC/Rkg8ceBVF2CNPAvBg2bhIyRwjVwZsURJwVi5kVMELZFF5r8IFluJEC2MaxEaBs9irSuw",
            "zbNqWO2ihBa+X2KDsdUnw8LHmuKgAbMID7FNAy+RGwXTomoALdag1QIh8Wz3XywgEs8Y+JYYMIm0E2NapFolJufsnUSL8BCjZee4fy8pgs2LaZH3AniL",
            "tPjHLn2LxrFakRYlH8ALrbJZJlnYEfCi808JnkWTfVmghQTTosWEtHhpgK3T+4SQQnHZGSI0skRY6HAs3nXe+4djEd5vlsc7MhTJopQIekLC6BSLmZqn",
            "DQnSYqYm02JFpM4ITMJyhfAs1vK/vOjEx2JWC61QkwaladW3SbwHavpBOiHyogG0+Ecw4BaHYCActjM7jkXVqEYYif0Ak2Jx0XDohJwOzELnREkcDg9D",
            "+4ZZHL9BGRc4i297dqDFXQMpcdXASlw00BKHT2xJn9lyo3BQIUsIIYQQQgghhBBCCCGE2PkBZX6jTQ==",
        ].joined()
        let packed = try #require(Data(base64Encoded: encoded))
        let compressed = Data(packed.dropFirst(2).dropLast(4))
        var masks = [UInt8](repeating: 0, count: 134 * 175)
        let byteCount = masks.count
        let written = masks.withUnsafeMutableBytes { destination in compressed.withUnsafeBytes { source in
            compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, byteCount,
                source.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
        } }
        try #require(written == masks.count)
        try #require(F.hash(Data(masks)) == "0bf5bd548b84b0251d8635d53e4097f719c48f1ffd4cbd961d55ff314c468140")
        var ink = 0, artwork = 0, remaining = 0, paintedArtwork = 0
        for i in masks.indices {
            if masks[i] & 1 != 0 {
                ink += 1
                if restored[i * 4 + 3] < 250 || F.delta(restored, original, i) < 10 { remaining += 1 }
            }
            if masks[i] & 2 != 0 {
                artwork += 1
                if restored[i * 4 + 3] != 0 { paintedArtwork += 1 }
            }
        }
        #expect(ink == 500 && artwork == 20652)
        #expect(remaining == 0, "Every annotated source letter must be erased")
        #expect(paintedArtwork == 0, "Face icon and drawing outside reviewed owned glyphs must stay untouched")
    }
}
