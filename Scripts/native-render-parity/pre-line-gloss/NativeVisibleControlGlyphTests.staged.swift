import CoreGraphics
import CoreText
import Foundation
import Testing

@Suite struct NativeVisibleControlGlyphTests {
    @Test(arguments:["AppleSDGothicNeo-Bold","Helvetica-Bold"],[false,true])
    func formFeedPaintMatchesExplicitMissingGlyph(fontName:String,antialias:Bool) throws {
        let font=CTFontCreateWithName(fontName as CFString,16,nil)
        let source=NSMutableAttributedString(string:"\u{000C}",attributes:[
            NSAttributedString.Key(kCTFontAttributeName as String):font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
        NativeVisibleControlGlyphs.apply(to:source)
        #expect(source.string == "\u{000C}")
        let line=CTLineCreateWithAttributedString(source)
        let runs=CTLineGetGlyphRuns(line) as! [CTRun]
        let run=try #require(runs.first)
        var glyph:CGGlyph=1,advance=CGSize.zero
        CTRunGetGlyphs(run,CFRange(location:0,length:1),&glyph)
        CTRunGetAdvances(run,CFRange(location:0,length:1),&advance)
        var expectedGlyph:CGGlyph=0,expectedAdvance=CGSize.zero
        CTFontGetAdvancesForGlyphs(font,.horizontal,&expectedGlyph,&expectedAdvance,1)
        #expect(glyph == 0 && advance.width == expectedAdvance.width && advance.width > 0)
        let actual=try bitmap(antialias:antialias){ context in
            context.textPosition=CGPoint(x:10,y:24);CTLineDraw(line,context)
        }
        let expected=try bitmap(antialias:antialias){ context in
            var position=CGPoint(x:10,y:24),glyph:CGGlyph=0
            CTFontDrawGlyphs(font,&glyph,&position,1,context)
        }
        #expect(actual.elementsEqual(expected))
        #expect(actual.contains(where:{$0<255}))
        let actualPDF=try pdfRaster(antialias:antialias){context in
            context.textPosition=CGPoint(x:10,y:24);CTLineDraw(line,context)
        }
        let expectedPDF=try pdfRaster(antialias:antialias){context in
            var position=CGPoint(x:10,y:24),glyph:CGGlyph=0
            CTFontDrawGlyphs(font,&glyph,&position,1,context)
        }
        #expect(actualPDF.elementsEqual(expectedPDF))
        #if os(macOS)
        if let directory=ProcessInfo.processInfo.environment["AIDOKU_FF_ARTIFACT_DIR"] {
            let root=URL(fileURLWithPath:directory,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let name="\(fontName)-\(antialias ? "aa":"integer")"
            for (suffix,bytes) in [("actual-rgba",actual),("reference-rgba",expected),
                ("actual-pdf-rgba",actualPDF),("reference-pdf-rgba",expectedPDF)] {
                try Data(bytes).write(to:root.appendingPathComponent("\(name)-\(suffix).bin"))
            }
        }
        #endif
    }

    @Test func overrideUsesTheActualAttributedFontAndPreservesSourceIndices() throws {
        let first=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,16,nil)
        let second=CTFontCreateWithName("Courier-Bold" as CFString,23,nil)
        let source=NSMutableAttributedString(string:"A\u{000C}B\u{000C}C",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):first])
        source.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),value:second,range:NSRange(location:3,length:1))
        let before=source.string
        NativeVisibleControlGlyphs.apply(to:source)
        #expect(source.string == before)
        for index in [1,3] {
            let actualObject=try #require(source.attribute(NSAttributedString.Key(kCTFontAttributeName as String),at:index,effectiveRange:nil))
            #expect(CFGetTypeID(actualObject as CFTypeRef) == CTFontGetTypeID())
            let actual=actualObject as! CTFont
            let info=try #require(source.attribute(NSAttributedString.Key(kCTGlyphInfoAttributeName as String),at:index,effectiveRange:nil))
            #expect(CFGetTypeID(info as CFTypeRef) == CTGlyphInfoGetTypeID())
            #expect(CTFontCopyPostScriptName(actual) as String == CTFontCopyPostScriptName(index==1 ? first:second) as String)
            let line=CTLineCreateWithAttributedString(source.attributedSubstring(from:NSRange(location:index,length:1)))
            var glyph:CGGlyph=1;CTRunGetGlyphs((CTLineGetGlyphRuns(line) as! [CTRun])[0],CFRange(location:0,length:1),&glyph)
            #expect(glyph == 0)
        }
    }

    private func bitmap(antialias:Bool,draw:(CGContext)->Void)throws->[UInt8] {
        var bytes=[UInt8](repeating:255,count:96*64*4)
        try bytes.withUnsafeMutableBytes { data in
            let context=try #require(CGContext(data:data.baseAddress,width:96,height:64,bitsPerComponent:8,bytesPerRow:96*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray:0,alpha:1));context.textMatrix = .identity
            context.setShouldAntialias(antialias);context.setAllowsAntialiasing(true)
            context.setShouldSmoothFonts(false);context.setAllowsFontSmoothing(false)
            draw(context)
        }
        return bytes
    }
    private func pdfRaster(antialias:Bool,draw:(CGContext)->Void)throws->[UInt8] {
        let bytes=NSMutableData(),consumer=try #require(CGDataConsumer(data:bytes as CFMutableData))
        var bounds=CGRect(x:0,y:0,width:96,height:64)
        let context=try #require(CGContext(consumer:consumer,mediaBox:&bounds,nil))
        context.beginPDFPage(nil);context.setFillColor(CGColor(gray:0,alpha:1));context.textMatrix = .identity
        draw(context);context.endPDFPage();context.closePDF()
        let provider=try #require(CGDataProvider(data:bytes as CFData)),document=try #require(CGPDFDocument(provider))
        let page=try #require(document.page(at:1))
        return try bitmap(antialias:antialias){$0.drawPDFPage(page)}
    }
}
