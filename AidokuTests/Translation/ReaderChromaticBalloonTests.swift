import Testing
import UIKit
@testable import Aidoku

@MainActor
struct ReaderChromaticBalloonTests {
    @Test(arguments: [CGSize(width: 1, height: 1), CGSize(width: 1, height: 100),
                      CGSize(width: 100, height: 1), CGSize(width: 2, height: 100),
                      CGSize(width: 4, height: 4096), CGSize(width: 4096, height: 4)])
    func narrowImagesPreserveRegionsWithoutContours(size: CGSize) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = try #require(UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }.cgImage)
        let input = [ReaderTranslationRegion(id: "dialogue", rect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
                                             source: "これは文章です")]
        #expect(ReaderTranslationChromaticBalloon.interiors(input, image: image) == [nil])
        #expect(ReaderTranslationChromaticBalloon.applying(input, image: image) == input)
    }

    private func page(_ balloons: [CGRect], fullTint: Bool = false) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 360, height: 480), format: format).image { context in
            UIColor(white: 0.85, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
            UIColor(red: 0.45, green: 0.27, blue: 0.5, alpha: 1).setFill()
            if fullTint { context.fill(CGRect(x: 0, y: 0, width: 360, height: 480)) }
            for rect in balloons { UIBezierPath(ovalIn: rect).fill() }
        }.cgImage!
    }
    private func region(_ id: String, _ text: String, _ box: CGRect) -> ReaderTranslationRegion {
        .init(id: id, rect: CGRect(x: box.minX / 360, y: box.minY / 480, width: box.width / 360, height: box.height / 480),
              source: text, confidence: 0.95, sourceImageAspectRatio: 0.75, sourceOrientation: .vertical,
              sourceSingleVerticalColumn: true)
    }
    @Test func adjacentColumnsShareOnlyTheirMeasuredBalloon() {
        let regions = [region("left", "左です", CGRect(x: 150, y: 130, width: 20, height: 80)),
                       region("right", "右から", CGRect(x: 180, y: 130, width: 20, height: 80))]
        let output = ReaderTranslationChromaticBalloon.applying(regions, image: page([CGRect(x: 90, y: 80, width: 180, height: 190)]))
        #expect(output.count == 1)
        #expect(output.first?.source == "右から左です")
        #expect(output.first?.unitMemberRects.count == 2)
        #expect(output.first?.balloonInterior?.contourVerified == true)
    }
    @Test func horizontalFragmentCanJoinItsAdjacentVerticalBalloonColumn() {
        let left = region("left", "左です", CGRect(x: 150, y: 130, width: 20, height: 80))
        var right = region("right", "右から", CGRect(x: 170, y: 130, width: 40, height: 25))
        right.sourceOrientation = .horizontal
        right.sourceSingleVerticalColumn = false
        let output = ReaderTranslationChromaticBalloon.applying([left, right],
            image: page([CGRect(x: 90, y: 80, width: 180, height: 190)]))
        #expect(output.count == 1)
        #expect(output.first?.source == "右から左です")
        #expect(output.first?.unitMemberRects.count == 2)
        #expect(output.first?.balloonInterior?.contourVerified == true)
    }
    @Test func distantMixedDirectionRepliesStaySeparate() {
        let left = region("left", "左です", CGRect(x: 120, y: 170, width: 20, height: 80))
        var right = region("right", "右から", CGRect(x: 150, y: 100, width: 40, height: 25))
        right.sourceOrientation = .horizontal
        let input = [left, right]
        let output = ReaderTranslationChromaticBalloon.applying(input,
            image: page([CGRect(x: 70, y: 70, width: 210, height: 240)]))
        #expect(output.count == 2)
        #expect(output.map(\.source) == input.map(\.source))
    }
    @Test func separateBalloonsOfTheSameColorStaySeparate() {
        let regions = [region("left", "はいです", CGRect(x: 90, y: 110, width: 20, height: 80)),
                       region("right", "いいえ", CGRect(x: 240, y: 110, width: 20, height: 80))]
        let output = ReaderTranslationChromaticBalloon.applying(regions, image: page([
            CGRect(x: 20, y: 60, width: 140, height: 180), CGRect(x: 190, y: 60, width: 140, height: 180)]))
        #expect(output.count == 2)
        #expect(output.map(\.source) == regions.map(\.source))
        #expect(output[0].balloonInterior != output[1].balloonInterior)
    }
    @Test func staggeredRepliesInAConnectedBalloonStaySeparate() {
        let regions = [region("left", "左です", CGRect(x: 120, y: 170, width: 20, height: 80)),
                       region("right", "右から", CGRect(x: 150, y: 130, width: 20, height: 80))]
        let output = ReaderTranslationChromaticBalloon.applying(regions, image: page([CGRect(x: 70, y: 70, width: 210, height: 240)]))
        #expect(output.count == 2)
        #expect(output.map(\.source) == regions.map(\.source))
    }
    @Test func punctuationRecoveryDoesNotAbsorbAnOrdinaryLatinWord() {
        let regions = [region("body", "あああ", CGRect(x: 120, y: 110, width: 40, height: 120)),
                       region("tail", "!?OK", CGRect(x: 120, y: 220, width: 40, height: 35))]
        #expect(ReaderTranslationChromaticBalloon.attachingReactionPunctuation(regions,
            image: page([CGRect(x: 60, y: 60, width: 230, height: 250)])) == regions)
    }
    @Test func connectedParagraphsRetainTheirOwnBalloonBodies() {
        var top = region("top", "これは上の吹き出しの文章です", CGRect(x: 138.75, y: 127.5, width: 60, height: 75))
        var bottom = region("bottom", "これは下の吹き出しの文章です", CGRect(x: 138.75, y: 236.25, width: 60, height: 75))
        top.sourceSingleVerticalColumn = false
        bottom.sourceSingleVerticalColumn = false
        let output = ReaderTranslationChromaticBalloon.applying([top, bottom], image: page([
            CGRect(x: 93.75, y: 93.75, width: 157.5, height: 142.5), CGRect(x: 93.75, y: 217.5, width: 157.5, height: 142.5)]))
        #expect(output.count == 2)
        #expect(output[0].source == top.source)
        #expect(output[1].source == bottom.source)
        #expect((output[0].balloonInterior?.center.y ?? 1) < 0.45)
        #expect((output[1].balloonInterior?.center.y ?? 0) > 0.45)
    }
    @Test func diagonalConnectedBodiesHaveIndependentCenters() {
        let upper = region("upper", "上の文章です", CGRect(x: 206.25, y: 138.75, width: 15, height: 67.5))
        let lower = region("lower", "下の文章です", CGRect(x: 138.75, y: 258.75, width: 15, height: 60))
        let output = ReaderTranslationChromaticBalloon.applying([upper, lower], image: page([
            CGRect(x: 138.75, y: 105, width: 127.5, height: 157.5), CGRect(x: 78.75, y: 217.5, width: 142.5, height: 142.5)]))
        #expect(output.count == 2)
        #expect((output[0].balloonInterior?.center.y ?? 1) < 0.5)
        #expect((output[1].balloonInterior?.center.y ?? 0) > 0.5)
    }
    @Test func pageBackgroundCannotBecomeABalloon() {
        let regions = [region("one", "本文です", CGRect(x: 150, y: 130, width: 20, height: 80))]
        let output = ReaderTranslationChromaticBalloon.applying(regions, image: page([], fullTint: true))
        #expect(output.first?.balloonInterior == nil)
    }
    @Test func grayscalePageDoesNotCreateAChromaticContour() {
        let regions = [region("one", "本文です", CGRect(x: 150, y: 130, width: 20, height: 80))]
        #expect(ReaderTranslationChromaticBalloon.interiors(regions, image: page([])) == [nil])
    }
    @Test func solidTintedBalloonAcceptsAColumnAtItsTaperedShoulder() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 480), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
            UIColor(red: 0.45, green: 0.7, blue: 0.8, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 90, y: 80, width: 180, height: 240)).fill()
        }.cgImage!
        // The OCR box crosses the oval's shoulder although its centre and
        // most of its sampled text area belong to the coloured balloon.
        let shoulder = region("shoulder", "これは文章です", CGRect(x: 120, y: 70, width: 40, height: 200))
        let outside = region("outside", "別の文章です", CGRect(x: 10, y: 70, width: 40, height: 200))
        let contours = ReaderTranslationChromaticBalloon.interiors([shoulder, outside], image: image)
        #expect(contours[0]?.contourVerified == true)
        #expect(contours[1] == nil)
        let rectangularPanel = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 480), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
            UIColor(red: 0.45, green: 0.7, blue: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 90, y: 80, width: 180, height: 240))
        }.cgImage!
        #expect(ReaderTranslationChromaticBalloon.interiors([shoulder], image: rectangularPanel) == [nil])
    }
    @Test func outlinedBalloonCanBeNearlyFilledByItsSourceTextBox() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 480), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
            UIColor.black.setFill(); UIBezierPath(ovalIn: CGRect(x: 90, y: 80, width: 180, height: 190)).fill()
            UIColor(white: 0.72, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 94, y: 84, width: 172, height: 182)).fill()
        }.cgImage!
        let region = region("full", "長い文章が吹き出しの内側を満たします", CGRect(x: 108, y: 98, width: 145, height: 155))
        #expect(ReaderTranslationChromaticBalloon.interiors([region], image: image).first??.contourVerified == true)
    }
    @Test func connectedBalloonCenterStaysInsideItsMeasuredSlice() {
        // Gallery 2842254 page 4: a connected, bent bubble has its centroid
        // between lobes; its measured horizontal slice ends before x=0.16.
        let rect = CGRect(x: 0.1064453125, y: 0.08103975535168195,
                          width: 0.234375, height: 0.2782874617737003)
        var spans = [Double](repeating: -1, count: 96)
        spans[60] = 0.1103515625; spans[61] = 0.1591796875
        spans[62] = 0.109375; spans[63] = 0.1591796875
        spans[90] = 0.1240234375; spans[91] = 0.232421875
        let invalid = CGPoint(x: 0.2065914411145264, y: 0.2571481091559299)
        let size = CGSize(width: 1024, height: 655)
        let projected = ReaderTranslationChromaticBalloon.centerInsideVerifiedSpans(
            invalid, rect: rect, spans: spans, imageSize: size)
        #expect(projected.x > 0.1103515625 && projected.x < 0.1591796875)
        #expect(projected.y >= rect.minY + rect.height * 30 / 48)
        #expect(projected.y <= rect.minY + rect.height * 31 / 48)
        #expect(ReaderTranslationChromaticBalloon.centerInsideVerifiedSpans(
            projected, rect: rect, spans: spans, imageSize: size) == projected)
    }
    @Test(arguments: [0.0, 0.01, 0.07, 0.33, 0.67, 0.93, 0.99])
    func sparseHueStillKeepsItsBalloon(hue: CGFloat) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 480), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
            UIColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 90, y: 80, width: 180, height: 190)).fill()
        }.cgImage!
        let regions = [region("one", "本文です", CGRect(x: 150, y: 130, width: 20, height: 80))]
        let contours = ReaderTranslationChromaticBalloon.interiors(regions, image: image)
        #expect(contours.first??.contourVerified == true)
    }
    @Test func observedShortKanaKeepsItsVerticalSourceAxis() {
        let box = CGRect(x: 0, y: 0, width: 50, height: 180)
        #expect(BrowserOverlayTextFlow.usesVerticalSourceLayout(rect: box, text: "・は？", sourceOrientation: .vertical))
        #expect(BrowserOverlayTextFlow.usesVerticalSourceLayout(rect: box, text: "oo・はい", sourceOrientation: .vertical))
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(rect: box, text: "Hello", sourceOrientation: .vertical))
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(rect: box, text: "は？", sourceOrientation: .horizontal))
    }
}
