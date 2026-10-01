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

    @Test(arguments: ["safe", "unproven-frame", "not-page", "horizontal-source", "content-overflow", "auxiliary-ink", "excluded-ink", "dark-backing"])
    func narrowSourceFrameReflowRetainsAllPixelAndContentGuards(_ condition: String) {
        typealias Trial = NativeSlantedTypographyTrial
        let candidate = Trial.Candidate(rect: CGRect(x: 0, y: 0, width: 13.3, height: 43.1),
            font: 5, pitch: 5.9668, padding: [0.74, 0.55, 0.74, 0.55])
        let entry = Trial.Entry(quad: candidate.rect, initial: candidate, text: "음(승인가)",
            sourceVertical: condition != "horizontal-source", canMeasureWords: false, sourceForeground: [56, 56, 56])
        let width = 40, height = 140
        var safe: [UInt8] = (0..<(width * height)).map { $0 % width >= 6 && $0 % width <= 33 ? 1 : 0 }
        if condition == "auxiliary-ink" { safe[50 * width + 20] = 0 }
        if condition == "excluded-ink" { safe[75 * width + 18] = 0 }
        let luminance = [UInt8](repeating: condition == "dark-backing" ? 12 : 245, count: width * height)
        let surface = Trial.Surface(id: "owned-page", isPage: condition != "not-page", width: width, height: height,
            safe: safe, luminance: luminance, verifiedNarrowFrame: condition != "unproven-frame")
        var fractions: [Double] = []
        let hooks = Trial.Hooks(measure: { c in
            fractions.append(c.fraction)
            let narrow = c.fraction <= 0.7
            return Trial.Measurement(glyphs: narrow ? [[3, 10, 10, 32]] : [[0.5, 15, 12.5, 26]], lines: [],
                lineCount: narrow ? 4 : 2, contentFits: condition != "content-overflow", wordBroken: false)
        }, longestWord: { _ in 0 }, fits: { s, c, glyphs, color, audit in
            // Exercise the actual glyph-footprint checker, not an accepting mock.
            NativeSlantedInkSafety.rotatedPageInkFits(width: s.width, height: s.height, safe: s.safe, luminance: s.luminance,
                sx: 1, sy: 1, ox: 0, oy: 0, rects: glyphs, node: [0, 0, 13.3, 43.1], angle: c.angle,
                toImage: { [$0 * 3, $1 * 3] }, foreground: color, audit: &audit)
        })
        let result = Trial.run(entry, surface: surface, hooks: hooks)
        if condition == "safe" {
            #expect(result.accepted && result.candidate.fraction == 0.7)
            #expect(result.measurement?.lineCount == 4 && result.candidate.font == 5)
            #expect(result.safety?.unsafeCount == 0 && result.safety?.dim == 0)
            #expect(result.foreground == entry.sourceForeground)
        } else if condition == "dark-backing" {
            // Polarity correction remains the original behavior when ownership is safe.
            #expect(result.accepted && result.candidate.fraction == 0.7)
            #expect(result.safety?.unsafeCount == 0 && result.foreground != entry.sourceForeground)
        } else {
            #expect(!result.accepted)
        }
        if ["unproven-frame", "not-page", "horizontal-source"].contains(condition) {
            #expect(fractions.allSatisfy { $0 == 1 })
        }
        #expect(result.measurements <= 8)
        #expect(surface.safe == safe && surface.luminance == luminance)
    }
}
