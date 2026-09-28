import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderColumnLayoutTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("ColumnLayout") }

    @Test func adjacentColumnsShareTypeSizeWithoutCrossingTheImageOrEachOther() throws {
        let sources = [CGRect(x: 4, y: 20, width: 12, height: 100),
                       CGRect(x: 40, y: 21, width: 14, height: 110),
                       CGRect(x: 82, y: 20, width: 16, height: 100)]
        let variants: [BrowserOverlayDisplayVariant] = ["안녕, 잘 지냈어?", "오늘 다시 만나서 반가워.", "앗, 고마워!"].map { .plain($0, vertical: false) }
        let bounds = CGRect(x: 0, y: 0, width: 430, height: 320)
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: bounds, measurementCache: .init())
        #expect(layouts.count == 3)
        let ordered = try sources.indices.map { try #require(layouts[$0]) }
        #expect(Set(ordered.map(\.maximumFontSize)).count == 1)
        #expect(ordered.allSatisfy { bounds.contains($0.rect) && $0.maximumFontSize >= 7.5 })
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: ordered.map(\.rect)))
        #expect(ordered[0].rect.maxX < ordered[1].rect.minX)
        #expect(ordered[1].rect.maxX < ordered[2].rect.minX)
    }

    @Test func alignedSourceRowTrimsInwardAndKeepsExistingColumnAllocation() throws {
        let sources = [CGRect(x: 20, y: 20, width: 20, height: 100),
                       CGRect(x: 60, y: 23, width: 20, height: 100),
                       CGRect(x: 100, y: 21, width: 20, height: 100)]
        let variants = ["네!", "오늘은 괜찮아.", "응!"].map {
            BrowserOverlayDisplayVariant.plain($0, vertical: false)
        }
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: .init())
        let ordered = try sources.indices.map { try #require(layouts[$0]) }
        #expect(Set(ordered.map { $0.rect.minY }) == [23])
        #expect(Set(ordered.map(\.maximumFontSize)).count == 1)
        // Equal source spacing stays equal despite unequal translation lengths.
        #expect(ordered[0].rect.midX == 30)
        #expect(ordered[1].rect.midX == 70)
        #expect(ordered[2].rect.midX == 110)
        for (index, layout) in ordered.enumerated() {
            #expect(layout.rect.maxY == sources[index].maxY)
            #expect(layout.rect.height <= sources[index].height)
        }
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: ordered.map(\.rect)))
    }

    @Test func shortRepliesStayInTheTallDialogueRow() throws {
        let sources = [CGRect(x: 20, y: 20, width: 12, height: 100),
                       CGRect(x: 60, y: 21, width: 12, height: 24),
                       CGRect(x: 100, y: 20, width: 12, height: 100)]
        let variants = ["오늘 다시 만나서 반가워.", "앗!", "그러니까 사과하지 말라니까!"].map {
            BrowserOverlayDisplayVariant.plain($0, vertical: false)
        }
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: .init())
        let ordered = try sources.indices.map { try #require(layouts[$0]) }
        #expect(Set(ordered.map { $0.rect.minY }) == [21])
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: ordered.map(\.rect)))
    }

    @Test func shortLabelsWithoutTallDialogueAreNotAColumnRow() {
        let sources = [CGRect(x: 20, y: 20, width: 12, height: 24),
                       CGRect(x: 60, y: 20, width: 12, height: 24)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("앗!", vertical: false) }
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
    }

    @Test func isolatedBalloonAndDifferentRowsKeepTheirOriginalPlanner() {
        let sources = [CGRect(x: 20, y: 20, width: 20, height: 100),
                       CGRect(x: 60, y: 120, width: 20, height: 100)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("괜찮아, 고마워.", vertical: false) }
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants, eligible: [true, true],
            bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants, eligible: [false, false],
            bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
    }

    @Test func compactPageNeverOffersColumnsBelowTheRenderedFontFloor() {
        let sources = [CGRect(x: 4, y: 10, width: 6, height: 60),
                       CGRect(x: 30, y: 10, width: 7, height: 60)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("앗, 네!", vertical: false) }
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true], bounds: CGRect(x: 0, y: 0, width: 215, height: 160), measurementCache: nil)
        #expect(layouts.isEmpty)
    }

    @Test func aSeparateCaptionInTheGapBlocksColumnExpansion() {
        let sources = [CGRect(x: 20, y: 20, width: 15, height: 100),
                       CGRect(x: 65, y: 20, width: 15, height: 100),
                       CGRect(x: 42, y: 45, width: 17, height: 12)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("괜찮아, 고마워.", vertical: false) }
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants, eligible: [true, true, false],
            bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
    }

    @Test func sourceEmphasisKeepsALargerSizeInsideTheSameColumns() throws {
        let sources = [CGRect(x: 12, y: 20, width: 15, height: 130),
                       CGRect(x: 58, y: 20, width: 15, height: 130),
                       CGRect(x: 104, y: 20, width: 15, height: 130)]
        let variants = ["오늘 다시 만났네.", "정말 반가워!", "멈춰!"].map {
            BrowserOverlayDisplayVariant.plain($0, vertical: false)
        }
        let normal = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil)
        let styled = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil,
            sourceSizes: [8, 8.2, 16])
        #expect(styled.count == 3)
        for index in sources.indices { #expect(styled[index]?.rect == normal[index]?.rect) }
        #expect(try #require(styled[2]).maximumFontSize > #require(styled[0]).maximumFontSize)
    }

    @Test func whiteQuotedCaptionsShareTheRowDespiteDifferentLengths() {
        let sources = [
            CGRect(x: 94.93076923076923, y: 15.711538461538462, width: 10.584615384615384, height: 105.35),
            CGRect(x: 218.47307692307692, y: 15.38076923076923, width: 11.576923076923078, height: 37.21153846153847),
            CGRect(x: 326.30384615384617, y: 15.711538461538462, width: 11.080769230769231, height: 84.51153846153845),
            CGRect(x: 119.73846153846155, y: 16.04230769230769, width: 10.419230769230769, height: 84.0153846153846),
            CGRect(x: 145.0423076923077, y: 16.20769230769231, width: 17.861538461538462, height: 97.57692307692307),
            CGRect(x: 185.72692307692307, y: 16.20769230769231, width: 18.52307692307692, height: 146.2),
            CGRect(x: 285.45384615384614, y: 15.876923076923077, width: 26.461538461538463, height: 98.07307692307691),
            CGRect(x: 45.97692307692308, y: 16.869230769230768, width: 17.696153846153845, height: 127.18076923076924),
            CGRect(x: 244.10769230769233, y: 16.538461538461537, width: 26.296153846153846, height: 138.59230769230768),
            CGRect(x: 351.60769230769233, y: 19.01923076923077, width: 18.192307692307693, height: 94.93076923076923),
            CGRect(x: 166.04615384615386, y: 195.81538461538463, width: 15.38076923076923, height: 44.32307692307692),
        ]
        let variants: [BrowserOverlayDisplayVariant] = [
            "“그러니까 사과하지 말라니까!”",
            "“아우………”",
            "“미…… 미안해……”",
            "“미안…… 미안해……”",
            "“자, 물 데워졌으니까 얼른 몸 깨끗하게 씻어!”",
            "“그런 건 내 일이야! 당신은 아이들이나 잘 돌보고 있으라고!”",
            "“정말! 왜 당신이 사과하는 거야? 사과해야 할 쪽은 나라고!”",
            "“……아아 정말, 진짜 둔해 빠졌네! 자, 어서 다 벗어!”",
            "“어차피 밀어붙여져서 거절 못 한 거지? 맨날 그렇게 손해만 본다니까!”",
            "“왜 그런 짓을 한 거야? 당신은 처음이라면서!”",
            "“으앙~”",
        ].map { .plain($0, vertical: false) }
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: sources.map { _ in true }, bounds: CGRect(x: 0, y: 0, width: 430, height: 322.5),
            measurementCache: .init())
        #expect(layouts.count == 10)
        #expect(Set(layouts.values.map { $0.rect.minY }).count == 1)
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: layouts.values.map(\.rect)))
        for (index, layout) in layouts {
            #expect(abs(layout.rect.midX - sources[index].midX) <= 24)
            #expect(layout.rect.minY >= sources[index].minY)
            #expect(layout.rect.minY - sources[index].minY <= 8)
            #expect(layout.maximumFontSize >= 7.5)
        }
    }

    @Test func coloredQuotedCaptionsShareTheRowDespiteDifferentLengths() {
        let sources = [
            CGRect(x: 308.7730769230769, y: 43.330769230769235, width: 11.742307692307692, height: 113.12307692307692),
            CGRect(x: 283.63461538461536, y: 43.9923076923077, width: 11.411538461538461, height: 91.62307692307694),
            CGRect(x: 333.58076923076925, y: 43.9923076923077, width: 27.123076923076923, height: 129.66153846153847),
            CGRect(x: 374.76153846153846, y: 43.82692307692307, width: 10.915384615384616, height: 112.29615384615386),
            CGRect(x: 400.06538461538463, y: 44.15769230769231, width: 10.419230769230769, height: 139.25384615384615),
            CGRect(x: 36.05384615384615, y: 44.32307692307692, width: 18.192307692307693, height: 138.92307692307693),
        ]
        let variants: [BrowserOverlayDisplayVariant] = [
            "에에...... 그냥 너라고 불러도 돼",
            "'에...... 저기...... 저는......'",
            "아...... 하지만 지금은 마리 씨가 안 계셔서...... 조금 있으면 돌아오실 것 같으니까...... 그...... 기다려 주시겠어요?'",
            "'그럼 이번에도 \"보답\"을 부탁할게'",
            "저기...... 기부...... 감사합니다",
            "'이 고아원에 기부하면 시스터가 보답을 해주는 거겠지?'",
        ].map { .plain($0, vertical: false) }
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: sources.map { _ in true }, bounds: CGRect(x: 0, y: 0, width: 430, height: 322.5),
            measurementCache: .init())
        #expect(layouts.count == 5)
        #expect(Set(layouts.values.map { $0.rect.minY }).count == 1)
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: layouts.values.map(\.rect)))
        for (index, layout) in layouts {
            #expect(abs(layout.rect.midX - sources[index].midX) <= 24)
            #expect(layout.rect.minY >= sources[index].minY)
            #expect(layout.rect.minY - sources[index].minY <= 8)
            #expect(layout.maximumFontSize >= 7.5)
        }
    }

    // Opt-in replay of manually annotated source captures and fixed translations.
    // This measures layout/rasterization, not OCR or provider accuracy.
}
