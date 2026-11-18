import CoreGraphics
import CoreText
import Foundation
import Darwin
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeAOTRawTextPainterTests {
    @Test func boundRoundContourSurvivesTighteningAndRejectsDifferentGlyphAlpha() throws {
        let width = 300, height = 100, font: CGFloat = 40
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let row = NSAttributedString(string: "MWAV ···", attributes: [
            .init(kCTFontAttributeName as String): CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, font, nil),
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            .init(kCTKernAttributeName as String): 0])
        let baseline = CGPoint(x: 20, y: 60)
        context.textMatrix = .identity; context.textPosition = CGPoint(x: baseline.x, y: CGFloat(height) - baseline.y)
        CTLineDraw(CTLineCreateWithAttributedString(row), context)
        let image = try #require(context.makeImage())
        let style = NativeSourceStylePaint.Style(sourceFontPixels: 40,
            bands: [.init(rgb: [221, 90, 5], width: 5.5)], shadow: nil)
        #expect(try NativeSourceStylePaint.bindingRoundedContour(style, fill: image, rows: [row],
            baselines: [baseline], fontPixels: font, enabled: false) == nil)
        let bound = try #require(try NativeSourceStylePaint.bindingRoundedContour(style, fill: image, rows: [row],
            baselines: [baseline], fontPixels: font, enabled: true))
        #expect(bound.sourceFontPixels == style.sourceFontPixels && bound.bands[0].rgb == style.bands[0].rgb)
        #expect(bound.bands[0].width == 5.5 && bound.shadow == nil)
        #expect(!NativeSourceStylePaint.sameRoundedContour(style, bound))
        #expect(NativeSourceStylePaint.sameRoundedContour(bound, bound))
        let oracle = try NativeSourceStylePaint.renderRoundedContour(bound, fill: image, fontPixels: font)
        #expect(bound.roundedContour?.directCoreTextComparison["opaqueNativeGlyphFillChangedPixels"] == 0)
        #expect(oracle.audit["opaqueNativeGlyphFillRGBAExact"] as? Bool == true)
        #expect(oracle.audit["renderOracle"] as? String == "bound-stroke-raster-first-unchanged-retained-fill-raster-last")
        let finalContext = try #require(CGContext(data: nil, width: oracle.image.width, height: oracle.image.height,
            bitsPerComponent: 8, bytesPerRow: oracle.image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let prepared = try NativeMandatoryDisplayStroke.prepare(fill: image, restored: oracle.image,
            fontOutputPixels: font, fillFrame: oracle.fillFrame, sourceContourOnly: true)
        _ = try NativeSourceStylePaint.paint(bound, fill: prepared.fill, frame: prepared.frame, fontPixels: font,
            mandatoryOutward: prepared.outwardPixels, pageHeight: prepared.pageHeight, context: finalContext)
        NativeMandatoryDisplayStroke.paint([prepared], in: finalContext)
        let actual = try #require(finalContext.makeImage())
        #expect(try NativeMandatoryDisplayStroke.rgba(actual) == NativeMandatoryDisplayStroke.rgba(oracle.image))
        #expect(try NativeSourceStylePaint.bindingRoundedContour(style, fill: image, rows: [row],
            baselines: [CGPoint(x: baseline.x + 1, y: baseline.y)], fontPixels: font, enabled: true) == nil)
        var fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: image,
            frame: CGRect(x: 40, y: 40, width: width, height: height), fontOutputPixels: font)
        fill.ownerID = "bound"; fill.sourceStyle = bound; fill.sourceContourOnly = true
        let old = try NativeFinalTextPaintAdmission.retainedFootprint(fill)
        let tight = try NativeFinalTextPaintAdmission.tight(fill)
        let next = try NativeFinalTextPaintAdmission.retainedFootprint(tight)
        #expect(old.bounds == next.bounds && old.pixels == next.pixels && old.runs.count == next.runs.count)
        #expect(zip(old.runs, next.runs).allSatisfy { $0.y == $1.y && $0.left == $1.left && $0.right == $1.right })
        let tightOracle = try NativeSourceStylePaint.renderRoundedContour(bound, fill: tight.image, fontPixels: font)
        #expect(try NativeMandatoryDisplayStroke.rgba(tightOracle.image) == NativeMandatoryDisplayStroke.rgba(oracle.image))
        var bytes = try NativeMandatoryDisplayStroke.rgba(image)
        bytes[0] = 255; bytes[1] = 255; bytes[2] = 255; bytes[3] = 255
        var stale = fill
        stale.image = try NativeMandatoryDisplayStroke.image(bytes, width: width, height: height)
        #expect(throws: NativeMandatoryDisplayStroke.Failure.self) {
            _ = try NativeFinalTextPaintAdmission.retainedFootprint(stale)
        }
        bytes = try NativeMandatoryDisplayStroke.rgba(image)
        let opaque = try #require(stride(from: 3, to: bytes.count, by: 4).first { bytes[$0] == 255 })
        bytes[opaque - 3] = 254 // Same alpha and geometry, different fill RGBA.
        stale.image = try NativeMandatoryDisplayStroke.image(bytes, width: width, height: height)
        #expect(throws: NativeMandatoryDisplayStroke.Failure.self) {
            _ = try NativeFinalTextPaintAdmission.retainedFootprint(stale)
        }
    }
    @Test func finalVerificationAcceptsRestoredTransparentCanvasAfterAdmission() throws {
        let width = 12, height = 10, page = CGRect(x: 0, y: 0, width: 100, height: 100)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 3..<7 { for x in 2..<9 {
            let j = (y * width + x) * 4
            bytes[j] = 255; bytes[j + 1] = 255; bytes[j + 2] = 255; bytes[j + 3] = 255
        } }
        var original = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(
            image: try NativeMandatoryDisplayStroke.image(bytes, width: width, height: height),
            frame: CGRect(x: 20, y: 20, width: width, height: height), fontOutputPixels: 20)
        original.ownerID = "canvas"; original.hasFinalEffects = true
        let support = try NativeFinalTextPaintAdmission.retainedFootprint(original)
        let admitted = try NativeFinalTextPaintAdmission.place([original], page: page,
            fixedOrigins: ["canvas": support.bounds.origin])
        let tight = try #require(admitted.fills.first)
        #expect(tight.image.width < width && tight.image.height < height)
        // Reattach the authentic transparent canvas without another place call.
        var restored = tight; restored.image = original.image; restored.frame = original.frame
        let next = try NativeFinalTextPaintAdmission.retainedFootprint(restored)
        let actual = try NativeFinalTextPaintAdmission.retainedFootprint(tight)
        #expect(next.bounds == actual.bounds && next.pixels == actual.pixels)
        #expect(zip(next.runs, actual.runs).allSatisfy { $0.y == $1.y && $0.left == $1.left && $0.right == $1.right })
        try NativeFinalTextPaintAdmission.verifyRetainedPlacement([restored], footprints: [next], page: page)
        #expect(restored.frame == original.frame && restored.image.width == width && restored.image.height == height)
    }
    @Test func roundedSourceJoinsAreExplicitAndPreserveOpaqueGlyphFill() throws {
        let width = 480, height = 100, size: CGFloat = 40
        let face = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let text = "MWAV 한글", ink = CGColor(gray: 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): face, .init(kCTForegroundColorAttributeName as String): ink]
        func render(enabled: Bool, sourceOnly: Bool, outlinePresent: Bool, fillOnly: Bool = false) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let applied = NativeAOTRawTextPainter.configureRoundedSourceJoins(in: context,
                sourceContourOnly: sourceOnly, sourceOutlinePresent: outlinePresent, enabled: enabled)
            #expect(applied == (enabled && sourceOnly && outlinePresent))
            context.textMatrix = .identity
            if !fillOnly {
                let stroke = NSMutableAttributedString(string: text, attributes: attributes)
                stroke.addAttributes([.init(kCTStrokeColorAttributeName as String):
                    CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1),
                    .init(kCTStrokeWidthAttributeName as String): 27.5], range: NSRange(location: 0, length: stroke.length))
                context.textPosition = CGPoint(x: 20, y: 45)
                CTLineDraw(CTLineCreateWithAttributedString(stroke), context)
            }
            context.textPosition = CGPoint(x: 20, y: 45)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            return try NativeMandatoryDisplayStroke.rgba(#require(context.makeImage()))
        }
        let old = try render(enabled: false, sourceOnly: true, outlinePresent: true)
        #expect(try render(enabled: true, sourceOnly: false, outlinePresent: true) == old)
        #expect(try render(enabled: true, sourceOnly: true, outlinePresent: false) == old)
        let round = try render(enabled: true, sourceOnly: true, outlinePresent: true)
        let glyph = try render(enabled: false, sourceOnly: true, outlinePresent: true, fillOnly: true)
        #expect(round != old)
        for j in stride(from: 0, to: old.count, by: 4) {
            #expect(!(old[j + 3] == 0 && round[j + 3] > 0))
            if glyph[j + 3] == 255 {
                #expect(old[j..<j + 4].elementsEqual(round[j..<j + 4]))
            }
        }
    }
    @Test func emptySourceStylePreservesActualSupportAndFinalPalette() throws {
        let context = try #require(CGContext(data:nil,width:24,height:18,bitsPerComponent:8,bytesPerRow:96,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0,alpha:1))
        context.fill(CGRect(x:5,y:4,width:14,height:10))
        var plain = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image:try #require(context.makeImage()),
            frame:CGRect(x:40,y:40,width:24,height:18),fontOutputPixels:20)
        plain.ownerID="plain";plain.displayStrokeEndpoint=255
        var inert=plain
        inert.sourceStyle=try NativeSourceStylePaint.style(["sourceFontSize":20.0,
            "sourceAppearance":["outline":["present":false],"shadow":["present":false]]])
        #expect(inert.sourceStyle != nil)
        let before=try NativeFinalTextPaintAdmission.retainedFootprint(plain)
        let after=try NativeFinalTextPaintAdmission.retainedFootprint(inert)
        #expect(before.bounds==after.bounds && before.pixels==after.pixels)
        #expect(before.runs.count==after.runs.count)
        #expect(zip(before.runs,after.runs).allSatisfy {$0.y==$1.y && $0.left==$1.left && $0.right==$1.right})
        let background=try #require(CGContext(data:nil,width:120,height:120,bitsPerComponent:8,bytesPerRow:480,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        background.setFillColor(CGColor(gray:1,alpha:1));background.fill(CGRect(x:0,y:0,width:120,height:120))
        let restored=try #require(background.makeImage())
        let a=try #require(try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(plain,restored:restored))
        let b=try #require(try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(inert,restored:restored))
        #expect(NSDictionary(dictionary:a).isEqual(to:b))
    }

    @Test func semanticRowsPreserveOriginalTextAndClassifiedFontWeight() throws {
        let face = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        for (text, prefix, suffix, width) in [
            ("짜증 나……♡", "짜증 나", "……♡", CGFloat(110)),
            ("짜증나.....♡", "짜증나", ".....♡", CGFloat(110)),
            ("“짜증 나……♡”", "“짜증 나", "……♡”", CGFloat(110)),
            ("본문을 읽는다… (정말 그랬을까?)", "본문을 읽는다… ", "(정말 그랬을까?)", CGFloat(220))
        ] {
            let wrapped = try NativeWholeWordWrap.layout(text: text, font: face, size: 24,
                width: width, necessaryCJK: true)
            let ns = text as NSString
            #expect(wrapped.rows.map { ns.substring(with: $0.ownedRange) }.joined() == text)
            #expect(wrapped.rows.contains { $0.ownedRange.location == prefix.utf16.count })
            #expect(wrapped.rows.last.map { ns.substring(with: $0.paintedRange) } == suffix)
            #expect(wrapped.rows.allSatisfy { $0.overflow < 0.01 })
            let wide = try NativeWholeWordWrap.layout(text: text, font: face, size: 24, width: 1000, necessaryCJK: true)
            #expect(wide.rows.count == 1)
        }
        #expect(try NativeAOTRawTextPainter.sourceFontName(raw: ["sourceFontWeight": "bold", "renderBold": true]) == "AppleSDGothicNeo-Bold")
        #expect(try NativeAOTRawTextPainter.sourceFontName(raw: ["sourceFontWeight": "regular", "renderBold": false]) == "AppleSDGothicNeo-Regular")
        let longText = "첫 번째 문장을 읽고 두 번째 문장도 계속 읽는다……♡"
        let paragraph = try NativeWholeWordWrap.layout(text: longText, font: face, size: 24, width: 220, necessaryCJK: true)
        #expect(paragraph.rows.count >= 3)
        #expect(paragraph.rows.last.map { NativeLineBreakPolicy.isExpressiveTailRow(text: longText, range: $0.ownedRange) } == false)
        #expect(NativeRenderWrapQuality.semanticCrossings(longText, ranges: paragraph.rows.map(\.ownedRange)) == 0)
    }

    @Test func explicitExpressiveRowsKeepSpacesCenterAndActualClassifiedBoldFace() throws {
        let faceName = try NativeAOTRawTextPainter.sourceFontName(raw:["sourceFontWeight":"bold","renderBold":true])
        #expect(faceName == "AppleSDGothicNeo-Bold")
        let face = CTFontCreateWithName(faceName as CFString,24,nil)
        for (text, paintedPrefix) in [
            ("짜증 나\n……♡", "짜증 나"),
            ("짜증  나\n……♡", "짜증  나"),
            ("짜증나\n……♡", "짜증나"),
            ("짜증 나  \n  ……♡", "짜증 나")
        ] {
            let wrapped = try NativeWholeWordWrap.layout(text:text,font:face,size:24,width:300,necessaryCJK:true)
            let flow = try #require(try NativeFinalTextFlow.horizontal(text:text,font:face,size:24,width:300,
                minimumLineHeight:36,outwardExtent:2,color:CGColor(gray:0,alpha:1)))
            let ns = text as NSString
            #expect(wrapped.completeOwnership && wrapped.unresolvedGlyphRanges.isEmpty && flow.complete)
            try #require(wrapped.rows.count == 2 && flow.lines.count == 2)
            #expect(wrapped.rows.first?.hardBreak == true && wrapped.rows.last?.hardBreak == false)
            #expect(wrapped.rows.map {ns.substring(with:$0.ownedRange)}.joined() == text)
            #expect(flow.ranges.map {ns.substring(with:$0)}.joined() == text && flow.visibleUTF16 == ns.length)
            #expect(flow.ranges == wrapped.rows.map(\.ownedRange))
            #expect(ns.substring(with:wrapped.rows[0].paintedRange) == paintedPrefix)
            #expect(ns.substring(with:wrapped.rows[1].paintedRange) == "……♡")
            #expect(flow.appliedTracking == 0 && flow.aligned(.center).baselines == flow.baselines)
            for i in flow.lines.indices {
                let line = flow.lines[i], ink = CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
                let advance = CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
                let left = min(0,ink.isNull || ink.isEmpty ? 0:ink.minX)
                let right = max(advance,ink.isNull || ink.isEmpty ? 0:ink.maxX)
                #expect(abs(flow.baselines[i].x + (left+right)/2 - 150) < 0.01)
            }
            var letterRuns = 0
            for run in CTLineGetGlyphRuns(flow.lines[0]) as! [CTRun] {
                let r = CTRunGetStringRange(run), prefix = paintedPrefix as NSString
                try #require(r.location >= 0 && r.length > 0 && r.location+r.length <= prefix.length)
                let fragment = prefix.substring(with:NSRange(location:r.location,length:r.length))
                if fragment.unicodeScalars.contains(where:{CharacterSet.letters.contains($0)}) {
                    letterRuns += 1
                    let attrs = CTRunGetAttributes(run) as NSDictionary, actual = attrs[kCTFontAttributeName] as! CTFont
                    #expect(CTFontCopyPostScriptName(actual) as String == faceName)
                    #expect(CTFontGetSize(actual) == 24)
                }
            }
            #expect(letterRuns > 0)
        }
        for text in ["짜증 나……♡", "짜증 나 ……♡", "짜증나……♡"] {
            let ns = text as NSString
            let wide = try NativeWholeWordWrap.layout(text:text,font:face,size:24,width:1000,necessaryCJK:true)
            let flow = try #require(try NativeFinalTextFlow.horizontal(text:text,font:face,size:24,width:1000,
                minimumLineHeight:36,outwardExtent:2,color:CGColor(gray:0,alpha:1)))
            #expect(wide.rows.count == 1 && flow.lines.count == 1)
            #expect(wide.rows.map {ns.substring(with:$0.ownedRange)}.joined() == text)
            #expect(flow.ranges.map {ns.substring(with:$0)}.joined() == text)
        }
    }

    @Test func sharedTypographyUsesOneAlignmentWithoutChangingSeparateNarrationOrProtectedText() {
        let source: [[String: Any]] = [
            ["id": "a", "typographyGroupID": "cohort", "textAlignment": "left",
             "text": "First paragraph", "frame": [1, 2, 100, 80],
             "textPlacementGuide": ["horizontal": "left", "vertical": "top"]],
            ["id": "b", "typographyGroupID": "cohort", "textAlignment": "center"],
            ["id": "c", "typographyGroupID": "cohort", "textAlignment": "center"],
            ["id": "d", "typographyGroupID": "narration", "textAlignment": "left"],
            ["id": "e", "typographyGroupID": "narration", "textAlignment": "left"],
            ["id": "f", "typographyGroupID": "cohort", "textAlignment": "right", "keptLettering": true],
            ["id": "g", "typographyGroupID": "cohort", "textAlignment": "right", "vertical": true]
        ]
        let result = NativeTextAlignmentPolicy.annotate(source)
        #expect(result.map { $0["textAlignment"] as? String } == ["center", "center", "center", "left", "left", "right", "right"])
        #expect(result[0]["frame"] as? [Int] == [1, 2, 100, 80])
        #expect(result[0]["text"] as? String == "First paragraph")
        #expect(result[0]["textPlacementGuide"] as? [String: String] == ["horizontal": "center", "vertical": "top"])
        let tied = NativeTextAlignmentPolicy.annotate(Array(source.prefix(2)))
        #expect(tied.allSatisfy { $0["textAlignment"] as? String == "center" })
        let second = NativeTextAlignmentPolicy.annotate(result)
        #expect(NSDictionary(dictionary: ["items": second]).isEqual(to: ["items": result]))
    }

    @Test(arguments: ["AppleSDGothicNeo-Regular", "TimesNewRomanPS-ItalicMT"])
    func explicitRowAlignmentPreservesShapingAndDefaultCenter(fontName: String) throws {
        let text = "Different row widths\nshort\n마지막 줄", width: CGFloat = 380
        let face = CTFontCreateWithName(fontName as CFString, 24, nil)
        let original = try #require(try NativeFinalTextFlow.horizontal(text: text, font: face, size: 24,
            width: width, minimumLineHeight: 36, outwardExtent: 3, color: CGColor(gray: 0, alpha: 1)))
        #expect(original.lines.count == 3)
        #expect(original.aligned(.center).baselines == original.baselines)
        for alignment: CTTextAlignment in [.left, .right] {
            let aligned = original.aligned(alignment)
            #expect(aligned.ranges == original.ranges && aligned.visibleUTF16 == text.utf16.count)
            #expect(aligned.baselines.map(\.y) == original.baselines.map(\.y))
            #expect(aligned.size == original.size && aligned.appliedTracking == original.appliedTracking)
            for index in aligned.lines.indices {
                let bounds = CTLineGetImageBounds(aligned.lines[index], nil)
                    .union(CTLineGetBoundsWithOptions(aligned.lines[index], [.useGlyphPathBounds]))
                #expect(!bounds.isNull && !bounds.isEmpty)
                let edge = aligned.baselines[index].x + (alignment == .left ? bounds.minX : bounds.maxX)
                #expect(abs(edge - (alignment == .left ? 0 : width)) < 0.01)
            }
            let fitted = try #require(aligned.centered(height: original.size.height + 20))
            #expect(CGRect(origin: .zero, size: fitted.size).insetBy(dx: -0.01, dy: -0.01).contains(fitted.inkBounds))
        }
    }

    @Test func explicitlyAuthorizedCapacityShrinkKeepsFontClosureAndCompleteText() throws {
        let viewport = CGSize(width: 420, height: 220)
        let context = try #require(CGContext(data: nil, width: 420, height: 220, bitsPerComponent: 8,
            bytesPerRow: 420 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: viewport))
        let restored = try #require(context.makeImage())
        let texts = ["일반화된 경계 안에 모든 글자를 유지한다.", "짧은 문장"]
        let items: [NativeAOTRawTextPainter.Item] = texts.enumerated().map { index, text in
            .init(id: "fit-\(index)", text: text,
                frame: CGRect(x: 35 + index * 210, y: 35, width: 100, height: 120),
                fontSize: 36, lineHeight: 50.4, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "fixture")
        }
        var raws: [[String: Any]] = []
        var policies: [String: NativeTextExpansionPolicy] = [:]
        for (index, item) in items.enumerated() {
            let rect = [Double(20 + index * 210) / 420, 20.0 / 220, 150.0 / 420, 160.0 / 220]
            let spans = [rect[0], rect[0] + rect[2], rect[0], rect[0] + rect[2]]
            let policy = NativeTextExpansionPolicy(allowedRectNormalized: rect, candidates: [rect],
                maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 36, kind: "inside-balloon-mask",
                maskRectNormalized: rect, maskSpansNormalized: spans)
            #expect(policy.valid)
            policies[item.id] = policy
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
            raws.append(["id": item.id, "sourceBounds": [Double(item.frame.minX / viewport.width),
                Double(item.frame.minY / viewport.height), Double(item.frame.width / viewport.width),
                Double(item.frame.height / viewport.height)], "ensembleStrokeRatio": 0.06,
                "renderPreserveRequestedFontSize": false, "typographyGroupID": "same-family", "sourceFontFitGroupID": "same-source-em",
                "textExpansionPolicy": encoded])
        }
        let layer = try NativeAOTRawTextPainter.withConstrainedShapeCapacityRetry(true) {
            try NativeAOTRawTextPainter.renderCentered(items: items, rawItems: raws, viewport: viewport,
                restored: restored, allowShrink: true)
        }
        #expect(layer.complete && layer.expectedItems == 2 && layer.paintedItems == 2)
        let rows = try #require(layer.audit["rawNativeItems"] as? [[String: Any]])
        let fonts = try rows.map { try #require($0["fontSize"] as? Double) }
        #expect(fonts.count == 2 && abs(fonts[0] - fonts[1]) < 0.01)
        #expect(fonts.allSatisfy { $0 < 36 && $0 >= 36 * pow(0.9, 8) - 0.01 })
        for row in rows {
            let id = try #require(row["id"] as? String)
            let item = try #require(items.first { $0.id == id })
            #expect(row["sourceUTF16"] as? Int == item.text.utf16.count)
            #expect(row["visibleUTF16"] as? Int == item.text.utf16.count)
        }
        let admitted = try #require(layer.audit["finalPaintAdmission"] as? [[String: Any]])
        for receipt in admitted {
            let id = try #require(receipt["owner"] as? String)
            let bounds = try #require(receipt["finalFootprintOutputPixels"] as? [CGFloat])
            let policy = try #require(policies[id])
            #expect(policy.allows(CGRect(x: bounds[0], y: bounds[1],
                width: bounds[2], height: bounds[3]), page: CGRect(origin: .zero, size: viewport)))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func requestedFontSurvivesSmallSourceBoxesAndClosedSurfaceLocks(allowShrink: Bool, simpleLayout: Bool) throws {
        let viewport = CGSize(width: 480, height: 640)
        let requestedFontSize: CGFloat = 22
        let context = try #require(CGContext(data: nil, width: 480, height: 640,
            bitsPerComponent: 8, bytesPerRow: 480 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: viewport))
        let restored = try #require(context.makeImage())
        let items: [NativeAOTRawTextPainter.Item] = [
            .init(id: "shorter", text: "작은 원문 상자보다 긴 번역문도 요청한 글자 크기를 그대로 유지해야 한다.",
                frame: CGRect(x: 100, y: 120, width: requestedFontSize, height: 24),
                fontSize: requestedFontSize, lineHeight: 28,
                chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "test-fixture"),
            .init(id: "longer", text: "원문 상자의 크기가 작고 닫힌 표면과 레이아웃 잠금이 함께 전달되어도 " +
                "더 긴 번역문 전체를 같은 요청 글자 크기로 새롭게 조판하고 필요한 공간을 확장해야 한다.",
                frame: CGRect(x: 320, y: 440, width: 34, height: 26),
                fontSize: requestedFontSize, lineHeight: 28,
                chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "test-fixture")
        ]
        let rawItems: [[String: Any]] = items.map { item in
            ["id": item.id,
             "originalClosedSurfaceCapacity": [
                "version": 1,
                "slotNormalized": [Double(item.frame.minX / viewport.width), Double(item.frame.minY / viewport.height),
                    Double(item.frame.width / viewport.width), Double(item.frame.height / viewport.height)]
             ],
             "ensembleLockLayout": true,
             "renderPreserveRequestedFontSize": true]
        }

        // Exercise actual CoreText reshaping and retained paint, rather than a layout proposal.
        let layer = try NativeSimpleTextLayout.withEnabled(simpleLayout) {
            try NativeSimpleTextLayout.withWidthFit(true) {
                try NativeAOTRawTextPainter.renderCentered(items: items, rawItems: rawItems,
                    viewport: viewport, restored: restored, allowShrink: allowShrink)
            }
        }
        #expect(layer.complete)
        #expect(layer.expectedItems == items.count)
        #expect(layer.paintedItems == items.count)
        let audit = try #require(layer.audit["rawNativeItems"] as? [[String: Any]])
        #expect(audit.count == items.count)
        for item in items {
            let row = try #require(audit.first { $0["id"] as? String == item.id })
            #expect(try #require(row["fontSize"] as? Double) == Double(requestedFontSize))
            #expect(row["visibleUTF16"] as? Int == item.text.utf16.count)
            #expect(row["sourceUTF16"] as? Int == item.text.utf16.count)
            #expect(row["capacityExpanded"] as? Bool == true)
            #expect(row["fontShrunkForCapacity"] as? Bool == false)
            #expect(row["requestedCertifiedLayout"] as? Bool == false)
            #expect(row["certifiedLayoutConsumed"] as? Bool == false)
            if simpleLayout {
                // A complete one-letter word such as “긴” may occupy its own row.
                let ranges = try #require(row["lineRangesUTF16"] as? [[Int]])
                let lines = try #require(row["actualCoreTextLineStrings"] as? [String])
                let segmentation = try NativeAOTRawTextPainter.capacitySegmentation(text: item.text,
                    ranges: ranges, lines: lines)
                #expect(segmentation.isolatedSingletonRows == 0 && segmentation.cuts == 0)
            } else {
                #expect(row["oneCharacterRowsProxy"] as? Int == 0)
            }
        }
    }
}

extension NativeAOTRawTextPainterTests {
    private func gapMetric(_ rect: CGRect, font: Double = 24, scale: Double = 1,
                           cuts: Int = 0) -> NativeAOTRawTextPainter.CapacityMetric {
        .init(font: font, cuts: cuts, rows: 1, isolatedSingletonRows: 0,
            fontPixels: font * scale, paint: rect, readable: rect)
    }

    @Test(arguments: [true, false])
    func zeroCutSameFontNearContactRequiresIncumbentAndSeedsBothOwners(horizontal: Bool) throws {
        let first = CGRect(x: 0, y: 0, width: 40, height: 20)
        let oldPeer = horizontal ? CGRect(x: 83, y: 0, width: 40, height: 20)
            : CGRect(x: 0, y: 63, width: 40, height: 20)
        let newPeer = horizontal ? CGRect(x: 41, y: 0, width: 40, height: 20)
            : CGRect(x: 0, y: 21, width: 40, height: 20)
        let legacy = ["first": gapMetric(first), "peer": gapMetric(oldPeer)]
        let actual = ["first": gapMetric(first), "peer": gapMetric(newPeer)]
        // Exercise the same shortcut decision and comparator used by renderImpl.
        #expect(!NativeAOTRawTextPainter.capacityCanSkipLegacy(actual, initial: ["first": 24, "peer": 24]))
        let gap = try #require(NativeAOTRawTextPainter.capacityGaps(actual, legacy: legacy).first)
        #expect(gap.horizontal == horizontal)
        #expect(gap.before == 43)
        #expect(gap.after == 1)
        #expect(gap.regressed)
        #expect(NativeAOTRawTextPainter.capacityBadOwners(actual, legacy: legacy) == Set(["first", "peer"]))
        #expect(NativeAOTRawTextPainter.capacityCanSkipLegacy(["first": gapMetric(first)], initial: ["first": 24]))
    }

    @Test(arguments: [4.8, 5.0, 12.0])
    func generousWhitespaceCanShrinkToSafeFloorWithoutPreservingOldGap(newGap: Double) {
        let first = CGRect(x: 0, y: 0, width: 40, height: 20)
        let legacy = ["first": gapMetric(first), "peer": gapMetric(CGRect(x: 83, y: 0, width: 40, height: 20))]
        let actual = ["first": gapMetric(first), "peer": gapMetric(CGRect(x: 40 + newGap, y: 0, width: 40, height: 20))]
        // The exact .20em boundary also checks harmless floating-point subtraction.
        #expect(NativeAOTRawTextPainter.capacityBadOwners(actual, legacy: legacy).isEmpty)
        #expect(NativeAOTRawTextPainter.capacityGaps(actual, legacy: legacy).allSatisfy { !$0.regressed })
    }

    @Test
    func diagonalUnalignedPairsDoNotInventReadableGutters() {
        let first = CGRect(x: 0, y: 0, width: 40, height: 20)
        let legacy = ["first": gapMetric(first), "peer": gapMetric(CGRect(x: 83, y: 63, width: 40, height: 20))]
        let diagonal = ["first": gapMetric(first), "peer": gapMetric(CGRect(x: 41, y: 21, width: 40, height: 20))]
        #expect(NativeAOTRawTextPainter.capacityGaps(diagonal, legacy: legacy).isEmpty)
        #expect(NativeAOTRawTextPainter.capacityBadOwners(diagonal, legacy: legacy).isEmpty)
        let alignedLegacy = ["first": gapMetric(first), "peer": gapMetric(CGRect(x: 83, y: 0, width: 40, height: 20))]
        #expect(NativeAOTRawTextPainter.capacityGaps(diagonal, legacy: alignedLegacy).isEmpty)
    }

    @Test
    func safeReadableGapIsNotRejectedUsingTheSmallerHaloBoxGap() throws {
        let first = NativeAOTRawTextPainter.CapacityMetric(font: 24, cuts: 0, rows: 1, isolatedSingletonRows: 0, fontPixels: 24,
            paint: CGRect(x: 0, y: 0, width: 44, height: 24), readable: CGRect(x: 2, y: 2, width: 40, height: 20))
        let oldPeer = NativeAOTRawTextPainter.CapacityMetric(font: 24, cuts: 0, rows: 1, isolatedSingletonRows: 0, fontPixels: 24,
            paint: CGRect(x: 87, y: 0, width: 44, height: 24), readable: CGRect(x: 89, y: 2, width: 40, height: 20))
        let newPeer = NativeAOTRawTextPainter.CapacityMetric(font: 24, cuts: 0, rows: 1, isolatedSingletonRows: 0, fontPixels: 24,
            paint: CGRect(x: 45, y: 0, width: 44, height: 24), readable: CGRect(x: 47, y: 2, width: 40, height: 20))
        let legacy = ["first": first, "peer": oldPeer], actual = ["first": first, "peer": newPeer]
        let gap = try #require(NativeAOTRawTextPainter.capacityGaps(actual, legacy: legacy).first)
        #expect(gap.after == 5) // Paint-box gap is1; readable gap is safely above .20em.
        #expect(!gap.regressed)
        #expect(NativeAOTRawTextPainter.capacityBadOwners(actual, legacy: legacy).isEmpty)
    }

    private func completedMetricLayer(_ items: [NativeAOTRawTextPainter.Item],
                                      bounds: [String: CGRect]) throws -> NativeAOTTranslationPageComposer.TextLayer {
        // Synthetic completed-audit fixture, not a claim of actual alpha admission.
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let rows: [[String: Any]] = items.map { item in
            ["id": item.id, "fontSize": Double(item.fontSize), "softWordCuts": 0,
                "lineRangesUTF16": [[0, item.text.utf16.count]], "actualCoreTextLineStrings": [item.text],
                "sourceUTF16": item.text.utf16.count, "visibleUTF16": item.text.utf16.count]
        }
        // Reverse receipt order so the test requires an owner-ID join.
        let placements: [[String: Any]] = items.reversed().map { item in
            let r = bounds[item.id]!
            let rect = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
            return ["owner": item.id, "finalFootprintOutputPixels": rect, "readableBoundsOutputPixels": rect]
        }
        return .init(image: image, expectedItems: items.count, paintedItems: items.count, complete: true,
            audit: ["rawNativeItems": rows, "finalPaintAdmission": placements])
    }

    @Test
    func completedBoundsRemainOutputPixelsAndFontConvertsExactlyOnce() throws {
        let items: [NativeAOTRawTextPainter.Item] = ["first", "peer"].map { id in
            .init(id: id, text: "A", frame: CGRect(x: 0, y: 0, width: 20, height: 10), fontSize: 12,
                lineHeight: 16, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "test-fixture")
        }
        let first = CGRect(x: 100, y: 100, width: 40, height: 20)
        let oldBounds = ["first": first, "peer": CGRect(x: 150, y: 100, width: 40, height: 20)]
        let newBounds = ["first": first, "peer": CGRect(x: 143, y: 100, width: 40, height: 20)]
        let legacy = try NativeAOTRawTextPainter.capacityMetrics(completedMetricLayer(items, bounds: oldBounds), items: items, scale: 2)
        let actual = try NativeAOTRawTextPainter.capacityMetrics(completedMetricLayer(items, bounds: newBounds), items: items, scale: 2)
        #expect(actual["first"]?.font == 12)
        #expect(actual["first"]?.fontPixels == 24)
        #expect(actual["first"]?.rows == 1)
        #expect(actual["first"]?.isolatedSingletonRows == 0)
        #expect(actual["first"]?.paint == first)
        #expect(actual["peer"]?.readable == newBounds["peer"])
        let gap = try #require(NativeAOTRawTextPainter.capacityGaps(actual, legacy: legacy).first)
        #expect(gap.before == 10)
        #expect(gap.after == 3)
        #expect(gap.em == 24)
        #expect(gap.regressed) // Would be missed if logical12pt were confused with output24px.
        #expect(gap.audit["comparisonFontPixels"] as? Double == 24)
        #expect(gap.audit["candidateGapPixels"] as? Double == 3)
        let minimumGap = try #require(gap.audit["minimumGapPixels"] as? Double)
        #expect(abs(minimumGap - 4.8) < 1e-6)
    }

    @Test
    func moderateReadableGapsAreNotHiddenByHaloBoundingBoxesOrFontRecovery() throws {
        let first = CGRect(x: 0, y: 0, width: 128, height: 887)
        let legacy = ["first": gapMetric(first, font: 42),
            "peer": gapMetric(CGRect(x: 143, y: 0, width: 153, height: 467), font: 42)]
        let actual = ["first": gapMetric(first, font: 42),
            "peer": gapMetric(CGRect(x: 136, y: 9, width: 212, height: 262), font: 42)]
        #expect(NativeAOTRawTextPainter.capacityBadOwners(actual, legacy: legacy) == Set(["first", "peer"]))
        let upper = CGRect(x: 100, y: 0, width: 121, height: 524)
        let legacyStack = ["upper": gapMetric(upper, font: 43.74),
            "lower": gapMetric(CGRect(x: 0, y: 556, width: 211, height: 209), font: 43.74)]
        let actualStack = ["upper": gapMetric(CGRect(x: 92, y: 0, width: 134, height: 554), font: 48.6),
            "lower": gapMetric(CGRect(x: 0, y: 560, width: 235, height: 223), font: 48.6)]
        #expect(NativeAOTRawTextPainter.capacityBadOwners(actualStack, legacy: legacyStack) == Set(["upper", "lower"]))
        let stackGap = try #require(NativeAOTRawTextPainter.capacityGaps(actualStack, legacy: legacyStack).first)
        #expect(stackGap.before == 32)
        #expect(stackGap.after == 6)
    }

    @Test
    func peerComparisonBudgetDoesNotAddAnOwnerCountValidationFailure() throws {
        #expect(NativeAOTRawTextPainter.capacityArbitrationWithinBudget(itemCount: 256))
        #expect(!NativeAOTRawTextPainter.capacityArbitrationWithinBudget(itemCount: 257))
        let items: [NativeAOTRawTextPainter.Item] = (0..<257).map { i in
            .init(id: "owner-\(i)", text: "A", frame: CGRect(x: i * 2, y: 0, width: 1, height: 1), fontSize: 12,
                lineHeight: 16, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "test-fixture")
        }
        let bounds = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.frame) })
        let metrics = try NativeAOTRawTextPainter.capacityMetrics(completedMetricLayer(items, bounds: bounds), items: items, scale: 1)
        #expect(metrics.count == 257) // Budget is a wrapper bypass, never a new metrics rejection.
    }
}

extension NativeAOTRawTextPainterTests {
    private func segmentationMetric(_ lines: [String], font: Double) throws -> NativeAOTRawTextPainter.CapacityMetric {
        var offset = 0, ranges: [[Int]] = []
        for line in lines {
            ranges.append([offset, line.utf16.count]); offset += line.utf16.count
        }
        let actual = try NativeAOTRawTextPainter.capacitySegmentation(text: lines.joined(), ranges: ranges, lines: lines)
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 100)
        return .init(font: font, cuts: actual.cuts, rows: actual.rows, isolatedSingletonRows: actual.isolatedSingletonRows,
            fontPixels: font, paint: bounds, readable: bounds)
    }

    @Test
    func repeatedActualSingletonSplitsVetoFontRecovery() throws {
        let legacy = try segmentationMetric(["가나……", "다라……", "마바……"], font: 19.44)
        let actual = try segmentationMetric(["가", "나……", "다", "라……", "마", "바……"], font: 21.6)
        #expect(legacy.cuts == 0 && legacy.rows == 3 && legacy.isolatedSingletonRows == 0)
        #expect(actual.cuts == 3 && actual.rows == 6 && actual.isolatedSingletonRows == 3)
        #expect(NativeAOTRawTextPainter.capacityRepeatedFragmentation(actual, legacy: legacy))
        #expect(NativeAOTRawTextPainter.capacityBadOwners(["owner": actual], legacy: ["owner": legacy]) == Set(["owner"]))
        #expect(!NativeAOTRawTextPainter.capacityCanSkipLegacy(["owner": actual], initial: ["owner": 21.6]))
    }

    @Test
    func occasionalSingleSoftCutCanStillTradeForRecoveredFont() throws {
        let legacy = try segmentationMetric(["가나……"], font: 20)
        let actual = try segmentationMetric(["가", "나……"], font: 22)
        #expect(actual.cuts == 1 && actual.isolatedSingletonRows == 1)
        #expect(!NativeAOTRawTextPainter.capacityRepeatedFragmentation(actual, legacy: legacy))
        #expect(NativeAOTRawTextPainter.capacityBadOwners(["owner": actual], legacy: ["owner": legacy]).isEmpty)
        // The same extra cut at unchanged font remains rejected by the original rule.
        let sameFont = try segmentationMetric(["가", "나……"], font: 20)
        #expect(NativeAOTRawTextPainter.capacityBadOwners(["owner": sameFont], legacy: ["owner": legacy]) == Set(["owner"]))
    }

    @Test
    func repeatedCutsWithoutIsolatedSingletonsAreNotAutomaticallyFragmentation() throws {
        let legacy = try segmentationMetric(["가나다라마바사아자"], font: 20)
        let actual = try segmentationMetric(["가나다", "라마바", "사아자"], font: 22)
        #expect(actual.cuts == 2 && actual.rows == 3 && actual.isolatedSingletonRows == 0)
        #expect(!NativeAOTRawTextPainter.capacityRepeatedFragmentation(actual, legacy: legacy))
        #expect(NativeAOTRawTextPainter.capacityBadOwners(["owner": actual], legacy: ["owner": legacy]).isEmpty)
    }

    @Test
    func singletonCutIncreaseRequiresMaterialRowInflation() throws {
        let legacy = try segmentationMetric(["가나…", "다라…", "마바…", "사아…", "자차…"], font: 20)
        let actual = try segmentationMetric(["가", "나…", "다", "라…", "마바…", "사아…", "자차…"], font: 22)
        #expect(actual.cuts == 2 && actual.isolatedSingletonRows == 2)
        #expect(legacy.rows == 5 && actual.rows == 7)
        #expect(!NativeAOTRawTextPainter.capacityRepeatedFragmentation(actual, legacy: legacy))
    }

    @Test
    func intentionalHardBreakSingletonsAndPunctuationAreNotSoftFragments() throws {
        let paragraphs = try NativeAOTRawTextPainter.capacitySegmentation(text: "가\n나\n다",
            ranges: [[0, 2], [2, 2], [4, 1]], lines: ["가\n", "나\n", "다"])
        #expect(paragraphs.rows == 3 && paragraphs.cuts == 0 && paragraphs.isolatedSingletonRows == 0)
        let punctuation = try NativeAOTRawTextPainter.capacitySegmentation(text: "…!?",
            ranges: [[0, 1], [1, 1], [2, 1]], lines: ["…", "!", "?"])
        #expect(punctuation.rows == 3 && punctuation.cuts == 0 && punctuation.isolatedSingletonRows == 0)
        #expect(throws: NativeAOTRawTextPainter.Failure.self) {
            try NativeAOTRawTextPainter.capacitySegmentation(text: "가나", ranges: [[0, 1], [1, 1]], lines: ["가", "다"])
        }
    }

    @Test
    func trimmedAuditStringsPreserveNaturalSpacedWrapOwnership() throws {
        // Owned slices are "아픈 ", "것도 기분 ", "좋아"; the native audit trims their edges.
        let spaced = try NativeAOTRawTextPainter.capacitySegmentation(text: "아픈 것도 기분 좋아",
            ranges: [[0, 3], [3, 6], [9, 2]], lines: ["아픈", "것도 기분", "좋아"])
        #expect(spaced.rows == 3)
        #expect(spaced.cuts == 0)
        #expect(spaced.isolatedSingletonRows == 0)
        // A soft cut ending a true single-grapheme row still uses untrimmed offsets.
        let split = try NativeAOTRawTextPainter.capacitySegmentation(text: " 가나… ",
            ranges: [[0, 2], [2, 3]], lines: ["가", "나…"])
        #expect(split.rows == 2)
        #expect(split.cuts == 1)
        #expect(split.isolatedSingletonRows == 1)
        #expect(throws: NativeAOTRawTextPainter.Failure.self) {
            try NativeAOTRawTextPainter.capacitySegmentation(text: "아픈 것도 기분 좋아",
                ranges: [[0, 3], [3, 6], [9, 2]], lines: ["아픈", "것도 다른", "좋아"])
        }
    }
}

extension NativeAOTRawTextPainterTests {
    @Test(arguments: [false, true], [NativeOperationalAppearance.sourceContourOnlyDiagnosticEnabled])
    func freshBoundSourceContourReachesActualFinalPaint(bound: Bool, diagnosticEnabled: Bool) throws {
        let viewport = CGSize(width: 360, height: 240)
        let canvas = try #require(CGContext(data: nil, width: 360, height: 240,
            bitsPerComponent: 8, bytesPerRow: 360 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.65, alpha: 1)); canvas.fill(CGRect(origin: .zero, size: viewport))
        let restored = try #require(canvas.makeImage())
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "a", count: 64))
        })
        let appearance: [String: Any] = ["sourceOnly": true, "fill": ["rgb": [255, 255, 255]],
            "outline": ["present": true, "rgb": [221, 90, 5], "widthPx": 3.0],
            "shadow": ["present": false], "background": ["rgb": [166, 166, 166]]]
        var raw: [String: Any] = ["id": "contour", "sourceFontSize": 30.0,
            "sourceAppearance": appearance, "sourceAppearanceBinding": binding,
            "sourceFontWeight": "regular", "renderBold": false,
            "ensembleDisplayStroke": [255.0, 255.0, 255.0], "ensembleStrokeRatio": 0.035,
            "renderPreserveRequestedFontSize": true]
        if bound {
            let packet: [String: Any] = ["schema": "aidoku-live-source-appearance-v1", "binding": binding,
                "sourceOnly": true, "freshInference": true, "GTAtInference": false, "cachedPredictionsRead": false,
                "prediction": appearance]
            raw = try NativeOperationalAppearance.apply(packet: JSONSerialization.data(withJSONObject: packet),
                expectedBinding: binding, to: raw)
        }
        let text = "가독성\n확인"
        let item = NativeAOTRawTextPainter.Item(id: "contour", text: text,
            frame: CGRect(x: 70, y: 45, width: 210, height: 150), fontSize: 30, lineHeight: 50,
            chosenFill: CGColor(gray: 1, alpha: 1), colorAuthority: "source-fixture")
        let layer = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: [raw],
            viewport: viewport, restored: restored, allowShrink: false)
        #expect(layer.complete && layer.paintedItems == 1)
        let row = try #require((layer.audit["rawNativeItems"] as? [[String: Any]])?.first)
        #expect(row["visibleUTF16"] as? Int == text.utf16.count)
        #expect(row["fontSize"] as? Double == 30)
        let decision = try #require((layer.audit["endpointDecisions"] as? [[String: Any]])?.first)
        let sourceOnly = bound && diagnosticEnabled
        if sourceOnly {
            #expect(decision["paintMode"] as? String == "source-contour-only")
            #expect(decision["guardPainted"] as? Bool == false)
            #expect(decision["finalEndpoint"] is NSNull)
            #expect(row["finalDisplayFill"] as? [Int] == [255, 255, 255])
            #expect(row["finalDisplayStroke"] as? [Double] == [221, 90, 5])
            let style = try #require((layer.audit["sourceStylePaint"] as? [[String: Any]])?.first)
            #expect(style["displayCumulativeRadiiPixels"] as? [Double] == [3])
            let bytes = try NativeMandatoryDisplayStroke.rgba(layer.image)
            #expect(stride(from: 0, to: bytes.count, by: 4).contains {
                bytes[$0] == 255 && bytes[$0+1] == 255 && bytes[$0+2] == 255 && bytes[$0+3] == 255
            })
            #expect(stride(from: 0, to: bytes.count, by: 4).contains {
                bytes[$0] == 221 && bytes[$0+1] == 90 && bytes[$0+2] == 5 && bytes[$0+3] == 255
            })
        } else {
            #expect(decision["paintMode"] as? String != "source-contour-only")
            let endpoint = try #require(decision["finalEndpoint"] as? Int)
            #expect(endpoint == 0 || endpoint == 255)
        }
        let palette: [String: Any] = ["kind": "source-contour-only", "displayFillRGB": [255,255,255],
            "sourceOutlineRGB": [221.0,90.0,5.0], "sourceOutlineWidthPixels": 3.0,
            "syntheticGuardPainted": false, "outwardPixels": 0.0]
        #expect(NativeBalloonReadabilityReflow.paintDecisionMatches(decision, palette: palette) == sourceOnly)
        #expect(!NativeBalloonReadabilityReflow.paintDecisionMatches(["displayFillRGB": [255,255,255]], palette: palette))
    }
}

extension NativeAOTRawTextPainterTests {
    @Test(arguments: [false, true], [NativeOperationalAppearance.sourceContourOnlyDiagnosticEnabled])
    func sourceStyleCohortUsesOneContourPaintMode(peerWidthChanged: Bool, diagnosticEnabled: Bool) throws {
        let viewport = CGSize(width: 480, height: 240)
        let canvas = try #require(CGContext(data: nil, width: 480, height: 240, bitsPerComponent: 8,
            bytesPerRow: 480*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.65, alpha: 1)); canvas.fill(CGRect(origin: .zero, size: viewport))
        let restored = try #require(canvas.makeImage())
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "b", count: 64))
        })
        let packet: [String: Any] = ["schema": "aidoku-live-source-appearance-v1", "binding": binding,
            "sourceOnly": true, "freshInference": true, "GTAtInference": false, "cachedPredictionsRead": false,
            "prediction": ["sourceOnly": true, "fill": ["rgb": [255,255,255]],
                "outline": ["present": true, "rgb": [221,90,5], "widthPx": 3.0],
                "shadow": ["present": false], "background": ["rgb": [166,166,166]]]]
        var items: [NativeAOTRawTextPainter.Item] = [], raws: [[String: Any]] = []
        for index in 0..<2 {
            let id = "member-\(index)"
            let raw: [String: Any] = ["id":id,"sourceStyleGroupID":"one-style","sourceFontSize":24.0,
                "sourceFontWeight":"regular","renderBold":false,"renderPreserveRequestedFontSize":true,
                "ensembleDisplayStroke":[255.0,255.0,255.0],"ensembleStrokeRatio":0.035]
            var bound = try NativeOperationalAppearance.apply(packet:JSONSerialization.data(withJSONObject:packet),
                expectedBinding:binding,to:raw)
            if index == 1 && peerWidthChanged { bound["renderSourceOutlineWidthPx"] = 4.0 }
            raws.append(bound)
            items.append(.init(id:id,text:"확인",frame:CGRect(x:40+index*230,y:45,width:170,height:120),
                fontSize:24,lineHeight:42,chosenFill:CGColor(gray:1,alpha:1),colorAuthority:"source-fixture"))
        }
        let layer = try NativeAOTRawTextPainter.renderCentered(items:items,rawItems:raws,
            viewport:viewport,restored:restored,allowShrink:false)
        #expect(layer.complete && layer.paintedItems == 2)
        let decisions = try #require(layer.audit["endpointDecisions"] as? [[String:Any]])
        #expect(decisions.count == 2)
        let sourceOnly = diagnosticEnabled && !peerWidthChanged
        #expect(decisions.allSatisfy { ($0["paintMode"] as? String == "source-contour-only") == sourceOnly })
        for decision in decisions where !sourceOnly {
            let endpoint = try #require(decision["finalEndpoint"] as? Int)
            #expect(endpoint == 0 || endpoint == 255)
        }
    }
}

extension NativeAOTRawTextPainterTests {
    @Test func terminalBodySourceRecoveryRepaintsSameGlyphsWithUnchangedPalette() throws {
        let key = "AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY"
        let previous = ProcessInfo.processInfo.environment[key]
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        setenv(key, "1", 1)
        let page = CGRect(x: 0, y: 0, width: 160, height: 120)
        func image(_ width: Int, _ height: Int, white: Bool) throws -> CGImage {
            let c = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(CGColor(gray:white ? 1:0,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
            return try #require(c.makeImage())
        }
        let restored = try image(160,120,white:true), glyph = try image(8,8,white:false)
        let allowed = [2.0/160,2.0/120,156.0/160,116.0/120]
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:allowed,candidates:[allowed],maskCoverage:[1],
            backgroundRisk:[0],sourceFontPixels:20,kind:"inside-balloon-mask",maskRectNormalized:allowed,
            maskSpansNormalized:[2.0/160,158.0/160,2.0/160,158.0/160])
        var fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive] = []
        let bodyRect: [Double] = [0.0625,Double(20)/120,0.625,Double(80)/120]
        let guideY = Double(40)/120, guideWidth = Double(8)/160, guideHeight = Double(8)/120
        let specifications: [(Int,CGFloat,CGFloat)] = [(0,20,16),(1,80,80)]
        for (order,x,sourceX) in specifications {
            var fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image:glyph,
                frame:CGRect(x:x,y:40,width:8,height:8),fontOutputPixels:20)
            fill.ownerID = order == 0 ? "recover":"peer"
            fill.textExpansionPolicy = policy
            fill.placementDomain = { policy.allows($0,page:page) }
            let guideRect: [Double] = [Double(sourceX)/160,guideY,guideWidth,guideHeight]
            fill.textPlacementGuide = NativeTextPlacementGuide(rectNormalized:guideRect,horizontal:.center,vertical:.center)
            let packet = NativeBalloonPlacement(bodyID:"shared-body",rectNormalized:bodyRect,
                preserveSourceOffsets:true,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0,
                maskSHA256:String(repeating:"b",count:64),order:order)
            fill.balloonPlacement = packet
            fill.balloonTargetRelaxed = true
            fills.append(fill)
        }
        let fixed = try Dictionary(uniqueKeysWithValues:fills.map { fill in
            (fill.ownerID!,try NativeFinalTextPaintAdmission.retainedFootprint(fill).bounds.origin)
        })
        let incumbent = try NativeFinalTextPaintAdmission.place(fills,page:page,fixedOrigins:fixed)
        let blank = NativeAOTTranslationPageComposer.TextLayer(image:restored,expectedItems:2,paintedItems:2,complete:true,audit:[:])
        let before = try NativeAOTTranslationPageComposer.refineFinalReadability(layer:blank,fills:fills,
            restored:restored,admittedOverride:incumbent,forceRepaint:true)
        let after = try NativeAOTRawTextPainter.finalSourcePhysicalInterior(layer:before,baseline:incumbent,restored:restored)
        #expect(after.complete && after.paintedItems == 2)
        #expect(after.audit["bodySourceAnchorRecoveryApplied"]as?[String] == ["recover"])
        let old = try #require(before.audit["endpointDecisions"]as?[[String:Any]])
        let new = try #require(after.audit["endpointDecisions"]as?[[String:Any]])
        #expect(old.count == 2 && new.count == 2)
        for i in old.indices {
            #expect(old[i]["displayFillRGB"]as?[Int] == [0,0,0] && new[i]["displayFillRGB"]as?[Int] == [0,0,0])
            #expect(old[i]["finalEndpoint"]as?Int == 255 && new[i]["finalEndpoint"]as?Int == 255)
        }
        let a = try NativeMandatoryDisplayStroke.rgba(before.image), b = try NativeMandatoryDisplayStroke.rgba(after.image)
        #expect(stride(from:3,to:a.count,by:4).filter {a[$0]>0}.count == stride(from:3,to:b.count,by:4).filter {b[$0]>0}.count)
        for y in 0..<120 {
            #expect(Array(a[(y*160+4)*4..<(y*160+60)*4]) == Array(b[y*160*4..<(y*160+56)*4]))
            #expect(Array(a[(y*160+60)*4..<(y+1)*160*4]) == Array(b[(y*160+60)*4..<(y+1)*160*4]))
        }
    }

    @Test func terminalPhysicalGapConflictRetriesOriginalPhysicalOnlyTransaction() throws {
        let w = 160, h = 120, page = CGRect(x:0,y:0,width:w,height:h)
        let key = "AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY", physicalKey = "AIDOKU_SOURCE_PHYSICAL_INTERIOR"
        let previous = ProcessInfo.processInfo.environment[key], oldPhysical = ProcessInfo.processInfo.environment[physicalKey]
        defer {
            if let previous { setenv(key,previous,1) } else { unsetenv(key) }
            if let oldPhysical { setenv(physicalKey,oldPhysical,1) } else { unsetenv(physicalKey) }
        }
        setenv(key,"1",1); setenv(physicalKey,"1",1)
        func normalized(_ r: CGRect) -> [Double] { [r.minX/160,r.minY/120,r.width/160,r.height/120].map(Double.init) }
        let allowed = normalized(CGRect(x:10,y:10,width:140,height:100))
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:allowed,candidates:[allowed],maskCoverage:[1],
            backgroundRisk:[0],sourceFontPixels:10,kind:"inside-balloon-mask",maskRectNormalized:allowed,
            maskSpansNormalized:[10.0/160,150.0/160,10.0/160,150.0/160])
        var rgb = [UInt8](repeating:0,count:w*h*3), background = [UInt8](repeating:255,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let value: UInt8 = (83..<125).contains(x) && (70..<100).contains(y) ? 255:90
            for c in 0..<3 { rgb[(y*w+x)*3+c] = value; background[(y*w+x)*4+c] = value }
        }}
        var erased = [UInt8](repeating:0,count:w*h)
        erased[83*w+88] = 255
        for c in 0..<3 { rgb[(83*w+88)*3+c] = 0 }
        let context = try #require(NativeSourcePhysicalInteriorContext(rgb:rgb,width:w,height:h,erased:erased,
            sourceIdentity:"composed-source-gap-synthetic"))
        let restored = try NativeMandatoryDisplayStroke.image(background,width:w,height:h)
        var glyphBytes = [UInt8](repeating:0,count:6*4*4)
        for p in stride(from:3,to:glyphBytes.count,by:4) { glyphBytes[p] = 255 }
        let glyph = try NativeMandatoryDisplayStroke.image(glyphBytes,width:6,height:4)
        var fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive] = []
        for (i,values) in [(82,87),(104,107)].enumerated() {
            var fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image:glyph,
                frame:CGRect(x:values.0,y:82,width:6,height:4),fontOutputPixels:10,displayStrokeEndpoint:255)
            fill.ownerID = i == 0 ? "left":"right"; fill.balloonTargetRelaxed = true
            fill.textExpansionPolicy = policy; fill.placementDomain = { policy.allows($0,page:page) }
            fill.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:values.1,y:80,width:4,height:8)),
                horizontal:.center,vertical:.center)
            fill.balloonPlacement = .init(bodyID:"composed-source-gap",rectNormalized:allowed,preserveSourceOffsets:false,
                biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0.6,maskSHA256:String(repeating:"e",count:64),order:i)
            fills.append(fill)
        }
        let fixed = try Dictionary(uniqueKeysWithValues:fills.map { f in
            (f.ownerID!,try NativeFinalTextPaintAdmission.retainedFootprint(f).bounds.origin)
        })
        let incumbent = try NativeFinalTextPaintAdmission.place(fills,page:page,fixedOrigins:fixed)
        let anchored = NativeBodySourceAnchorRecovery.refine(incumbent,page:page,boundaryGate: { before, after in
            context.boundaryClearance(before:before,after:after)
        })
        func gap(_ tuple: NativeBodySourceAnchorRecovery.Tuple) throws -> CGFloat {
            let supports = try tuple.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
            return try #require(NativeAdaptiveTextGutter.clearance(supports[0].readableBounds ?? supports[0].bounds,
                supports[1].readableBounds ?? supports[1].bounds))
        }
        #expect(try gap(incumbent) == 12)
        #expect(try gap(anchored) == 13)
        let combined = context.refine(anchored,page:page)
        #expect(try gap(combined) == 10) // Real boundary gate selects A+1/B+2; physical A+4 consumes the required11px gap.
        let validation = NativeBodySourceAnchorRecovery.validateTerminal(incumbent,terminal:combined,
            recoveredBodyIDs:["composed-source-gap"],page:page)
        #expect(!validation.accepted && validation.reason == "source-aware-gap-regression")
        let originalPhysical = context.refine(incumbent,page:page)
        #expect(originalPhysical.fills[0].frame != incumbent.fills[0].frame)
        #expect(originalPhysical.fills[1].frame == incumbent.fills[1].frame)
        let blank = NativeAOTTranslationPageComposer.TextLayer(image:restored,expectedItems:2,paintedItems:2,complete:true,audit:[:])
        let before = try NativeAOTTranslationPageComposer.refineFinalReadability(layer:blank,fills:fills,restored:restored,
            admittedOverride:incumbent,forceRepaint:true)
        let expected = try NativeAOTTranslationPageComposer.refineFinalReadability(layer:before,fills:fills,restored:restored,
            admittedOverride:originalPhysical,forceRepaint:true)
        let actual = try NativeSourcePhysicalInteriorContext.$current.withValue(context) {
            try NativeAOTRawTextPainter.finalSourcePhysicalInterior(layer:before,baseline:incumbent,restored:restored)
        }
        #expect(try NativeMandatoryDisplayStroke.rgba(actual.image) == NativeMandatoryDisplayStroke.rgba(expected.image))
        #expect(actual.complete && actual.expectedItems == 2 && actual.paintedItems == 2)
        #expect(actual.audit["bodySourceAnchorRecoveryRollback"] as? String ==
            "physical-reconciliation-source-contract: source-aware-gap-regression")
        let receipt = try #require(actual.audit["bodySourceAnchorRecoveryTerminalValidation"] as? [String:Any])
        #expect(receipt["accepted"] as? Bool == false)
        #expect(actual.audit["bodySourceAnchorRecoveryApplied"] == nil)
        #expect(actual.audit["sourcePhysicalInteriorApplied"] as? [String] == ["left"])
        #expect(actual.audit["finalCompositeAlphaVerified"] as? Bool == true)
        let a = try #require(before.audit["endpointDecisions"] as? [[String:Any]])
        let b = try #require(actual.audit["endpointDecisions"] as? [[String:Any]])
        for i in a.indices {
            #expect(a[i]["displayFillRGB"] as? [Int] == b[i]["displayFillRGB"] as? [Int])
            #expect(a[i]["finalEndpoint"] as? Int == b[i]["finalEndpoint"] as? Int)
        }
    }

    @Test func terminalPhysicalInteriorKeepsGlyphsAndMovesOffActualRim() throws {
        let width = 360, height = 180, viewport = CGSize(width: width, height: height)
        func canvas(glyph: Bool) throws -> CGImage {
            let c = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(CGColor(gray:0.35,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
            c.setFillColor(CGColor(gray:0,alpha:1));c.fill(CGRect(x:27,y:27,width:146,height:116))
            c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:30,y:30,width:140,height:110))
            if glyph { c.setFillColor(CGColor(gray:0,alpha:1));c.fill(CGRect(x:45,y:90,width:4,height:20)) }
            return try #require(c.makeImage())
        }
        let original = try canvas(glyph:true), restored = try canvas(glyph:false)
        // CG drawing coordinates above are bottom-left; source bytes and guides
        // below use top-left, matching original image decoder and page masks.
        let source = try NativeRFDETRSourceImage.decode(original)
        var erased = [UInt8](repeating:0,count:width*height)
        for y in 70..<90 { for x in 45..<49 { erased[y*width+x] = 255 } }
        let context = try #require(NativeSourcePhysicalInteriorContext(rgb:[UInt8](source.rgb),width:width,
            height:height,erased:erased,sourceIdentity:source.identity))
        let policy: [String:Any] = ["kind":"inside-balloon-mask","allowedRectNormalized":[5.0/360,5.0/180,345.0/360,165.0/180],
            "maskRectNormalized":[5.0/360,5.0/180,345.0/360,165.0/180],
            "maskSpansNormalized":Array(repeating:[5.0/360,350.0/360],count:165).flatMap{$0},
            "candidates":[[5.0/360,5.0/180,345.0/360,165.0/180]],"maskCoverage":[1.0],"backgroundRisk":[0.0],"sourceFontPixels":24.0]
        let raw: [String:Any] = ["id":"rim","sourceFontWeight":"regular","renderBold":false,
            "renderPreserveRequestedFontSize":true,"ensembleDisplayStroke":[255.0,255.0,255.0],
            "textExpansionPolicy":policy,
            "textPlacementGuide":["rectNormalized":[42.0/360,60.0/180,12.0/360,40.0/180],"horizontal":"center","vertical":"center"]]
        let text = "확인"
        let item = NativeAOTRawTextPainter.Item(id:"rim",text:text,frame:CGRect(x:42,y:60,width:12,height:40),
            fontSize:24,lineHeight:38,chosenFill:CGColor(gray:0,alpha:1),colorAuthority:"source-fixture")
        let before = try NativeAOTRawTextPainter.renderCentered(items:[item],rawItems:[raw],viewport:viewport,
            restored:restored,allowShrink:false)
        let after = try NativeSourcePhysicalInteriorContext.$current.withValue(context) {
            try NativeAOTRawTextPainter.renderCentered(items:[item],rawItems:[raw],viewport:viewport,
                restored:restored,allowShrink:false)
        }
        #expect(before.complete && after.complete && before.paintedItems == after.paintedItems)
        let oldRow = try #require((before.audit["rawNativeItems"]as?[[String:Any]])?.first)
        let newRow = try #require((after.audit["rawNativeItems"]as?[[String:Any]])?.first)
        #expect(oldRow["fontSize"]as?Double == newRow["fontSize"]as?Double)
        #expect(oldRow["lineRangesUTF16"]as?[[Int]] == newRow["lineRangesUTF16"]as?[[Int]])
        #expect(newRow["visibleUTF16"]as?Int == text.utf16.count)
        #expect(after.audit["sourcePhysicalInteriorApplied"]as?[String] == ["rim"])
        let placements = try #require(after.audit["sourcePhysicalInterior"]as?[[String:Any]])
        let report = try #require(placements.first?["sourcePhysicalInterior"]as?[String:Any])
        #expect(report["evidenceAvailable"]as?Bool == true)
        #expect((report["beforeOutsidePixels"]as?Int ?? 0)>0)
        #expect(report["afterOutsidePixels"]as?Int == 0)
        let shift = try #require(report["shiftOutputPixels"]as?[Int])
        #expect(shift.count == 2 && shift.reduce(0, { $0+$1*$1 }) <= 12*12)
        let bytes = try NativeMandatoryDisplayStroke.rgba(after.image)
        for y in 0..<height { for x in 0..<width where bytes[(y*width+x)*4+3]>0 {
            #expect(x>=30 && x<170 && y>=40 && y<150)
        }}
    }
}

extension NativeAOTRawTextPainterTests {
    @Test func localSourceBoundaryMatchesAlphaWithoutAggregateCancellation() throws {
        typealias C = NativeSourcePhysicalInteriorContext
        typealias N = NativeFinalTextPaintAdmission
        let w = 128, h = 96
        var rgb = [UInt8](repeating:255,count:w*h*3)
        for y in 4..<92 { for x in [20,64] { for c in 0..<3 { rgb[(y*w+x)*3+c] = 0 } } }
        let context = try #require(C(rgb:rgb,width:w,height:h,erased:[UInt8](repeating:0,count:w*h),sourceIdentity:"synthetic-preserved-rim"))
        func support(_ points: [(Int,Int)]) -> N.Footprint {
            let left = points.map { $0.0 }.min()!, right = points.map { $0.0 }.max()!
            let top = points.map { $0.1 }.min()!, bottom = points.map { $0.1 }.max()!
            return .init(runs:points.map { .init(y:$0.1,left:$0.0,right:$0.0+1) },
                bounds:CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1),pixels:points.count)
        }
        // First point retreats from left edge 1->3, second approaches right
        // edge 3->1. Aggregate close contacts stay equal; matching must veto.
        let old = support([(22,40),(60,50)])
        let blocked = context.boundaryClearance(before:old,after:old.translated(CGPoint(x:2,y:0)))
        #expect(blocked.allowed == false)
        #expect(blocked.audit["adverseAlphaPixels"] as? Int == 1)
        #expect(blocked.audit["physicalContainmentMeasured"] as? Bool == false)
        let safe = context.boundaryClearance(before:old,after:old.translated(CGPoint(x:1,y:0)))
        #expect(safe.allowed == true) // 3->2 is an allowed one-pixel decrease.
        let diagonal = support([(60,50)])
        #expect(context.boundaryClearance(before:diagonal,after:diagonal.translated(CGPoint(x:2,y:2))).allowed == false)
        // Query across tile boundary; stationary/retreating contact is inherited.
        let seam = support([(63,50)])
        #expect(context.boundaryClearance(before:seam,after:seam.translated(CGPoint(x:3,y:0))).allowed == true)
        var erased = [UInt8](repeating:0,count:w*h)
        for y in 4..<92 { for x in [20,64] { erased[y*w+x] = 1 } }
        let textOnly = try #require(C(rgb:rgb,width:w,height:h,erased:erased,sourceIdentity:"synthetic-erased-text"))
        #expect(textOnly.boundaryClearance(before:old,after:old.translated(CGPoint(x:2,y:0))).allowed == true)
        // Malformed correspondence and unobservable image edge never claim pass.
        let malformed = support([(24,40),(63,50)])
        #expect(context.boundaryClearance(before:old,after:malformed).allowed == nil)
        let clippedObservation = support([(0,40)])
        #expect(context.boundaryClearance(before:clippedObservation,after:clippedObservation).allowed == nil)
        #expect(C(rgb:[],width:w,height:h,erased:erased,sourceIdentity:"bad") == nil)
    }

    @Test func sourceBoundaryVetoLazilyRepacksIndependentIntegerChoices() throws {
        typealias R = NativeBodySourceAnchorRecovery
        typealias N = NativeFinalTextPaintAdmission
        let page = CGRect(x:0,y:0,width:160,height:120)
        func norm(_ box: CGRect) -> [Double] { [box.minX/160,box.minY/120,box.width/160,box.height/120].map(Double.init) }
        var rgba = [UInt8](repeating:0,count:6*4*4)
        // Includes alpha=1: the veto must use every actually painted sample.
        for p in 0..<24 { rgba[p*4+3] = p%6 == 5 ? 1:255 }
        let glyph = try NativeMandatoryDisplayStroke.image(rgba,width:6,height:4)
        let allowed = norm(CGRect(x:2,y:2,width:156,height:116))
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:allowed,candidates:[allowed],maskCoverage:[1],
            backgroundRisk:[0],sourceFontPixels:20,kind:"inside-balloon-mask",maskRectNormalized:allowed,
            maskSpansNormalized:[2.0/160,158.0/160,2.0/160,158.0/160])
        var fills: [R.Primitive] = []
        for i in 0..<2 {
            let x: CGFloat = i == 0 ? 54:100
            var f = R.Primitive(image:glyph,frame:CGRect(x:x,y:40,width:6,height:4),fontOutputPixels:20)
            f.ownerID = "boundary-member-\(i)"; f.hasFinalEffects = true
            f.textExpansionPolicy = policy; f.placementDomain = { policy.allows($0,page:page) }
            f.textPlacementGuide = .init(rectNormalized:norm(f.frame.offsetBy(dx:i == 0 ? 8:0,dy:0)),horizontal:.left,vertical:.top)
            f.balloonPlacement = .init(bodyID:"boundary-body",rectNormalized:allowed,preserveSourceOffsets:false,
                biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0,
                maskSHA256:String(repeating:"c",count:64),order:i)
            f.balloonTargetRelaxed = true; fills.append(f)
        }
        let fixed = try Dictionary(uniqueKeysWithValues:fills.map { ($0.ownerID!,try N.retainedFootprint($0).bounds.origin) })
        var original = try N.place(fills,page:page,fixedOrigins:fixed)
        for i in original.audit.indices {
            original.audit[i]["balloonBodyPlaced"] = false
            original.audit[i]["balloonCapacityFallback"] = true
        }
        var rgb = [UInt8](repeating:255,count:160*120*3), erased = [UInt8](repeating:0,count:160*120)
        for y in 10..<110 { for c in 0..<3 { rgb[(y*160+64)*3+c] = 0 } }
        let context = try #require(NativeSourcePhysicalInteriorContext(rgb:rgb,width:160,height:120,erased:erased,sourceIdentity:"synthetic-fixed-rim"))
        let gate: R.BoundaryGate = { context.boundaryClearance(before:$0,after:$1) }
        let legacy = R.refine(original,page:page)
        #expect(legacy.fills[0].frame.minX == 62) // no-context behavior unchanged.
        let safe = R.refine(original,page:page,boundaryGate:gate)
        #expect(safe.fills[0].frame.minX == 55) // 8,6,4,2 blocked; 1 survives.
        #expect(safe.fills[1].frame == original.fills[1].frame)
        var deniedCalls = 0
        let denied = R.refine(original,page:page,boundaryGate:{ _,_ in
            deniedCalls += 1
            return (false,["evidenceAvailable":true,"status":"synthetic-preserved-obstruction"])
        })
        #expect(deniedCalls == 8) // Only selected candidates are measured: 8...1, never an eager per-option sweep.
        #expect(denied.fills.map(\.frame) == original.fills.map(\.frame))
        #expect(denied.audit[0]["bodySourceBoundaryGate"] != nil)
        for i in safe.fills.indices {
            #expect(try NativeMandatoryDisplayStroke.rgba(safe.fills[i].image) == NativeMandatoryDisplayStroke.rgba(original.fills[i].image))
            #expect(safe.fills[i].fontOutputPixels == original.fills[i].fontOutputPixels)
        }
        let info = try #require(safe.audit[0]["bodySourceAnchorRecovery"] as? [String:Any])
        #expect(info["candidateOrdinal"] as? Int == 8)
        #expect(info["sourceBoundaryVetoedChoiceCount"] as? Int == 7)
        #expect(info["boundaryCalls"] as? Int == 8)
        #expect(R.validateTerminal(original,terminal:safe,recoveredBodyIDs:["boundary-body"],page:page,boundaryGate:gate).accepted)
        #expect(!R.validateTerminal(original,terminal:legacy,recoveredBodyIDs:["boundary-body"],page:page,boundaryGate:gate).accepted)
        // A matched-alpha translation may approach a rim by one pixel. After
        // lexical shaping, NEW page pixels still need the ORIGINAL shape gate;
        // the later translation may not inherit the reshaped alpha as authority.
        var closeRGB=[UInt8](repeating:255,count:160*120*3)
        for y in 10..<110 {for c in 0..<3 {closeRGB[(y*160+63)*3+c]=0}}
        let closeContext=try #require(NativeSourcePhysicalInteriorContext(rgb:closeRGB,width:160,height:120,
            erased:erased,sourceIdentity:"synthetic-post-lexical-rim"))
        var laterFills=original.fills
        for i in laterFills.indices {
            laterFills[i].hasFinalEffects=false
            laterFills[i].displayStrokeEndpoint=255
            laterFills[i].displayStrokeRatio=0.05
            laterFills[i].recheckFinalEndpoint=false
        }
        let laterFixed=try Dictionary(uniqueKeysWithValues:laterFills.map {
            ($0.ownerID!,try N.retainedFootprint($0).bounds.origin)
        })
        let laterOriginal=try N.place(laterFills,page:page,fixedOrigins:laterFixed)
        var originalGlyphs=laterOriginal
        originalGlyphs.fills[0].image=try NativeMandatoryDisplayStroke.image(rgba,width:6,height:4)
        let background=try #require(CGContext(data:nil,width:160,height:120,bitsPerComponent:8,bytesPerRow:640,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        background.setFillColor(CGColor(gray:1,alpha:1));background.fill(page)
        let restored=try #require(background.makeImage())
        let blank=NativeAOTTranslationPageComposer.TextLayer(image:restored,expectedItems:2,paintedItems:2,complete:true,audit:[:])
        let beforeLayer=try NativeAOTTranslationPageComposer.refineFinalReadability(layer:blank,fills:laterOriginal.fills,
            restored:restored,admittedOverride:laterOriginal,forceRepaint:true)
        let guarded=try NativeSourcePhysicalInteriorContext.$current.withValue(closeContext) {
            try NativeAOTRawTextPainter.finalSourcePhysicalInterior(layer:beforeLayer,baseline:laterOriginal,
                restored:restored,lexicalOriginals:originalGlyphs)
        }
        #expect(guarded.audit["lexicalTerminalSourceGateRollback"] as? String == "later-move-not-original-source-gated",
            "body=\(String(describing:guarded.audit["bodySourceAnchorRecoveryRollback"])); lineage=\(String(describing:guarded.audit["retainedBalloonStateRollback"]))")
        #expect(try NativeMandatoryDisplayStroke.rgba(guarded.image)==NativeMandatoryDisplayStroke.rgba(beforeLayer.image))
        for y in 10..<110 { erased[y*160+64] = 1 }
        let erasedContext = try #require(NativeSourcePhysicalInteriorContext(rgb:rgb,width:160,height:120,erased:erased,sourceIdentity:"synthetic-erased-glyph"))
        let erasedResult = R.refine(original,page:page,boundaryGate:{ erasedContext.boundaryClearance(before:$0,after:$1) })
        #expect(erasedResult.fills.map(\.frame) == legacy.fills.map(\.frame))
        let unknown = R.refine(original,page:page,boundaryGate:{ _,_ in (nil,["evidenceAvailable":false,"status":"synthetic-unknown"]) })
        #expect(unknown.fills.map(\.frame) == original.fills.map(\.frame))
        #expect((unknown.audit[0]["bodySourceBoundaryGate"] as? [String:Any])?["boundaryBudgetDeferred"] as? Bool == true)
    }
}

// R138: disjoint terminal-edge regressions; no shared helper/painter edits.
extension NativeAOTRawTextPainterTests {
    @Test func terminalExteriorPageEdgeRescuePreservesActualAlphaPaletteAndStyles() throws {
        typealias N = NativeFinalTextPaintAdmission
        typealias E = NativeRetainedPageEdgeRecovery
        typealias P = NativeAOTTranslationPageComposer
        let keys = ["AIDOKU_FINAL_PAGE_EDGE_GUARD", "AIDOKU_RETAINED_PAGE_EDGE_RECOVERY", "AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let w = 256, h = 128, page = CGRect(x:0,y:0,width:w,height:h)
        func image(_ width: Int, _ height: Int, white: Bool) throws -> CGImage {
            let c = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(CGColor(gray:white ? 1:0,alpha:1)); c.fill(CGRect(x:0,y:0,width:width,height:height))
            return try #require(c.makeImage())
        }
        func norm(_ r: CGRect) -> [Double] { [r.minX/CGFloat(w),r.minY/CGFloat(h),r.width/CGFloat(w),r.height/CGFloat(h)].map(Double.init) }
        let restored = try image(w,h,white:true)
        let whole = [0.0,0,1,1]
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:whole,candidates:[whole],maskCoverage:[1],backgroundRisk:[0],
            sourceFontPixels:20,kind:"source-near-limited-expansion",maskRectNormalized:nil,maskSpansNormalized:nil)
        #expect(policy.valid)
        // One true legacy edge case and a fully inset no-op control. The old
        // guard is disabled ONLY while constructing the authentic legacy layer.
        for touchesBorder in [true, false] {
            setenv(keys[0],touchesBorder ? "0":"1",1)
            setenv(keys[1],"1",1); setenv(keys[2],"0",1)
            var fills: [P.TranslatedFillPrimitive] = []
            for (index, size) in [(0,CGSize(width:8,height:24)),(1,CGSize(width:8,height:8)),(2,CGSize(width:8,height:8))] {
                var f = P.TranslatedFillPrimitive(image:try image(Int(size.width),Int(size.height),white:false),
                    frame:CGRect(origin:CGPoint(x:40,y:40),size:size),fontOutputPixels:20)
                f.ownerID = ["edge-tall","edge-right","stationary-control"][index]
                f.displayStrokeEndpoint = 255; f.displayStrokeRatio = 0.05; f.recheckFinalEndpoint = false
                f.sourceStyle = .init(sourceFontPixels:20,bands:[.init(rgb:[30,90,170],width:1)],shadow:nil)
                f.textExpansionPolicy = policy; f.placementDomain = { policy.allows($0,page:page) }
                fills.append(f)
            }
            let initial = try fills.map { try N.retainedFootprint($0) }
            let margin: CGFloat = touchesBorder ? 0:3
            let top = CGFloat(h)-margin-initial[0].bounds.height
            for i in fills.indices {
                let x: CGFloat = i == 0 ? 60 : i == 1 ? CGFloat(w)-margin-initial[i].bounds.width : 20
                let y: CGFloat = i < 2 ? top:20
                fills[i].frame = fills[i].frame.offsetBy(dx:x-initial[i].bounds.minX,dy:y-initial[i].bounds.minY)
                let support = try N.retainedFootprint(fills[i])
                fills[i].textPlacementGuide = .init(rectNormalized:norm(support.bounds),horizontal:.center,vertical:.top)
                if i < 2 {
                    fills[i].sourceClusterAlignment = .init(groupID:"synthetic-exterior-edge-cohort",axis:.top,
                        anchorNormalized:Double(top)/Double(h),anchorPolicy:"source-near-final-alpha",anchorsToSourceStart:true)
                }
            }
            let oldSupports = try fills.map { try N.retainedFootprint($0) }
            let fixed = Dictionary(uniqueKeysWithValues:fills.indices.map { (fills[$0].ownerID!,oldSupports[$0].bounds.origin) })
            var incumbent = try N.place(fills,page:page,fixedOrigins:fixed)
            let stateKey = NativeBalloonPlacement.RetainedState.auditKey
            for i in incumbent.audit.indices {
                var state = try #require(incumbent.audit[i][stateKey] as? [String:Any])
                state["provenance"] = "fixedOriginRevalidated"
                state["historicalStateExact"] = false
                state["sourceIdentity"] = "authenticated-terminal-edge-fixture"
                incumbent.audit[i][stateKey] = state
            }
            let blank = P.TextLayer(image:restored,expectedItems:3,paintedItems:3,complete:true,audit:[:])
            let before = try P.refineFinalReadability(layer:blank,fills:fills,restored:restored,
                admittedOverride:incumbent,forceRepaint:true)
            #expect(before.complete && before.paintedItems == 3)
            #expect(oldSupports[0].bounds.maxY == CGFloat(h)-margin)
            #expect(oldSupports[1].bounds.maxX == CGFloat(w)-margin)
            setenv(keys[0],"1",1)
            let preview = E.recover(incumbent,page:page)
            let shift = touchesBorder ? CGPoint(x:-1,y:-1):.zero
            for i in fills.indices {
                let delta = i < 2 ? shift:.zero
                #expect(preview.tuple.fills[i].frame == incumbent.fills[i].frame.offsetBy(dx:delta.x,dy:delta.y))
                #expect(NativeBodySourceAnchorRecovery.carrierPreserved(incumbent.fills[i],preview.tuple.fills[i],shift:delta))
                #expect(try NativeMandatoryDisplayStroke.rgba(incumbent.fills[i].image) == NativeMandatoryDisplayStroke.rgba(preview.tuple.fills[i].image))
            }
            #expect(Set(preview.changedOwnerIDs) == (touchesBorder ? Set(["edge-tall","edge-right"]):Set<String>()))
            let retained = try preview.tuple.fills.map { try N.retainedFootprint($0) }
            let anchors = try #require(NativeReadablePeerGutter.retainedAnchors(packets:fills.map(\.sourceClusterAlignment),origins:retained.map { $0.bounds.origin }))
            try N.verifyRetainedPlacement(preview.tuple.fills,footprints:retained,page:page,retainedClusterAnchors:anchors)
            #expect(retained.allSatisfy { page.insetBy(dx:1,dy:1).contains($0.bounds) })
            if touchesBorder {
                #expect(preview.metadata["nativeFixedOriginTransactionVerified"] as? Bool == true)
                // Admission may not mutate repaint configuration while keeping
                // the same image bytes; the shared carrier guard must reject it.
                var ran = false
                let corrupt = E.recover(incumbent,page:page,admission:{ candidate, bounds in
                    ran = true
                    let supports = try candidate.fills.map { try N.retainedFootprint($0) }
                    let anchors = try #require(NativeReadablePeerGutter.retainedAnchors(packets:candidate.fills.map(\.sourceClusterAlignment),origins:supports.map { $0.bounds.origin }))
                    var actual = try N.place(candidate.fills,page:bounds,
                        fixedOrigins:Dictionary(uniqueKeysWithValues:candidate.fills.indices.map { (candidate.fills[$0].ownerID!,supports[$0].bounds.origin) }),retainedClusterAnchors:anchors)
                    actual.fills[0].minimumFillStrokeContrast += 1
                    return actual
                })
                #expect(ran && corrupt.changedOwnerIDs.isEmpty)
                #expect(corrupt.tuple.fills.map(\.frame) == incumbent.fills.map(\.frame))
            }
            // Actual final terminal repaint, not an isolated helper-only test.
            let after = try NativeSourcePhysicalInteriorContext.$current.withValue(nil) {
                try NativeAOTRawTextPainter.finalSourcePhysicalInterior(layer:before,baseline:incumbent,restored:restored)
            }
            #expect(after.complete && after.expectedItems == 3 && after.paintedItems == 3)
            #expect(after.audit["retainedPageEdgeRecoveryRollback"] == nil)
            #expect(after.audit["bodySourceAnchorRecoveryRollback"] == nil,
                "terminal stage: \(String(describing: after.audit["finalSourcePhysicalInteriorRollbackStage"]))")
            #expect(after.audit["finalCompositeAlphaVerified"] as? Bool == true)
            let finalAdmission = try #require(after.audit["finalPaintAdmission"] as? [[String:Any]])
            for i in incumbent.audit.indices {
                #expect(try NativeBalloonPlacement.RetainedState.decode(finalAdmission[i][stateKey]!, owner:fills[i].ownerID!) ==
                    NativeBalloonPlacement.RetainedState.decode(incumbent.audit[i][stateKey]!, owner:fills[i].ownerID!))
            }
            let old = try NativeMandatoryDisplayStroke.rgba(before.image), new = try NativeMandatoryDisplayStroke.rgba(after.image)
            var expected = [UInt8](repeating:0,count:old.count)
            for i in fills.indices {
                let delta = i < 2 ? shift:.zero
                for run in oldSupports[i].runs { for x in run.left..<run.right {
                    let source = (run.y*w+x)*4, target = ((run.y+Int(delta.y))*w+x+Int(delta.x))*4
                    #expect(old[source+3]>0 && expected[target+3]==0)
                    for c in 0..<4 { expected[target+c] = old[source+c] }
                }}
            }
            #expect(new.elementsEqual(expected))
            #expect(stride(from:3,to:old.count,by:4).filter {old[$0]>0}.count == stride(from:3,to:new.count,by:4).filter {new[$0]>0}.count)
            let oldPalette = try #require(before.audit["endpointDecisions"] as? [[String:Any]])
            let newPalette = try #require(after.audit["endpointDecisions"] as? [[String:Any]])
            #expect(oldPalette.count == 3 && newPalette.count == 3)
            for i in oldPalette.indices {
                #expect(oldPalette[i]["displayFillRGB"] as? [Int] == newPalette[i]["displayFillRGB"] as? [Int])
                #expect(oldPalette[i]["finalEndpoint"] as? Int == newPalette[i]["finalEndpoint"] as? Int)
            }
            #expect(try JSONSerialization.data(withJSONObject:before.audit["sourceStylePaint"]!,options:.sortedKeys) ==
                JSONSerialization.data(withJSONObject:after.audit["sourceStylePaint"]!,options:.sortedKeys))
            if touchesBorder {
                #expect(after.audit["retainedPageEdgeRecoveryApplied"] as? [String] == ["edge-tall","edge-right"])
            } else {
                #expect(after.audit["retainedPageEdgeRecoveryApplied"] == nil)
                #expect(new == old)
            }
        }
    }
}

// R141: exact retained contour pitch is distinct from ordinary spacing policy.
extension NativeAOTRawTextPainterTests {
    private func retainedPitchRows(tallFallback: Bool = false) throws -> NativeWholeWordWrap.Result {
        let face = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        let tallerFace = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 48, nil)
        return try NativeWholeWordWrap.layoutInternal(text: "가나다Ω\n라마바\n사아자", font: face, size: 24, width: 320,
            captionBoundaryRules: false, tracking: 0, color: CGColor(gray: 0, alpha: 1), necessaryCJK: true,
            lineFactory: { fragment in
                let painted = NSMutableAttributedString(attributedString: fragment)
                let range = (painted.string as NSString).range(of: "Ω")
                if tallFallback, range.location != NSNotFound {
                    // Actual mixed-face CoreText metrics, not invented ascent values.
                    painted.addAttribute(.init(kCTFontAttributeName as String), value: tallerFace, range: range)
                }
                return CTLineCreateWithAttributedString(painted)
            })
    }

    @Test func retainedContourPitchPreservesExactDeltasWithoutOrdinaryQuantization() throws {
        let rows = try retainedPitchRows()
        #expect(rows.completeOwnership && rows.unresolvedGlyphRanges.isEmpty && rows.rows.count == 3)
        let top = try #require(rows.rows.map(\.upperExtent).max())
        let bottom = try #require(rows.rows.map(\.lowerExtent).max())
        let extent: CGFloat = 2
        // This is already a safe measured pitch. Ordinary .12em breathing room
        // and .1em rounding must not be imposed on it for a second time.
        let pitch = top + bottom + 2 * extent + 1 + 0.125
        let retained = try NativeWholeWordGlyphPainter.positionRetainedPitch(rows, width: 320,
            pitch: pitch, outwardExtent: extent)
        let ordinary = try NativeWholeWordGlyphPainter.position(rows, width: 320,
            minimumLineHeight: pitch, outwardExtent: extent)
        #expect(retained.baselines.count == 3 && ordinary.baselines.count == 3)
        #expect(retained.wrapped.requestedFontName == rows.requestedFontName)
        #expect(retained.wrapped.requestedFontSize == 24 && retained.wrapped.appliedTracking == 0)
        #expect(retained.wrapped.rows.map(\.ownedRange) == rows.rows.map(\.ownedRange))
        #expect(retained.wrapped.rows.map(\.ascent) == rows.rows.map(\.ascent))
        #expect(retained.wrapped.rows.map(\.descent) == rows.rows.map(\.descent))
        #expect(retained.baselines.map(\.x) == ordinary.baselines.map(\.x))
        for i in retained.baselines.indices.dropFirst() {
            #expect(abs(retained.baselines[i].y - retained.baselines[i - 1].y - pitch) < 0.000001)
        }
        #expect(abs(retained.baselines[2].y - retained.baselines[0].y - 2 * pitch) < 0.000001)
        #expect(ordinary.baselines[1].y - ordinary.baselines[0].y > pitch + 0.01)
        #expect(ordinary.size.height > retained.size.height)
        #expect(retained.fillBounds.minX == ordinary.fillBounds.minX)
        #expect(retained.fillBounds.maxX == ordinary.fillBounds.maxX)
    }

    @Test func retainedContourPitchRejectsUnsafeEffectsAndActualTallFallback() throws {
        let rows = try retainedPitchRows(), taller = try retainedPitchRows(tallFallback: true)
        #expect(rows.completeOwnership && taller.completeOwnership)
        #expect(rows.unresolvedGlyphRanges.isEmpty && taller.unresolvedGlyphRanges.isEmpty)
        #expect(rows.rows.count == 3 && taller.rows.count == 3)
        func inkHeight(_ wrapped: NativeWholeWordWrap.Result) throws -> CGFloat {
            let top = try #require(wrapped.rows.map { max(0, $0.inkBounds.maxY) }.max())
            let bottom = try #require(wrapped.rows.map { max(0, -$0.inkBounds.minY) }.max())
            return top + bottom
        }
        let tallTop = try #require(taller.rows.map(\.upperExtent).max())
        let tallBottom = try #require(taller.rows.map(\.lowerExtent).max())
        let ink = try inkHeight(rows), tallInk = try inkHeight(taller)
        let extent: CGFloat = 2, pitch = ink + 2 * extent + 1 + 0.125
        _ = try NativeWholeWordGlyphPainter.positionRetainedPitch(rows, width: 320,
            pitch: pitch, outwardExtent: extent)
        #expect(ink + 2 * 4 + 1 > pitch + 0.01)
        #expect(tallInk + 2 * extent + 1 > pitch + 0.01)
        for (candidate, outward) in [(rows, CGFloat(4)), (taller, extent)] {
            do {
                _ = try NativeWholeWordGlyphPainter.positionRetainedPitch(candidate, width: 320,
                    pitch: pitch, outwardExtent: outward)
                Issue.record("Unsafe effect/fallback metrics must reject the retained pitch")
            } catch NativeWholeWordGlyphPainter.Failure.invalidSpacing {
                // No metrics shrinking, larger pitch or natural-policy fallback.
            } catch {
                Issue.record("Expected invalidSpacing, received \(error)")
            }
        }
        #expect(taller.rows.map(\.upperExtent).max() == tallTop)
        #expect(taller.rows.map(\.lowerExtent).max() == tallBottom)
    }
}

// Actual recoverFixedFont regression: supplied neutral rasters intentionally
// isolate placement from CoreText shaping. No private helper or solver copy.
extension NativeAOTRawTextPainterTests {
    private enum RecoveryPolishCase: Equatable { case edge, gutter, pinnedEdge }

    private func recoveryPolishRect(_ row: [String:Any], _ key: String) throws -> CGRect {
        let raw = try #require(row[key] as? [Any])
        let v = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        #expect(v.count == 4)
        return CGRect(x:v[0],y:v[1],width:v[2],height:v[3])
    }

    private func exerciseActualRecoveryPolish(_ kind: RecoveryPolishCase) throws {
        typealias P = NativeAOTRawTextPainter
        typealias C = NativeAOTTranslationPageComposer
        typealias N = NativeFinalTextPaintAdmission
        let page = CGRect(x:0,y:0,width:400,height:400)
        let keys = ["AIDOKU_FINAL_BODY_TARGETS", "AIDOKU_ADAPTIVE_GUTTER", "AIDOKU_BODY_INK_SEPARATION",
            "AIDOKU_CONTOUR_CLEARANCE", "AIDOKU_INK_CONTOUR_CLEARANCE", "AIDOKU_PAGE_EDGE_MARGIN",
            "AIDOKU_PAGE_EDGE_PEER_PACKING", "AIDOKU_FINAL_PAGE_EDGE_GUARD",
            "AIDOKU_CAPTURE_FINAL_GLYPH_WITNESSES", "AIDOKU_RETAINED_PEER_GUTTER_REPLAY"]
        let prior = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (key,value) in zip(keys,prior) {
                if let value { setenv(key,value,1) } else { unsetenv(key) }
            }
        }
        for key in keys { setenv(key,"0",1) }
        setenv("AIDOKU_FINAL_PAGE_EDGE_GUARD","1",1)
        setenv("AIDOKU_CAPTURE_FINAL_GLYPH_WITNESSES","1",1)
        let canvas = try #require(CGContext(data:nil,width:400,height:400,bitsPerComponent:8,
            bytesPerRow:400*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(gray:1,alpha:1); canvas.fill(page)
        let restored = try #require(canvas.makeImage())
        func norm(_ r: CGRect) -> [Double] {
            [r.minX/400,r.minY/400,r.width/400,r.height/400].map(Double.init)
        }
        func primitive(_ id: String, _ x: CGFloat, _ y: CGFloat) throws -> C.TranslatedFillPrimitive {
            var bytes = [UInt8](repeating:255,count:10*10*4)
            // Observable nonopaque AA must survive the real prepared/final plane.
            for row in 0..<10 { for channel in 0..<4 { bytes[row*40+channel] = 80 } }
            var f = C.TranslatedFillPrimitive(image:try NativeMandatoryDisplayStroke.image(bytes,width:10,height:10),
                frame:CGRect(x:x,y:y,width:10,height:10),fontOutputPixels:20)
            f.ownerID = id; f.displayStrokeEndpoint = 0; f.displayStrokeRatio = 0.1
            let p = NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],
                maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:20,kind:"source-near-limited-expansion",
                maskRectNormalized:nil,maskSpansNormalized:nil)
            f.textExpansionPolicy = p; f.placementDomain = { p.allows($0,page:page) }
            // The initial solve prefers the actual incumbent alpha origin; a
            // default guide at raw fill origin would erase the edge deficit.
            let alpha = try N.retainedFootprint(f).bounds
            f.textPlacementGuide = .init(rectNormalized:norm(alpha),horizontal:.left,vertical:.top)
            return f
        }
        var fills: [C.TranslatedFillPrimitive]
        switch kind {
        case .edge: fills = try [primitive("moving",4,60),primitive("peer",250,250)]
        case .gutter:
            fills = try [primitive("moving",60,60),primitive("partner",78,60),primitive("peer",250,250)]
            let cluster = NativeSourceClusterAlignment(groupID:"recovery-paragraph",axis:.top,
                anchorNormalized:0.145,anchorPolicy:"source-near-final-alpha",anchorsToSourceStart:true)
            fills[0].sourceClusterAlignment = cluster; fills[1].sourceClusterAlignment = cluster
        case .pinnedEdge: fills = try [primitive("moving",180,100),primitive("peer",4,60)]
        }
        let items: [P.Item] = fills.map { f in
            .init(id:f.ownerID!,text:"A",frame:f.frame,fontSize:20,lineHeight:24,
                chosenFill:CGColor(gray:1,alpha:1),colorAuthority:"synthetic-neutral-recovery-fixture")
        }
        let rows: [[String:Any]] = items.map { item in
            ["id":item.id,"fontSize":20.0,"lineRangesUTF16":[[0,1]],"actualCoreTextLineStrings":["A"],
                "sourceUTF16":1,"visibleUTF16":1,"retainedLinePitchOutputPixels":24.0,
                "neutralPrimitiveFixture":true]
        }
        let prepared = P.FixedFontPreparedBatch(audit:rows,primitives:fills)
        var options: [String:[String:Any]] = [:]
        for f in fills {
            var raw: [String:Any] = ["renderPreserveRequestedFontSize":true]
            if let cluster = f.sourceClusterAlignment {
                // Exercise real complete-cohort closure; partner cannot become
                // an accidentally fixed external peer in the gutter case.
                raw["sourceClusterAlignment"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(cluster))
            }
            options[f.ownerID!] = raw
        }
        func recover() throws -> P.FixedFontAttempt {
            let outcome = try P.recoverFixedFont(items:items,viewport:page.size,restored:restored,
                contours:[:],options:options,cause:"moving",prepared:prepared)
            let attempt = try #require(outcome.attempt)
            let receipt = try #require(attempt.value.audit["fixedFontRecovery"] as? [String:Any])
            #expect(receipt["paintCalls"] as? Int == 1)
            #expect(receipt["fixedPeerOwners"] as? [String] == ["peer"])
            #expect(attempt.value.complete && attempt.value.expectedItems == items.count)
            #expect(attempt.value.paintedItems == items.count && attempt.excludedOwners.isEmpty)
            #expect(attempt.value.audit["fontRefitForHalo"] as? Bool == false)
            return attempt
        }
        // Both arms execute actual recovery, native final verification and
        // paint. Only the relevant existing polish flag differs.
        let before = try recover()
        let flag = kind == .gutter ? "AIDOKU_ADAPTIVE_GUTTER":"AIDOKU_PAGE_EDGE_MARGIN"
        setenv(flag,"1",1)
        let after = try recover()
        func placements(_ a: P.FixedFontAttempt) throws -> [String:[String:Any]] {
            let rows = try #require(a.value.audit["finalPaintAdmission"] as? [[String:Any]])
            #expect(rows.count == items.count)
            return Dictionary(uniqueKeysWithValues:try rows.map { (try #require($0["owner"] as? String),$0) })
        }
        func witnesses(_ a: P.FixedFontAttempt) throws -> [String:[String:Any]] {
            let wrapper = try #require(a.value.audit["finalGlyphWitnesses"] as? [String:Any])
            #expect(wrapper["version"] as? Int == 1 && wrapper["glyphProofComplete"] as? Bool == true)
            let rows = try #require(wrapper["owners"] as? [[String:Any]])
            #expect(rows.count == items.count)
            return Dictionary(uniqueKeysWithValues:try rows.map { (try #require($0["ownerID"] as? String),$0) })
        }
        let old = try placements(before), new = try placements(after)
        let oldWitness = try witnesses(before), newWitness = try witnesses(after)
        for i in items.indices {
            let id = items[i].id
            let a = before.primitives[i], b = after.primitives[i]
            #expect(a.ownerID == id && b.ownerID == id)
            #expect(a.fontOutputPixels == 20 && b.fontOutputPixels == 20)
            #expect(a.textPlacementGuide == b.textPlacementGuide && a.textExpansionPolicy == b.textExpansionPolicy)
            #expect(a.sourceClusterAlignment == b.sourceClusterAlignment && a.balloonPlacement == b.balloonPlacement)
            #expect(a.balloonTargetRelaxed == b.balloonTargetRelaxed)
            #expect(try NativeMandatoryDisplayStroke.rgba(a.image) == NativeMandatoryDisplayStroke.rgba(fills[i].image))
            #expect(try NativeMandatoryDisplayStroke.rgba(a.image) == NativeMandatoryDisplayStroke.rgba(b.image))
            let ow = try #require(oldWitness[id]), nw = try #require(newWitness[id])
            #expect(ow["glyphOnly"] as? Bool == true && nw["hasFinalEffects"] as? Bool == false)
            for key in ["width","height","fontOutputPixels","premultipliedRGBASHA256","pngSHA256","pngBase64"] {
                let oldValue = try #require(ow[key]), newValue = try #require(nw[key])
                #expect(NSDictionary(dictionary:[key:oldValue]).isEqual(to:[key:newValue]))
            }
            let png = try #require(nw["pngBase64"] as? String)
            #expect(Data(base64Encoded:png)?.isEmpty == false)
            let oldPlacement = try #require(old[id]), newPlacement = try #require(new[id])
            let oldState = try #require(oldPlacement[NativeBalloonPlacement.RetainedState.auditKey] as? [String:Any])
            let newState = try #require(newPlacement[NativeBalloonPlacement.RetainedState.auditKey] as? [String:Any])
            #expect(NSDictionary(dictionary:oldState).isEqual(to:newState))
            let priorRows = try #require(before.value.audit["rawNativeItems"] as? [[String:Any]])
            let actualRows = try #require(after.value.audit["rawNativeItems"] as? [[String:Any]])
            #expect(priorRows[i]["lineRangesUTF16"] as? [[Int]] == [[0,1]])
            #expect(actualRows[i]["lineRangesUTF16"] as? [[Int]] == [[0,1]])
            #expect(priorRows[i]["retainedLinePitchOutputPixels"] as? Double == 24)
            #expect(actualRows[i]["retainedLinePitchOutputPixels"] as? Double == 24)
        }
        let oldPeer = try #require(old["peer"]), newPeer = try #require(new["peer"])
        #expect(try recoveryPolishRect(oldPeer,"finalFootprintOutputPixels") == recoveryPolishRect(newPeer,"finalFootprintOutputPixels"))
        let oldPin = try #require(before.primitives.first { $0.ownerID == "peer" })
        let newPin = try #require(after.primitives.first { $0.ownerID == "peer" })
        #expect(oldPin.frame == newPin.frame)
        switch kind {
        case .edge:
            let a = try recoveryPolishRect(#require(old["moving"]),"finalFootprintOutputPixels")
            let b = try recoveryPolishRect(#require(new["moving"]),"finalFootprintOutputPixels")
            #expect(a.minX < 3 && b.minX >= 3 && a.size == b.size)
            #expect(a.minY == b.minY)
        case .gutter:
            let a = try recoveryPolishRect(#require(old["moving"]),"readableBoundsOutputPixels")
            let b = try recoveryPolishRect(#require(old["partner"]),"readableBoundsOutputPixels")
            let c = try recoveryPolishRect(#require(new["moving"]),"readableBoundsOutputPixels")
            let d = try recoveryPolishRect(#require(new["partner"]),"readableBoundsOutputPixels")
            let gapBefore = try #require(NativeAdaptiveTextGutter.clearance(a,b))
            let gapAfter = try #require(NativeAdaptiveTextGutter.clearance(c,d))
            #expect(gapBefore < 7 && gapAfter >= 7 && gapAfter > gapBefore)
            #expect(a.minY == c.minY && b.minY == d.minY)
        case .pinnedEdge:
            // A genuinely deficient pinned peer would improve if movable.
            // The whole transaction must keep its previously successful image.
            #expect(try recoveryPolishRect(oldPeer,"finalFootprintOutputPixels").minX < 3)
            #expect(before.primitives.map(\.frame) == after.primitives.map(\.frame))
            #expect(try NativeMandatoryDisplayStroke.rgba(before.value.image) == NativeMandatoryDisplayStroke.rgba(after.value.image))
        }
    }

    @Test func fixedFontRecoveryActuallyPolishesEdgeWithoutMovingFixedPeer() throws {
        try exerciseActualRecoveryPolish(.edge)
    }
    @Test func fixedFontRecoveryActuallyPolishesGutterWithoutChangingGlyphsOrFixedPeer() throws {
        try exerciseActualRecoveryPolish(.gutter)
    }
    @Test func fixedFontRecoveryRetainsSuccessfulOriginalWhenPolishWouldMovePinnedEdgePeer() throws {
        try exerciseActualRecoveryPolish(.pinnedEdge)
    }
}
