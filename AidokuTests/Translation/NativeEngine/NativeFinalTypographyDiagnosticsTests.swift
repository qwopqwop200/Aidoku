import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeFinalTypographyDiagnosticsTests {
    private func card() throws -> NativeTranslationRenderer.Card {
        let data = Data(#"{"id":"final-runs","text":"A😀\n漢","x":5,"y":6,"width":100,"height":80,"fontSize":12,"lineHeight":16,"paddingTop":0,"paddingRight":0,"paddingBottom":0,"paddingLeft":0,"sourceBounds":[0,0,1,1],"sourceFrame":[0,0,100,80]}"#.utf8)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:data)
        let style = NativeTranslationTypography.Style(fontSize:12,lineHeight:16,optimizesKoreanWrapping:false)
        return .init(item:item,typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,
            heavyStrokeWidth:0,finalFontSize:12)
    }

    @Test func finalRowsExposeActualFallbackGlyphRunsWithoutChangingLayout() throws {
        let card = try card(), originalRanges = card.typography.rangeBounds
        let report = NativeTranslationRenderer.finalTypographyDiagnostics(card)
        let rows = try #require(report["coreTextRows"] as? [[String:Any]])
        #expect(rows.count == 2)
        #expect(rows.compactMap { $0["text"] as? String }.joined() == card.typography.shapedText)
        let runs = rows.flatMap { $0["runs"] as? [[String:Any]] ?? [] }
        #expect(!runs.isEmpty && runs.allSatisfy { !($0["fontName"] as? String ?? "").isEmpty })
        #expect(runs.allSatisfy { ($0["glyphs"] as? [Int])?.count == ($0["positions"] as? [[Double]])?.count })
        #expect(JSONSerialization.isValidJSONObject(report))
        #expect(card.typography.rangeBounds == originalRanges)
    }

    @Test func absoluteChildRowsAreReportedAtTheirActualMovedFrames() throws {
        var card = try card()
        let style = NativeTranslationTypography.Style(fontSize:8,lineHeight:10,optimizesKoreanWrapping:false)
        let frame = CGRect(x:4,y:8,width:20,height:40)
        card.unitTextParts = [.init(text:"가",frame:frame,
            typography:NativeTranslationTypography.layout(text:"가",in:frame.size,style:style),style:style)]
        card.unitTextPartsOrigin = .zero
        card.textShift = CGPoint(x:2,y:3)
        let report = NativeTranslationRenderer.finalTypographyDiagnostics(card)
        let parts = try #require(report["parts"] as? [[String:Any]])
        #expect(report["parentTextDrawn"] as? Bool == false && parts.count == 1)
        #expect(parts[0]["shapedText"] as? String == "가")
        let rect = try #require(parts[0]["frame"] as? [Double])
        #expect(rect == [11,17,20,40])
        #expect(!(parts[0]["coreTextRows"] as? [[String:Any]] ?? []).isEmpty)
        #expect(JSONSerialization.isValidJSONObject(report))
    }
}
