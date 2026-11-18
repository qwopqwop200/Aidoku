import Foundation
import CoreText
import CoreGraphics

// Only inert painter carriers: production positioning is compiled unchanged;
// raster(), CGContext and CTLineDraw are never called by this measurement test.
final class NativeAOTTranslationPageComposer {
    struct TranslatedFillPrimitive { let image: CGImage; let frame: CGRect; let fontOutputPixels: CGFloat }
}
enum NativeAOTRawTextPainter {
    struct Item { let text: String; let fontSize: CGFloat; let frame: CGRect; let chosenFill: CGColor }
}

@main enum LineBreakChecks {
    static func main() throws {
        let font=CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString,30,nil)
        var cases=0, failures:[String]=[], oldOutside=0, newOutside=0, overlap=0
        let mixed: [[String: Any]] = [
            ["id":"a", "typographyGroupID":"same", "textAlignment":"left", "frame":[1,2,3,4],
             "textPlacementGuide":["horizontal":"left", "vertical":"top"]],
            ["id":"b", "typographyGroupID":"same", "textAlignment":"center"],
            ["id":"c", "typographyGroupID":"same", "textAlignment":"center"],
            ["id":"d", "typographyGroupID":"narration", "textAlignment":"left"],
            ["id":"e", "typographyGroupID":"narration", "textAlignment":"left"],
            ["id":"f", "textAlignment":"right"]]
        let harmonized = NativeTextAlignmentPolicy.annotate(mixed)
        if harmonized.map({$0["textAlignment"] as? String}) != ["center","center","center","left","left","right"] ||
            harmonized[0]["frame"] as? [Int] != [1,2,3,4] ||
            (harmonized[0]["textPlacementGuide"] as? [String:String]) != ["horizontal":"center","vertical":"top"] {
            failures.append("shared-typography-alignment")
        }
        if NativeTextAlignmentPolicy.annotate(Array(mixed.prefix(2))).contains(where:{$0["textAlignment"] as? String != "center"}) {
            failures.append("shared-typography-center-tie")
        }
        let semanticFont = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        for (text, prefix, suffix, width) in [
            ("짜증 나……♡", "짜증 나", "……♡", CGFloat(110)),
            ("짜증나.....♡", "짜증나", ".....♡", CGFloat(110)),
            ("“짜증 나……♡”", "“짜증 나", "……♡”", CGFloat(110)),
            ("본문을 읽는다… (정말 그랬을까?)", "본문을 읽는다… ", "(정말 그랬을까?)", CGFloat(220))
        ] {
            let split = prefix.utf16.count
            if !NativeLineBreakPolicy.legalOffsets(text: text).contains(split) ||
                !NativeLineBreakPolicy.preferredOffsets(text: text).contains(split) {
                failures.append("semantic-suffix-boundary")
            }
            let result = try NativeWholeWordWrap.layout(text: text, font: semanticFont, size: 24,
                width: width, necessaryCJK: true)
            let ns = text as NSString
            if !result.rows.contains(where:{$0.ownedRange.location == split}) ||
                result.rows.map({ns.substring(with:$0.ownedRange)}).joined() != text ||
                result.rows.last.map({ns.substring(with:$0.paintedRange)}) != suffix {
                failures.append("semantic-suffix-row")
            }
            let wide = try NativeWholeWordWrap.layout(text: text, font: semanticFont, size: 24,
                width: 1000, necessaryCJK: true)
            if wide.rows.count != 1 { failures.append("semantic-forced-unnecessary-row") }
        }
        // Real final-flow CTLines/positions, not just preferred break offsets.
        // Host supplies the actual Bold face; iOS additionally calls the real
        // classified-weight resolver before exercising these same native paths.
        var expressiveBoldAssertions = 0
        func expressiveCheck(_ value: Bool, _ reason: String) {
            expressiveBoldAssertions += 1
            if !value { failures.append("expressive-bold-" + reason) }
        }
        let boldFace = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, 24, nil)
        expressiveCheck(CTFontCopyPostScriptName(boldFace) as String == "AppleSDGothicNeo-Bold", "requested-face")
        let hardFixtures = [
            ("짜증 나\n……♡", "짜증 나"),
            ("짜증  나\n……♡", "짜증  나"),
            ("짜증나\n……♡", "짜증나"),
            ("짜증 나  \n  ……♡", "짜증 나")
        ]
        for (text, paintedPrefix) in hardFixtures {
            let wrapped = try NativeWholeWordWrap.layout(text:text,font:boldFace,size:24,width:300,necessaryCJK:true)
            guard let flow = try NativeFinalTextFlow.horizontal(text:text,font:boldFace,size:24,width:300,
                minimumLineHeight:36,outwardExtent:2,color:CGColor(gray:0,alpha:1)) else {
                failures.append("expressive-bold-final-flow-missing"); continue
            }
            let ns = text as NSString
            expressiveCheck(wrapped.completeOwnership && wrapped.unresolvedGlyphRanges.isEmpty && flow.complete,
                "complete-hard-ownership")
            expressiveCheck(wrapped.rows.count == 2 && flow.lines.count == 2, "explicit-two-rows")
            expressiveCheck(wrapped.rows.first?.hardBreak == true && wrapped.rows.last?.hardBreak == false,
                "explicit-newline-not-soft-preference")
            expressiveCheck(wrapped.rows.map {ns.substring(with:$0.ownedRange)}.joined() == text &&
                flow.ranges.map {ns.substring(with:$0)}.joined() == text, "all-original-spaces-and-newline")
            expressiveCheck(flow.ranges == wrapped.rows.map(\.ownedRange) && flow.visibleUTF16 == ns.length,
                "final-flow-exact-original-utf16")
            expressiveCheck(ns.substring(with:wrapped.rows[0].paintedRange) == paintedPrefix &&
                ns.substring(with:wrapped.rows[1].paintedRange) == "……♡", "internal-spaces-never-corrected")
            expressiveCheck(flow.appliedTracking == 0 && flow.aligned(.center).baselines == flow.baselines,
                "native-center-zero-tracking")
            for i in flow.lines.indices {
                let line = flow.lines[i], ink = CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
                let advance = CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
                let left = min(0,ink.isNull || ink.isEmpty ? 0:ink.minX)
                let right = max(advance,ink.isNull || ink.isEmpty ? 0:ink.maxX)
                expressiveCheck(abs(flow.baselines[i].x + (left+right)/2 - 150) < 0.01,
                    "actual-ctline-occupied-center")
            }
            var measuredLetters = 0
            for run in CTLineGetGlyphRuns(flow.lines[0]) as! [CTRun] {
                let range = CTRunGetStringRange(run), prefix = paintedPrefix as NSString
                guard range.location >= 0,range.length > 0,range.location+range.length <= prefix.length else {
                    failures.append("expressive-bold-run-ownership"); continue
                }
                let fragment = prefix.substring(with:NSRange(location:range.location,length:range.length))
                if fragment.unicodeScalars.contains(where:{CharacterSet.letters.contains($0)}) {
                    measuredLetters += 1
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    let actual = attrs[kCTFontAttributeName] as! CTFont
                    expressiveCheck(CTFontCopyPostScriptName(actual) as String == "AppleSDGothicNeo-Bold" &&
                        CTFontGetSize(actual) == 24, "actual-shaped-letter-run-bold-face")
                }
            }
            expressiveCheck(measuredLetters > 0, "actual-bold-letters-inspected")
        }
        for text in ["짜증 나……♡", "짜증 나 ……♡", "짜증나……♡"] {
            let ns = text as NSString
            let wide = try NativeWholeWordWrap.layout(text:text,font:boldFace,size:24,width:1000,necessaryCJK:true)
            guard let flow = try NativeFinalTextFlow.horizontal(text:text,font:boldFace,size:24,width:1000,
                minimumLineHeight:36,outwardExtent:2,color:CGColor(gray:0,alpha:1)) else {
                failures.append("expressive-bold-wide-flow-missing"); continue
            }
            expressiveCheck(wide.rows.count == 1 && flow.lines.count == 1, "wide-soft-remains-one-line")
            expressiveCheck(wide.rows.map {ns.substring(with:$0.ownedRange)}.joined() == text &&
                flow.ranges.map {ns.substring(with:$0)}.joined() == text, "wide-original-spacing")
        }
        for text in ["……♡", "word♡", "3.14", "word…next", "word……", "word..."] {
            if !NativeLineBreakPolicy.preferredOffsets(text: text).isEmpty { failures.append("semantic-invalid-tail") }
        }
        let longText = "첫 번째 문장을 읽고 두 번째 문장도 계속 읽는다……♡"
        let longWrapped = try NativeWholeWordWrap.layout(text:longText,font:semanticFont,size:24,
            width:220,necessaryCJK:true)
        if longWrapped.rows.count < 3 || longWrapped.rows.last.map({
            NativeLineBreakPolicy.isExpressiveTailRow(text:longText,range:$0.ownedRange)
        }) == true || NativeRenderWrapQuality.semanticCrossings(longText,ranges:longWrapped.rows.map(\.ownedRange)) != 0 {
            failures.append("long-paragraph-must-not-gain-decorative-tail-row")
        }
        if NativeRenderWrapQuality.evaluate("word♡",ranges:[NSRange(location:0,length:4),NSRange(location:4,length:1)]).orphans != 1 ||
            NativeRenderWrapQuality.evaluate("word……♡",ranges:[NSRange(location:0,length:6),NSRange(location:6,length:1)]).orphans != 1 ||
            NativeLineBreakPolicy.isExpressiveTailRow(text:"word……♡",range:NSRange(location:4,length:1)) {
            failures.append("partial-symbol-tail-must-still-fail")
        }
        do {
            let paletteText=NSAttributedString(string:"one two three four five six",attributes:[.init(kCTFontAttributeName as String):font])
            let lexical=NativeRenderWrapQuality.lexicalLineWidths(paletteText,minimumWidth:20,maximumWidth:300,limit:5)
            if lexical.isEmpty || lexical.count>5 || lexical != lexical.sorted() || lexical.contains(where:{$0<=20 || $0>300}) ||
                lexical != NativeRenderWrapQuality.lexicalLineWidths(paletteText,minimumWidth:20,maximumWidth:300,limit:5) {
                failures.append("bounded-deterministic-lexical-palette")
            }
            let separated=NSAttributedString(string:"two\nthree",attributes:[.init(kCTFontAttributeName as String):font])
            let separateWidths=NativeRenderWrapQuality.lexicalLineWidths(separated,minimumWidth:0,maximumWidth:1000)
            let expectedWidths=["two","three"].map {NativeRenderWrapQuality.joinedLineWidth(NSAttributedString(string:$0,
                attributes:[.init(kCTFontAttributeName as String):font]))}.sorted()
            if separateWidths != expectedWidths {failures.append("lexical-hard-paragraph-boundary")}
            if !NativeRenderWrapQuality.lexicalLineWidths(paletteText,minimumWidth:.nan,maximumWidth:300).isEmpty ||
                !NativeRenderWrapQuality.lexicalLineWidths(paletteText,minimumWidth:0,maximumWidth:300,limit:0).isEmpty ||
                NativeRenderWrapQuality.lexicalLineWidths(paletteText,minimumWidth:0,maximumWidth:300,limit:1).count != 1 {
                failures.append("lexical-invalid-budget-and-single-sample")
            }
            let unicodeText=NSAttributedString(string:"가나다 👩🏽‍💻 한글",attributes:[.init(kCTFontAttributeName as String):font])
            let unicodeBefore=unicodeText.string
            if NativeRenderWrapQuality.lexicalLineWidths(unicodeText,minimumWidth:0,maximumWidth:1000).isEmpty ||
                unicodeText.string != unicodeBefore {failures.append("lexical-unicode-ownership")}
        }
        enum Rejected: Error { case candidate }
        var attempts: [Bool] = []
        let fallback = try NativeFinalTextFlow.withRefinementFallback { enabled, record in
            attempts.append(enabled)
            if enabled { record(); throw Rejected.candidate }
            return 42
        }
        if fallback.value != 42 || !fallback.usedBaselineRetry || attempts != [true, false] {
            failures.append("final-admission-baseline-retry")
        }
        var ownerAttempts:[Set<String>]=[]
        let scoped=try NativeFinalTextFlow.withOwnerRefinementFallback(rejectedOwners:{_ in ["blocked"]}) {excluded,record in
            ownerAttempts.append(excluded)
            if !excluded.contains("independent") {record("independent")}
            if !excluded.contains("blocked") {record("blocked");throw Rejected.candidate}
            return !excluded.contains("independent")
        }
        if !scoped.value || scoped.excludedOwners != ["blocked"] || ownerAttempts.count != 2 {
            failures.append("independent-owner-refinement-preserved")
        }
        var recoveredOwners=Set<String>(),recoveryAttempts=0
        let recovered=try NativeFinalTextFlow.withOwnerRefinementFallback(rejectedOwners:{_ in ["wide"]},recoverRefinement:{owners in
            guard let id=owners.subtracting(recoveredOwners).first else{return false}
            recoveredOwners.insert(id);return true
        }) {excluded,record in
            recoveryAttempts+=1;record("wide");record("independent")
            if !recoveredOwners.contains("wide") {throw Rejected.candidate}
            return !excluded.contains("independent")
        }
        if !recovered.value || !recovered.excludedOwners.isEmpty || recoveryAttempts != 2 {
            failures.append("recover-prior-word-fit-before-exclusion")
        }
        let plainFont = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for (text,cut) in [("「당연하잖아.」",2),("「편리해서……」",3),("「고맙습니다……♡」",3),("(translation)",5)] {
            let styled=NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):plainFont])
            let ranges=[NSRange(location:0,length:cut),NSRange(location:cut,length:text.utf16.count-cut)]
            let widths=NativeRenderWrapQuality.wordJoinWidths(styled,ranges:ranges,includeAttachedPunctuation:true)
            let bound=NativeRenderWrapQuality.joinedLineWidth(styled)
            if !widths.contains(where:{abs($0-bound)<0.01}) {failures.append("attached-punctuation-width "+text)}
        }
        let utterance="「아... 윽!」"
        let utteranceFont=CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString,24,nil)
        let utteranceStyled=NSAttributedString(string:utterance,attributes:[.init(kCTFontAttributeName as String):utteranceFont])
        let utteranceWidth=NativeRenderWrapQuality.joinedLineWidth(utteranceStyled)
        let utterancePlans=try NativeFinalTextFlow.horizontalCandidates(text:utterance,font:utteranceFont,size:24,
            width:utteranceWidth*0.6,maximumWidth:utteranceWidth+1,minimumLineHeight:36,outwardExtent:2,
            color:CGColor(gray:0,alpha:1),preferCompactRefinement:true)
        if utterancePlans.first?.lines.count != 1 || utterancePlans.first?.ranges.first?.length != utterance.utf16.count {
            failures.append("short-zero-word-cut-utterance-one-line")
        }
        let koreanFont = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let previousBudgetFlag=ProcessInfo.processInfo.environment["AIDOKU_ROW_BUDGET_CJK"]
        let flexibleText="도서관에서 친구들과 책을 읽었습니다 오늘도 즐겁게 이야기했습니다"
        let flexibleRanges=stride(from:0,to:flexibleText.utf16.count,by:6).map {
            NSRange(location:$0,length:min(6,flexibleText.utf16.count-$0))
        }
        var flexible:[NativeWholeWordWrap.Result?]=[]
        for flag in ["0","1"] {
            setenv("AIDOKU_ROW_BUDGET_CJK",flag,1)
            flexible.append(try NativeWholeWordWrap.layoutPreservingRows(text:flexibleText,font:koreanFont,size:24,
                width:120,originalRanges:flexibleRanges,color:CGColor(gray:0,alpha:1)))
        }
        if let before=flexible[0],let after=flexible[1] {
            let oldCuts=NativeRenderWrapQuality.wordCutOffsets(flexibleText,ranges:before.rows.map(\.ownedRange)).count
            let newCuts=NativeRenderWrapQuality.wordCutOffsets(flexibleText,ranges:after.rows.map(\.ownedRange)).count
            let q=NativeRenderWrapQuality.evaluate(flexibleText,ranges:after.rows.map(\.ownedRange))
            if newCuts>=oldCuts || after.rows.count != flexibleRanges.count || !after.completeOwnership ||
                !after.unresolvedGlyphRanges.isEmpty || after.requiredWidth>120.01 || q.illegal>0 || q.orphans>0 {
                failures.append("fixed-row-budget-explores-alternative-cjk-breaks")
            }
        } else {failures.append("fixed-row-budget-alternative-missing")}
        if let previousBudgetFlag {setenv("AIDOKU_ROW_BUDGET_CJK",previousBudgetFlag,1)}
        else {unsetenv("AIDOKU_ROW_BUDGET_CJK")}
        let budgetPieces=["😀 가나다라마 ","바사아자차\n","카타파하 ","가나"]
        let budgetText=budgetPieces.joined()
        var budgetOffset=0
        let budgetRanges=budgetPieces.map {piece -> NSRange in
            defer {budgetOffset+=piece.utf16.count}
            return NSRange(location:budgetOffset,length:piece.utf16.count)
        }
        if let budget=try NativeWholeWordWrap.layoutPreservingRows(text:budgetText,font:koreanFont,size:24,width:300,
            originalRanges:budgetRanges,color:CGColor(gray:0,alpha:1)) {
            if budget.rows.count != 4 || !budget.completeOwnership || budget.rows.filter(\.hardBreak).count != 1 ||
                !NativeRenderWrapQuality.wordCutOffsets(budgetText,ranges:budget.rows.map(\.ownedRange)).isEmpty {
                failures.append("lexical-dp-preserves-hard-paragraph-row-budgets")
            }
        } else {failures.append("lexical-dp-row-budget-missing")}
        let sameRows="가나다라마 가나다라마"
        if let measured=try NativeWholeWordWrap.widthPreservingRows(text:sameRows,font:koreanFont,size:24,
            minimumWidth:80,maximumWidth:160,rows:2,color:CGColor(gray:0,alpha:1)) {
            let shaped=try NativeWholeWordWrap.layout(text:sameRows,font:koreanFont,size:24,width:measured,necessaryCJK:true)
            if shaped.rows.count != 2 || !shaped.completeOwnership || measured>160 ||
                !NativeRenderWrapQuality.wordCutOffsets(sameRows,ranges:shaped.rows.map(\.ownedRange)).isEmpty {
                failures.append("same-row-count-measured-word-width")
            }
        } else {failures.append("same-row-count-width-missing")}
        if try NativeWholeWordWrap.widthPreservingRows(text:sameRows,font:koreanFont,size:24,
            minimumWidth:80,maximumWidth:90,rows:2,color:CGColor(gray:0,alpha:1)) != nil {
            failures.append("same-row-count-width-capacity")
        }
        let lexicalText="도서관에서 책을 읽었습니다"
        let narrow=try NativeFinalTextFlow.horizontalCandidates(text:lexicalText,font:koreanFont,size:24,
            width:80,maximumWidth:160,minimumLineHeight:40,outwardExtent:5,color:CGColor(gray:0,alpha:1),allowRefinement:false)
        let lexical=try NativeFinalTextFlow.horizontalCandidates(text:lexicalText,font:koreanFont,size:24,
            width:80,maximumWidth:160,minimumLineHeight:40,outwardExtent:5,color:CGColor(gray:0,alpha:1))
        if let initial=narrow.first,let preferred=lexical.first {
            let before=NativeRenderWrapQuality.wordCutOffsets(lexicalText,ranges:initial.ranges).count
            let after=NativeRenderWrapQuality.wordCutOffsets(lexicalText,ranges:preferred.ranges).count
            if before==0 || after>=before || preferred.size.width>160.01 ||
                preferred.refinementOriginWidth != 80 || lexical.last?.ranges != initial.ranges ||
                preferred.visibleUTF16 != lexicalText.utf16.count {failures.append("measured-lexical-width-repair")}
        } else {failures.append("measured-lexical-width-missing")}
        let cleanParagraph="좋은 글은 읽기 편한 문장으로 함께 자연스럽게 배치한다"
        let ordinaryParagraph=try NativeFinalTextFlow.horizontalCandidates(text:cleanParagraph,font:koreanFont,size:24,
            width:122,maximumWidth:480,minimumLineHeight:40,outwardExtent:2,color:CGColor(gray:0,alpha:1),allowRefinement:false)
        let compactParagraph=try NativeFinalTextFlow.horizontalCandidates(text:cleanParagraph,font:koreanFont,size:24,
            width:122,maximumWidth:480,minimumLineHeight:40,outwardExtent:2,color:CGColor(gray:0,alpha:1),preferCompactRefinement:true)
        if let before=ordinaryParagraph.first,let after=compactParagraph.first {
            if before.lines.count<4 || after.lines.count>=before.lines.count ||
                !NativeRenderWrapQuality.wordCutOffsets(cleanParagraph,ranges:after.ranges).isEmpty ||
                !compactParagraph.contains(where:{$0.refinementOriginWidth==nil && $0.ranges==before.ranges}) ||
                after.visibleUTF16 != cleanParagraph.utf16.count {failures.append("clean-paragraph-compact-alternative")}
        } else {failures.append("clean-paragraph-compact-missing")}
        let hardRows=NSAttributedString(string:"alpha\nbeta\ngamma\ndelta",attributes:[.init(kCTFontAttributeName as String):koreanFont])
        if !NativeRenderWrapQuality.compactParagraphWidths(hardRows,
            ranges:[NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:6),NSRange(location:17,length:5)],
            currentWidth:30,maximumWidth:480).isEmpty {failures.append("hard-paragraphs-never-joined")}
        let hardLines=NSAttributedString(string:"alpha\u{2028}beta\u{2028}gamma\u{2028}delta",attributes:[.init(kCTFontAttributeName as String):koreanFont])
        if !NativeRenderWrapQuality.compactParagraphWidths(hardLines,
            ranges:[NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:6),NSRange(location:17,length:5)],
            currentWidth:30,maximumWidth:480).isEmpty {failures.append("hard-line-separators-never-joined")}
        let surrogate=NSAttributedString(string:"😀 가나다라",attributes:[.init(kCTFontAttributeName as String):koreanFont])
        let lexicalWidths=NativeRenderWrapQuality.wordJoinWidths(surrogate,
            ranges:[NSRange(location:0,length:5),NSRange(location:5,length:2)])
        let expectedWidth=NativeRenderWrapQuality.joinedLineWidth(surrogate.attributedSubstring(from:NSRange(location:3,length:4)))
        if lexicalWidths.count != 1 || abs((lexicalWidths.first ?? 0)-expectedWidth)>0.001 {
            failures.append("lexical-width-original-surrogate-ownership")
        }
        let candidates = try NativeFinalTextFlow.horizontalCandidates(text: "정신을 차렸을 때", font: koreanFont, size: 24,
            width: 80, maximumWidth: 105, minimumLineHeight: 40, outwardExtent: 5, color: CGColor(gray: 0, alpha: 1))
        if candidates.count != 2 || candidates.first?.quality?.softOrphans != 0 ||
            (candidates.first?.lines.count ?? 0) >= (candidates.last?.lines.count ?? 0) ||
            candidates.last?.refinementOriginWidth != nil { failures.append("bounded-tail-width-refinement") }
        if NativeRenderWrapQuality.shortTailOffsets("가나다라마",ranges:[NSRange(location:0,length:4),NSRange(location:4,length:1)]) != [4] {
            failures.append("single-syllable-soft-tail")
        }
        if NativeRenderWrapQuality.wordCutOffsets("가나다 라마",ranges:[NSRange(location:0,length:2),NSRange(location:2,length:2),NSRange(location:4,length:2)]) != [2] {
            failures.append("original-word-boundary-cost")
        }
        if !NativeRenderWrapQuality.wordCutOffsets("가나\n다라",ranges:[NSRange(location:0,length:3),NSRange(location:3,length:2)]).isEmpty {
            failures.append("intentional-paragraph-not-word-cut")
        }
        if NativeRenderWrapQuality.wordCutOffsets("😀 가나",ranges:[NSRange(location:0,length:4),NSRange(location:4,length:1)]) != [4] {
            failures.append("word-cost-original-surrogate-offset")
        }
        let measuredTail=NSAttributedString(string:"가나다라마",attributes:[.init(kCTFontAttributeName as String):koreanFont])
        let widths=NativeRenderWrapQuality.tailJoinWidths(measuredTail,ranges:[NSRange(location:0,length:4),NSRange(location:4,length:1)])
        if widths.count != 1 {failures.append("measured-tail-width-count")}
        else {
            let setter=CTFramesetterCreateWithAttributedString(measuredTail)
            let path=CGPath(rect:CGRect(x:0,y:0,width:widths[0],height:200),transform:nil)
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil)
            if CFArrayGetCount(CTFrameGetLines(frame)) != 1 || CTFrameGetVisibleStringRange(frame).length != measuredTail.length {
                failures.append("measured-tail-joins-at-native-font")
            }
        }
        for (text,ranges) in [("가나다라\n마",[NSRange(location:0,length:5),NSRange(location:5,length:1)]),
                              ("가나다라마",(0..<5).map {NSRange(location:$0,length:1)}),
                              ("가나",[NSRange(location:0,length:1),NSRange(location:1,length:1)]),
                              ("가나다라\n1",[NSRange(location:0,length:5),NSRange(location:5,length:1)])] {
            if !NativeRenderWrapQuality.shortTailOffsets(text,ranges:ranges).isEmpty {failures.append("intentional-short-paragraph")}
        }
        for text in ["1'234", "1’234’567.89", "１２＇３４５", "1\u{2009}234", "12\u{2007}345", "1’234 kg"] {
            let legal = NativeLineBreakPolicy.legalOffsets(text: text)
            var offset = 0
            for c in text.dropLast() {
                offset += String(c).utf16.count
                if legal.contains(offset) { failures.append("grouped-number") }
            }
        }
        for unit in ["hPa", "kN", "kg·m/s²", "m/s^2", "µmol/L", "a.m.", "개월", "번째로", "개의", "원까지"] {
            let text = "10 " + unit, legal = NativeLineBreakPolicy.legalOffsets(text: text)
            var offset = 0
            for c in text.dropLast() {
                offset += String(c).utf16.count
                if legal.contains(offset) { failures.append("unit-grammar") }
            }
        }
        for word in ["hello", "개성", "주름", "시작", "시간표", "번역"] {
            if !NativeLineBreakPolicy.legalOffsets(text: "10 " + word).contains(3) { failures.append("unit-prefix-overconstraint") }
        }
        for value: UInt32 in [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let mark = String(UnicodeScalar(value)!)
            for (left, right) in [("(" + mark, "AB)"), ("AB", mark + ")"), ("10" + mark + " ", "kg"),
                                  ("l" + mark, "’ami"), ("l’" + mark, "ami")] {
                if NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count) { failures.append("bidi-kinsoku-bypass") }
            }
        }
        for (text, offset) in [("AB\u{200E}\u{00AD}CD", 3), ("AB\u{00AD}\u{200E}CD", 2)] {
            let flow = try NativeFinalTextFlow.horizontal(text: text, font: plainFont, size: 20, width: 40,
                minimumLineHeight: 24, outwardExtent: 0, color: CGColor(gray: 0, alpha: 1))
            if flow?.discretionaryHyphenOffsets != [offset] { failures.append("bidi-discretionary-hyphen") }
        }
        let soft = "AB\u{00AD}CD"
        let softNarrow = try NativeWholeWordWrap.layout(text: soft, font: plainFont, size: 20, width: 40, tracking: 0.1)
        let softWide = try NativeWholeWordWrap.layout(text: soft, font: plainFont, size: 20, width: 200)
        let decorated = CTLineCreateWithAttributedString(NSAttributedString(string: "AB\u{2010}", attributes: [
            .init(kCTFontAttributeName as String): CTFontCreateCopyWithAttributes(plainFont, 20, nil, nil),
            .init(kCTKernAttributeName as String): 0.1
        ]))
        if !softNarrow.completeOwnership || softNarrow.rows.count != 2 || softNarrow.rows.first?.discretionaryHyphen != true ||
            abs((softNarrow.rows.first?.advance ?? 0) - CGFloat(CTLineGetTypographicBounds(decorated, nil, nil, nil))) > 0.001 ||
            softWide.rows.count != 1 || softWide.rows.contains(where: \.discretionaryHyphen) {
            failures.append("discretionary-hyphen-width")
        }
        for text in ["well-known-self-contained", "root/folder/file-name", "well‐known‐self‐contained"] {
            let result = try NativeWholeWordWrap.layout(text: text, font: plainFont, size: 20, width: 110, necessaryCJK: true)
            if !result.completeOwnership || result.requiredWidth > 110.01 || result.rows.count < 2 {
                failures.append("natural-delimiter-wrap")
            }
        }
        for separator in ["\n", "\r\n", "\u{2028}", "\u{0085}"] {
            for (open, close) in [("\"", "\""), ("＂", "＂"), ("'", "'"), ("‘", "’"), ("„", "“"), ("»", "«")] {
                let left = "彼は" + open + "はい" + separator + "そうだ", prefix = left + close
                if NativeLineBreakPolicy.legalOffsets(text: left + close + "と言った").contains(left.utf16.count) ||
                    !NativeLineBreakPolicy.legalOffsets(text: prefix + "次").contains(prefix.utf16.count) {
                    failures.append("multiline-quote-pair")
                }
            }
        }
        let eastAsianFont = CTFontCreateWithName("HiraginoSans-W3" as CFString, 24, nil)
        for text in ["ｶﾀｶﾅﾉﾌﾞﾝｼｮｳｦﾖﾐﾏｽ", String(repeating: "神﨑", count: 5), "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒ"] {
            let result = try NativeWholeWordWrap.layout(text: text, font: eastAsianFont, size: 24, width: 80, necessaryCJK: true)
            if !result.completeOwnership || !result.unresolvedGlyphRanges.isEmpty || result.requiredWidth > 80.01 {
                failures.append("east-asian-script-overflow")
            }
        }
        let four = NSAttributedString(string: "alpha alpha alpha alpha", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): plainFont
        ])
        let balancedWidth = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(four), nil, nil, nil)) + 1
        let balanced = try NativeWholeWordWrap.layout(text: "alpha alpha alpha alpha alpha", font: plainFont, size: 24, width: balancedWidth)
        if !balanced.completeOwnership || balanced.rows.count != 2 ||
            (balanced.rows.last?.occupiedWidth ?? 0) < balancedWidth * 0.35 || balanced.requiredWidth > balancedWidth + 0.01 {
            failures.append("avoidable-short-tail")
        }
        for separator in ["\u{000B}", "\u{000C}"] {
            let result = try NativeWholeWordWrap.layout(text: "first" + separator + "second", font: plainFont, size: 24, width: 500)
            if !result.completeOwnership || result.rows.count != 2 || result.rows.first?.hardBreak != true {
                failures.append("mandatory-control-break")
            }
        }
        for dash in ["-", "‐", "–"] {
            if NativeLineBreakPolicy.legalOffsets(text: dash + dash).contains(dash.utf16.count) { failures.append("dash-run") }
        }
        for mark in ["─", "—", "―", "~", "〜", "～", "-"] {
            if NativeLineBreakPolicy.legalOffsets(text: "문장" + mark).contains("문장".utf16.count) ||
                NativeLineBreakPolicy.legalOffsets(text: mark + "문장").contains(mark.utf16.count) {
                failures.append("orphan-continuation")
            }
        }
        for (left, right) in [("彼は\"", "はい\"と言った"), ("He said:\"", "hello\"again"),
                              ("彼は＂", "はい＂と言った"), ("\"hello ", "\"again"),
                              ("彼は\"はい\"と\"", "いいえ\"と言った"), ("l", "’ami"), ("l’", "ami")] {
            if NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count) { failures.append("paired-quote-open") }
        }
        for (left, right) in [("He said:", "\"hello\""), ("彼は", "\"はい\"と言った"),
                              ("\"hello \" ", "again"), ("彼は", "'はい'と言った")] {
            if !NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count) { failures.append("paired-quote-close") }
        }
        var finalFlowCalculations = 0
        for text in ["alpha alpha alpha alpha alpha", "그는 (안녕!)이라고 말했다.", "가격 ₩ 12,345, 무게 10 kg.",
                     "「括弧」句読点。続きの文。", "first\u{000B}second\u{000C}third", "e\u{301}cole 👩🏽‍💻", "“italic f!”"] {
            for width in [180.0, 300] {
                guard let flow = try NativeFinalTextFlow.horizontal(text: text, font: plainFont, size: 24,
                    width: width, minimumLineHeight: 32, outwardExtent: 5, color: CGColor(gray: 0, alpha: 1)),
                    let centered = flow.centered(height: flow.size.height + 20) else {
                    failures.append("final-flow-incomplete"); continue
                }
                let ns = text as NSString, legal = NativeLineBreakPolicy.legalOffsets(text: text)
                if !flow.complete || flow.visibleUTF16 != ns.length || flow.ranges.map({ ns.substring(with: $0) }).joined() != text {
                    failures.append("final-flow-ownership")
                }
                for range in flow.ranges.dropLast() {
                    let fragment = ns.substring(with: range)
                    if !legal.contains(NSMaxRange(range)) && !(fragment.last.map(NativeLineBreakPolicy.isBreak) ?? false) {
                        failures.append("final-flow-soft-boundary")
                    }
                }
                if !CGRect(origin: .zero, size: centered.size).insetBy(dx: -0.01, dy: -0.01).contains(centered.inkBounds) {
                    failures.append("final-flow-clipping")
                }
                for alignment: CTTextAlignment in [.left, .right, .center] {
                    let aligned = flow.aligned(alignment)
                    if aligned.ranges != flow.ranges || aligned.visibleUTF16 != ns.length ||
                        aligned.appliedTracking != flow.appliedTracking || aligned.size != flow.size ||
                        aligned.baselines.map(\.y) != flow.baselines.map(\.y) {
                        failures.append("alignment-changed-shaping")
                    }
                    if alignment == .center && aligned.baselines != flow.baselines {
                        failures.append("default-center-regression")
                    }
                    for index in aligned.lines.indices where alignment != .center {
                        let ink = CTLineGetImageBounds(aligned.lines[index], nil)
                            .union(CTLineGetBoundsWithOptions(aligned.lines[index], [.useGlyphPathBounds]))
                        if ink.isNull || ink.isEmpty { continue }
                        let edge = aligned.baselines[index].x + (alignment == .left ? ink.minX : ink.maxX)
                        if abs(edge - (alignment == .left ? 0 : width)) > 0.01 {
                            failures.append("row-alignment-edge")
                        }
                    }
                    guard let fit = aligned.centered(height: flow.size.height + 20),
                          CGRect(origin: .zero, size: fit.size).insetBy(dx: -0.01, dy: -0.01).contains(fit.inkBounds)
                    else { failures.append("aligned-final-flow-clipping"); continue }
                }
                finalFlowCalculations += 1
            }
        }
        let fixtures=["「引号」句読点。", "『（括弧）』……！", "“italic f!”", "jazz?!", "e\u{301}\u{302}\u{303}cole…", "그는 (안녕!)이라고 말했다.", "10 kg, 42개를 ₩ 12,345에", "one\u{200B}two", "\n\r\n\u{0085}\u{2028}\u{2029}", "👩🏽‍💻 🇰🇷 한글"]
        for text in fixtures {
            for width in [15.0,30,55,90,150] {
                for tracking in [-0.5,0,1.5] {
                    let result=try NativeWholeWordWrap.layout(text:text,font:font,size:30,width:width,tracking:tracking,characterControl:true)
                    let plan=try NativeWholeWordGlyphPainter.position(result,width:max(width,result.requiredWidth),minimumLineHeight:0)
                    let boxWidth=max(width,result.requiredWidth),legal=NativeLineBreakPolicy.legalOffsets(text:text)
                    if !result.completeOwnership {failures.append("ownership")}
                    for (index,row) in result.rows.enumerated() {
                        if index<result.rows.count-1 && !row.hardBreak && !legal.contains(NSMaxRange(row.ownedRange)) {failures.append("soft-boundary")}
                        if row.hasInk {
                            let before=(boxWidth-row.advance)/2
                            if before+row.inkBounds.minX < -0.001 || before+row.inkBounds.maxX > boxWidth+0.001 {oldOutside+=1}
                            let x=plan.baselines[index].x
                            if x+row.inkBounds.minX < -0.001 || x+row.inkBounds.maxX > boxWidth+0.001 {newOutside+=1}
                            if plan.baselines[index].y-row.inkBounds.maxY < -0.001 {failures.append("upper-clipping")}
                            if index>0 {
                                let prev=result.rows[index-1]
                                if prev.hasInk && plan.baselines[index].y-row.inkBounds.maxY < plan.baselines[index-1].y-prev.inkBounds.minY-0.001 {overlap+=1}
                            }
                        }
                    }
                    cases+=1
                }
            }
        }
        // Explicit UTF16 pairs, independently specified expected no-break edges.
        let noBreak:[(String,String)] = [("（ ","字"),("字 ","）"),("字","ㇰ"),("字","々"),("字","،"),("字","؟"),("12 ","kg"),("12 k","g"),("말","♡"),("글","²"),("Hallo","“"),("Bonjour","«"),("2026-","11-11"),("− ","12"),(".","5 kg"),("★ ","항목"),("10","개를"),("USD ","10"),("1.2","3e−4"),("—","—"),("A\u{2060}","B"),("A","\u{00A0}B")]
        for (a,b) in noBreak {if NativeLineBreakPolicy.legalOffsets(text:a+b).contains(a.utf16.count) {failures.append("illegal "+a+"|"+b)}}
        let allow:[(String,String)] = [("word ","next"),("。","次"),("word ",".5 kg"),("닫힘） ","다음"),("word\u{200B}","next")]
        for (a,b) in allow {if !NativeLineBreakPolicy.legalOffsets(text:a+b).contains(a.utf16.count) {failures.append("blocked "+a+"|"+b)}}
        let report:[String:Any] = ["positionCalculations":cases,"finalFlowCalculations":finalFlowCalculations,"oldOutside":oldOutside,"newOutside":newOutside,"rowInkOverlaps":overlap,"failures":failures,"imageRenders":0,"expressiveBoldFlowAssertions":expressiveBoldAssertions]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count>1 {try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
        print(String(data:data,encoding:.utf8)!)
        if !failures.isEmpty || newOutside>0 || overlap>0 {exit(1)}
    }
}
