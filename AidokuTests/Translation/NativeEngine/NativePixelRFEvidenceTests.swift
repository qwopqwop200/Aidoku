import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct NativePixelRFEvidenceTests {
    private func fixture(badClassLogit: Float? = nil, badMaskLogit: Float? = nil) -> NativeRFDETRLayoutResult {
        let width = 1027, height = 163, side = 162
        let masks = (0..<4).map { channel -> NativeRFDETRLayoutMask in
            var logits = (0..<(side * side)).map { index -> Float in
                let x = index % side, y = index / side
                switch (x + 3 * y + channel) % 9 {
                case 0: return -Float.zero
                case 1: return Float.leastNonzeroMagnitude
                case 2: return Float(80).nextUp
                case 3: return -Float(80).nextUp
                default: return Float((3 * x + y + channel) % 17 - 8) / 4
                }
            }
            if channel == 3, let badMaskLogit { logits[side * side - 1] = badMaskLogit }
            return .init(queryID: channel, sourceWidth: width, sourceHeight: height, logits: logits)
        }
        let boxes = [
            CGRect(x: 0.5 / 162, y: 0, width: 23.0 / 162, height: 1),
            CGRect(x: 0, y: 0.5 / 162, width: 1, height: 0),
            CGRect(x: -0.125, y: -0.125, width: 0.75, height: 0.75),
            CGRect(x: 0.75, y: 0.75, width: 0.5, height: 0.5)
        ]
        let queries = (0..<300).map { q -> NativeRFDETRClassEvidence in
            let group = q % 4
            var logits = (0..<5).map { i in Float((q + 2 * i) % 7 - 3) }
            if q == 0, let badClassLogit { logits[4] = badClassLogit }
            let mask = NativeRFDETRLayoutMask(queryID: q, sourceWidth: width, sourceHeight: height,
                                               logits: masks[group].logits)
            return .init(queryID: q, logits: logits, probabilities: [], normalizedBounds: boxes[group],
                         sourceBounds: .zero, mask: mask)
        }
        let primitives = (0..<8).map { i in
            NativeRFDETRLayoutPrimitive(queryID: i, semanticClass: NativeRFDETRLayoutClass(rawValue: i % 4)!,
                confidence: i < 4 ? 0.5 : 0.75, normalizedBounds: .zero, sourceBounds: .zero,
                mask: i == 7 ? nil : masks[i % 4])
        }
        return .init(imageIdentity: "rf-support", sourceWidth: width, sourceHeight: height,
            primitives: primitives, maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0,
            modelMilliseconds: 0, decodeMilliseconds: 0, computeUnits: "fixture", fromCache: false,
            classEvidence: Array(queries.reversed()))
    }

    @Test func supportPreservesNativePlaneBytesAcrossTilesAndClampedEdges() throws {
        let evidence = try NativePixelRFEvidence(result: fixture())
        let members = [[CGPoint(x: 7, y: 2), CGPoint(x: 700, y: 2), CGPoint(x: 450, y: 139)]]
        // The scalar reference emitted these native Float32 byte hashes before
        // separable interpolation, including quantized logits and owner constants.
        let controls = [
            (CGRect(x: 0, y: 0, width: 1027, height: 3), "23d941f4e8e06babdef0a4604bfe662386e4b3d5f6cefc16dc9121f10ef5daf4"),
            (CGRect(x: 1, y: 3, width: 513, height: 159), "aabe2e29860f2b99334ecb0b60be417fffefab237548c03a60b02b52bd1b4d99"),
            (CGRect(x: 514, y: 161, width: 513, height: 2), "6e8fddeea7e30c8d2faa54e2494af334e7e1fc3285f74df3769544a001941ca1")
        ]
        for (crop, expected) in controls {
            let support = try evidence.support(crop: crop, polygons: members, sourceIdentity: "rf-support")
            var digest = SHA256()
            for plane in [support.full, support.coarse, support.affinityScores] {
                plane.withUnsafeBytes { digest.update(bufferPointer: $0) }
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            #expect(hash == expected)
            #expect(support.ownerQueries == [20, 4, 16, 0, 12])
        }
    }

    @Test func containedCropsReuseOnlyOwnerIndependentNativeCells() throws {
        let page = fixture()
        let cached = try NativePixelRFEvidence(result: page)
        let a = [[CGPoint(x: 30, y: 10), CGPoint(x: 425, y: 22), CGPoint(x: 200, y: 140)]]
        let b = [[CGPoint(x: 320, y: 48), CGPoint(x: 830, y: 21), CGPoint(x: 670, y: 156)]]
        let outer = CGRect(x: 0, y: 0, width: 1027, height: 163)
        let inner = CGRect(x: 412, y: 37, width: 210, height: 52)
        _ = try cached.support(crop: outer, polygons: a, sourceIdentity: page.imageIdentity)
        for members in [a, b, a] {
            let expected = try NativePixelRFEvidence(result: page).support(
                crop: inner, polygons: members, sourceIdentity: page.imageIdentity)
            let actual = try cached.support(crop: inner, polygons: members, sourceIdentity: page.imageIdentity)
            #expect(actual.ownerQueries == expected.ownerQueries)
            for (lhs, rhs) in [(actual.affinityScores, expected.affinityScores),
                               (actual.coarse, expected.coarse), (actual.full, expected.full)] {
                #expect(lhs.elementsEqual(rhs) { $0.bitPattern == $1.bitPattern })
            }
        }
    }

    @Test func rejectsNonfiniteModelSamplesAndInvalidSourceIdentity() throws {
        for bad in [Float.nan, .infinity, -.infinity] {
            #expect(throws: NativePixelRFEvidence.Failure.incompleteQueries) {
                try NativePixelRFEvidence(result: fixture(badClassLogit: bad))
            }
            #expect(throws: NativePixelRFEvidence.Failure.incompleteQueries) {
                try NativePixelRFEvidence(result: fixture(badMaskLogit: bad))
            }
        }
        let evidence = try NativePixelRFEvidence(result: fixture())
        #expect(throws: NativePixelRFEvidence.Failure.sourceMismatch) {
            try evidence.support(crop: .zero, polygons: [], sourceIdentity: "other")
        }
        let validMembers = [[CGPoint(x: 7, y: 2), CGPoint(x: 70, y: 2), CGPoint(x: 45, y: 13)]]
        for invalidCrop in [
            CGRect(x: 0.5, y: 0, width: 32, height: 32),
            CGRect(x: CGFloat.nan, y: 0, width: 32, height: 32),
            CGRect(x: 0, y: 0, width: 0, height: 32)
        ] {
            #expect(throws: NativePixelRFEvidence.Failure.invalidGeometry) {
                try evidence.support(crop: invalidCrop, polygons: validMembers, sourceIdentity: "rf-support")
            }
        }
    }
}
