import Testing
@testable import Aidoku

@Suite struct NativeFinalInkStageTests {
    private func card(id: String, owner: [Double], cluster: [Double]? = nil) -> NativeTranslationSourceStylePostPolish.Display {
        .init(id: id, eligible: true, sourceTextOnly: false, rotation: 0, script: "korean", vertical: false,
            fontName: "system", fontWeight: "700", glyph: 16, font: 16,
            sample: ["foreground": [60.0,20,20], "confidence": ["foreground": 0.9]], foreground: [60,20,20],
            stroke: nil, strokeWidth: 0, textPreserved: true, strokePreserved: false, darkMeasured: false,
            captionBackground: [255,255,255], ownerBackground: owner, restored: false,
            surfaceRange: nil, overlappingSurfaceLuminances: [], cluster: cluster)
    }

    @Test func finalContrastUsesNewOwnerAfterGeometryAndPreservesInitialCohort() throws {
        let input = (0..<4).map { card(id: String($0), owner: [255,255,255]) }
        let initial = NativeTranslationSourceStylePostPolish.resolve(input, preserveText: true, opacity: 1,
            clusterStrokes: false, stage: .initialInk)
        #expect(initial.allSatisfy { $0.foreground == [60,20,20] })
        #expect(initial.allSatisfy { $0.cluster == [60,20,20] })
        let moved = initial.map { card(id: $0.id, owner: [0,0,0], cluster: $0.cluster) }
        let final = NativeTranslationSourceStylePostPolish.resolve(moved, preserveText: true, opacity: 1,
            clusterStrokes: false, stage: .finalContrast)
        #expect(final.allSatisfy { $0.cluster == [60,20,20] })
        #expect(final.allSatisfy { $0.foreground != [60,20,20] })
        #expect(final.allSatisfy {
            NativeTranslationSourceStylePostPolish.luminanceContrast(
                NativeTranslationSourceStylePostPolish.luminance($0.foreground), 0, 0) >= 4.5
        })
    }

    @Test func certifiedSourcePositionKeepsItsReadableOutlineOnNewSurface() {
        var input = card(id: "source", owner: [0,0,0])
        input.stroke = [250,250,250]; input.strokeWidth = 1.5
        input.partialSourcePositionProof = true; input.strokePreserved = true
        let final = NativeTranslationSourceStylePostPolish.resolve([input], preserveText: true, opacity: 1,
            clusterStrokes: false, stage: .finalContrast)
        #expect(final.first?.foreground == [60,20,20])
        #expect(final.first?.stroke == [250,250,250])
        #expect(final.first?.strokeWidth == 1.5)
    }
}
