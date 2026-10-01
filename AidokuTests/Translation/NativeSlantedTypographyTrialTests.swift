import CoreGraphics
import Testing
@testable import Aidoku

struct NativeSlantedTypographyTrialTests {
    @Test func coarseDisplaySearchRetainsBodyCeilingBeforeFineFloor() {
        let sizes = NativeSlantedTypographyTrial.sizes(original: 40, base: 32, floor: 18, step: 0.5)
        #expect(Array(sizes.prefix(5)) == [40, 37.5, 35.25, 33, 32])
        #expect(sizes.last == 18)
        #expect(sizes.contains(31.5))
    }

    @Test func unsafeSourceOwnershipRejectsEveryAlternativeInk() {
        var colors: [[Double]] = []
        let chosen = NativeSlantedTypographyTrial.ink(source: [100, 30, 140], observed: [100, 30, 140],
            surface: .init(id: "unowned")) { color, audit in
                colors.append(color)
                audit.unsafeCount = 1
                audit.range = [245, 245]
                audit.samples = 100
                return false
            }
        #expect(chosen == nil)
        #expect(colors == [[100, 30, 140]])
    }

    @Test func flatPaperExtensionRequiresFourMatchingNeighbours() {
        let width = 12, height = 12
        let safe: [UInt8] = (0..<(width * height)).map { i in
            i % width >= 2 && i % width < 10 && i / width >= 2 && i / width < 10 ? 1 : 0
        }
        var luminance = [UInt8](repeating: 245, count: width * height)
        luminance[width + 5] = 100
        let source = NativeSlantedTypographyTrial.Surface(id: "paper", width: width, height: height,
            safe: safe, luminance: luminance)
        let expanded = NativeSlantedTypographyTrial.paperExpanded(source)
        #expect(expanded?.safe[width + 3] == 1)
        #expect(expanded?.safe[width + 5] == 0)
        #expect(expanded?.safe[width + 4] == 0)
        #expect(expanded?.safe[0] == 0)
        #expect(source.safe[width + 3] == 0)
    }

    @Test func exhaustedDeferredLiftKeepsCommittedGeometryAndColor() {
        let candidate = NativeSlantedTypographyTrial.Candidate(rect: CGRect(x: 30, y: 40, width: 60, height: 90),
            font: 6, pitch: 7.2, padding: [2, 2, 2, 2], angle: 0.2)
        let measurement = NativeSlantedTypographyTrial.Measurement(glyphs: [[2, 20, 10, 26]], lines: [],
            lineCount: 1, contentFits: true, wordBroken: false)
        let entry = NativeSlantedTypographyTrial.Entry(quad: candidate.rect, initial: candidate,
            text: "문장", sourceForeground: [80, 30, 120])
        let committed = NativeSlantedTypographyTrial.Result(candidate: candidate, measurement: measurement,
            surface: .init(id: "certified"), foreground: [80, 30, 120], accepted: true, pendingReadableLift: true)
        let hooks = NativeSlantedTypographyTrial.Hooks(measure: { _ in
            Issue.record("Exhausted budget must not shape a candidate")
            return nil
        }, longestWord: { _ in 0 }, fits: { _, _, _, _, _ in
            Issue.record("Exhausted budget must not inspect pixels")
            return false
        })
        var budget = 0
        let result = NativeSlantedTypographyTrial.lift(entry, result: committed, obstacles: [], budget: &budget, hooks: hooks)
        #expect(result.candidate.rect == committed.candidate.rect)
        #expect(result.candidate.font == 6)
        #expect(result.foreground == [80, 30, 120])
        #expect(result.surface?.id == "certified")
        #expect(!result.pendingReadableLift)
        #expect(budget == 0)
    }
}
