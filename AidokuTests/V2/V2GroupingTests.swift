import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct V2GroupingTests {
    private func column(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat, _ text: String, width: CGFloat = 40) -> V2Line {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        return V2Line(polygon: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                      bounds: rect, vertical: true, detectionScore: 0.9, text: text, confidence: 0.95)
    }

    @Test func groupsBalloonColumnsRightToLeftAndAttachesBalloon() {
        let balloon = V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 380, y: 80, width: 200, height: 400), score: 0.95)
        let lines = [column(420, 100, 300, "左"), column(470, 100, 300, "右"),
                     column(100, 900, 200, "下")]
        let blocks = V2Grouping.group(lines, layout: [balloon], pageSize: CGSize(width: 1000, height: 1400))
        #expect(blocks.count == 2)
        #expect(blocks[0].lines.map(\.text) == ["右", "左"])
        #expect(blocks[0].sourceText == "右左")
        #expect(blocks[0].balloon == balloon.bounds)
        #expect(blocks[1].balloon == nil)
        #expect(blocks.map(\.readingOrder) == [0, 1])
        #expect(blocks.map(\.id) == [0, 1])
    }

    @Test func panelFramesOrderRightPanelFirst() {
        let frames = [V2LayoutRegion(kind: .frame, bounds: CGRect(x: 520, y: 20, width: 460, height: 1360), score: 0.9),
                      V2LayoutRegion(kind: .frame, bounds: CGRect(x: 20, y: 20, width: 460, height: 1360), score: 0.9)]
        // The left panel's text sits higher, so a plain top-to-bottom pass would read it first.
        let lines = [column(200, 60, 200, "L"), column(700, 400, 200, "R")]
        let blocks = V2Grouping.group(lines, layout: frames, pageSize: CGSize(width: 1000, height: 1400))
        #expect(blocks.map(\.sourceText) == ["R", "L"])
    }

    @Test func roleFilterMarksOnlyUnambiguousSoundEffects() {
        let sfx = V2LayoutRegion(kind: .sfx, bounds: CGRect(x: 0, y: 0, width: 300, height: 300), score: 0.9)
        let weak = V2LayoutRegion(kind: .sfx, bounds: CGRect(x: 500, y: 0, width: 300, height: 300), score: 0.6)
        let balloon = V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 0, y: 500, width: 300, height: 300), score: 0.9)
        let sfxInBalloon = V2LayoutRegion(kind: .sfx, bounds: CGRect(x: 0, y: 500, width: 300, height: 300), score: 0.95)
        let layout = [sfx, weak, balloon, sfxInBalloon]
        #expect(V2RoleFilter.role(of: CGRect(x: 50, y: 50, width: 100, height: 100), layout: layout) == .sfx)
        #expect(V2RoleFilter.role(of: CGRect(x: 550, y: 50, width: 100, height: 100), layout: layout) == .dialogue)
        #expect(V2RoleFilter.role(of: CGRect(x: 50, y: 550, width: 100, height: 100), layout: layout) == .dialogue)
        #expect(V2RoleFilter.role(of: CGRect(x: 900, y: 900, width: 50, height: 50), layout: layout) == .dialogue)
    }

    @Test func joinsLatinWithSpacesAndCJKDirectly() {
        #expect(V2Grouping.joinedText(["こんにちは", "世界"]) == "こんにちは世界")
        #expect(V2Grouping.joinedText(["HELLO", "WORLD"]) == "HELLO WORLD")
        #expect(V2Grouping.joinedText([]) == "")
    }
}
