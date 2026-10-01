import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCTFontStrokePainterTests {
    private func context() throws -> CGContext {
        try #require(CGContext(data: nil, width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 640,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    private func line(secondStroke: CGFloat) -> CTLine {
        let font=CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil)
        let key=NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
        let text=NSMutableAttributedString(string: "AB", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 1),key: 5])
        text.addAttribute(key,value:secondStroke,range:NSRange(location:1,length:1))
        return CTLineCreateWithAttributedString(text)
    }
    @Test func unsupportedLaterRunDeclinesBeforeAnyPainting() throws {
        let canvas=try context()
        #expect(!NativeCTFontStrokePainter.draw(line:line(secondStroke:-5),context:canvas,anchor:CGPoint(x:20,y:40)))
        let bytes=try #require(canvas.data).assumingMemoryBound(to:UInt8.self)
        #expect(UnsafeBufferPointer(start:bytes,count:640*80).allSatisfy {$0==0})
    }
    @Test func validStrokePassRetainsParentTransform() throws {
        let canvas=try context()
        canvas.translateBy(x:8,y:7);canvas.rotate(by:0.2)
        let matrix=canvas.ctm
        canvas.textMatrix = CGAffineTransform(a:1,b:0.1,c:0,d:1,tx:0,ty:0)
        canvas.textPosition = CGPoint(x:3,y:4)
        let textMatrix=canvas.textMatrix,textPosition=canvas.textPosition
        #expect(NativeCTFontStrokePainter.draw(line:line(secondStroke:5),context:canvas,anchor:CGPoint(x:20,y:40),horizontalScale:0.9))
        #expect(canvas.ctm==matrix)
        #expect(canvas.textMatrix==textMatrix && canvas.textPosition==textPosition)
        let bytes=try #require(canvas.data).assumingMemoryBound(to:UInt8.self)
        #expect(UnsafeBufferPointer(start:bytes,count:640*80).contains {$0>0})
    }

    @Test func followingCoreTextFillKeepsItsOriginalOrientation() throws {
        let painted=try context(),control=try context()
        #expect(NativeCTFontStrokePainter.draw(line:line(secondStroke:5),context:painted,anchor:CGPoint(x:20,y:30)))
        let fill=CTLineCreateWithAttributedString(NSAttributedString(string:"AB",attributes:[
            NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica-Bold" as CFString,20,nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(red:0,green:0,blue:1,alpha:1)]))
        for canvas in [painted,control] {
            canvas.textPosition=CGPoint(x:90,y:50)
            CTLineDraw(fill,canvas)
        }
        let actual=try #require(painted.data).assumingMemoryBound(to:UInt8.self)
        let expected=try #require(control.data).assumingMemoryBound(to:UInt8.self)
        var hasFill=false
        for y in 0..<80 { for x in 80..<160 { for channel in 0..<4 {
            let offset=y*640+x*4+channel
            #expect(actual[offset]==expected[offset])
            hasFill = hasFill || expected[offset] != 0
        } } }
        #expect(hasFill)
    }

    @Test func followingPathRetainsItsAuthoredMiterLimit() throws {
        let painted = try context(), control = try context()
        for canvas in [painted, control] { canvas.setMiterLimit(10) }
        #expect(NativeCTFontStrokePainter.draw(line: line(secondStroke: 5), context: painted, anchor: CGPoint(x: 10, y: 30)))
        for canvas in [painted, control] {
            canvas.setStrokeColor(CGColor(gray: 0, alpha: 1))
            canvas.setLineWidth(5)
            canvas.move(to: CGPoint(x: 90, y: 15))
            canvas.addLine(to: CGPoint(x: 110, y: 65))
            canvas.addLine(to: CGPoint(x: 112, y: 15))
            canvas.strokePath()
        }
        let actual = try #require(painted.data).assumingMemoryBound(to: UInt8.self)
        let expected = try #require(control.data).assumingMemoryBound(to: UInt8.self)
        var visible = false
        for y in 0..<80 { for x in 80..<160 { for channel in 0..<4 {
            let offset = y * 640 + x * 4 + channel
            #expect(actual[offset] == expected[offset])
            visible = visible || expected[offset] != 0
        } } }
        #expect(visible)
    }
}
