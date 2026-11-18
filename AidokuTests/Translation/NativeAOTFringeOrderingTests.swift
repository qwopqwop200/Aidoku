import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeAOTFringeOrderingTests {
    private typealias Builder = NativeMainAOTRemovalMaskBuilder

    private func digest(_ mask: [UInt8]) -> String {
        SHA256.hash(data: Data(mask.map { $0 == 0 ? UInt8(0) : 255 }))
            .map { String(format: "%02x", $0) }.joined()
    }

    @Test func suppliedSelectionReplacesLegacyBeforeFringeAndSkipsGeneration() throws {
        var mask: [UInt8] = [255, 0, 0, 0]
        let selected: [UInt8] = [0, 255, 0, 0]
        var generatedCalls = 0, proposalCalls = 0
        let receipt = try Builder.selectAndCompleteFringe(mask: &mask, supplied: { selected }, generated: {
            generatedCalls += 1
            return [255, 255, 255, 255]
        }, propose: { seed in
            proposalCalls += 1
            #expect(seed == selected)
            return .init(additions: [2], audit: [])
        })
        #expect(generatedCalls == 0)
        #expect(proposalCalls == 1)
        #expect(mask == [0, 255, 1, 0]) // Legacy-only pixel must not leak back in.
        #expect(receipt.additions == [2])
        #expect(receipt.audit["seedOrigin"] as? String == "supplied-selected")
        #expect(receipt.audit["seedMaskSHA256"] as? String == digest(selected))
    }

    @Test func generatedSelectionReplacesLegacyBeforeFringe() throws {
        var mask: [UInt8] = [255, 0, 0, 0]
        let selected: [UInt8] = [0, 0, 255, 0]
        var generatedCalls = 0
        let receipt = try Builder.selectAndCompleteFringe(mask: &mask, supplied: { nil }, generated: {
            generatedCalls += 1
            return selected
        }, propose: { seed in
            #expect(seed == selected)
            return .init(additions: [3], audit: [])
        })
        #expect(generatedCalls == 1)
        #expect(mask == [0, 0, 255, 1])
        #expect(receipt.audit["seedOrigin"] as? String == "generated-selected")
        #expect(receipt.audit["seedMaskSHA256"] as? String == digest(selected))
    }

    @Test func legacyWithoutSelectionRetainsExistingSeedAndOnePassCompletion() throws {
        var mask: [UInt8] = [1, 0, 0, 0]
        let legacy = mask
        var proposalCalls = 0
        let receipt = try Builder.selectAndCompleteFringe(mask: &mask, supplied: { nil }, generated: { nil }, propose: { seed in
            proposalCalls += 1
            #expect(seed == legacy)
            #expect(seed[1] == 0) // A proposal cannot become a seed for another growth step.
            return .init(additions: [0, 1], audit: [])
        })
        #expect(proposalCalls == 1)
        #expect(mask == [1, 1, 0, 0])
        #expect(receipt.additions == [1]) // Already-masked support is not a new addition.
        #expect(receipt.audit["proposalAdditions"] as? Int == 1)
        #expect(receipt.audit["seedOrigin"] as? String == "legacy-no-selected")
        #expect(receipt.audit["seedMaskSHA256"] as? String == digest([255, 0, 0, 0]))
    }

    @Test(arguments: [false, true])
    func finalHardAndForeignProtectionWinsEvenWithRFExemptions(generated: Bool) throws {
        var mask: [UInt8] = [255, 0, 0, 0, 0]
        let selected: [UInt8] = [0, 255, 0, 0, 0]
        let receipt = try Builder.selectAndCompleteFringe(mask: &mask,
            supplied: { generated ? nil : selected }, generated: { selected }, propose: { _ in
                .init(additions: [2, 3, 4], audit: [])
            })
        // Pixel 2 represents hard/foreign protection, 3 an RF boundary veto,
        // and 4 an existing allowed RF exemption. Hard protection also covers
        // selected seed pixel 1, so protection cannot be bypassed by selection.
        let excluded = Builder.applyFinalProtection(mask: &mask,
            blocked: [0, 0, 255, 255, 255], hard: [0, 255, 255, 0, 0], exemptions: [1, 2, 4])
        #expect(mask == [0, 0, 0, 0, 255])
        #expect(excluded == 3)
        let retained = receipt.additions.filter { mask[$0] != 0 }.count
        #expect(retained == 1)
        #expect(receipt.additions.count - retained == 2)
    }

    @Test func disabledCompletionAndLegacyProtectionRemainUnchanged() throws {
        var mask: [UInt8] = [1, 1, 0]
        let receipt = try Builder.selectAndCompleteFringe(mask: &mask,
            supplied: { nil }, generated: { nil }, propose: { _ in .init(additions: [], audit: []) })
        let excluded = Builder.applyFinalProtection(mask: &mask, blocked: [0, 255, 0], hard: nil, exemptions: [])
        #expect(mask == [255, 0, 0])
        #expect(excluded == 1)
        #expect(receipt.additions.isEmpty)
    }

    @Test func emptyMaskRecoveryRequiresMatchingSFXNegativesForEveryOwner() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        let original = try #require(context.makeImage())
        let crop = CGRect(x: 0, y: 0, width: 4, height: 4)
        let polygon = [CGPoint.zero, CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 4), CGPoint(x: 0, y: 4)]
        func selected(_ pixels: [Int]) -> NativeSelectedSourceSegmentationMasks.Entry {
            var bytes = [UInt8](repeating: 0, count: 16)
            for pixel in pixels { bytes[pixel] = 255 }
            return .init(ownerPolygon: polygon, crop: crop, mask: bytes)
        }
        func region(_ query: Int, source: String, observed: @escaping (Int, Int) -> Bool) -> Ensemble100RFRegion {
            .init(queryID: query, classID: 1, confidence: 0.9, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                exterior: [], holes: [], sourcePixelMask: .init(sourceIdentity: source, queryID: query,
                    sourceWidth: 4, sourceHeight: 4, sample: observed))
        }
        let sfx = region(0, source: "source") { x, y in x == 0 && y == 0 }
        let overlapping = region(1, source: "source") { x, y in x == 1 && y == 0 }
        let stale = region(2, source: "different-source") { _, _ in false }
        func recover(_ entries: [NativeSelectedSourceSegmentationMasks.Entry]) throws -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 16)
            let count = try Builder.recoverSelectedInkOutsideSFX(original: original, sourceIdentity: "source",
                entries: entries, regions: [sfx, overlapping, stale], mask: &result) { stillProtected in
                #expect(stillProtected.map(\.queryID) == [2])
                var hard = [UInt8](repeating: 0, count: 16)
                hard[2] = 255 // Kept lettering or an actual protected contour.
                return hard
            }
            #expect(count == result.filter { $0 != 0 }.count)
            return result
        }
        let good = selected([0, 1, 2, 3])
        let result = try recover([good])
        #expect(result.indices.filter { result[$0] != 0 } == [3])
        let withheld = try recover([good, selected([0, 1, 2])])
        #expect(withheld.allSatisfy { $0 == 0 })
    }

    @Test func failedGenerationNeverRunsFringeOrFallsBackToLegacy() throws {
        enum FixtureFailure: Error { case generation }
        var mask: [UInt8] = [255, 0]
        var proposalCalls = 0
        do {
            _ = try Builder.selectAndCompleteFringe(mask: &mask, supplied: { nil }, generated: {
                throw FixtureFailure.generation
            }, propose: { _ in
                proposalCalls += 1
                return .init(additions: [1], audit: [])
            })
            Issue.record("Failed selected generation must propagate before fringe completion")
        } catch FixtureFailure.generation {
            #expect(proposalCalls == 0)
            #expect(mask == [255, 0])
        }
    }
}
