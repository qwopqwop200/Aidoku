import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeMinimalSourceStyleInputTests {
    @Test func componentAreasKeepDiagonalConnectionsAndSparseBorders() throws {
        let ops = NativeOpenCVAppearanceImageOperations()
        let w = 7, h = 5
        var mask = [UInt8](repeating: 0, count: w * h)
        #expect(try ops.componentSizes(mask, width: w, height: h).isEmpty)
        mask[w + 1] = 255
        mask[2 * w + 2] = 1
        mask[3 * w + 3] = 128
        mask[4 * w + 6] = 255
        #expect(try ops.componentSizes(mask, width: w, height: h) == [3, 1])

        for y in 0..<h { for x in 0..<w {
            mask[y * w + x] = x.isMultiple(of: 2) && y.isMultiple(of: 2) ? 255 : 0
        } }
        #expect(try ops.componentSizes(mask, width: w, height: h) == [Int](repeating: 1, count: 12))
    }

    @Test func minimalDefaultAndExplicit32RetainOnlySelectedLearnedSourceClosure() throws {
        #expect(NativeSourceInferencePolicy.defaultMode == .minimalM1P9Body64Presence95)
        for mode in [NativeSourceInferencePolicy.Mode.minimalM1P9Body32, .minimalM1P9Body64, .minimalM1P9Body64Presence95] {
            #expect(mode.usesMinimalObservations && mode.usesMinimalM1Style && mode.usesSingleBodyWeight)
            #expect(!mode.usesAcceptedAppearance && !mode.usesAcceptedWeight)
            #expect(NativeSourceInferencePolicy.resolveMode(override: mode.rawValue) == mode)
            #expect(NativeSourceInferencePolicy.erasureConfiguration(for: mode) ==
                NativeSourceInferencePolicy.primaryM1Configuration)
            #expect(NativeSourceInferencePolicy.erasureConfiguration(for: mode, erasurePolicy: .strong)?.policySHA256 ==
                NativeSourceInferencePolicy.primaryErasureConfiguration(.strong).policySHA256)
            #expect(NativeSourceInferencePolicy.erasureConfiguration(for: mode, erasurePolicy: .originalM1) ==
                NativeSourceInferencePolicy.primaryM1Configuration)
        }
        #expect(NativeM1SourceStyleInference.cacheIdentity(for: .rounds32) !=
            NativeM1SourceStyleInference.cacheIdentity(for: .rounds64))
        #expect(NativeM1SourceStyleInference.roleSHA256(for: .rounds64).count == 5)
        #expect(NativeM1SourceStyleInference.roleAssetBytes(for: .rounds64) == 180_037)
    }

    @Test func stagedAssetsAreExplicitLocalAndMissingNeverFallsBack() throws {
        let mode = NativeSourceInferencePolicy.Mode.minimalM1P9Body32
        #expect(throws: (any Error).self) { try NativeSourceInferencePolicy.resolveStagedM1StyleDirectory(mode: mode) }
        #expect(throws: (any Error).self) {
            try NativeSourceInferencePolicy.resolveStagedM1StyleDirectory(mode: mode, environmentPath: "relative/models")
        }
        #expect(throws: (any Error).self) {
            try NativeSourceInferencePolicy.resolveStagedM1StyleDirectory(mode: mode, override: URL(string: "https://example.invalid/models")!)
        }
        #expect(try NativeSourceInferencePolicy.resolveStagedM1StyleDirectory(mode: .minimalPrimary, environmentPath: "ignored") == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(try NativeSourceInferencePolicy.resolveStagedM1StyleDirectory(mode: mode, override: directory) == directory.standardizedFileURL)
        #expect(throws: (any Error).self) { try NativeM1SourceStyleInference(directory: directory, variant: .rounds32) }
    }

    private func input(mask: [UInt8], primary: [Float]? = nil) -> NativeMinimalSourceStyleInput {
        let w = 16, h = 16
        var rgb = [UInt8](repeating: 240, count: w * h * 3)
        for y in 4..<12 { for x in 6..<10 {
            for c in 0..<3 { rgb[(y * w + x) * 3 + c] = 20 }
        }}
        return .init(width: w, height: h, rgb: rgb, ownMask: mask,
            primary: primary ?? [Float](repeating: 0.7, count: w * h), fontPriorSourcePixels: 12,
            bbox: CGRect(x: 3, y: 3, width: 10, height: 10), sourceIdentity: "synthetic-source-style-test",
            sourceText: "字", memberPolygons: [[CGPoint(x: 3, y: 3), CGPoint(x: 13, y: 3),
                CGPoint(x: 13, y: 13), CGPoint(x: 3, y: 13)]])
    }

    @Test func acceptsActualNative255MaskAndRejectsInvalidProbability() throws {
        try input(mask: [UInt8](repeating: 255, count: 256)).validate()
        #expect(throws: (any Error).self) {
            try input(mask: [UInt8](repeating: 1, count: 256), primary: [Float](repeating: .nan, count: 256)).validate()
        }
    }

    @Test func native44UsesRealPrimaryAndRetainsMeasuredEmptyMask() throws {
        let observations = input(mask: [UInt8](repeating: 0, count: 256))
        let packet = try NativeM1SourceStyleFeatures44.extract(observations,
            ops: NativeOpenCVAppearanceImageOperations())
        #expect(!packet.colors.isEmpty)
        #expect(packet.maskFraction == 0)
        #expect(packet.features.allSatisfy { $0.count == 44 && $0.allSatisfy(\.isFinite) })
        for row in packet.features {
            // Empty own and near-own regions have no manufactured support.
            #expect(Array(row[35..<41]) == [Float](repeating: 0, count: 6))
            #expect(row[43] == 1)
            #expect(abs(row[41] - 0.7) < 0.00001)
        }
    }

    @Test func nativeMask255AndMask1MeasureSame44() throws {
        var mask = [UInt8](repeating: 0, count: 256)
        for y in 4..<12 { for x in 6..<10 { mask[y * 16 + x] = 1 }}
        let ops = NativeOpenCVAppearanceImageOperations()
        let a = try NativeM1SourceStyleFeatures44.extract(input(mask: mask), ops: ops)
        let b = try NativeM1SourceStyleFeatures44.extract(input(mask: mask.map { $0 == 0 ? 0 : 255 }), ops: ops)
        #expect(a.colors == b.colors)
        #expect(a.features == b.features)
        #expect(a.pair == b.pair)
    }
}
