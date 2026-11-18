"""Production crop endpoint checks: detached weak ink, long bars and polarity."""
import ast
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[2]
ocr=root/'Aidoku/Core/Translation/NativeEngine/OCR'
tree=ast.parse((root/'Scripts/tests/run-ocr-rf-primary-smoke.py').read_text())
stubs=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='stubs' for t in n.targets))
# Match the actual RF primitive; OCR read/box confidence remains Double.
stubs=stubs.replace('let semanticClass: NativeRFDETRLayoutClass\n    let confidence: Double',
                    'let semanticClass: NativeRFDETRLayoutClass\n    let confidence: Float')
stubs=stubs.replace('struct NativeOCRDetectorSeedEvidence: Sendable { var components: [Int] = [] }','')
stubs=stubs.replace('struct NativeCoreMLRecognizedRegion {',
    'struct NativeCoreMLCTCTokenObservation { let text: String; let confidence: Double }\nstruct NativeCoreMLRecognizedRegion {')
stubs=stubs.replace('    let text: String\n    let confidence: Double\n}',
    '    let text: String\n    let confidence: Double\n    var tokenObservations: [NativeCoreMLCTCTokenObservation] = []\n}',1)

stubs+=''.join((ocr/n).read_text() for n in ['NativeOCRSourceROIProbabilityEvidence.swift','NativeOCRDetectorSeedEvidence.swift'])
production=''.join((ocr/n).read_text() for n in ['NativeOCRLocalCoordinates.swift','NativeOCRDirectionAdapters.swift'])
gap_source=(ocr/'NativeOCRRFGapRecovery.swift').read_text()
group_source='    struct Group:'+gap_source.split('    struct Group:',1)[1].split('\n    }',1)[0]+'\n    }\n'
production+=gap_source.split('    struct Group:')[0]+group_source+'\n}\n'
production+=(ocr/'NativeOCRContextualColumnRecovery.swift').read_text()
checks=r'''
setenv("AIDOKU_OCR_ORIENTED_PATHS","pixelLocal",1)
let side=320
func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->[CGPoint] {
    NativeOCRDirectionGeometry.corners(CGRect(x:x,y:y,width:w,height:h))
}
var assertions=0
func check(_ value:Bool,_ label:String) { if !value { fputs("FAILED: \(label)\n",stderr); exit(1) }; assertions += 1 }

check(NativeOCRContextualColumnRecovery.isSymbolicPointTrain("……"),"ellipsis-only retained sources are eligible without inventing word letters")
check(!NativeOCRContextualColumnRecovery.isSymbolicPointTrain("あい……"),"word recovery retains its existing stricter admission")
check(!NativeOCRContextualColumnRecovery.isSymbolicPointTrain("！"),"an isolated symbol is not a source point train")
check(NativeOCRContextualColumnRecovery.isSymbolicPointTrain("・・！"),"multiple middle-dot observations remain a physical point train")
check(!NativeOCRContextualColumnRecovery.isSymbolicPointTrain("・！"),"one middle dot cannot manufacture a point train")
check(NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"…!』",baseline:"･……！",head:false,tail:true),
    "source-proven terminal reads can retokenize the same leading point as a middle dot")
check(!NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"…』",baseline:"･……！",head:false,tail:true),
    "middle-dot normalization cannot discard an observed exclamation")

check(NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"…!",baseline:"……",head:false,tail:true),"two source-proven reads can restore a terminal exclamation without counting dots")
check(!NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"!…",baseline:"……",head:false,tail:true),"a tail proof cannot add a head mark")
check(!NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"…",baseline:"……!",head:false,tail:true),"symbol recovery cannot drop an observed exclamation")
check(!NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"…あ!",baseline:"……",head:false,tail:true),"point train recovery cannot introduce word letters")
check(!NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:"…!",baseline:"……",head:false,tail:false),"new punctuation requires a measured terminal")
let symbolProof=NativeCoreMLRecognizedRegion(sourceIndex:9,polygon:rect(1,1,8,30),text:"…!",confidence:0.7)
check(NativeOCRContextualColumnRecovery.retainsConfirmedSymbolicTerminal(candidate:symbolProof,
    baseline:"……",confirmed:symbolProof,head:false,tail:true),"the exact two-read terminal certificate survives later original-crop control")
let movedSymbol=NativeCoreMLRecognizedRegion(sourceIndex:9,polygon:rect(2,1,8,30),text:"…!",confidence:0.9)
check(!NativeOCRContextualColumnRecovery.retainsConfirmedSymbolicTerminal(candidate:movedSymbol,
    baseline:"……",confirmed:symbolProof,head:false,tail:true),"an unrelated later crop cannot borrow a source terminal certificate")
let changedSymbol=NativeCoreMLRecognizedRegion(sourceIndex:9,polygon:symbolProof.polygon,text:"…?",confidence:0.9)
check(!NativeOCRContextualColumnRecovery.retainsConfirmedSymbolicTerminal(candidate:changedSymbol,
    baseline:"……",confirmed:symbolProof,head:false,tail:true),"a different mark cannot borrow a paired terminal certificate")


check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"「ぐすっ….ぐすっ",confidence:0.89,baseline:"「ぐすっ..ぐす",threshold:0.4,retainsOriginalSpan:true,confirmedTerminalCompletion:true,newlyAcquiredPeerTexts:["っ...うっ』"]),"a valid font repetition cannot borrow the following word's recognized glyph")
check(NativeOCRContextualColumnRecovery.hasTerminalExclamation("あい！』"),"an observed terminal exclamation survives Unicode closing punctuation")
check(!NativeOCRContextualColumnRecovery.hasTerminalExclamation("あい…」"),"ordinary dots cannot enable a stem-dot completion")
check(!NativeOCRContextualColumnRecovery.hasTerminalExclamation("!あい"),"an internal exclamation cannot authorize an unrelated terminal dot")
check(NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:"やぁっ♡",word:"やあ",fragment:"♡",budget:1),
    "paired fragment recovery preserves the old word and symbol while a measured clipped band supplies one glyph")
check(!NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:"やうっ♡",word:"やあ",fragment:"♡",budget:1),
    "fragment recovery cannot replace an existing word character")
check(!NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:"やぁっ",word:"やあ",fragment:"♡",budget:1),
    "fragment recovery cannot drop the separately retained symbol")
check(!NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:"やぁっと♡",word:"やあ",fragment:"♡",budget:1),
    "a one-glyph source band cannot authorize an unbounded invented suffix")
check(!NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:"♡やぁっ",word:"やあ",fragment:"♡",budget:1),
    "separate retained reads keep their observed order")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あぇ…",confidence:0.9,baseline:"あえ…",
    threshold:0.4,retainsOriginalSpan:true),"unproven crop changes do not silently fold a kana spelling")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あぇ…",confidence:0.9,baseline:"あえ…",
    threshold:0.4,retainsOriginalSpan:true,confirmedMeasuredTrim:true),
    "a source-certified paired trim carries its measured spelling equivalence through final core admission")
var variableWidthGlyphs:[CGRect]=[]
for k in 0..<6 {
    let y=CGFloat(70+k*27),width=CGFloat(16+k*3)
    variableWidthGlyphs.append(CGRect(x:88,y:y,width:width,height:20))
}
check(NativeOCRContextualColumnRecovery.measuredGlyphSlope(variableWidthGlyphs,span:190,glyph:56,grid:1)==nil,
    "aligned text with changing glyph widths cannot become a slanted baseline merely because its centres move")
check(NativeOCRContextualColumnRecovery.preservesNormalWord(candidate:"あい…」",baseline:"あい…",head:false,tail:true),
    "an independently measured tail corner permits only its newly observed terminal punctuation")
check(!NativeOCRContextualColumnRecovery.preservesNormalWord(candidate:"あい…」",baseline:"あい…",head:true,tail:false),
    "head proof cannot certify a new closing mark at the other end")
check(!NativeOCRContextualColumnRecovery.preservesNormalWord(candidate:"あう…」",baseline:"あい…",head:false,tail:true),
    "source terminal proof never permits replacing an existing word character")
check(!NativeOCRContextualColumnRecovery.preservesNormalWord(candidate:"あい…",baseline:"「あい…",head:true,tail:true),
    "a new terminal cannot erase an already observed opening quote")
check(NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あいう―…",baseline:"あいうー"),
    "a measured terminal horizontal bar preserves an existing prolonged stroke before recovered points")
check(NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あいう—…",baseline:"あいうー"),
    "an em dash spelling preserves the same terminal stroke count")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あいう…",baseline:"あいうー"),
    "terminal typography equivalence never permits deleting an actual old stroke")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あいう―…",baseline:"あいうーー"),
    "two original strokes cannot become one horizontal bar")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あ―いう…",baseline:"あーいう"),
    "internal word strokes stay literal outside terminal punctuation context")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あいう一…",baseline:"あいうー"),
    "a semantic letter is not a terminal stroke spelling")
check(NativeOCRRFPrimaryEnsemble.measuredTrimContent("あいう―…") == NativeOCRRFPrimaryEnsemble.measuredTrimContent("あいうー"),
    "context core checks preserve the observed terminal glyph across its Unicode spellings")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう―…♡",confidence:0.9,baseline:"あいうー♡",
    threshold:0.4,retainsOriginalSpan:true,confirmedTerminalCompletion:true),
    "actual terminal completion retains a long stroke and the old heart without synthesizing either")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう―…",confidence:0.9,baseline:"あいうー♡",
    threshold:0.4,retainsOriginalSpan:true,confirmedTerminalCompletion:true),
    "terminal bar equivalence cannot hide loss of the original heart")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"AB―…",baseline:"ＡＢー"),
    "terminal stroke spelling equivalence leaves full-width letters literal rather than folding unrelated word characters")
unsetenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT")
unsetenv("AIDOKU_OCR_RF_ENDPOINT_COMPLETION")
unsetenv("AIDOKU_OCR_ORIENTED_PATHS")
check(NativeOCRDirectionGeometry.paths.allSatisfy { !NativeOCRDirectionGeometry.enabled($0) },
    "other model tiers have no implicit direction-path changes")
NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(true) {
    check(NativeOCRDirectionGeometry.paths.allSatisfy(NativeOCRDirectionGeometry.enabled),
        "full-frame manga enables every verified direction kernel without A/B flags")
    NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(false) {
        check(!NativeOCRDirectionGeometry.enabled("pixelLocal"),"scoped direction policy overrides an inherited full-frame request")
    }
    setenv("AIDOKU_OCR_ORIENTED_PATHS","quoted",1)
    check(NativeOCRDirectionGeometry.enabled("quoted") && !NativeOCRDirectionGeometry.enabled("pixelLocal"),
        "explicit diagnostic selections still override manga defaults")
    unsetenv("AIDOKU_OCR_ORIENTED_PATHS")
}
check(!NativeOCRDirectionGeometry.enabled("pixelLocal"),"direction policy does not leak into the next request")
setenv("AIDOKU_OCR_ORIENTED_PATHS","pixelLocal",1)
check(!NativeOCRRFPrimaryEnsemble.refinesEndpointInk && NativeOCRRFPrimaryEnsemble.endpointCompletionMode == nil,
    "non-manga and scoped callers have no implicit endpoint policy")
NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
    check(NativeOCRRFPrimaryEnsemble.refinesEndpointInk && NativeOCRRFPrimaryEnsemble.endpointCompletionMode == "db+pixel",
        "full-frame manga applies the verified policy without host environment flags")
    NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(false) {
        check(!NativeOCRRFPrimaryEnsemble.refinesEndpointInk && NativeOCRRFPrimaryEnsemble.endpointCompletionMode == nil,
            "a nested scoped read cannot inherit full-frame manga defaults")
    }
    check(NativeOCRRFPrimaryEnsemble.refinesEndpointInk,"leaving a nested scope restores the manga policy")
    setenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT","0",1)
    check(!NativeOCRRFPrimaryEnsemble.refinesEndpointInk,"an explicit control run can still compare the previous crop path")
    unsetenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT")
}
check(!NativeOCRRFPrimaryEnsemble.refinesEndpointInk,"request completion cannot leak a manga policy into another read")
setenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT","1",1)
check(NativeOCRRFPrimaryEnsemble.measuredTrimSignature("「あいう…♡」") ==
    NativeOCRRFPrimaryEnsemble.measuredTrimSignature("「あいう.....♡」"),
    "measured trim confirmation tolerates dot-run retokenization without changing word or marks")
check(NativeOCRRFPrimaryEnsemble.measuredTrimSignature("「あいう」") !=
    NativeOCRRFPrimaryEnsemble.measuredTrimSignature("あいう」"),
    "two trim samples disagree when one loses the opening bracket")
check(NativeOCRRFPrimaryEnsemble.measuredTrimSignature("あいう」") !=
    NativeOCRRFPrimaryEnsemble.measuredTrimSignature("あいう"),
    "a trimmed word cannot silently lose its previous closing bracket")
check(NativeOCRRFPrimaryEnsemble.measuredTrimSignature("あいう!") !=
    NativeOCRRFPrimaryEnsemble.measuredTrimSignature("あいう"),
    "a trimmed word cannot silently lose an actual exclamation")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"はひゅー…♡」",confidence:0.9,
    baseline:"はひゆ",threshold:0.4,retainsOriginalSpan:true,confirmedTerminalCompletion:true),
    "two source-proven agreeing terminal reads may finish a prolonged stroke with the same kana word")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ひゅ♡はひゅー",confidence:0.9,
    baseline:"ひゅー♡はひゆ",threshold:0.4,retainsOriginalSpan:true,confirmedTerminalCompletion:true),
    "terminal completion cannot lose an existing internal prolonged stroke in a grouped word")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"はひゅー",confidence:0.9,
    baseline:"はひゆ♡",threshold:0.4,retainsOriginalSpan:true,confirmedTerminalCompletion:true),
    "canonical terminal confirmation cannot delete an existing heart")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"はひゅ",baseline:"はひゅー"),
    "finishing a terminal never permits dropping its original prolonged stroke")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいうえお",confidence:0.8,baseline:"あえお",threshold:0.4),
    "new source characters may be recovered between retained tokens")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"わかんな",confidence:0.9,
    baseline:"わかんない",threshold:0.4,confirmedMeasuredTrim:true),
    "two agreeing trimmed crops cannot certify losing an already recovered terminal letter")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう",confidence:0.9,
    baseline:"「あいう",threshold:0.4),
    "an unmeasured trim cannot delete a recorded quote")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あえ",confidence:0.99,baseline:"あえお",threshold:0.4),
    "higher confidence cannot authorize dropping a retained source character")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あえお",confidence:0.39,baseline:"あえお",threshold:0.4),
    "paired endpoint verification does not lower the user's recognition threshold")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あえお",confidence:0.9,baseline:"あえおお",threshold:0.4),
    "repeated source characters cannot be accounted for by one token")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ッ~",confidence:0.6,baseline:"~",threshold:0.4,
    overlappingPeerTexts:["フゥ〜ッ"]),
    "a resized symbol read cannot reacquire all its new letters from an overlapping accepted word")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ッ~",confidence:0.6,baseline:"~",threshold:0.4),
    "new content without an overlapping peer remains eligible")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ん~",confidence:0.6,baseline:"~",threshold:0.4,
    overlappingPeerTexts:["フゥ〜ッ"]),"novel independent letters are not suppressed")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ッッ~",confidence:0.6,baseline:"~",threshold:0.4,
    overlappingPeerTexts:["ッ"]),"one peer letter cannot account for two new letters")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ふッ~",confidence:0.8,baseline:"ふ~",threshold:0.4,
    overlappingPeerTexts:["ッ"]),"an established word core retains its normal recovery path")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"う~",confidence:0.8,baseline:"~",threshold:0.4,
    overlappingPeerTexts:["ぅ"]),"small kana is not rewritten to manufacture borrowed-content evidence")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"シッ~",confidence:0.71,baseline:"~",threshold:0.4,
    overlappingPeerTexts:["フゥ〜ッ"],newlyAcquiredPeerTexts:["フゥ〜ッ"]),
    "a newly enlarged peer intersection cannot certify a partly borrowed new word for a symbol source")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ん~",confidence:0.71,baseline:"~",threshold:0.4,
    overlappingPeerTexts:["フゥ〜ッ"],newlyAcquiredPeerTexts:["フゥ〜ッ"]),
    "independent novel letters remain eligible even with new geometric overlap")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ぐちゅっゅっ",confidence:0.9,baseline:"ぐちゅっ",threshold:0.4,
    newlyAcquiredPeerTexts:["ゅっ"]),"an expanded established word cannot append an independent peer's literal content")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"もみ♡",confidence:0.99,baseline:"もみ♡",threshold:0.4,
    unprovenLongGrowth:true),"an unchanged read cannot certify a long expansion into background")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"もみ♡",confidence:0.99,baseline:"もみ♡",threshold:0.4),
    "a source terminal or small glyph finishing keeps the ordinary paired-read path")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう",confidence:0.99,baseline:"あい",threshold:0.4,
    unprovenLongGrowth:true),"independent new recognized letters can justify a longer crop")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"ぐちゅっゅっ",confidence:0.9,baseline:"ぐちゅっ",threshold:0.4,
    unprovenLongGrowth:true,newlyAcquiredPeerTexts:["ぐちゃっ"]),
    "a partly misread independent word cannot justify a long unsupported expansion")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう",confidence:0.9,baseline:"あい",threshold:0.4,
    unprovenLongGrowth:true,newlyAcquiredPeerTexts:["かき"]),
    "independent genuinely novel letters retain the ordinary long-growth recovery path")
// A common overlay transforms ink and paper together. Its contrast vector,
// not absolute RGB relative to the new paper, identifies the same source style.
let overlayRuns = (10..<40).map { NativeOCRDetectorSeedEvidence.Run(y:$0,x:5,count:10) }
let overlayEvidence = NativeOCRDetectorSeedEvidence(ownerID:"overlay-source",parentBoxIndex:0,
    provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
    mapFullWidth:160,mapFullHeight:160,sourceWidth:160,sourceHeight:160,
    components:[.init(seed:1605,pixelCount:300,meanProbability:1,runs:overlayRuns)],
    ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
let exclusiveEvidence=NativeOCRDetectorSeedEvidence(ownerID:"exclusive-source",parentBoxIndex:0,
    provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
    mapFullWidth:160,mapFullHeight:160,sourceWidth:160,sourceHeight:160,
    components:[.init(seed:1921,pixelCount:1,meanProbability:1,runs:[.init(y:12,x:1,count:1)])],
    ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],
    candidateComponents:[.init(component:.init(seed:1605,pixelCount:300,meanProbability:1,
        runs:(10..<40).map { .init(y:$0,x:5,count:10) }),competingOwnerIDs:["peer"],outsideCompetingCells:[280])])
func exclusivePalette(_ peers:[String:[[CGPoint]]])->Bool {
    NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:exclusiveEvidence,columns:20,rows:100,start:0,length:60,
        project:{$0},rgb:{ row,column in
            (10..<40).contains(row) && (5..<15).contains(column) ? [12,90,160] : [255,255,255]
        },candidatePeerPolygons:peers) != nil
}
check(!exclusivePalette([:]),"unlocated competing owners cannot become private font samples")
check(!exclusivePalette(["peer":[rect(0,0,20,60)]]),"a candidate inside another read cannot teach source ink")
check(exclusivePalette(["peer":[rect(0,38,20,30)]]),
    "exclusive candidate cells inside the original crop can teach ink despite sparse private components")
let overlayPalette = NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:overlayEvidence,
    columns:20,rows:140,start:0,length:60,project:{$0},rgb:{ row,column in
        let ink = (10..<40).contains(row) || (80..<90).contains(row)
        let stroke = ink && (5..<15).contains(column)
        if row >= 60 { return stroke ? [90,40,170] : [200,120,180] }
        return stroke ? [20,80,220] : [240,240,240]
    })
check(overlayPalette != nil,"source palette remains available across a tinted-paper overlay")
if let overlayPalette {
    check(overlayPalette.growthMask[85*20+10] != 0,
        "same source ink under a common coloured veil must retain growth evidence")
    check(overlayPalette.mask[85*20+10] != 0,
        "disconnected chromatic source strokes under a veil must survive trimming")
    check(overlayPalette.mask[85*20+1] == 0,"tinted paper is not source ink")
}
// A coloured lettering tile is paper even when the external gutters are
// another colour. Private DB components describe text regions, not ink masks.
let panelEvidence = NativeOCRDetectorSeedEvidence(ownerID:"panel-source",parentBoxIndex:0,
    provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
    mapFullWidth:160,mapFullHeight:160,sourceWidth:160,sourceHeight:160,
    components:[.init(seed:1600,pixelCount:1000,meanProbability:1,
        runs:(10..<60).map { .init(y:$0,x:0,count:20) })],
    ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"こんなの…...全然",confidence:0.8,baseline:"こんなの....全然",threshold:0.4),
    "compatibility ellipsis encoding cannot veto a crop with the same recognized words and punctuation")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"優しく.お願いします..",confidence:0.9,baseline:"優しく..お願いします...",threshold:0.4),
    "a shortened read cannot silently discard recorded punctuation")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"優しく.お願いします..",confidence:0.9,baseline:"優しく..お願いします...",threshold:0.4,retainsOriginalSpan:true),
    "punctuation count variation cannot veto a full-span expansion with identical words")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"やめっー",confidence:0.9,baseline:"やめっ!",threshold:0.4,retainsOriginalSpan:true),
    "a fully observed recovered terminal may retokenize an earlier cropped punctuation read")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あえ",confidence:0.99,baseline:"あえお",threshold:0.4,retainsOriginalSpan:true),
    "full-span punctuation handling still rejects an actual missing word character")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あ",confidence:0.99,baseline:"あ♡",threshold:0.4,retainsOriginalSpan:true),
    "a meaningful heart remains a required source symbol")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"!",confidence:0.99,baseline:"……",threshold:0.4,retainsOriginalSpan:true),
    "punctuation-only reads do not gain a content-free acceptance shortcut")
let panelPalette=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:panelEvidence,
    columns:20,rows:120,start:0,length:70,project:{$0},rgb:{ row,column in
        guard column >= 0, column < 20 else { return [0,0,0] }
        let glyph=(10..<20).contains(row) || (30..<40).contains(row) || (45..<55).contains(row)
        if glyph && (5..<15).contains(column) { return [255,255,255] }
        return row < 35 ? [255,60,160] : [38,215,255]
    })
check(panelPalette != nil,"white lettering remains identifiable over coloured source panels")
if let panelPalette {
    check(panelPalette.mask[85*20+10] == 0,
        "coloured source paper must not become a new text stroke outside the established crop")
    check(panelPalette.mask[15*20+10] != 0,"the actual white source glyph is retained")
}
let orangeFill=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[221,90,5],[255,255,255]])
let whiteOutline=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[254,254,253],[225,94,8]])
check(!NativeOCRRFPrimaryEnsemble.distinctEndpointInk(orangeFill,whiteOutline),
    "fill and outline dominance cannot erase the boundary between adjacent independent words")
check(NativeOCRRFPrimaryEnsemble.distinctEndpointInk(.init([12,92,166]),.init([254,254,253])),
    "independent blue and white text layers remain distinct without a shared learned ink")
let outlineShade=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:panelEvidence,
    columns:20,rows:150,start:0,length:70,project:{$0},rgb:{ row,column in
        let paper=[160,110,70]
        guard column >= 0,column < 20 else { return paper }
        let glyph=(10..<20).contains(row) || (30..<40).contains(row) || (45..<55).contains(row)
        if glyph && (7..<13).contains(column) { return [220,90,5] }
        if glyph && (5..<15).contains(column) { return [255,254,250] }
        if (100..<120).contains(row) && (6..<14).contains(column) { return [208,182,160] }
        return paper
    })
check(outlineShade != nil,"the source fill and its white outline teach a valid palette")
if let outlineShade {
    check(outlineShade.mask[105*20+10] == 0,
        "a detached faded outline-colour surface cannot certify a new source glyph")
    check(outlineShade.mask[15*20+8] != 0,"the source's actual fill remains visible")
}
let widthColumns=24,widthRows=120
var widthMask=[UInt8](repeating:0,count:widthColumns*widthRows)
var widthSeeds=[Bool](repeating:false,count:widthMask.count)
for y in 10..<46 { for x in 10..<13 { widthMask[y*widthColumns+x]=1;widthSeeds[y*widthColumns+x]=true } }
for x in 6..<18 { widthMask[80*widthColumns+x]=1 }
for y in 75..<110 { widthMask[y*widthColumns+20]=1 }
let widthProof=NativeOCRRFPrimaryEnsemble.certifyingSecondaryInk(mask:widthMask,primary:widthMask,seeds:widthSeeds,
    columns:widthColumns,rows:widthRows,start:0,length:60,rgb:{ y,x in
        guard y>=0,y<widthRows,x>=0,x<widthColumns else { return [255,255,255] }
        return widthMask[y*widthColumns+x] != 0 ? [210,80,40] : [255,255,255]
    })
check(widthProof[80*widthColumns+12]==0,
    "one-pixel detached texture is thinner than a measured three-pixel source stroke")
check(widthProof[90*widthColumns+20] != 0,
    "measured thin terminal strokes retain their existing shape exception")
check(widthProof[20*widthColumns+11] != 0,
    "source-private strokes stay intact during detached-width verification")
// Source fill texture is measured around each component's own colour: a
// coloured veil is allowed, unrelated textured shading is not another glyph.
let textureColumns=24,textureRows=150
var textureMask=[UInt8](repeating:0,count:textureColumns*textureRows)
var textureSeeds=[Bool](repeating:false,count:textureMask.count)
for y in 0..<textureRows { for x in 0..<textureColumns {
    if ((10..<26).contains(y) || (45..<61).contains(y) || (80..<96).contains(y)) && (8..<16).contains(x) {
        textureMask[y*textureColumns+x]=1
        if y < 26 { textureSeeds[y*textureColumns+x]=true }
    }
    if (105..<145).contains(y) && (3..<6).contains(x) { textureMask[y*textureColumns+x]=1 }
} }
func textureRGB(_ y:Int,_ x:Int)->[Int]? {
    if y < 26 { return [40,60,140] }
    if y < 61 { return [90,40,170] }
    return [90+(x*19+y*7)%90,30+(x*7+y*13)%70,50+(x*11+y*5)%80]
}
let textureProof=NativeOCRRFPrimaryEnsemble.certifyingSourceInkTexture(mask:textureMask,family:textureMask,seeds:textureSeeds,
    columns:textureColumns,rows:textureRows,start:0,length:100,rgb:textureRGB)
check(textureProof[18*24+12] != 0,"private source fill survives texture filtering")
check(textureProof[52*24+12] != 0,"a uniformly recoloured glyph under a veil retains its own coherent fill")
check(textureProof[88*24+12] == 0,"unowned textured art inside original padding is not another source glyph")
check(textureProof[120*24+4] != 0,"a measured long thin terminal can cross a textured surface")
let noTextureAnchor=NativeOCRRFPrimaryEnsemble.certifyingSourceInkTexture(mask:textureMask,family:textureMask,
    seeds:[Bool](repeating:false,count:textureMask.count),columns:textureColumns,rows:textureRows,start:0,length:100,rgb:textureRGB)
check(noTextureAnchor == textureMask,"texture rejection needs actual private source samples")
let texturedFont=NativeOCRRFPrimaryEnsemble.certifyingSourceInkTexture(mask:textureMask,family:textureMask,seeds:textureSeeds,
    columns:textureColumns,rows:textureRows,start:0,length:100,rgb:{ y,x in
        [90+(x*19+y*7)%90,30+(x*7+y*13)%70,50+(x*11+y*5)%80]
    })
check(texturedFont[88*24+12] != 0,"a textured original font supplies its own permissive noise reference")
// A detector may own only the outline; infer a repeated interior from
// source-colour brackets, without adding fake private detector components.
let companionColumns=24,companionRows=100
var companionSeeds=[Bool](repeating:false,count:companionColumns*companionRows)
for y in 0..<companionRows where (10..<20).contains(y) || (30..<40).contains(y) || (50..<60).contains(y) {
    companionSeeds[y*24+6]=true;companionSeeds[y*24+18]=true
}
var companionPaper=[Int](repeating:0,count:512);companionPaper[3*64+4*8+4]=1000
func companionRGB(_ y:Int,_ x:Int)->[Int]? {
    let glyph=(10..<20).contains(y) || (30..<40).contains(y) || (50..<60).contains(y)
    if glyph && (8..<16).contains(x) { return [1,2,0] }
    if glyph && (5..<19).contains(x) { return [255,255,253] }
    return [120,130,140]
}
let companion=NativeOCRRFPrimaryEnsemble.sourceCompanionInk(primary:[255,255,253],tolerance:48,
    seeds:companionSeeds,sourceMask:nil,columns:24,rows:100,start:0,length:70,paper:companionPaper,paperCount:1000,rgb:companionRGB)
check(companion?.ink == [1,2,0],"repeated bracketed interiors recover the actual fill absent from private outline samples")
var commonPaper=[Int](repeating:0,count:512);commonPaper[0]=1000
let noCompanionPaper=NativeOCRRFPrimaryEnsemble.sourceCompanionInk(primary:[255,255,253],tolerance:48,
    seeds:companionSeeds,sourceMask:nil,columns:24,rows:100,start:0,length:70,paper:commonPaper,paperCount:1000,rgb:companionRGB)
check(noCompanionPaper == nil,"ordinary external paper cannot masquerade as a new font layer")
let noCompanionProof=NativeOCRRFPrimaryEnsemble.sourceCompanionInk(primary:[255,255,253],tolerance:48,
    seeds:[Bool](repeating:false,count:2400),sourceMask:nil,columns:24,rows:100,start:0,length:70,
    paper:companionPaper,paperCount:1000,rgb:companionRGB)
check(noCompanionProof == nil,"bracket discovery needs actual private source anchors")
let bracketRuns=(10..<24).flatMap { y in [NativeOCRDetectorSeedEvidence.Run(y:y,x:6,count:1),.init(y:y,x:17,count:1)] } +
    (35..<49).flatMap { y in [NativeOCRDetectorSeedEvidence.Run(y:y,x:6,count:1),.init(y:y,x:17,count:1)] } +
    (58..<72).flatMap { y in [NativeOCRDetectorSeedEvidence.Run(y:y,x:6,count:1),.init(y:y,x:17,count:1)] }
let bracketEvidence=NativeOCRDetectorSeedEvidence(ownerID:"bracket-source",parentBoxIndex:0,
    provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:160,mapFullHeight:160,
    sourceWidth:160,sourceHeight:160,components:[.init(seed:1606,pixelCount:bracketRuns.count,meanProbability:1,runs:bracketRuns)],
    ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
let bracketPalette=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:bracketEvidence,columns:24,rows:130,start:0,length:80,
    project:{$0},rgb:{ y,x in
        let glyph=(10..<24).contains(y) || (35..<49).contains(y) || (58..<72).contains(y) || (95..<110).contains(y)
        if glyph && (8..<16).contains(x) { return [1,2,0] }
        if glyph && (5..<19).contains(x) || (82..<92).contains(y) && x==12 { return [255,255,253] }
        return [120,130,140]
    })
check(bracketPalette != nil,"private outline pixels establish the palette before companion discovery")
if let bracketPalette {
    check(bracketPalette.mask[15*24+6] != 0,"actual source outline remains present")
    check(bracketPalette.mask[85*24+12] == 0,"an isolated outline-colour stripe lacks the source's actual interior")
    check(bracketPalette.mask[100*24+6] != 0,"new genuine lettering keeps its observed companion relation")
    check(bracketPalette.mask[15*24+12] == 0,"auxiliary colour proof does not invent another admitted foreground layer")
}
let veilRuns=(0..<80).flatMap { y -> [NativeOCRDetectorSeedEvidence.Run] in
    if (10..<24).contains(y) || (35..<49).contains(y) || (58..<72).contains(y) {
        return [.init(y:y,x:5,count:14)]
    }
    return []
}
let veilEvidence=NativeOCRDetectorSeedEvidence(ownerID:"veil-paired-source",parentBoxIndex:0,
    provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:160,mapFullHeight:160,
    sourceWidth:160,sourceHeight:160,components:[.init(seed:1605,pixelCount:veilRuns.count*14,meanProbability:1,runs:veilRuns)],
    ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
let veilPair=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:veilEvidence,columns:24,rows:130,start:0,length:80,
    project:{$0},rgb:{ (y:Int,x:Int)->[Int]? in
        let covered=y >= 90
        let glyph=(10..<24).contains(y) || (35..<49).contains(y) || (58..<72).contains(y) || (95..<110).contains(y)
        if glyph && (8..<16).contains(x) { return covered ? [50,45,140]:[10,90,170] }
        if glyph && (5..<19).contains(x) { return covered ? [172,127,182]:[255,255,255] }
        return covered ? [120,80,140]:[150,160,170]
    })
check(veilPair != nil,"private fill and outline establish a measured paired source style")
if let veilPair {
    check(veilPair.mask[100*24+10] != 0,"the existing outline's veil transform certifies the faded source fill")
}
let paperCompanionSeeds:[Bool]=(0..<(24*80)).map { p in
    let y=p/24,x=p%24
    return y >= 10 && y < 70 && (x==6 || x==17)
}
let paperCompanion=NativeOCRRFPrimaryEnsemble.sourceCompanionInk(primary:[0,0,0],tolerance:16,
    seeds:paperCompanionSeeds,sourceMask:nil,columns:24,rows:80,start:0,length:80,
    paper:[Int](repeating:1,count:512),paperCount:512,rgb:{ (y:Int,x:Int)->[Int]? in
        if (10..<70).contains(y) && (x==6 || x==17) { return [0,0,0] }
        return [250,250,250]
    })
check(paperCompanion == nil,"white paper inside black letter counters cannot certify a paired font")
let antialiasCompanion=NativeOCRRFPrimaryEnsemble.sourceCompanionInk(primary:[254,254,254],tolerance:16,
    seeds:paperCompanionSeeds,sourceMask:nil,columns:24,rows:80,start:0,length:80,
    paper:[Int](repeating:1,count:512),paperCount:512,sourceContrast:[254,254,254],rgb:{ (y:Int,x:Int)->[Int]? in
        if (10..<70).contains(y) && (7..<17).contains(x) { return [109,110,109] }
        return [254,254,254]
    })
check(antialiasCompanion == nil,"known source contrast rejects gray antialiasing even when glyphs cover border probes")
let pairColumns=24,pairRows=145
var pairMask=[UInt8](repeating:0,count:pairColumns*pairRows),pairPrimary=pairMask,pairSecondary=pairMask
var pairSeeds=[Bool](repeating:false,count:pairMask.count)
for y in 0..<pairRows { for x in 0..<pairColumns {
    let own=(10..<60).contains(y) && (9..<15).contains(x)
    let recovered=(80..<96).contains(y) && (9..<15).contains(x)
    let drawing=(115..<132).contains(y) && (11..<14).contains(x)
    let outline=((8..<62).contains(y) || (78..<98).contains(y)) && (7..<17).contains(x) && !(own || recovered)
    let p=y*pairColumns+x
    if own || recovered || drawing { pairPrimary[p]=1;pairMask[p]=1 }
    if outline { pairSecondary[p]=1;pairMask[p]=1 }
    if own { pairSeeds[p]=true }
} }
let pairProof=NativeOCRRFPrimaryEnsemble.certifyingSourceInkPair(mask:pairMask,primary:pairPrimary,
    family:pairPrimary,secondary:pairSecondary,seeds:pairSeeds,columns:pairColumns,rows:pairRows,start:0,length:70)
check(pairProof[30*24+12] != 0,"paired-ink filtering preserves every established source glyph")
check(pairProof[85*24+12] != 0,"a recovered glyph retains the source's measured fill and outline")
check(pairProof[120*24+12] == 0,"a detached drawing line cannot copy only the fill of an outlined font")
var joinedOutlineMask=pairMask,joinedOutlinePrimary=pairPrimary
for y in 60..<75 { joinedOutlineMask[y*24+12]=1;joinedOutlinePrimary[y*24+12]=1 }
// Continue far below the source with no matching outline. This is still
// inside a deliberately loose original crop, not an immutable glyph proof.
for y in 100..<145 { joinedOutlineMask[y*24+12]=1;joinedOutlinePrimary[y*24+12]=1 }
let joinedOutlineProof=NativeOCRRFPrimaryEnsemble.certifyingSourceInkPair(mask:joinedOutlineMask,primary:joinedOutlinePrimary,
    family:joinedOutlinePrimary,secondary:pairSecondary,seeds:pairSeeds,columns:24,rows:pairRows,start:0,length:140,refineEnds:true)
check(joinedOutlineProof[130*24+12] == 0,"a same-colour end without its measured companion is not protected by crop padding")
check(joinedOutlineProof[30*24+12] != 0,"paired end rejection keeps the original glyph core")
check(joinedOutlineProof[85*24+12] != 0,"a genuine recovered paired glyph remains eligible beyond the core")
var terminalPairMask=pairMask,terminalPairPrimary=pairPrimary,terminalPairSecondary=pairSecondary
for p in (62*24)..<terminalPairMask.count {
    terminalPairMask[p]=0;terminalPairPrimary[p]=0;terminalPairSecondary[p]=0
}
for y in 60..<115 { terminalPairMask[y*24+12]=1;terminalPairPrimary[y*24+12]=1 }
let terminalPairProof=NativeOCRRFPrimaryEnsemble.certifyingSourceInkPair(mask:terminalPairMask,primary:terminalPairPrimary,
    family:terminalPairPrimary,secondary:terminalPairSecondary,seeds:pairSeeds,columns:24,rows:pairRows,start:0,length:70,refineEnds:true)
check(terminalPairProof[110*24+12] != 0,"a long single-colour terminal attached to a paired font survives end pruning")
var junctionPairMask=terminalPairMask,junctionPairPrimary=terminalPairPrimary
for y in 60..<68 { for x in 7..<17 { junctionPairMask[y*24+x]=1;junctionPairPrimary[y*24+x]=1 } }
let junctionPairProof=NativeOCRRFPrimaryEnsemble.certifyingSourceInkPair(mask:junctionPairMask,primary:junctionPairPrimary,
    family:junctionPairPrimary,secondary:terminalPairSecondary,seeds:pairSeeds,columns:24,rows:pairRows,start:0,length:70,refineEnds:true)
check(junctionPairProof[110*24+12] != 0,"a short broad glyph junction cannot hide its source-connected narrow terminal")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"これはなぁ....",confidence:0.81,
    baseline:"これはなぁ.....",threshold:0.4,retainsDetectorSpan:true),"detector-complete trims permit dot count retokenization")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう…",confidence:0.9,
    baseline:"あいぅ....",threshold:0.4,retainsDetectorSpan:true),"detector-complete crop tolerates small-kana typography with dot retokenization")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"でも",confidence:0.99,
    baseline:"ーでも",threshold:0.4,retainsDetectorSpan:true),"detector coverage cannot excuse a missing long-vowel stroke")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あ",confidence:0.99,
    baseline:"あ♡",threshold:0.4,retainsDetectorSpan:true),"detector coverage cannot excuse a missing meaningful symbol")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あ!",confidence:0.99,
    baseline:"あ?",threshold:0.4,retainsDetectorSpan:true),"detector-only proof cannot replace arbitrary punctuation")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう",confidence:0.99,
    baseline:"あいぅ!",threshold:0.4,confirmedMeasuredTrim:true),"source-complete two-read trim permits typography and punctuation retokenization")
check(NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう…",confidence:0.99,
    baseline:"あいぅ....",threshold:0.4,confirmedMeasuredTrim:true),"source-complete two-read trims permit small-kana and dot retokenization")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう",confidence:0.99,
    baseline:"あいう♡",threshold:0.4,confirmedMeasuredTrim:true),"measured trim consensus preserves meaningful symbols")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あい",confidence:0.99,
    baseline:"あいう",threshold:0.4,confirmedMeasuredTrim:true),"measured trim cannot excuse a missing letter")
check(!NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:"あいう",confidence:0.99,
    baseline:"あいぅ!",threshold:0.4),"typography relaxation requires explicit source ink and confirming read proof")
check(NativeOCRRFPrimaryEnsemble.preservesAlignedFragment(candidate:"あいうっ♡",fragment:"っ",confidence:0.9,threshold:0.4),
    "a real single-glyph continuation is retained by its independently recognized combined column")
check(!NativeOCRRFPrimaryEnsemble.preservesAlignedFragment(candidate:"あいうっ♡",fragment:"の",confidence:0.9,threshold:0.4),
    "an unrelated single glyph cannot be suppressed by a nearby word")
check(!NativeOCRRFPrimaryEnsemble.preservesAlignedFragment(candidate:"あいうかな",fragment:"かな",confidence:0.9,threshold:0.4),
    "a multi-glyph fine-print word cannot enter the small-fragment route")
let paleTerminal=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:panelEvidence,
    columns:20,rows:130,start:0,length:70,project:{$0},rgb:{ row,column in
        guard column >= 0,column < 20 else { return [255,255,255] }
        let glyph=(10..<20).contains(row) || (30..<40).contains(row) || (45..<55).contains(row)
        if glyph && (7..<13).contains(column) { return [0,0,0] }
        if glyph && (column==6 || column==13) || (55..<110).contains(row) && column==9 { return [214,214,214] }
        return [255,255,255]
    })
check(paleTerminal != nil,"antialias shades remain a source ink observation")
if let paleTerminal {
    check(paleTerminal.mask[90*20+9] != 0,"a measured pale terminal cannot be merged with white source paper")
    check(paleTerminal.mask[90*20+2] == 0,"direct colour tolerance must remain narrower than the observed paper contrast")
}
let proofColumns=20,proofRows=150
var proofMask=[UInt8](repeating:0,count:proofColumns*proofRows),proofPrimary=proofMask
var proofSeeds=[Bool](repeating:false,count:proofMask.count)
func proofRGB(_ y:Int,_ x:Int)->[Int]? {
    if (10..<50).contains(y) && (7..<13).contains(x) { return [0,0,0] }
    if (65..<80).contains(y) && (8..<11).contains(x) || (100..<140).contains(y) && (0..<20).contains(x) { return [220,0,70] }
    return [240,240,240]
}
for y in 0..<proofRows { for x in 0..<proofColumns {
    let p=y*proofColumns+x,c=proofRGB(y,x)!
    if c != [240,240,240] { proofMask[p]=1 }
    if c == [0,0,0] { proofPrimary[p]=1;proofSeeds[p]=true }
} }
let strokeProof=NativeOCRRFPrimaryEnsemble.certifyingSecondaryInk(mask:proofMask,primary:proofPrimary,seeds:proofSeeds,
    columns:proofColumns,rows:proofRows,start:0,length:60,rgb:proofRGB)
check(strokeProof[70*proofColumns+9] != 0,"a secondary source colour with two-sided stroke contrast survives")
check(strokeProof[120*proofColumns+10] == 0,"matching secondary-colour paper is not a source stroke")
var noisyMask=proofMask,noisyPrimary=proofPrimary
for y in 85..<97 { let x=5+(y-85)/3;noisyMask[y*20+x]=1;noisyPrimary[y*20+x]=1 }
let noisyProof=NativeOCRRFPrimaryEnsemble.certifyingSecondaryInk(mask:noisyMask,primary:noisyPrimary,seeds:proofSeeds,
    columns:proofColumns,rows:proofRows,start:0,length:60,rgb:{ y,x in
        if (85..<97).contains(y) && x==5+(y-85)/3 { return [0,0,0] }
        return proofRGB(y,x)
    })
check(noisyProof[90*20+6] == 0,"a detached primary-colour drawing stroke must match the source font weight")
check(noisyProof[30*20+9] != 0,"established primary source lettering survives weight validation")
// A coloured tile surrounding primary lettering is surface evidence even
// when colour changes/printing texture offer local contrast inside the tile.
var tileMask=[UInt8](repeating:1,count:20*70),tilePrimary=[UInt8](repeating:0,count:20*70)
var tileSeeds=[Bool](repeating:false,count:20*70)
for y in 10..<60 { for x in 8..<12 { tilePrimary[y*20+x]=1;tileSeeds[y*20+x]=true } }
var paperPaletteBits:UInt8=0
let tileVotes=tilePrimary.map { $0 == 0 ? UInt8(2):UInt8(1) }
let tileProof=NativeOCRRFPrimaryEnsemble.certifyingSecondaryInk(mask:tileMask,primary:tilePrimary,seeds:tileSeeds,
    columns:20,rows:70,start:0,length:70,rgb:{ y,x in
        if (10..<60).contains(y) && (8..<12).contains(x) { return [255,255,255] }
        return (y+x)%6 < 3 ? [30,170,230] : [70,210,255]
    },paletteVotes:tileVotes,surfacePaletteObserver:{paperPaletteBits |= $0})
check(tileProof[35*20+9] != 0,"the primary glyph on a coloured tile is retained")
check(tileProof[35*20+3] == 0,"a dense component enclosing the primary glyph is paper despite local colour texture")
check(paperPaletteBits == 2,"paper beneath original private glyphs supplies a reusable secondary-palette proof")
// Private DB regions may contain a paper wrinkle as well as the actual ink.
// That weak neutral patch must not become a global continuation of blue type.
func toneGrowth(neutralInk:Bool,fadedInk:Bool,paperInPrivate:Bool)->(original:Bool,growth:Bool) {
    typealias E = NativeOCRDetectorSeedEvidence
    var runs:[E.Run]=[]
    for y in 0..<90 { for x in 0..<20 {
        if (4..<12).contains(x) && [10..<20,30..<40,50..<60,70..<80].contains(where:{$0.contains(y)}) {
            runs.append(.init(y:y,x:x,count:1))
        }
    } }
    let evidence=E(ownerID:"printed-font-with-paper",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.count,meanProbability:0.99,runs:runs)],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let fit=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:evidence,columns:20,rows:160,start:0,length:90,
        project:{ .init(x:$0.x-0.5,y:$0.y-0.5) },rgb:{ y,x in
            let glyph=(4..<12).contains(x) && [10..<20,30..<40,50..<60,70..<80].contains(where:{$0.contains(y)})
            let line=(9..<12).contains(x) && (paperInPrivate ? 50:95)<=y && y<150
            if line {
                if y>=90,fadedInk { return [196,212,231] }
                return paperInPrivate ? [214,217,212]:[224,224,224]
            }
            if glyph { return neutralInk ? [20,20,20]:[20,90,170] }
            return [250,250,250]
        })!
    return (fit.mask[55*20+5] != 0,fit.growthMask[120*20+10] != 0)
}
let neutralPaper=toneGrowth(neutralInk:false,fadedInk:false,paperInPrivate:true)
check(neutralPaper.original,"original primary DB foreground is retained beside a neutral paper patch")
check(!neutralPaper.growth,"a weak neutral colour found in the private region cannot grow alone beyond it")
// New neutral shading cannot acquire a chromatic source even when that
// particular paper tone never occurred inside the private detector region.
check(!toneGrowth(neutralInk:false,fadedInk:false,paperInPrivate:false).growth,
    "new grey shading lacks the measured blue contrast direction even without a private paper palette")
// Real veiled ink retains its measured contrast direction; neutral lettering
// also keeps its original achromatic continuation policy.
check(toneGrowth(neutralInk:false,fadedInk:true,paperInPrivate:true).growth,
    "a real faded blue continuation retains its measured chromatic direction")
check(toneGrowth(neutralInk:true,fadedInk:false,paperInPrivate:true).growth,
    "achromatic antialiasing remains the primary ink family for neutral lettering")

for degrees in stride(from:0.0,to:360,by:15) {
    let a=degrees*Double.pi/180
    let cosine=cos(a),sine=sin(a)
    func turn(_ p:CGPoint)->CGPoint {
        CGPoint(x:160+(p.x-160)*cosine-(p.y-160)*sine,y:160+(p.x-160)*sine+(p.y-160)*cosine)
    }
    let skew=[CGPoint(x:140,y:95),CGPoint(x:160,y:96),CGPoint(x:165,y:185),CGPoint(x:143,y:183)].map(turn)
    let growthBase=rect(150,100,20,100).map(turn)
    let firstCap=rect(150,100,20,112).map(turn),lastCap=rect(150,100,20,117).map(turn)
    let joinedCap=NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(base:firstCap,supplement:lastCap,minimumChange:0)
    check(zip(joinedCap,lastCap).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y) < 1e-6 },
        "two measured caps retain a real sub-half-glyph difference at every rotation")
    let speculative=rect(150,40,20,190).map(turn)
    let measuredAlternative=NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(candidate:speculative,
        baseline:growthBase,terminalProof:firstCap)
    check(measuredAlternative != nil,"one speculative end does not discard the measured opposite cap")
    if let alternative=measuredAlternative {
        let ys=alternative.map { ($0.x-160)*(-sine)+($0.y-160)*cosine+160 }
        check(abs(ys.min()!-100)<1e-6 && abs(ys.max()!-212)<1e-6,
            "the extra recognition crop uses the original span and actual cap, not speculative padding")
        check(!NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(candidate:alternative,
            baseline:growthBase,terminalProof:firstCap),"the measured recognition alternative needs no speculative-end exemption")
    }
    let trimmedHeadCap=rect(150,105,20,107).map(turn)
    let originalHeadAlternative=NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(candidate:trimmedHeadCap,
        baseline:growthBase,terminalProof:firstCap)
    check(originalHeadAlternative != nil,"a proven tail retains an original-head recognition alternative when the opposite trim changes punctuation")
    check(NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(candidate:speculative,baseline:growthBase,terminalProof:nil)==nil,
        "an unmeasured crop cannot manufacture another endpoint alternative")
    check(NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(candidate:speculative,baseline:growthBase,terminalProof:growthBase)==nil,
        "a duplicate baseline is not recognized again")
    check(!NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(candidate:rect(150,90,20,120).map(turn),
        baseline:growthBase,terminalProof:nil),"one-glyph finishing room is intrinsic at every angle")
    check(!NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(candidate:rect(150,70,20,130).map(turn),
        baseline:growthBase,terminalProof:nil),"glyph finishing includes ordinary source-relative crop padding")
    check(NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(candidate:rect(150,50,20,150).map(turn),
        baseline:growthBase,terminalProof:nil),"a long unmeasured expansion needs additional foreground evidence")
    check(!NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(candidate:rect(150,50,20,150).map(turn),
        baseline:growthBase,terminalProof:rect(150,53,20,147).map(turn)),"a measured terminal cap justifies its own long extension")
    check(NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(candidate:rect(150,30,20,170).map(turn),
        baseline:growthBase,terminalProof:rect(150,53,20,147).map(turn)),"a terminal proof cannot justify unrelated space beyond its measured cap")
    let extendedSkew=[CGPoint(x:140,y:95),CGPoint(x:160,y:96),CGPoint(x:166,y:230),CGPoint(x:144,y:228)].map(turn)
    let kept=NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(base:skew,supplement:extendedSkew)
    let e=CGPoint(x:skew[1].x-skew[0].x,y:skew[1].y-skew[0].y)
    let f=CGPoint(x:kept[1].x-kept[0].x,y:kept[1].y-kept[0].y)
    check(abs(e.x*f.y-e.y*f.x)<1e-7,"length refinement must retain the first-edge angle: \(degrees)")
    let replacement=NativeOCRRFPrimaryEnsemble.replacingEndpointExtent(base:skew,proposal:extendedSkew)
    let replacementEdge=CGPoint(x:replacement[1].x-replacement[0].x,y:replacement[1].y-replacement[0].y)
    check(abs(e.x*replacementEdge.y-e.y*replacementEdge.x)<1e-7,
        "bidirectional replacement retains the original first-edge basis")
    func continuationBox(_ id:String,_ peerID:String,_ start:Int,_ end:Int,_ boxY:CGFloat,
                         exclusive:Bool = true)->NativeCoreMLDetectionBox {
        var cells=Set<Int>()
        for y in start..<end { for x in 153..<167 {
            let q=turn(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
            cells.insert(Int(floor(q.y))*side+Int(floor(q.x)))
        } }
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in Set(cells.map {$0/side}).sorted() {
            let xs=cells.filter {$0/side==y}.map {$0%side}.sorted()
            var begin=xs[0],last=begin
            for x in xs.dropFirst() {
                if x==last+1 {last=x;continue}
                runs.append(.init(y:y,x:begin,count:last-begin+1));begin=x;last=x
            }
            runs.append(.init(y:y,x:begin,count:last-begin+1))
        }
        let peerPolygon=rect(150,boxY==100 ? 182:100,20,90).map(turn)
        let outside=cells.filter { cell in
            !NativeOCRDirectionGeometry.contains(peerPolygon,CGPoint(x:CGFloat(cell%side)+0.5,y:CGFloat(cell/side)+0.5))
        }.count
        let component=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
            pixelCount:cells.count,meanProbability:1,runs:runs)
        let evidence=NativeOCRDetectorSeedEvidence(ownerID:id,parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],
            candidateComponents:[.init(component:component,competingOwnerIDs:[peerID],
                outsideCompetingCells:[exclusive ? outside:1])])
        return .init(polygon:rect(150,boxY,20,90).map(turn),score:0.9,detectorSeedEvidence:evidence)
    }
    let upperPiece=continuationBox("upper","lower",103,184,100)
    let lowerPiece=continuationBox("lower","upper",187,266,182)
    let columnSupport=rect(140,90,40,190).map(turn)
    var columnRF=NativeRFDETRLayoutPrimitive(queryID:77,semanticClass:.text,confidence:0.9,
        sourceBounds:NativeOCRDirectionGeometry.bounds(columnSupport))
    columnRF.supportPolygon=columnSupport
    check(NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(upperPiece,peer:lowerPiece,scope:columnRF),
        "reciprocal exclusive detector pieces can continue one RF-confirmed column at every angle")
    check(NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(lowerPiece,peer:upperPiece,scope:columnRF),
        "the same physical continuation proof works from either endpoint")
    var leadingDirection:Bool?,trailingDirection:Bool?
    _ = NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(upperPiece,peer:lowerPiece,scope:columnRF) { _,_,forward in
        leadingDirection=forward
    }
    _ = NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(lowerPiece,peer:upperPiece,scope:columnRF) { _,_,forward in
        trailingDirection=forward
    }
    check(leadingDirection==true && trailingDirection==false,
        "leading versus trailing continuation follows the stored reading basis through all rotations")
    let privateBase=upperPiece.detectorSeedEvidence!
    let privateEvidence=NativeOCRDetectorSeedEvidence(ownerID:privateBase.ownerID,parentBoxIndex:0,
        provenance:privateBase.provenance,threshold:privateBase.threshold,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:privateBase.candidateComponents!.map(\.component),ownershipVersion:2,completeCCScan:true,
        ambiguousComponents:[],candidateComponents:[])
    let privateUpper=NativeCoreMLDetectionBox(polygon:upperPiece.polygon,score:0.9,detectorSeedEvidence:privateEvidence)
    check(NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(privateUpper,peer:lowerPiece,scope:columnRF),
        "a private DB winner joins its source-exclusive candidate continuation at every angle")
    check(NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(lowerPiece,peer:privateUpper,scope:columnRF),
        "private/candidate continuation remains symmetric under scene rotation")
    let broadOverlap=NativeCoreMLDetectionBox(polygon:rect(150,180,20,90).map(turn),score:0.9,
        detectorSeedEvidence:lowerPiece.detectorSeedEvidence)
    check(!NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(upperPiece,peer:broadOverlap,scope:columnRF),
        "substantial source overlap is not established as mere padding by this narrow continuation proof")
    let contestedPiece=continuationBox("lower","upper",187,266,182,exclusive:false)
    check(!NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(upperPiece,peer:contestedPiece,scope:columnRF),
        "mostly borrowed detector components cannot establish column continuation")
    var unrelatedScope=columnRF
    unrelatedScope.supportPolygon=rect(5,5,10,10).map(turn)
    check(!NativeOCRRFPrimaryEnsemble.confirmedEndpointContinuation(upperPiece,peer:lowerPiece,scope:unrelatedScope),
        "matching lane geometry without common RF text support remains an independent read")
    let groupBase=rect(150,100,20,170).map(turn)
    func memberCrop(_ q:[CGPoint])->NativeOCRRFPrimaryEnsemble.EndpointCrop {
        .init(polygon:q,baseline:nil,pixelProof:nil,pixelInkProof:nil,terminalProof:nil,continuationPeers:[])
    }
    let memberA=memberCrop(rect(150,100,20,55).map(turn))
    let memberB=memberCrop(rect(150,155,20,80).map(turn))
    let observedGroup=NativeOCRRFPrimaryEnsemble.observedTerminalGroup(base:rect(150,100,20,80).map(turn),
        members:[rect(151,142,18,95).map(turn),rect(151,101,18,37).map(turn)],grid:1)
    check(observedGroup != nil && observedGroup!.order == [1,0],
        "a recovered terminal group keeps intrinsic word order under every rotation")
    if let observedGroup,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(rect(150,100,20,80).map(turn)) {
        let q=f.bounds(observedGroup.polygon)
        check(abs(q.minY-f.rect.minY)<0.001 && abs(q.width-f.rect.width)<0.001 && q.maxY>136,
            "observed group reconciliation preserves head,width and angle while retaining the actual recovered tail")
    }
    check(NativeOCRRFPrimaryEnsemble.observedTerminalGroup(base:rect(150,100,20,80).map(turn),
        members:[rect(151,101,18,70).map(turn),rect(151,142,18,95).map(turn)],grid:1)==nil,
        "overlapping alternative reads cannot be concatenated into a duplicated word")
    check(NativeOCRRFPrimaryEnsemble.observedTerminalGroup(base:rect(150,100,20,80).map(turn),
        members:[rect(151,101,18,37).map(turn),rect(185,142,18,95).map(turn)],grid:1)==nil,
        "a neighboring column cannot become an existing same-column group's tail")
    let measuredGroup=NativeOCRRFPrimaryEnsemble.groupedEndpointCrop(base:groupBase,members:[memberA,memberB])!
    check(abs(measuredGroup.polygon.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!-75)<0.01,
        "a supplemental group does not restore blank padding trimmed from its actual member crops")
    check(measuredGroup.baseline == groupBase,"the group baseline remains a separately recognized control")
    check(NativeOCRRFPrimaryEnsemble.groupedEndpointCrop(base:groupBase,members:[memberA]) == nil,
        "one measured fragment cannot silently replace a multi-fragment group")
    let retainedCells=[CGPoint(x:148,y:115),CGPoint(x:170,y:155),CGPoint(x:151,y:178)].map(turn)
    check(NativeOCRContextualColumnRecovery.retainsObservedSource(retainedCells,
        candidate:rect(145,110,30,75).map(turn),uncertainty:1.5),
        "a recrop retains observed glyph cells in every scene direction")
    check(!NativeOCRContextualColumnRecovery.retainsObservedSource(retainedCells,
        candidate:rect(153,110,15,75).map(turn),uncertainty:1.5),
        "higher recognition confidence cannot justify clipping an observed side stroke")
    // A square detector's minimum-area rectangle is not a text baseline.
    // Rotate actual DB evidence and a long neighbouring line together.
    func contextEvidence(_ id:Int,_ region:CGRect)->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            if region.contains(.init(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)) {
                if let last=runs.last,last.y==y,last.x+last.count==x {
                    runs[runs.count-1] = .init(y:y,x:last.x,count:last.count+1)
                } else { runs.append(.init(y:y,x:x,count:1)) }
            }
        } }
        return .init(ownerID:"context-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let sharedGlyphRegion=CGRect(x:154,y:191,width:10,height:12)
    let sharedGlyphBoxes=[
        NativeCoreMLDetectionBox(polygon:rect(150,100,20,70).map(turn),score:0.95),
        NativeCoreMLDetectionBox(polygon:rect(150,185,20,25).map(turn),score:0.95,
            detectorSeedEvidence:contextEvidence(1,sharedGlyphRegion)),
        NativeCoreMLDetectionBox(polygon:rect(150,180,20,75).map(turn),score:0.95,
            detectorSeedEvidence:contextEvidence(2,sharedGlyphRegion))]
    let sharedGlyphReads=[
        NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:sharedGlyphBoxes[0].polygon,text:"あい",confidence:0.95),
        NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:sharedGlyphBoxes[1].polygon,text:"う",confidence:0.95),
        NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:sharedGlyphBoxes[2].polygon,text:"うえ",confidence:0.95)]
    check(NativeOCRContextualColumnRecovery.borrowsRetainedGlyph(members:[0,1],boxes:sharedGlyphBoxes,
        reads:sharedGlyphReads,threshold:0.4),
        "a supplemental join cannot repeat a shared physical glyph already read inside another original word")
    var distinctGlyphReads=sharedGlyphReads
    distinctGlyphReads[2] = .init(sourceIndex:2,polygon:sharedGlyphBoxes[2].polygon,text:"おか",confidence:0.95)
    check(!NativeOCRContextualColumnRecovery.borrowsRetainedGlyph(members:[0,1],boxes:sharedGlyphBoxes,
        reads:distinctGlyphReads,threshold:0.4),
        "geometrical overlap alone cannot reject a fragment when the other word did not read it")
    var expandedForeignBoxes=sharedGlyphBoxes
    expandedForeignBoxes[2] = .init(polygon:rect(150,220,20,75).map(turn),score:0.95,
        detectorSeedEvidence:sharedGlyphBoxes[2].detectorSeedEvidence)
    check(!NativeOCRContextualColumnRecovery.borrowsRetainedGlyph(members:[0,1],boxes:expandedForeignBoxes,
        reads:sharedGlyphReads,threshold:0.4),
        "a new expansion cannot manufacture an original competing owner for a fragment")
    check(NativeOCRContextualColumnRecovery.borrowsRetainedGlyph(members:[0,1],boxes:sharedGlyphBoxes,
        reads:sharedGlyphReads.filter { $0.sourceIndex != 1 },threshold:0.4,retainedAliases:[2:[1]]),
        "an already verified shared-glyph transfer survives removal of its weak standalone decode")
    check(!NativeOCRContextualColumnRecovery.borrowsRetainedGlyph(members:[0,1],boxes:expandedForeignBoxes,
        reads:sharedGlyphReads.filter { $0.sourceIndex != 1 },threshold:0.4,retainedAliases:[2:[1]]),
        "a transfer record alone cannot replace original geometry and shared physical glyph proof")
    let trimParts=contextEvidence(8,CGRect(x:154,y:105,width:12,height:15)).components +
        contextEvidence(9,CGRect(x:154,y:140,width:12,height:15)).components
    let trimEvidence=NativeOCRDetectorSeedEvidence(ownerID:"immutable-expansion-word",parentBoxIndex:0,
        provenance:"db-4connected-original-cells-v1",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:trimParts)
    let trimSource=NativeCoreMLDetectionBox(polygon:rect(150,100,20,60).map(turn),score:0.95,
        detectorSeedEvidence:trimEvidence)
    let proposedTrimRead=rect(150,100,20,95).map(turn)
    let trimScopeQuad=rect(145,95,30,65).map(turn)
    var trimScope=NativeRFDETRLayoutPrimitive(queryID:107,semanticClass:.text,confidence:0.95,
        sourceBounds:NativeOCRDirectionGeometry.bounds(trimScopeQuad))
    trimScope.supportPolygon=trimScopeQuad
    let trimLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[trimScope])
    func immutableTrimFrame(crossing:Bool)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            if CGRect(x:154,y:105,width:12,height:15).contains(p) ||
                CGRect(x:154,y:140,width:12,height:crossing ? 35:15).contains(p) ||
                (!crossing && CGRect(x:154,y:163,width:12,height:12).contains(p)) {
                for k in 0..<3 { bytes[(y*side+x)*4+k]=0 }
            }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    let immutableTrims=NativeOCRContextualColumnRecovery.retainedExpansionTrims(boxes:[trimSource],
        frame:immutableTrimFrame(crossing:false),layout:trimLayout,inkStyles:[.init([0,0,0])],retained:[0],
        peerPolygons:[0:proposedTrimRead],excluding:[])
    check(immutableTrims.count==1 && immutableTrims[0].measuredTrimOnly && immutableTrims[0].immutableExpansionTrim,
        "an expanded read cannot turn an unowned island beyond the original RF observation into its own body")
    if let plan=immutableTrims.first,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(proposedTrimRead) {
        check(f.bounds(plan.polygon).maxY >= 59 && f.bounds(plan.polygon).maxY <= 62,
            "a paired post-read trim removes new excess while preserving the original calibrated span")
    }
    let crossingTrims=NativeOCRContextualColumnRecovery.retainedExpansionTrims(boxes:[trimSource],
        frame:immutableTrimFrame(crossing:true),layout:trimLayout,inkStyles:[.init([0,0,0])],retained:[0],
        peerPolygons:[0:proposedTrimRead],excluding:[])
    check(crossingTrims.allSatisfy { plan in
        NativeOCRRFPrimaryEnsemble.EndpointFrame(proposedTrimRead)!.bounds(plan.polygon).maxY >= 75
    },"a real stroke crossing the immutable edge remains complete even beyond RF")
    check(NativeOCRContextualColumnRecovery.retainedExpansionTrims(boxes:[trimSource],
        frame:immutableTrimFrame(crossing:false),layout:trimLayout,inkStyles:[.init([0,0,0])],retained:[0],
        peerPolygons:[0:trimSource.polygon],excluding:[]).isEmpty,
        "the new route does not retry a word with no expansion")
    let measuredCap=rect(150,100,20,80).map(turn)
    let protectedCapTrims=NativeOCRContextualColumnRecovery.retainedExpansionTrims(boxes:[trimSource],
        frame:immutableTrimFrame(crossing:false),layout:trimLayout,inkStyles:[.init([0,0,0])],retained:[0],
        peerPolygons:[0:proposedTrimRead],excluding:[],terminalProofs:[0:measuredCap])
    check(protectedCapTrims.allSatisfy { plan in
        NativeOCRRFPrimaryEnsemble.EndpointFrame(proposedTrimRead)!.bounds(plan.polygon).maxY >= 80-0.01
    },"new padding alternatives cannot erase an already measured source cap")
    // A predominantly exclusive candidate CC is nomination evidence, not an
    // invented private DB component. Its actual source-colour glyphs can
    // establish a normal margin without borrowing the adjacent retained word.
    let normalEvidence=contextEvidence(40,CGRect(x:88,y:70,width:16,height:160))
    func normalCandidate(_ fraction:Double)->NativeOCRDetectorSeedEvidence {
        var e=normalEvidence
        e.ownershipVersion=2;e.completeCCScan=true
        e.candidateComponents=e.components.map { c in
            .init(component:c,competingOwnerIDs:["context-41"],
                outsideCompetingCells:[Int(Double(c.pixelCount)*fraction)])
        }
        e=NativeOCRDetectorSeedEvidence(ownerID:e.ownerID,parentBoxIndex:e.parentBoxIndex,
            provenance:e.provenance,threshold:e.threshold,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:e.candidateComponents)
        return e
    }
    let normalBox=rect(80,55,56,190).map(turn),normalPeer=rect(116,60,22,180).map(turn)
    var normalBytes=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        var own=false
        if p.x >= 88 && p.x < 104 {
            for k in 0..<6 {
                let top=CGFloat(70+k*27),bottom=top+20
                if p.y >= top && p.y < bottom { own=true }
            }
        }
        let other=p.x >= 118 && p.x < 134 && p.y >= 65 && p.y < 235
        for channel in 0..<3 { normalBytes[(y*side+x)*4+channel]=(own || other) ? 0:230 }
    } }
    let normalFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:normalBytes)!
    let normalPeerEvidence=contextEvidence(41,CGRect(x:118,y:65,width:16,height:170))
    func normalPlans(_ fraction:Double,_ image:NativeOCRRGBAFrame,_ supplied:[CGPoint]? = nil)->[NativeOCRContextualColumnRecovery.Proposal] {
        let parent=supplied ?? normalBox
        return NativeOCRContextualColumnRecovery.retainedNormalTrims(boxes:[
            .init(polygon:parent,score:0.65,detectorSeedEvidence:normalCandidate(fraction)),
            .init(polygon:normalPeer,score:0.95,detectorSeedEvidence:normalPeerEvidence)],frame:image,
            inkStyles:[.init([0,0,0]),.init([0,0,0])],retained:[0,1],
            peerPolygons:[0:parent,1:normalPeer],excluding:[])
    }
    let normalPlansResult=normalPlans(0.9,normalFrame)
    check(normalPlansResult.count==1 && normalPlansResult[0].measuredNormalOnly,
        "a predominantly exclusive CC seeds measured normal trim under every rotation")
    if let plan=normalPlansResult.first,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(normalBox) {
        let r=f.bounds(plan.polygon)
        check(r.width < f.rect.width*0.6 && abs(r.minY-f.rect.minY)<0.001 && abs(r.maxY-f.rect.maxY)<0.001,
            "normal refinement preserves observed head/tail and baseline while excluding the adjacent word")
    }
    check(normalPlans(0.7,normalFrame).isEmpty,"mostly disputed source support cannot nominate a word normal trim")
    let blackFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:[UInt8](repeating:0,count:side*side*4))!
    check(normalPlans(0.9,blackFrame).isEmpty,"open matching paper cannot become a closed printed glyph component")
    var outlinedBytes=normalBytes
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        var outline=false
        if p.x >= 85 && p.x < 107 {
            for k in 0..<6 {
                let top=CGFloat(67+k*27)
                if p.y >= top && p.y < top+26 { outline=true }
            }
        }
        if outline,normalBytes[(y*side+x)*4] != 0 {
            for c in 0..<3 { outlinedBytes[(y*side+x)*4+c]=[190,80,8][c] }
        }
    } }
    let rimPlans=normalPlans(0.9,NativeOCRRGBAFrame(width:side,height:side,bytes:outlinedBytes)!)
    check(rimPlans.count==1,"repeated closed companion outlines remain eligible under every rotation")
    if let plan=rimPlans.first,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(normalBox) {
        let r=f.bounds(plan.polygon)
        check(r.minX <= 5 && r.maxX >= 27,"normal crop includes the actual coloured rim, not just its filled stroke")
    }
    let tilt=CGFloat.pi*7/180
    let tiltedNormal=rect(80,55,56,190).map { p -> CGPoint in
        let dx=p.x-96,dy=p.y-150
        return turn(CGPoint(x:96+dx*cos(tilt)-dy*sin(tilt),y:150+dx*sin(tilt)+dy*cos(tilt)))
    }
    let correctedAxis=normalPlans(0.9,normalFrame,tiltedNormal)
    check(correctedAxis.count==1 && correctedAxis[0].measuredSourceAxis,
        "independent printed glyph bands can correct a detector axis: angle=\(degrees) plans=\(correctedAxis.count) measured=\(correctedAxis.first?.measuredSourceAxis as Any)")
    if let plan=correctedAxis.first {
        let v=CGPoint(x:plan.polygon[3].x-plan.polygon[0].x,y:plan.polygon[3].y-plan.polygon[0].y)
        let a=turn(CGPoint(x:96,y:150)),b=turn(CGPoint(x:96,y:140))
        let u=CGPoint(x:a.x-b.x,y:a.y-b.y)
        check(abs(v.x*u.y-v.y*u.x)/(hypot(v.x,v.y)*hypot(u.x,u.y)) < 0.02,
            "the corrected source baseline follows actual glyphs rather than a neighbouring box or the screen axes")
    }
    var joinedRim=outlinedBytes
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if p.x >= 85 && p.x < 87 && p.y >= 67 && p.y < 228 {
            for c in 0..<3 { joinedRim[(y*side+x)*4+c]=[190,80,8][c] }
        }
    } }
    let connectedRimPlans=normalPlans(0.9,NativeOCRRGBAFrame(width:side,height:side,bytes:joinedRim)!,tiltedNormal)
    check(connectedRimPlans.count==1 && connectedRimPlans[0].measuredSourceAxis,
        "a connected word outline cannot hide independently observed inner glyphs from source-axis estimation")
    var bridgedBytes=normalBytes
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if p.x >= 103 && p.x < 119 && p.y >= 78 && p.y < 82 {
            for channel in 0..<3 { bridgedBytes[(y*side+x)*4+channel]=0 }
        }
    } }
    check(normalPlans(0.9,NativeOCRRGBAFrame(width:side,height:side,bytes:bridgedBytes)!).isEmpty,
        "one source glyph connected to an independent peer vetoes the whole trim, not merely that glyph")
    let pointWord = NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:rect(40,60,16,150).map(turn),text:"あいう…",confidence:0.95)
    let containedPoint = NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:rect(44,185,6,12).map(turn),text:"…",confidence:0.498)
    let pointWordEvidence = contextEvidence(30,CGRect(x:44,y:68,width:6,height:90))
    let containedEvidence = contextEvidence(31,CGRect(x:46,y:187,width:2,height:8))
    let pointProof = rect(40,175,16,35).map(turn)
    let pointInk: [NativeOCRRFPrimaryEnsemble.EndpointInkStyle?] = [.init([155,68,122]),.init([129,84,110]),.init([155,68,122])]
    func pointOwners(_ reads:[NativeCoreMLRecognizedRegion], _ sources:[Int:[NativeOCRDetectorSeedEvidence]],
                     _ proofs:[Int:[CGPoint]], _ ink:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]) -> [Int:Int] {
        NativeOCRRFPrimaryEnsemble.containedPointOwners(reads:reads,evidence:sources,proofs:proofs,ink:ink,recognitionThreshold:0.4)
    }
    let pointSources = [0:[pointWordEvidence],1:[containedEvidence]]
    check(pointOwners([pointWord,containedPoint],pointSources,[0:pointProof],pointInk) == [1:0],
        "measured point duplicates transfer into a single actual word at every angle")
    check(pointOwners([pointWord,containedPoint],[0:[pointWordEvidence,containedEvidence],1:[containedEvidence]],
        [0:pointProof],pointInk).isEmpty,"composite words retain existing independent fragment layout")
    check(pointOwners([pointWord,containedPoint],pointSources,[:],pointInk).isEmpty,"containment alone cannot remove a point read")
    check(pointOwners([pointWord,containedPoint],pointSources,[0:pointProof],[.init([0,0,0]),.init([250,250,250])]).isEmpty,
        "different source ink cannot be absorbed")
    let letterPoint = NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:containedPoint.polygon,text:"あ",confidence:0.9)
    check(pointOwners([pointWord,letterPoint],pointSources,[0:pointProof],pointInk).isEmpty,"a real letter remains independent")
    let outsidePoint = NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:rect(60,185,6,12).map(turn),text:"…",confidence:0.498)
    check(pointOwners([pointWord,outsidePoint],pointSources,[0:pointProof],pointInk).isEmpty,"neighboring point columns remain independent")
    check(pointOwners([pointWord,containedPoint],[0:[pointWordEvidence],1:[contextEvidence(32,CGRect(x:72,y:185,width:2,height:8))]],
        [0:pointProof],pointInk).isEmpty,"private source cells must actually lie inside the proven word")
    let otherWord = NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:pointWord.polygon,text:"あいう…",confidence:0.95)
    check(pointOwners([pointWord,containedPoint,otherWord],[0:[pointWordEvidence],1:[containedEvidence],2:[pointWordEvidence]],
        [0:pointProof,2:pointProof],pointInk).isEmpty,"ambiguous ownership cannot erase a read")
    let reference=NativeCoreMLDetectionBox(polygon:rect(40,60,16,150).map(turn),score:0.95,
        detectorSeedEvidence:contextEvidence(0,CGRect(x:42,y:65,width:12,height:140)))
    let diamond=[CGPoint(x:82,y:109),CGPoint(x:92,y:119),CGPoint(x:82,y:129),CGPoint(x:72,y:119)].map(turn)
    let small=NativeCoreMLDetectionBox(polygon:diamond,score:0.9,
        detectorSeedEvidence:contextEvidence(1,CGRect(x:76,y:111,width:12,height:16)))
    var contextValues=[Float](repeating:0,count:side*side)
    var contextBytes=[UInt8](repeating:255,count:side*side*4)
    for e in [reference.detectorSeedEvidence!,small.detectorSeedEvidence!] {
        for c in e.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
            contextValues[run.y*side+x]=0.99
            for k in 0..<3 { contextBytes[(run.y*side+x)*4+k]=0 }
        } } }
    }
    let contextMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:contextValues)
    let contextFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:contextBytes)!
    let proposals=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,small],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0])])
    check(proposals.contains(where:{ $0.parent==1 && $0.samplings.count==2 && $0.samplings[0] != $0.samplings[1] }),
        "an ambiguous short glyph obtains two source-pixel crops in its neighbour's intrinsic baseline")
    let discardedReference=NativeCoreMLDetectionBox(polygon:rect(78,100,8,50).map(turn),score:0.99,
        detectorSeedEvidence:contextEvidence(2,CGRect(x:79,y:111,width:6,height:16)))
    let retainedBaseline=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,small],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0])],activePeers:[0,1])
        .first(where:{$0.parent==1})
    let withDiscarded=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,small,discardedReference],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])],activePeers:[0,1])
        .first(where:{$0.parent==1})
    check(retainedBaseline != nil && withDiscarded?.polygon==retainedBaseline?.polygon &&
        withDiscarded?.samplings==retainedBaseline?.samplings,
        "a discarded narrow fragment cannot change a late recovery's retained font scale or direction")
    check(!NativeOCRContextualColumnRecovery.proposals(boxes:[reference,small,discardedReference],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])],activePeers:[1])
        .contains(where:{$0.parent==1}),
        "a late recovery cannot invent a baseline from detections whose reads were all discarded")
    let unreadLong=NativeCoreMLDetectionBox(polygon:rect(76,105,12,60).map(turn),score:0.9,
        detectorSeedEvidence:contextEvidence(41,CGRect(x:78,y:110,width:8,height:60)))
    var unreadValues=[Float](repeating:0,count:side*side)
    var unreadBytes=[UInt8](repeating:255,count:side*side*4)
    for e in [reference.detectorSeedEvidence!,unreadLong.detectorSeedEvidence!] {
        for c in e.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
            unreadValues[run.y*side+x]=0.99
            for k in 0..<3 { unreadBytes[(run.y*side+x)*4+k]=0 }
        } } }
    }
    let unreadMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:unreadValues)
    let unreadFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:unreadBytes)!
    let unreadLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[
        .init(queryID:41,semanticClass:.text,confidence:0.5,sourceBounds:CGRect(x:0,y:0,width:side,height:side))])
    let sharedTrimPart=contextEvidence(51,CGRect(x:78,y:110,width:8,height:60)).components[0]
    let trimCompetitorEvidence=contextEvidence(52,CGRect(x:78,y:168,width:8,height:18))
    let trimCompetitor=NativeCoreMLDetectionBox(polygon:rect(76,165,12,25).map(turn),score:0.9,
        detectorSeedEvidence:trimCompetitorEvidence)
    let outsideTrimCells=sharedTrimPart.runs.reduce(0) { sum,run in
        sum+(run.x..<(run.x+run.count)).filter { x in
            !NativeOCRDirectionGeometry.contains(trimCompetitor.polygon,CGPoint(x:CGFloat(x)+0.5,y:CGFloat(run.y)+0.5))
        }.count
    }
    let sharedTrimEvidence=NativeOCRDetectorSeedEvidence(ownerID:"observed-shared-word",parentBoxIndex:0,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[
            .init(component:sharedTrimPart,competingOwnerIDs:[trimCompetitorEvidence.ownerID],outsideCompetingCells:[outsideTrimCells])])
    let sharedTrimBox=NativeCoreMLDetectionBox(polygon:rect(76,105,12,75).map(turn),score:0.9,
        detectorSeedEvidence:sharedTrimEvidence)
    let exclusiveTrim=NativeOCRRFPrimaryEnsemble.exclusiveObservedTrimInk(index:0,boxes:[sharedTrimBox,trimCompetitor])
    check(exclusiveTrim != nil,"an actual word may measure a mostly exclusive shared component without inventing private ownership")
    check(NativeOCRRFPrimaryEnsemble.exclusiveObservedTrimInk(index:0,boxes:[sharedTrimBox])==nil,
        "unknown competing-owner geometry cannot establish an exclusive observed trim core")
    let coveringCompetitor=NativeCoreMLDetectionBox(polygon:rect(76,105,12,85).map(turn),score:0.9,
        detectorSeedEvidence:trimCompetitorEvidence)
    check(NativeOCRRFPrimaryEnsemble.exclusiveObservedTrimInk(index:0,boxes:[sharedTrimBox,coveringCompetitor])==nil,
        "persisted outside-cell counts cannot override an actual competitor covering the candidate ink")
    check(NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:0,boxes:[sharedTrimBox,trimCompetitor],
        polygon:sharedTrimBox.polygon,layout:unreadLayout,frame:unreadFrame)==sharedTrimBox.polygon,
        "a shared-only source cannot change first-pass geometry before an actual word establishes its read")
    check(NativeOCRRFPrimaryEnsemble.observedTrimCompetitorStyles(index:0,boxes:[sharedTrimBox,trimCompetitor],
        inkStyles:[.init(colors:[[0,0,0],[255,255,255]]),.init([120,0,100])]) != nil,
        "an exclusively supported observed word may distinguish a measured competing print without a page rule")
    check(NativeOCRRFPrimaryEnsemble.observedTrimCompetitorStyles(index:0,boxes:[sharedTrimBox,trimCompetitor],
        inkStyles:[.init(colors:[[0,0,0],[255,255,255]]),.init(colors:[[255,255,255],[0,0,0]])]) == nil,
        "same-print connected words cannot acquire shared-only trim permission by swapping dominant fill and outline")
    check(NativeOCRRFPrimaryEnsemble.observedTrimCompetitorStyles(index:0,boxes:[sharedTrimBox,trimCompetitor],
        inkStyles:[.init([0,0,0]),nil]) == nil,
        "unknown competitor ink is not evidence that shared cells may be cropped away")
    check(NativeOCRRFPrimaryEnsemble.observedTrimCompetitorStyles(index:0,boxes:[sharedTrimBox,trimCompetitor],
        inkStyles:[.init([168,140,150]),.init([69,74,141])]) == nil,
        "a single shared-component paper colour cannot establish the core-and-outline source proof needed for a new trim")
    check(sharedTrimBox.detectorSeedEvidence?.components.isEmpty==true && sharedTrimBox.detectorSeedEvidence==sharedTrimEvidence,
        "exclusive observed support never rewrites the detector's shared-component provenance")
    func unreadProposals(_ scope:NativeRFDETRLayoutResult?,_ active:Set<Int>)->[NativeOCRContextualColumnRecovery.Proposal] {
        NativeOCRContextualColumnRecovery.proposals(boxes:[reference,unreadLong],layout:scope,
            probability:unreadMap,frame:unreadFrame,inkStyles:[.init([0,0,0]),.init([0,0,0])],activePeers:active)
    }
    let unreadProposal=unreadProposals(unreadLayout,[0]).first { $0.parent==1 }
    check(unreadProposal != nil,"a strong unread long column can recover in a retained font peer's shared RF scope at every angle")
    if let unreadProposal,let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(reference.polygon) {
        let original=basis.bounds(unreadLong.polygon),recovered=basis.bounds(unreadProposal.polygon)
        check(recovered.minX <= original.minX+0.001 && recovered.maxX >= original.maxX-0.001,
            "interior DB seeds cannot shrink an unread outlined glyph's original normal extent")
    }
    check(unreadProposals(nil,[0]).isEmpty,"a nearby font peer without shared RF support cannot rescue a long unread column")
    check(unreadProposals(unreadLayout,[0,1]).isEmpty,"a retained long column keeps its existing crop instead of taking the unread retry")
    let continuationBox=NativeCoreMLDetectionBox(polygon:rect(76,172,12,60).map(turn),score:0.75,
        detectorSeedEvidence:contextEvidence(42,CGRect(x:78,y:180,width:8,height:50)))
    let recoveredRead=NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:rect(76,105,12,65).map(turn),text:"あい…",confidence:0.6)
    let continuationRead=NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:continuationBox.polygon,text:"うえお…",confidence:0.9)
    let joinBoxes=[reference,unreadLong,continuationBox]
    func joins(_ reads:[NativeCoreMLRecognizedRegion],_ recovered:Set<Int>,_ scope:NativeRFDETRLayoutResult?,
               _ ink:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?])->[NativeOCRContextualColumnRecovery.ColumnJoin] {
        NativeOCRContextualColumnRecovery.recoveredColumnJoins(boxes:joinBoxes,reads:reads,recovered:recovered,
            layout:scope,inkStyles:ink,threshold:0.4,width:side,height:side)
    }
    let sameInk:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]=[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])]
    let columnJoins=joins([recoveredRead,continuationRead],[1],unreadLayout,sameInk)
    check(columnJoins.count==1 && columnJoins[0].parent==2 && columnJoins[0].recovered==1 && columnJoins[0].samplings.count==2,
        "a verified unread fragment nominates two full-column observations with its unique retained continuation at every angle")
    check(joins([recoveredRead,continuationRead],[],unreadLayout,sameInk).isEmpty,
        "the new continuation path does not regroup previously retained words")
    check(joins([recoveredRead,continuationRead],[1],nil,sameInk).isEmpty,
        "collinear words without shared RF support remain separate")
    check(joins([recoveredRead,continuationRead],[1],unreadLayout,[.init([0,0,0]),.init([0,0,0]),.init([255,255,255])]).isEmpty,
        "different original ink layers cannot establish the unread continuation")
    let weakContinuation=NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:continuationRead.polygon,text:continuationRead.text,confidence:0.6)
    check(joins([recoveredRead,weakContinuation],[1],unreadLayout,sameInk).isEmpty,
        "a second weak read cannot authorize regrouping the recovered column")
    let neighbouringRead=NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:rect(95,172,12,60).map(turn),text:continuationRead.text,confidence:0.9)
    check(joins([recoveredRead,neighbouringRead],[1],unreadLayout,sameInk).isEmpty,
        "a nearby parallel column is not a same-lane continuation")
    let lastGlyph=contextEvidence(20,CGRect(x:45,y:195,width:6,height:20))
    let retainedBody=contextEvidence(21,CGRect(x:43,y:65,width:10,height:115))
    let endpointParentEvidence=NativeOCRDetectorSeedEvidence(ownerID:"retained-word-end",parentBoxIndex:0,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:retainedBody.components,ownershipVersion:2,completeCCScan:true,
        ambiguousComponents:lastGlyph.components,candidateComponents:[])
    let endpointParent=NativeCoreMLDetectionBox(polygon:reference.polygon,score:0.95,detectorSeedEvidence:endpointParentEvidence)
    let endpointChild=NativeCoreMLDetectionBox(polygon:rect(44,195,8,23).map(turn),score:0.95,
        detectorSeedEvidence:lastGlyph)
    let tailInk=contextEvidence(22,CGRect(x:44,y:226,width:8,height:30))
    let precedingInk=contextEvidence(23,CGRect(x:43,y:42,width:10,height:14))
    let rejectedTail=NativeCoreMLDetectionBox(polygon:rect(44,224,8,36).map(turn),score:0.95,detectorSeedEvidence:tailInk)
    var endpointValues=[Float](repeating:0,count:side*side)
    var endpointBytes=[UInt8](repeating:255,count:side*side*4)
    for e in [precedingInk,retainedBody,lastGlyph,tailInk] {
        for c in e.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
            endpointValues[run.y*side+x]=e.ownerID==tailInk.ownerID ? 0.1:0.99
            for k in 0..<3 { endpointBytes[(run.y*side+x)*4+k]=0 }
        } } }
    }
    let endpointMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:endpointValues)
    let endpointFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:endpointBytes)!
    let endpointSupport=rect(40,60,16,156).map(turn)
    let endpointProposals=NativeOCRContextualColumnRecovery.proposals(boxes:[endpointParent,endpointChild,rejectedTail],layout:nil,
        probability:endpointMap,frame:endpointFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])],
        activePeers:[0],peerPolygons:[0:endpointSupport])
    let completedWord=endpointProposals.first(where:{$0.parent==0})
    check(completedWord != nil,"an exact shared endpoint glyph nominates completion of its retained long word")
    if let q=completedWord?.polygon {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine+160 }.max()!
        check(end>=254 && end<=260,"a narrow rejected tail supplies observation extent while the retained word supplies font scale")
        let baseline=NativeOCRRFPrimaryEnsemble.EndpointFrame(endpointSupport)!
        let measured=baseline.bounds(q)
        check(abs(measured.minY-baseline.rect.minY)<1e-6 && measured.minX<=baseline.rect.minX+1e-6 &&
            measured.maxX>=baseline.rect.maxX-1e-6,
            "tail completion keeps the retained head and width despite same-colour lettering just before it")
    }
    let unrelatedParent=NativeCoreMLDetectionBox(polygon:endpointParent.polygon,score:0.95,
        detectorSeedEvidence:retainedBody)
    check(!NativeOCRContextualColumnRecovery.proposals(boxes:[unrelatedParent,endpointChild,rejectedTail],layout:nil,
        probability:endpointMap,frame:endpointFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])],
        activePeers:[0],peerPolygons:[0:endpointSupport]).contains(where:{$0.parent==0}),
        "neighboring rectangles alone cannot extend a long retained word without exact shared-glyph lineage")
    let leftEvidence=contextEvidence(3,CGRect(x:67,y:110,width:2,height:18))
    let rightEvidence=contextEvidence(4,CGRect(x:96,y:110,width:2,height:18))
    let wrappingRuns=leftEvidence.components[0].runs+rightEvidence.components[0].runs
    let wrappingEvidence=NativeOCRDetectorSeedEvidence(ownerID:leftEvidence.ownerID,parentBoxIndex:3,
        provenance:leftEvidence.provenance,threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[.init(seed:leftEvidence.components[0].seed,pixelCount:wrappingRuns.count,
            meanProbability:0.99,runs:wrappingRuns)],ownershipVersion:2,completeCCScan:true,
        ambiguousComponents:[],candidateComponents:[])
    let wrappingPeer=NativeCoreMLDetectionBox(polygon:rect(66,109,33,20).map(turn),score:0.95,
        detectorSeedEvidence:wrappingEvidence)
    let wrappedProposals=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,small,wrappingPeer],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])])
    check(wrappedProposals.contains(where:{$0.parent==1}),
        "a peer's unoccupied interior cannot veto another glyph between its separated private runs")
    check(!NativeOCRContextualColumnRecovery.samplesObservedGlyph([rect(75,111,14,16).map(turn)],
        peerPolygon:wrappingPeer.polygon,evidence:wrappingEvidence),
        "late ownership revalidation preserves holes between another read's actual source cells")
    check(NativeOCRContextualColumnRecovery.samplesObservedGlyph([small.polygon],
        peerPolygon:small.polygon,evidence:small.detectorSeedEvidence!),
        "a newly committed source glyph cannot be reused by another proposal from the same recognition batch")
    let sharedMark=contextEvidence(9,CGRect(x:80,y:130,width:4,height:16))
    let sharedWide=contextEvidence(10,CGRect(x:65,y:130,width:40,height:14))
    let sharedOwner=NativeOCRDetectorSeedEvidence(ownerID:"shared-mark-source",parentBoxIndex:1,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:small.detectorSeedEvidence!.components,ownershipVersion:2,completeCCScan:true,
        ambiguousComponents:sharedMark.components+sharedWide.components,candidateComponents:[])
    let sharedSeeds=NativeOCRContextualColumnRecovery.sharedContinuationSeeds(evidence:sharedOwner,
        source:rect(74,110,16,24).map(turn),reference:rect(74,110,16,70).map(turn))
    check(sharedSeeds.contains(sharedMark.components[0].seed),
        "a narrow shared component already touching the source can complete its clipped mark")
    check(!sharedSeeds.contains(sharedWide.components[0].seed),
        "sharing a broad multi-column component cannot grant another whole column's glyphs")
    check(!NativeOCRContextualColumnRecovery.samplesObservedGlyph([rect(79,129,6,18).map(turn)],
        peerPolygon:rect(79,129,6,18).map(turn),evidence:sharedMark,excludingSeeds:sharedSeeds),
        "the same shared physical mark cannot act as an independent peer veto after a crop rotates")
    let nestedEvidence=contextEvidence(5,CGRect(x:76,y:112,width:12,height:17))
    let nestedChild=NativeCoreMLDetectionBox(polygon:rect(74,110,16,21).map(turn),score:0.95,
        detectorSeedEvidence:nestedEvidence)
    let distraction=contextEvidence(6,CGRect(x:99,y:112,width:10,height:35))
    let secondGlyph=contextEvidence(7,CGRect(x:77,y:135,width:11,height:12))
    let parentEvidence=NativeOCRDetectorSeedEvidence(ownerID:"nested-word",parentBoxIndex:8,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:distraction.components+secondGlyph.components,ownershipVersion:2,completeCCScan:true,
        ambiguousComponents:nestedEvidence.components,candidateComponents:[])
    let broadParent=NativeCoreMLDetectionBox(polygon:rect(70,105,44,47).map(turn),score:0.65,
        detectorSeedEvidence:parentEvidence)
    var nestedValues=contextValues,nestedBytes=contextBytes
    for e in [parentEvidence,nestedEvidence] {
        for c in e.components+(e.ambiguousComponents ?? []) { for run in c.runs { for x in run.x..<(run.x+run.count) {
            nestedValues[run.y*side+x]=0.99
            for k in 0..<3 { nestedBytes[(run.y*side+x)*4+k]=0 }
        } } }
    }
    let nestedMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,
        resizedWidth:side,resizedHeight:side,region:CGRect(x:0,y:0,width:side,height:side),
        width:side,height:side,values:nestedValues)
    let nestedFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:nestedBytes)!
    let nestedProposal=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,broadParent,nestedChild],layout:nil,
        probability:nestedMap,frame:nestedFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])]).first(where:{$0.parent==1})
    check(nestedProposal != nil,"a shared narrow child anchors the broad parent's actual remaining column")
    if let nestedProposal {
        check(NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:nestedEvidence,parent:parentEvidence,
            childPolygon:nestedChild.polygon,container:nestedProposal.polygon),
            "neighbouring print inside a broad parent cannot erase its own resolved child's shared glyph")
    }
    var contaminatedBytes=nestedBytes
    for c in distraction.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
        for k in 0..<3 { contaminatedBytes[(run.y*side+x)*4+k]=255 }
    } } }
    let contaminatedFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:contaminatedBytes)!
    let reanchored=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,broadParent],layout:nil,
        probability:nestedMap,frame:contaminatedFrame,inkStyles:[.init([0,0,0]),.init([255,255,255])],
        activePeers:[0,1]).first(where:{$0.parent==1})
    check(reanchored != nil,"a resolved neighbouring print colour can locate real ink when a broad parent learned paper")
    if let reanchored {
        let local=reanchored.polygon.map { p -> CGPoint in
            let dx=p.x-160,dy=p.y-160
            return CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        }
        check(NativeOCRDirectionGeometry.bounds(local).maxX < 94,
            "false detector paper to the side cannot move the measured source lane away from its actual glyphs")
    }
    if let p=proposals.first(where:{ $0.parent==1 }) {
        let edge=CGPoint(x:p.polygon[1].x-p.polygon[0].x,y:p.polygon[1].y-p.polygon[0].y)
        check(abs((edge.x*cosine+edge.y*sine)/hypot(edge.x,edge.y))>0.999,
            "context recovery rotates with the complete scene rather than snapping to a screen axis")
    }
    let twoGlyphReference=NativeCoreMLDetectionBox(polygon:rect(40,60,16,40).map(turn),score:0.95,
        detectorSeedEvidence:contextEvidence(0,CGRect(x:42,y:65,width:12,height:30)))
    check(NativeOCRContextualColumnRecovery.proposals(boxes:[twoGlyphReference,small],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0])]).contains(where:{$0.parent==1}),
        "a resolved two-glyph neighbour supplies an intrinsic baseline without requiring a long paragraph")
    check(NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:small.detectorSeedEvidence!,parent:small.detectorSeedEvidence!,
        childPolygon:small.polygon,container:rect(70,105,30,30).map(turn)),
        "a contextual word retains the same complete shared detector glyph through scene rotation")
    check(!NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:small.detectorSeedEvidence!,parent:small.detectorSeedEvidence!,
        childPolygon:small.polygon,container:rect(80,115,5,5).map(turn)),
        "a contextual word cannot suppress a partly clipped shared glyph")
    let clippedGlyph=NativeCoreMLDetectionBox(polygon:rect(74,124,16,22).map(turn),score:0.3,
        detectorSeedEvidence:small.detectorSeedEvidence)
    let fullGlyphProposal=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,clippedGlyph],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0])]).first(where:{$0.parent==1})
    check(fullGlyphProposal != nil,"a clipped glyph recovers its actual source pixels beyond one original endpoint")
    if let fullGlyphProposal {
        let bounds=NativeOCRDirectionGeometry.bounds(fullGlyphProposal.polygon.map { p in
            let dx=p.x-160,dy=p.y-160
            return CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        })
        check(bounds.minY <= 111 && bounds.maxY >= 127,"completion includes the whole measured glyph rather than adding empty padding")
    }
    let landscapeGlyph=NativeCoreMLDetectionBox(polygon:rect(72,108,21,20).map(turn),score:0.9,
        detectorSeedEvidence:small.detectorSeedEvidence)
    check(!NativeOCRContextualColumnRecovery.proposals(boxes:[reference,landscapeGlyph],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0]),.init([0,0,0])]).contains(where:{$0.parent==1}),
        "single-glyph edge relabeling and added sampling padding cannot invent a direction recovery")
    check(NativeOCRContextualColumnRecovery.proposals(boxes:[small],layout:nil,
        probability:contextMap,frame:contextFrame,inkStyles:[.init([0,0,0])]).isEmpty,
        "a lone square glyph cannot invent its own contextual baseline")
    let foreignEvidence=contextEvidence(2,CGRect(x:73,y:112,width:2,height:2))
    let foreignBox=NativeCoreMLDetectionBox(polygon:rect(72,111,4,4).map(turn),score:0.95,detectorSeedEvidence:foreignEvidence)
    var borrowedValues=contextValues,borrowedBytes=contextBytes
    for c in foreignEvidence.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
        borrowedValues[run.y*side+x]=0.99
        for k in 0..<3 { borrowedBytes[(run.y*side+x)*4+k]=0 }
    } } }
    let borrowedMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:borrowedValues)
    let borrowedFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:borrowedBytes)!
    let boundedProposals=NativeOCRContextualColumnRecovery.proposals(boxes:[reference,small,foreignBox],layout:nil,
        probability:borrowedMap,frame:borrowedFrame,inkStyles:[.init([0,0,0]),.init([0,0,0]),.init([0,0,0])])
    check(boundedProposals.filter({$0.parent==1}).allSatisfy { proposal in
        proposal.samplings.allSatisfy { sampling in
            foreignEvidence.components.allSatisfy { c in c.runs.allSatisfy { run in
                (run.x..<(run.x+run.count)).allSatisfy { x in
                    !NativeOCRDirectionGeometry.contains(sampling,CGPoint(x:CGFloat(x)+0.5,y:CGFloat(run.y)+0.5))
                }
            } }
        }
    },"context padding is clipped or rejected before it can sample another detector's private glyph")
    let observedEvidence=NativeOCRDetectorSeedEvidence(ownerID:foreignEvidence.ownerID,parentBoxIndex:2,
        provenance:foreignEvidence.provenance,threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:foreignEvidence.components,candidateComponents:[])
    let observedPeer=NativeCoreMLDetectionBox(polygon:foreignBox.polygon,score:0.95,
        detectorSeedEvidence:observedEvidence)
    check(!NativeOCRContextualColumnRecovery.samplesObservedGlyph([observedPeer.polygon],
        peerPolygon:observedPeer.polygon,evidence:observedEvidence),
        "an enclosing read cannot turn an ambiguous CC into exclusive physical glyph ownership")
    let polygon=rect(150,100,20,85).map(turn)
    check(NativeOCRRFPrimaryEnsemble.overlapsComparableEndpointRead(polygon,peer:rect(150,173,20,75).map(turn),
        ink:.init([235,79,152]),peerInk:.init([206,113,151])),
        "comparable original crop overlap is measured in actual rotated polygons")
    check(!NativeOCRRFPrimaryEnsemble.overlapsComparableEndpointRead(polygon,peer:rect(150,173,20,75).map(turn),
        ink:.init([12,92,166]),peerInk:.init([254,254,253])),
        "independent measured text layers cannot supply borrowed-letter evidence")
    check(!NativeOCRRFPrimaryEnsemble.overlapsComparableEndpointRead(polygon,peer:rect(150,240,20,40).map(turn),
        ink:.init([235,79,152]),peerInk:.init([206,113,151])),
        "nearby nonoverlapping words cannot veto a source recovery")
    check(NativeOCRRFPrimaryEnsemble.overlapsEndpointReadAfterGrowth(rect(150,100,20,150).map(turn),
        baseline:polygon,peer:rect(150,195,20,75).map(turn),
        ink:.init([12,92,166]),peerInk:.init([254,254,253])),
        "newly sampled independent word ink remains competing evidence even across different print colours")
    check(!NativeOCRRFPrimaryEnsemble.overlapsEndpointReadAfterGrowth(polygon,
        baseline:polygon,peer:rect(150,173,20,75).map(turn),
        ink:.init([12,92,166]),peerInk:.init([254,254,253])),
        "unchanged distinct-colour overlap gains no new borrowed-word veto")
    check(!NativeOCRRFPrimaryEnsemble.overlapsEndpointReadAfterGrowth(rect(150,100,20,100).map(turn),
        baseline:polygon,peer:rect(150,240,20,40).map(turn),
        ink:.init([12,92,166]),peerInk:.init([254,254,253])),
        "growth that never reaches an independent word remains eligible")
    let bases=[polygon,rect(150,240,20,40).map(turn)]
    let competing=[rect(150,90,20,170).map(turn),rect(150,200,20,90).map(turn)]
    check(NativeOCRRFPrimaryEnsemble.retainsOriginalReadingSpan(candidate:rect(150,90,20,110).map(turn),baseline:polygon),
        "a full intrinsic expansion preserves the original read span at all angles")
    check(!NativeOCRRFPrimaryEnsemble.retainsOriginalReadingSpan(candidate:rect(150,105,20,80).map(turn),baseline:polygon),
        "trimming a source endpoint cannot grant punctuation retokenization permission")
    check(!NativeOCRRFPrimaryEnsemble.retainsOriginalReadingSpan(candidate:rect(152,90,16,110).map(turn),baseline:polygon),
        "a narrow crop cannot claim to retain original source width")

    let paddedRead=rect(150,100,20,150).map(turn)
    let tooShort=rect(150,100,20,105).map(turn)
    let observedCap=rect(150,103,20,137).map(turn)
    let keptCap=NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:tooShort,candidate:paddedRead,
        original:polygon,proof:observedCap)
    check(abs(keptCap.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!-80)<1e-6,
        "a direct-colour trim must keep the measured recovered cap without protecting its sampling margin")
    check(NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:tooShort,candidate:paddedRead,
        original:polygon,proof:nil)==tooShort,"an unproved expansion cannot veto source-padding removal")
    check(NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:tooShort,candidate:paddedRead,
        original:polygon,proof:polygon)==tooShort,"original-only ink cannot claim an unmeasured new endpoint")
    let tailProof=rect(150,100,20,91).map(turn)
    let exactTail=NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(base:polygon,supplement:tailProof,minimumChange:0)
    let smallTail=NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:polygon,candidate:exactTail,
        original:polygon,proof:tailProof)
    check(abs(smallTail.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!-31)<1e-6,
        "a measured cap below the sampling deadband still reaches the actual tail")
    let headProof=rect(150,94,20,91).map(turn)
    let exactHead=NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(base:polygon,supplement:headProof,minimumChange:0)
    let smallHead=NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:polygon,candidate:exactHead,
        original:polygon,proof:headProof)
    check(abs(smallHead.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.min()!+66)<1e-6,
        "a measured cap below the sampling deadband still reaches the actual head")
    let headRead=rect(150,55,20,130).map(turn),shortHead=rect(150,90,20,95).map(turn)
    let headCap=NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:shortHead,candidate:headRead,
        original:polygon,proof:rect(150,60,20,125).map(turn))
    check(abs(headCap.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.min()!+100)<1e-6,
        "the same measured-cap contract protects a recovered head at every scene angle")

    let reconciled=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(competing,bases:bases)
    let firstEnds=reconciled[0].map { ($0.x-160)*(-sine)+($0.y-160)*cosine }
    let secondEnds=reconciled[1].map { ($0.x-160)*(-sine)+($0.y-160)*cosine }
    check(abs(firstEnds.max()!-25)<1e-6 && abs(secondEnds.min()!-80)<1e-6,
        "independent endpoints cannot both annex the same gap")
    check(abs(firstEnds.min()!+70)<1e-6 && abs(secondEnds.max()!-130)<1e-6,
        "endpoint ownership conflict preserves noncompeting growth")
    let paddedGap=[rect(150,100,20,116).map(turn),rect(150,212,20,68).map(turn)]
    let disjointInk=[rect(150,102,20,110).map(turn),rect(150,216,20,62).map(turn)]
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(paddedGap,bases:bases,
        pixelProofs:paddedGap.map { Optional($0) },pixelInkProofs:disjointInk.map { Optional($0) })==paddedGap,
        "overlapping sampling margins preserve disjoint measured source strokes at every angle")
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(paddedGap,bases:bases,
        pixelProofs:paddedGap.map { Optional($0) },pixelInkProofs:paddedGap.map { Optional($0) }) != paddedGap,
        "actual shared ink still cannot be claimed by both independent reads")
    let singleGrowth=[rect(150,100,20,125).map(turn),bases[1]]
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(singleGrowth,bases:bases)==singleGrowth,
        "one measured stroke can pass the gap midpoint without a competing growth claim")
    let crossingPeer=[rect(150,90,20,170).map(turn),bases[1]]
    let rejectedCrossing=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(crossingPeer,bases:bases)
    check(abs(rejectedCrossing[0].map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!-25)<1e-6,
        "a unilateral extension cannot enter an established independent read in the same lane")
    let boundedPointCap=rect(150,90,20,145).map(turn)
    let boundedCrossing=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(crossingPeer,bases:bases,
        pointTerminalProofs:[boundedPointCap,nil])
    check(zip(boundedCrossing[0],boundedPointCap).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
        "rejecting a newer cap beyond a peer retains the earlier measured point cap instead of reverting the entire endpoint")
    let reversedBounded=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(Array(crossingPeer.reversed()),
        bases:Array(bases.reversed()),pointTerminalProofs:[nil,boundedPointCap])
    check(zip(reversedBounded[1],boundedPointCap).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
        "a bounded proved-cap retry has identical source ownership when enumeration order is reversed")
    let provenCrossing=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(crossingPeer,bases:bases,
        pixelProofs:[crossingPeer[0],nil],inkStyles:[.init([12,92,166]),.init([254,254,253])])
    check(provenCrossing==crossingPeer,"measured peer-ink exclusion cannot be overruled by peer padding")
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(crossingPeer,bases:bases,
        pointTerminalProofs:[crossingPeer[0],nil])==crossingPeer,
        "a source-rooted point train with private-peer exclusion survives a peer's empty rectangular padding")
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(competing,bases:bases,
        pointTerminalProofs:competing.map { Optional($0) })==reconciled,
        "two observed point trains cannot both acquire the same previously unowned gap")
    let sharedPoints=[rect(150,100,20,135).map(turn),rect(150,190,20,90).map(turn)]
    let oneForwardProof=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(sharedPoints,bases:bases,
        pointTerminalProofs:[sharedPoints[0],nil])
    check(oneForwardProof[0]==sharedPoints[0] && zip(oneForwardProof[1],bases[1]).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
        "actual forward points survive an unproven backward proposal without granting it the same ink")
    let reversedForwardProof=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(Array(sharedPoints.reversed()),bases:Array(bases.reversed()),
        pointTerminalProofs:[nil,sharedPoints[0]])
    check(reversedForwardProof[1]==sharedPoints[0] && zip(reversedForwardProof[0],bases[1]).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
        "source enumeration order cannot change forward ownership of actual points")
    let assignedPoints=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(sharedPoints,bases:bases,
        pointTerminalProofs:sharedPoints.map { Optional($0) })
    check(assignedPoints[0]==sharedPoints[0] && zip(assignedPoints[1],bases[1]).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
        "a shared point train inside a true inter-word gap follows its preceding word without moving the following body")
    let rewindingPoints=[sharedPoints[0],rect(150,175,20,105).map(turn)]
    let assignedRewinding=NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(rewindingPoints,bases:bases,
        pointTerminalProofs:rewindingPoints.map { Optional($0) })
    check(assignedRewinding[0]==rewindingPoints[0] && zip(assignedRewinding[1],bases[1]).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
        "a following read cannot rewind into already enclosed initial points and cancel their valid forward tail")
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(competing,bases:bases,
        pixelProofs:competing.map { Optional($0) })==reconciled,
        "two pixel proposals still cannot acquire the same unowned gap")
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(crossingPeer,bases:bases,
        pixelProofs:[crossingPeer[0],nil],inkStyles:[.init([12,92,166]),.init([20,100,170])])==rejectedCrossing,
        "similar-colour independent sources retain their established endpoint ownership")
    check(NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(competing,bases:bases,
        pixelProofs:competing.map { Optional($0) },inkStyles:[.init([12,92,166]),.init([254,254,253])])==competing,
        "distinct source inks with actual pixel proof can occupy separate overlaid text layers")
    let box=NativeCoreMLDetectionBox(polygon:polygon,score:0.9)
    let support=rect(140,90,40,150).map(turn)
    var rf=NativeRFDETRLayoutPrimitive(queryID:1,semanticClass:.text,confidence:0.9,
        sourceBounds:NativeOCRDirectionGeometry.bounds(support))
    rf.supportPolygon=support
    let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[rf])
    func image(bar:Bool,opposite:Bool,rimMark:Bool = false,faint:Bool = false,blue:Bool = false,farBar:Bool = false,barOnly:Bool = false,foreign:Bool = false,connectedWord:Bool = false,outlined:Bool = false,nextWord:Bool = false,artworkTail:Bool = false,offsetStroke:Bool = false,antialiasedBar:Bool = false,noiseTail:Bool = false,weakIsland:Bool = false,splitHead:Bool = false,continuationWords:Bool = false,junctionTail:Bool = false,splitTailChain:Bool = false,splitHeadChain:Bool = false,shortCoreTail:Bool = false,shortChainWithArt:Bool = false)->NativeOCRRGBAFrame {
        var rgba=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let px=160+dx*cosine+dy*sine,py=160-dx*sine+dy*cosine
            let continuation = continuationWords && (0..<4).contains { n in
                CGRect(x:153,y:183+n*20,width:14,height:12).contains(CGPoint(x:px,y:py))
            }
            let glyph = (shortChainWithArt && CGRect(x:153,y:244,width:14,height:10).contains(CGPoint(x:px,y:py))) || (junctionTail && CGRect(x:153,y:183,width:14,height:11).contains(CGPoint(x:px,y:py))) || continuation || (!barOnly && (0..<(shortCoreTail ? 2:4)).contains { n in CGRect(x:153,y:103+n*20,width:14,height:12).contains(CGPoint(x:px,y:py)) }) ||
                (nextWord && CGRect(x:153,y:200,width:14,height:12).contains(CGPoint(x:px,y:py)))
            let rail=barOnly && (0..<4).contains { n in CGRect(x:158,y:100+n*45,width:3,height:40).contains(CGPoint(x:px,y:py)) }
            let headPiece=splitHead && CGRect(x:158,y:80,width:3,height:19).contains(CGPoint(x:px,y:py))
            let tail=bar && CGRect(x:158,y:183,width:3,height:farBar ? 72 : 42).contains(CGPoint(x:px,y:py))
            let link=(shortChainWithArt && (CGRect(x:158,y:173,width:3,height:24).contains(CGPoint(x:px,y:py)) || CGRect(x:158,y:200,width:3,height:25).contains(CGPoint(x:px,y:py)))) || (shortCoreTail && CGRect(x:158,y:133,width:3,height:82).contains(CGPoint(x:px,y:py))) || (splitTailChain && (CGRect(x:158,y:173,width:3,height:59).contains(CGPoint(x:px,y:py)) || CGRect(x:158,y:235,width:3,height:25).contains(CGPoint(x:px,y:py)))) || (splitHeadChain && (CGRect(x:158,y:59,width:3,height:19).contains(CGPoint(x:px,y:py)) || CGRect(x:158,y:80,width:3,height:19).contains(CGPoint(x:px,y:py)))) || (junctionTail && CGRect(x:158,y:173,width:3,height:72).contains(CGPoint(x:px,y:py))) || (connectedWord && CGRect(x:158,y:103,width:3,height:152).contains(CGPoint(x:px,y:py))) ||
                (offsetStroke && CGRect(x:165,y:163,width:3,height:62).contains(CGPoint(x:px,y:py)))
            var value:UInt8=(glyph || tail || rail || link || headPiece) ? 0 : 255
            if outlined && !(glyph || tail || rail || link) {
                let halo=(0..<4).contains { n in CGRect(x:150,y:100+n*20,width:20,height:18).contains(CGPoint(x:px,y:py)) } ||
                    (connectedWord && CGRect(x:155,y:100,width:9,height:158).contains(CGPoint(x:px,y:py)))
                value=halo ? 255 : 80
            }
            let i=(y*side+x)*4
            for c in 0..<3 { rgba[i+c]=value }
            if antialiasedBar && tail && py>=186 { for c in 0..<3 { rgba[i+c]=150 } }
            if noiseTail && px>=158 && px<159 && py>=200 && py<202 {
                for c in 0..<3 { rgba[i+c]=0 }
            }
            if weakIsland && px>=158 && px<161 && py>=200 && py<225 {
                for c in 0..<3 { rgba[i+c]=150 }
            }
            if blue && (glyph || tail) { rgba[i]=12;rgba[i+1]=91;rgba[i+2]=166 }
            if faint && px>=152 && px<168 && py>=195 && py<220 {
                rgba[i]=blue ? 134 : 225;rgba[i+1]=blue ? 173 : 225;rgba[i+2]=blue ? 211 : 225
            }
            if foreign && px>=153 && px<167 && py>=240 && py<252 {
                rgba[i]=230;rgba[i+1]=0;rgba[i+2]=0
            }
            if artworkTail && px>=158 && px<161 && py>=224 && py<255 {
                rgba[i]=230;rgba[i+1]=0;rgba[i+2]=0
            }
            if rimMark && px>=150 && px<154 && py>=214 && py<220 {
                for c in 0..<3 { rgba[i+c]=0 }
            }
            if opposite && py>=183 && py<225 && px>=157 && px<163 {
                // Opposite-polarity feature on a dark local backdrop.
                for c in 0..<3 { rgba[i+c]=255 }
            } else if opposite && py>=181 && py<229 && px>=140 && px<180 {
                for c in 0..<3 { rgba[i+c]=0 }
            }
        } }
        return .init(width:side,height:side,bytes:rgba)!
    }
    typealias E = NativeOCRDetectorSeedEvidence
    var cores:[E.Component]=[]
    for n in 0..<5 {
        let source=CGRect(x:153,y:n == 4 ? 240 : 103+n*20,width:14,height:12)
        let quad=NativeOCRDirectionGeometry.corners(source).map(turn)
        let bounds=NativeOCRDirectionGeometry.bounds(quad)
        var runs:[E.Run]=[]
        for y in Int(floor(bounds.minY))..<Int(ceil(bounds.maxY)) {
            var points:[Int]=[]
            for x in Int(floor(bounds.minX))..<Int(ceil(bounds.maxX)) {
                let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
                if source.contains(CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)) { points.append(x) }
            }
            if let first=points.first,let last=points.last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let first=runs.first!
        cores.append(.init(seed:first.y*side+first.x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs))
    }
    let evidence=E(ownerID:"fixture-core",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:cores,ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    check(evidence.isValid,"real private-ink carrier is valid")
    let foreignFrame=image(bar:false,opposite:false,foreign:true)
    let fitted=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:evidence,columns:20,rows:200,start:0,length:85,
        project: { p in
            let dx=p.x-160,dy=p.y-160
            return CGPoint(x:160+dx*cosine+dy*sine-150,y:160-dx*sine+dy*cosine-100)
        },rgb: { row,column in
            let p=turn(CGPoint(x:150+CGFloat(column)+0.5,y:100+CGFloat(row)+0.5))
            let x=Int(floor(p.x)),y=Int(floor(p.y))
            guard x>=0,y>=0,x<side,y<side else { return nil }
            let i=(y*side+x)*4
            return [Int(foreignFrame.bytes[i]),Int(foreignFrame.bytes[i+1]),Int(foreignFrame.bytes[i+2])]
        })
    let expandedFit=NativeOCRRFPrimaryEnsemble.endpointPalette(evidence:evidence,columns:20,rows:200,start:0,length:200,
        project: { p in
            let dx=p.x-160,dy=p.y-160
            return CGPoint(x:160+dx*cosine+dy*sine-150,y:160-dx*sine+dy*cosine-100)
        },rgb: { row,column in
            let p=turn(CGPoint(x:150+CGFloat(column)+0.5,y:100+CGFloat(row)+0.5))
            let x=Int(floor(p.x)),y=Int(floor(p.y))
            guard x>=0,y>=0,x<side,y<side else { return nil }
            let i=(y*side+x)*4
            return [Int(foreignFrame.bytes[i]),Int(foreignFrame.bytes[i+1]),Int(foreignFrame.bytes[i+2])]
        },sourceMask:(0..<(20*200)).map { $0/20 < 85 })
    check(expandedFit != nil,"an enlarged sampling crop can retain its original source palette")
    if let expandedFit {
        check(!expandedFit.seeds[145*20+10],
            "enlarging a sampling crop cannot acquire a neighboring private detector component")
    }
    check(fitted != nil,"private source palette fit remains available")
    if let fitted {
        check(fitted.mask[145*20+10] == 0,"shared CC cells outside the current crop cannot teach its palette")
        check(fitted.seeds[145*20+10] == false,"other cropped paragraphs are not private source anchors")
    }
    let provenColumn=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[columnRF])
    var measuredContinuationPeers=Set<Int>()
    let completeColumn=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[upperPiece,lowerPiece],
        layout:provenColumn,frame:image(bar:false,opposite:false,connectedWord:true,continuationWords:true),
        continuationObserver:{ measuredContinuationPeers.insert($0) })
    check(measuredContinuationPeers == [1],"only the actual font/CC-proven continuation is excluded from independent-peer borrowing")
    check(completeColumn != nil,"RF/CC-confirmed column continuation provides an actual source-pixel crop")
    if let q=completeColumn {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! > 90,
            "a font-supported complete detector component can extend beyond an overlapping fragment boundary")
    }
    let joined=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,detectorSeedEvidence:evidence)
    func pointTrainImage(white:Bool,irregular:Bool=false,shift:CGFloat=0,long:Bool=false,followingGlyph:Bool=false,distractor:Bool=false)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let ys:[CGFloat]=long ? stride(from:128,through:284,by:12).map { CGFloat($0) }:
                (irregular ? [128,140,152,176,200]:[128,140,152,164,176,188])
            let foreground=CGRect(x:155,y:105,width:10,height:12).contains(p) ||
                (distractor && CGRect(x:153,y:158,width:3,height:3).contains(p)) ||
                (followingGlyph && CGRect(x:154,y:198,width:12,height:16).contains(p)) ||
                ys.contains { CGRect(x:158,y:$0+shift,width:4,height:4).contains(p) }
            let c:[UInt8]=foreground ? (white ? [255,255,255]:[0,0,0]):(white ? [105,55,155]:[255,255,255])
            let i=(y*side+x)*4
            for k in 0..<3 { bytes[i+k]=c[k] }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    for white in [false,true] {
        let style=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(white ? [255,255,255]:[0,0,0])
        let train=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[joined],
            frame:pointTrainImage(white:white),inkStyle:style)
        check(train != nil,"a source-rooted point train completes in either print polarity")
        if let q=train {
            let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
            check(end >= 33 && end <= 37,"a point train stops at its measured final dot at every angle")
        }
        let lateTrainMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,
            resizedWidth:side,resizedHeight:side,region:CGRect(x:0,y:0,width:side,height:side),
            width:side,height:side,values:[Float](repeating:0,count:side*side))
        let lateTrains=NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[joined],
            frame:pointTrainImage(white:white),probability:lateTrainMap,inkStyles:[style],retained:[0],
            peerPolygons:[0:polygon],excluding:[],pointTrainParents:[0])
        check(lateTrains.count==1 && lateTrains[0].measuredTerminalOnly && lateTrains[0].sourceTailCompletion,
            "a retained word crop reuses its immutable ink palette to complete a source-proven train")
        let symbolicPlans=NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[joined],
            frame:pointTrainImage(white:white),probability:lateTrainMap,inkStyles:[style],retained:[0],
            peerPolygons:[0:polygon],excluding:[],pointTrainParents:[0],symbolicParents:[0])
        check(symbolicPlans.count==1 && symbolicPlans[0].symbolicTerminalOnly,
            "source-rooted punctuation uses the same train evidence at every angle and polarity")
        if let plan=symbolicPlans.first,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(polygon) {
            let q=f.bounds(plan.polygon),a=f.bounds(plan.samplings[0]),b=f.bounds(plan.samplings[1])
            check(a.width > q.width && b.width > a.width && abs(a.height-q.height)<0.01 && abs(b.height-q.height)<0.01,
                "independent symbol sampling widens only the intrinsic normal and leaves the measured terminal span unchanged")
        }
        if let q=lateTrains.first?.polygon,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(polygon) {
            check(abs(f.bounds(q).minX-f.rect.minX)<0.01 && abs(f.bounds(q).maxX-f.rect.maxX)<0.01,
                "a late source point-train proof cannot widen the column")
            check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[joined],
                frame:pointTrainImage(white:white),probability:lateTrainMap,inkStyles:[style],retained:[0],
                peerPolygons:[0:polygon],excluding:[],representedSpans:[0:[q]],pointTrainParents:[0]).isEmpty,
                "an existing complete group prevents redundant member-only point-train replacement")
        }
        check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[joined],
            frame:pointTrainImage(white:white,irregular:true),probability:lateTrainMap,inkStyles:[style],retained:[0],
            peerPolygons:[0:polygon],excluding:[],pointTrainParents:[0]).isEmpty,
            "post-recognition scheduling cannot turn irregular marks into a point train")
        let longTrain=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[joined],
            frame:pointTrainImage(white:white,long:true),inkStyle:style)
        check(longTrain != nil,"a source-rooted uniform point train can continue beyond the initial observation window")
        if let q=longTrain {
            let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
            check(end >= 129 && end <= 133,"adaptive observation stops at the measured final point rather than its search radius")
        }
        check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[joined],
            frame:pointTrainImage(white:white,irregular:true),inkStyle:style)==nil,
            "irregular isolated marks cannot invent a continued punctuation train")
    }
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[joined],
        frame:pointTrainImage(white:false),inkStyle:.init(colors:[[255,255,255],[0,0,0]])) != nil,
        "source-established secondary ink completes a train even when its primary colour is connected")
    let shortBeforePoints=NativeCoreMLDetectionBox(polygon:rect(150,100,20,22).map(turn),
        score:0.9,detectorSeedEvidence:evidence)
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0])) != nil,
        "a complete private glyph roots a directly adjoining missed point train at every angle")
    for white in [false,true] {
        let oldPointRead=rect(150,100,20,34).map(turn)
        let cutPointRead=rect(150,100,20,22).map(turn)
        let keptPoints=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
            frame:pointTrainImage(white:white),inkStyle:.init(white ? [255,255,255]:[0,0,0]),
            sourceWindow:cutPointRead,observedSource:oldPointRead)
        check(keptPoints != nil,"a proposed shorter read cannot make already observed source-rooted dots cease to exist")
        if let keptPoints,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(oldPointRead) {
            check(f.bounds(keptPoints).maxY >= f.rect.maxY,
                "the measured train veto includes every previously observed dot in either ink polarity")
        }
        let wideObservedRead=rect(150,100,20,94).map(turn)
        check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
            frame:pointTrainImage(white:white,shift:24),inkStyle:.init(white ? [255,255,255]:[0,0,0]),
            sourceWindow:cutPointRead,observedSource:wideObservedRead)==nil,
            "remote periodic print still cannot authorize new word growth")
        let oldPointVeto=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
            frame:pointTrainImage(white:white,shift:24),inkStyle:.init(white ? [255,255,255]:[0,0,0]),
            sourceWindow:cutPointRead,observedSource:wideObservedRead,protectingObservedPoints:true)
        check(oldPointVeto != nil,"visible periodic print already inside an actual read vetoes erasing it despite an unresolved growth root")
        if let oldPointVeto,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(wideObservedRead) {
            let cap=f.bounds(oldPointVeto)
            check(cap.minY >= f.rect.minY-0.001 && cap.maxY <= f.rect.maxY+0.001 && cap.maxY > 80,
                "observed point protection is clamped to old print and cannot acquire the rest of an external train")
        }
    }
    func observedStemPoints(shift:CGFloat=0,wrongStem:Bool=false)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let stem=CGRect(x:158,y:120+shift,width:4,height:28).contains(p)
            let printInk=CGRect(x:155,y:105,width:10,height:12).contains(p) ||
                [158,170,182,194,206,218].contains { CGRect(x:158,y:CGFloat($0)+shift,width:4,height:4).contains(p) }
            let c:[UInt8]=stem ? (wrongStem ? [0,120,150]:[0,0,0]):(printInk ? [0,0,0]:[255,255,255])
            for k in 0..<3 { bytes[(y*side+x)*4+k]=c[k] }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
        frame:observedStemPoints(),inkStyle:.init([0,0,0])) == nil,
        "a detector-only stem does not broaden the established pre-recognition endpoint rule")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
        frame:observedStemPoints(),inkStyle:.init([0,0,0]),observedSource:shortBeforePoints.polygon) != nil,
        "an actual retained word can nominate a directly adjacent measured terminal stem and dots")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
        frame:observedStemPoints(shift:24),inkStyle:.init([0,0,0]),observedSource:shortBeforePoints.polygon) == nil,
        "retained-word nomination cannot bridge a remote stem and dot pattern")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
        frame:observedStemPoints(wrongStem:true),inkStyle:.init([0,0,0]),observedSource:shortBeforePoints.polygon) == nil,
        "retained-word nomination cannot use a differently coloured stem")
    let firstPointOwned=NativeCoreMLDetectionBox(polygon:rect(150,100,20,34).map(turn),
        score:0.9,detectorSeedEvidence:evidence)
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[firstPointOwned],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0])) != nil,
        "one genuinely private source dot can root the remaining uniform point train")
    let sparseRoot=NativeCoreMLDetectionBox(polygon:shortBeforePoints.polygon,score:0.9,
        detectorSeedEvidence:contextEvidence(9,CGRect(x:156,y:105,width:8,height:6)))
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0])) != nil,
        "an observed private-connected glyph cap roots its dots even when DB seeds stop inside the glyph")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),sourceWindow:rect(150,100,20,48).map(turn)) != nil,
        "a group that already encloses initial dots still measures their root from its source glyph rather than its group edge")
    let dotParts=[CGFloat(128),140,152,164,176,188].map { contextEvidence(41,CGRect(x:158,y:$0,width:4,height:4)).components[0] }
    let dotSource=NativeOCRDetectorSeedEvidence(ownerID:"unread-point-source",parentBoxIndex:1,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:dotParts,
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let unreadDotBox=NativeCoreMLDetectionBox(polygon:rect(156,126,8,68).map(turn),score:0.9,detectorSeedEvidence:dotSource)
    var dotSourceOwners=Set<Int>()
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot,unreadDotBox],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),observedSource:sparseRoot.polygon,
        unreadPeers:[1],pointSourceObserver:{dotSourceOwners.formUnion($0)}) != nil && dotSourceOwners == [1],
        "an unread private DB source consisting of the same measured regular dots transfers ownership at every angle")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot,unreadDotBox],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),observedSource:sparseRoot.polygon) == nil,
        "a retained point peer remains an independent private-ink barrier")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot,unreadDotBox],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),unreadPeers:[1]) == nil,
        "unread point ownership cannot alter pre-recognition crops")
    let foreignLetter=NativeCoreMLDetectionBox(polygon:unreadDotBox.polygon,score:0.9,
        detectorSeedEvidence:contextEvidence(42,CGRect(x:151,y:128,width:4,height:26)))
    var foreignOwners=Set<Int>()
    _ = NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot,foreignLetter],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),observedSource:sparseRoot.polygon,
        unreadPeers:[1],pointSourceObserver:{foreignOwners.formUnion($0)})
    check(foreignOwners.isEmpty,"unread source cells outside the actual dot footprints cannot be absorbed")
    let unreadProposals=NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[sparseRoot,unreadDotBox],
        frame:pointTrainImage(white:false),inkStyles:[.init([0,0,0]),.init([0,0,0])],retained:[0],
        peerPolygons:[0:sparseRoot.polygon],excluding:[])
    check(unreadProposals.count==1 && unreadProposals[0].pointSources == [1],
        "a full measured point-source alias reaches the actual two-recognition proposal")
    check(NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[sparseRoot,unreadDotBox],
        frame:pointTrainImage(white:false),inkStyles:[.init([0,0,0]),.init([0,0,0])],retained:[0],
        peerPolygons:[0:sparseRoot.polygon,1:unreadDotBox.polygon],excluding:[]).isEmpty,
        "an independently retained point source cannot use the unread-source alias path")
    var noisyOwners=Set<Int>()
    let noisyTrain=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot,unreadDotBox],
        frame:pointTrainImage(white:false,distractor:true),inkStyle:.init([0,0,0]),observedSource:sparseRoot.polygon,
        unreadPeers:[1],pointSourceObserver:{noisyOwners.formUnion($0)})
    check(noisyTrain != nil && noisyOwners == [1],
        "off-column tiny ink cannot split an otherwise regular measured point source")
    if let q=noisyTrain {
        check(NativeOCRDirectionGeometry.contains(q,turn(CGPoint(x:160,y:190))),
            "the actual final point remains inside the measured crop despite interleaved off-column ink")
    }
    let connectedPointBox=NativeCoreMLDetectionBox(polygon:unreadDotBox.polygon,score:0.9,
        detectorSeedEvidence:contextEvidence(44,CGRect(x:158,y:128,width:4,height:64)))
    var connectedOwners=Set<Int>()
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot,connectedPointBox],
        frame:pointTrainImage(white:false,distractor:true),inkStyle:.init([0,0,0]),observedSource:sparseRoot.polygon,
        unreadPeers:[1],pointSourceObserver:{connectedOwners.formUnion($0)}) != nil && connectedOwners == [1],
        "a DB-connected outline between genuine regular points stays inside their measured half-pitch footprints")
    let clippedCapBox=NativeCoreMLDetectionBox(polygon:rect(150,100,20,11).map(turn),score:0.9,
        detectorSeedEvidence:contextEvidence(45,CGRect(x:156,y:105,width:8,height:6)))
    let observedCapWord=rect(150,100,20,22).map(turn)
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[clippedCapBox],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),sourceWindow:observedCapWord) == nil,
        "unread crops retain the immutable raw detector limit for their connected glyph cap")
    let recoveredCapTrain=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[clippedCapBox],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),sourceWindow:observedCapWord,observedSource:observedCapWord)
    check(recoveredCapTrain.map { NativeOCRDirectionGeometry.contains($0,turn(CGPoint(x:160,y:190))) } ?? false,
        "an actual word's privately connected cap roots its adjacent final dots beyond a clipped raw detector at every angle")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[clippedCapBox],
        frame:pointTrainImage(white:false,shift:24),inkStyle:.init([0,0,0]),sourceWindow:observedCapWord,
        observedSource:observedCapWord) == nil,"an observed cap cannot root a remote point train outside its read")
    func splitGlyphPoints()->NativeOCRRGBAFrame {
        var bytes=pointTrainImage(white:false).bytes
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            if CGRect(x:150,y:100,width:20,height:24).contains(p) {
                let black=CGRect(x:155,y:104,width:4,height:4).contains(p) || CGRect(x:156,y:115,width:12,height:5).contains(p)
                for k in 0..<3 { bytes[(y*side+x)*4+k]=black ? 0:255 }
            }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    func sharedCapBox(_ component:NativeOCRDetectorSeedEvidence.Component)->NativeCoreMLDetectionBox {
        let shared=NativeOCRDetectorSeedEvidence(ownerID:"shared-cap",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[component],candidateComponents:[])
        return .init(polygon:clippedCapBox.polygon,score:0.9,detectorSeedEvidence:shared)
    }
    let splitCap=sharedCapBox(contextEvidence(46,CGRect(x:156,y:106,width:7,height:14)).components[0])
    let splitCapTrain=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[splitCap],frame:splitGlyphPoints(),
        inkStyle:.init([0,0,0]),sourceWindow:observedCapWord,observedSource:observedCapWord)
    check(splitCapTrain.map { NativeOCRDirectionGeometry.contains($0,turn(CGPoint(x:160,y:190))) } ?? false,
        "a narrow shared DB component roots the actual word's disconnected final stroke beyond its clipped raw rectangle")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[splitCap],frame:splitGlyphPoints(),
        inkStyle:.init([0,0,0]),sourceWindow:observedCapWord) == nil,
        "an unread shared component receives no outside-raw sampling permission")
    let broadCap=sharedCapBox(contextEvidence(47,CGRect(x:145,y:106,width:30,height:14)).components[0])
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[broadCap],frame:splitGlyphPoints(),
        inkStyle:.init([0,0,0]),sourceWindow:observedCapWord,observedSource:observedCapWord) == nil,
        "a broad shared detector component cannot borrow an otherwise disconnected final stroke")
    let detachedCap=sharedCapBox(contextEvidence(48,CGRect(x:161,y:115,width:4,height:5)).components[0])
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[detachedCap],frame:splitGlyphPoints(),
        inkStyle:.init([0,0,0]),sourceWindow:observedCapWord,observedSource:observedCapWord) == nil,
        "a component with no measured contact inside the raw source cannot become a word anchor")
    let groupFirstEvidence=contextEvidence(0,CGRect(x:155,y:104,width:4,height:4))
    let groupLastEvidence=contextEvidence(1,CGRect(x:156,y:115,width:12,height:5))
    let groupFirst=NativeCoreMLDetectionBox(polygon:clippedCapBox.polygon,score:0.9,detectorSeedEvidence:groupFirstEvidence)
    let groupLast=NativeCoreMLDetectionBox(polygon:rect(156,115,12,5).map(turn),score:0.9,detectorSeedEvidence:groupLastEvidence)
    let groupBox=NativeCoreMLDetectionBox(polygon:observedCapWord,score:0.9)
    let originalGroup=NativeOCRRFPrimaryEnsemble.Group(index:2,members:[0,1],evidence:[groupFirstEvidence,groupLastEvidence])
    let groupTails=NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[groupFirst,groupLast,groupBox],
        frame:splitGlyphPoints(),inkStyles:[.init([0,0,0]),.init([0,0,0]),nil],retained:[2],
        peerPolygons:[2:observedCapWord],excluding:[],groups:[originalGroup])
    check(groupTails.count==1 && groupTails[0].parent==2 && groupTails[0].pointTailOnly &&
        NativeOCRDirectionGeometry.contains(groupTails[0].polygon,turn(CGPoint(x:160,y:190))),
        "an actual grouped word measures its final member's private pixels in the whole word frame without a synthetic seed")
    check(NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[groupFirst,groupLast,groupBox],
        frame:splitGlyphPoints(),inkStyles:[.init([0,0,0]),.init([0,0,0]),nil],retained:[2],
        peerPolygons:[2:observedCapWord],excluding:[]).isEmpty,
        "a synthetic crop cannot acquire member pixels without original group ownership")
    let independentPoint=NativeCoreMLDetectionBox(polygon:rect(156,162,8,8).map(turn),score:0.9,
        detectorSeedEvidence:contextEvidence(3,CGRect(x:158,y:164,width:4,height:4)))
    check(NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[groupFirst,groupLast,groupBox,independentPoint],
        frame:splitGlyphPoints(),inkStyles:[.init([0,0,0]),.init([0,0,0]),nil,.init([0,0,0])],retained:[2],
        peerPolygons:[2:observedCapWord,3:independentPoint.polygon],excluding:[],groups:[originalGroup]).isEmpty,
        "a grouped word's member access does not consume an independently retained peer's point pixels")

    func gradientGroupImage(foreign:Bool=false)->NativeOCRRGBAFrame {
        var bytes=splitGlyphPoints().bytes
        for y in 0..<side { for x in 0..<side where bytes[(y*side+x)*4] == 0 {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let c:[UInt8]=CGRect(x:156,y:115,width:12,height:5).contains(p)
                ? (foreign ? [240,30,30]:[14,134,208]):[8,137,218]
            for k in 0..<3 { bytes[(y*side+x)*4+k]=c[k] }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    let gradientTails=NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[groupFirst,groupLast,groupBox],
        frame:gradientGroupImage(),inkStyles:[.init([8,137,218]),.init([14,134,208]),nil],retained:[2],
        peerPolygons:[2:observedCapWord],excluding:[],groups:[originalGroup])
    check(gradientTails.count==1 && NativeOCRDirectionGeometry.contains(gradientTails[0].polygon,turn(CGPoint(x:160,y:190))),
        "actual group colours recalibrate a connected final member whose small colour shift otherwise misses its own points")
    check(NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[groupFirst,groupLast,groupBox],
        frame:gradientGroupImage(foreign:true),inkStyles:[.init([8,137,218]),.init([240,30,30]),nil],retained:[2],
        peerPolygons:[2:observedCapWord],excluding:[],groups:[originalGroup]).isEmpty,
        "group palette sharing cannot root a point layer absent from the actual final member's colour samples")

    let aliasComponent=contextEvidence(50,CGRect(x:46,y:185,width:4,height:16)).components[0]
    let aliasPrivate=contextEvidence(51,CGRect(x:44,y:70,width:8,height:70)).components[0]
    let aliasParentEvidence=NativeOCRDetectorSeedEvidence(ownerID:"shared-alias-word",parentBoxIndex:0,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[aliasPrivate],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[aliasComponent],candidateComponents:[])
    let aliasParentBox=NativeCoreMLDetectionBox(polygon:rect(40,60,16,130).map(turn),score:0.9,detectorSeedEvidence:aliasParentEvidence)
    let aliasOutside=aliasComponent.runs.reduce(0) { n,r in n+(r.x..<(r.x+r.count)).filter { x in
        !NativeOCRDirectionGeometry.contains(aliasParentBox.polygon,CGPoint(x:CGFloat(x)+0.5,y:CGFloat(r.y)+0.5))
    }.count }
    func aliasChild(_ privateParts:[NativeOCRDetectorSeedEvidence.Component]=[],multiple:Bool=false)->NativeOCRDetectorSeedEvidence {
        .init(ownerID:"shared-alias-child",parentBoxIndex:1,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:privateParts,ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[.init(
                component:aliasComponent,competingOwnerIDs:multiple ? [aliasParentEvidence.ownerID,"another-word"]:[aliasParentEvidence.ownerID],
                outsideCompetingCells:multiple ? [aliasOutside,aliasOutside]:[aliasOutside])])
    }
    let aliasChildBox=NativeCoreMLDetectionBox(polygon:rect(44,183,8,22).map(turn),score:0.9,detectorSeedEvidence:aliasChild())
    func aliasOwners(_ reads:[NativeCoreMLRecognizedRegion],_ evidence:[Int:[NativeOCRDetectorSeedEvidence]],
                     _ boxes:[NativeCoreMLDetectionBox])->[Int:Int] {
        NativeOCRRFPrimaryEnsemble.containedSharedSourceOwners(reads:reads,evidence:evidence,boxes:boxes,recognitionThreshold:0.4)
    }
    check(aliasOwners([pointWord],[0:[aliasParentEvidence]],[aliasParentBox,aliasChildBox]) == [1:0],
        "an unread alias of the same fully represented narrow component preserves provenance without adding a duplicate read")
    let privateChild=NativeCoreMLDetectionBox(polygon:aliasChildBox.polygon,score:0.9,
        detectorSeedEvidence:aliasChild([contextEvidence(52,CGRect(x:45,y:202,width:2,height:2)).components[0]]))
    check(aliasOwners([pointWord],[0:[aliasParentEvidence]],[aliasParentBox,privateChild]).isEmpty,
        "a shared candidate plus independent private ink cannot be silently transferred")
    let contestedChild=NativeCoreMLDetectionBox(polygon:aliasChildBox.polygon,score:0.9,detectorSeedEvidence:aliasChild(multiple:true))
    check(aliasOwners([pointWord],[0:[aliasParentEvidence]],[aliasParentBox,contestedChild]).isEmpty,
        "an unread component contested by different original owners has no unique word assignment")
    let croppedAliasWord=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:aliasParentBox.polygon,text:pointWord.text,confidence:0.95)
    check(aliasOwners([croppedAliasWord],[0:[aliasParentEvidence]],[aliasParentBox,aliasChildBox]).isEmpty,
        "a word that has not actually included the entire shared glyph cannot claim that source")
    let duplicateAliasWord=NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:pointWord.polygon,text:pointWord.text,confidence:0.95)
    check(aliasOwners([pointWord,duplicateAliasWord],[0:[aliasParentEvidence],2:[aliasParentEvidence]],
        [aliasParentBox,aliasChildBox]).isEmpty,"two covering reads do not establish unique alias ownership")
    let representedAlias=NativeCoreMLRecognizedRegion(sourceIndex:2,polygon:aliasChildBox.polygon,text:"…",confidence:0.9)
    check(aliasOwners([pointWord,representedAlias],[0:[aliasParentEvidence],2:[aliasChild()]],
        [aliasParentBox,aliasChildBox]).isEmpty,"an owner already represented by another retained read cannot be reassigned")
    check(aliasOwners([pointWord],[0:[aliasParentEvidence,contextEvidence(53,CGRect(x:44,y:145,width:4,height:8))]],
        [aliasParentBox,aliasChildBox]) == [1:0],"existing multi-source words preserve their other owners while adopting only the exact shared alias")
    let stablePeer=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:rect(40,60,16,180).map(turn),text:"あいう...",confidence:0.95)
    let stableSpan=NativeOCRContextualColumnRecovery.unchangedObservedWordSpan(before:pointWord,after:stablePeer,threshold:0.4)
    check(stableSpan==pointWord.polygon,"a word-preserving point recovery keeps its previously observed glyph span for concurrent ownership checks")
    check(!NativeOCRContextualColumnRecovery.samplesObservedGlyph([stablePeer.polygon],peerPolygon:stablePeer.polygon,
        evidence:aliasParentEvidence,excludingPolygon:stableSpan),
        "already observed private word pixels are not newly acquired solely because another point proposal committed first")
    check(NativeOCRContextualColumnRecovery.samplesObservedGlyph([stablePeer.polygon],peerPolygon:stablePeer.polygon,
        evidence:contextEvidence(54,CGRect(x:46,y:215,width:4,height:8)),excludingPolygon:stableSpan),
        "fresh private glyph pixels outside the original observed word remain strict barriers")
    let changedPeer=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:stablePeer.polygon,text:"あいえ...",confidence:0.95)
    check(NativeOCRContextualColumnRecovery.unchangedObservedWordSpan(before:pointWord,after:changedPeer,threshold:0.4)==nil,
        "a changed word identity receives the full private-glyph recheck")
    let formerPoints=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:pointWord.polygon,text:"…",confidence:0.9)
    check(NativeOCRContextualColumnRecovery.unchangedObservedWordSpan(before:formerPoints,after:stablePeer,threshold:0.4)==nil,
        "a former punctuation hallucination does not establish ownership of a freshly recovered word")
    check(NativeOCRContextualColumnRecovery.unchangedObservedWordSpan(before:nil,after:stablePeer,threshold:0.4)==nil,
        "a newly admitted neighbor keeps its complete ownership barrier")
    let sharedOnlyEvidence=NativeOCRDetectorSeedEvidence(ownerID:"shared-word",parentBoxIndex:0,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:sparseRoot.detectorSeedEvidence!.components,
        candidateComponents:[])
    let sharedWord=NativeCoreMLDetectionBox(polygon:sparseRoot.polygon,score:0.9,detectorSeedEvidence:sharedOnlyEvidence)
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sharedWord],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0])) == nil,
        "unrecognized shared detector cells cannot authorize point recovery")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sharedWord],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),observedSource:sharedWord.polygon) != nil,
        "an actual retained word may root its RGB points from shared cells strictly inside its source")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sharedWord],
        frame:pointTrainImage(white:false),inkStyle:.init([0,0,0]),observedSource:rect(20,20,10,20).map(turn)) == nil,
        "shared source cells outside the actual retained polygon cannot become anchors")
    check(NativeOCRContextualColumnRecovery.samplesObservedGlyph([sharedWord.polygon],
        peerPolygon:sharedWord.polygon,evidence:sparseRoot.detectorSeedEvidence!),
        "the ordinary ownership recheck still sees private peer glyphs")
    check(!NativeOCRContextualColumnRecovery.samplesObservedGlyph([sharedWord.polygon],
        peerPolygon:sharedWord.polygon,evidence:sparseRoot.detectorSeedEvidence!,excludingPolygon:sharedWord.polygon),
        "retained tail admission distinguishes existing overlap from newly sampled peer ink")
    let sharedComponent=sparseRoot.detectorSeedEvidence!.components[0]
    let candidatePeer=NativeOCRDetectorSeedEvidence(ownerID:"candidate-peer",parentBoxIndex:1,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[.init(
            component:sharedComponent,competingOwnerIDs:["shared-word"],outsideCompetingCells:[sharedComponent.pixelCount-1])])
    check(NativeOCRContextualColumnRecovery.samplesObservedGlyph([sharedWord.polygon],
        peerPolygon:sharedWord.polygon,evidence:candidatePeer),
        "uncontested exclusive candidates remain peer barriers")
    check(!NativeOCRContextualColumnRecovery.samplesObservedGlyph([sharedWord.polygon],
        peerPolygon:sharedWord.polygon,evidence:candidatePeer,contestedCandidateSeeds:[sharedComponent.seed]),
        "a CC contested by the current retained word is not promoted to a peer's private glyph")
    check(NativeOCRContextualColumnRecovery.samplesObservedGlyph([sharedWord.polygon],
        peerPolygon:sharedWord.polygon,evidence:sparseRoot.detectorSeedEvidence!,contestedCandidateSeeds:[sharedComponent.seed]),
        "contested candidate filtering never disables actual private peer cells")
    let boundedPoints=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot],
        frame:pointTrainImage(white:false,followingGlyph:true),inkStyle:.init([0,0,0]),observedSource:sparseRoot.polygon)
    check(boundedPoints != nil,"a following ordinary glyph does not prevent recovery of the genuine preceding dots")
    if let boundedPoints {
        let end=boundedPoints.map { ($0.x-160)*(-sine)+($0.y-160)*cosine+160 }.max()!
        check(end >= 192 && end <= 196,"late point completion stops before a following full-width glyph")
    }
    let pointProposals=NativeOCRContextualColumnRecovery.retainedPointTails(boxes:[sharedWord],
        frame:pointTrainImage(white:false),inkStyles:[.init([0,0,0])],retained:[0],
        peerPolygons:[0:sharedWord.polygon],excluding:[])
    check(pointProposals.count==1 && pointProposals[0].pointTailOnly,
        "retained point recovery requests two real reads with a punctuation-only admission rule")
    if let proposal=pointProposals.first,let local=NativeOCRRFPrimaryEnsemble.EndpointFrame(sharedWord.polygon) {
        let projected=local.bounds(proposal.polygon)
        check(abs(projected.minY-local.rect.minY)<0.001 && abs(projected.width-local.rect.width)<0.001,
            "a retained point proposal preserves its original head and reading width at every angle")
    }
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseRoot],
        frame:pointTrainImage(white:false,shift:24),inkStyle:.init([0,0,0])) == nil,
        "using the actual glyph cap does not turn a remote uniform texture into a continuation")
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[shortBeforePoints],
        frame:pointTrainImage(white:false,shift:24),inkStyle:.init([0,0,0])) == nil,
        "a remote regular point pattern is not rooted at the private glyph")
    func connectedOutlinePoints()->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let body=CGRect(x:153,y:103,width:14,height:12).contains(p)
            let bodyCounter=CGRect(x:155,y:105,width:10,height:8).contains(p)
            let border=CGRect(x:156,y:124,width:8,height:72).contains(p)
            let hole=[128,140,152,164,176,188].contains { CGRect(x:158,y:$0,width:4,height:4).contains(p) }
            let white=body && !bodyCounter || border && !hole
            let c:[UInt8]=white ? [255,255,255]:[130,70,40]
            for k in 0..<3 { bytes[(y*side+x)*4+k]=c[k] }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    let outlinedTrain=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[joined],
        frame:connectedOutlinePoints(),inkStyle:.init([255,255,255]))
    check(outlinedTrain != nil,"a connected printed outline still exposes its repeated closed point counters")
    if let q=outlinedTrain {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 35 && end <= 39,"counter completion includes the actual printed outline cap, not just its inner fill")
    }
    let sparseOutlineRoot=NativeCoreMLDetectionBox(polygon:shortBeforePoints.polygon,score:0.9,
        detectorSeedEvidence:contextEvidence(11,CGRect(x:153,y:103,width:14,height:2)))
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[sparseOutlineRoot],
        frame:connectedOutlinePoints(),inkStyle:.init([255,255,255]),sourceWindow:joined.polygon) != nil,
        "closed point counters use the observed print cap even when their private seeds stop in the glyph's upper border")
    func neutralOutlineImage(_ kind:Int)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let fill=(0..<4).contains { CGRect(x:kind>=25 ? 155:153,y:(kind>=25 ? 105:103)+$0*20,
                width:kind>=25 ? 10:14,height:kind>=25 ? 8:12).contains(p) }
            let outline=(0..<4).contains { CGRect(x:151,y:101+$0*20,width:18,height:16).contains(p) }
            let bar:Bool
            switch kind {
            case 1:bar=CGRect(x:150,y:177,width:20,height:78).contains(p)
            case 2:bar=CGRect(x:158,y:215,width:3,height:70).contains(p)
            case 3:bar=CGRect(x:158,y:177,width:3,height:160).contains(p)
            case 4:bar=CGRect(x:158,y:30,width:3,height:71).contains(p)
            case 5:bar=CGRect(x:158,y:177,width:3,height:78).contains(p)
            case 6:bar=CGRect(x:158,y:190,width:3,height:70).contains(p)
            case 7,9,10,11,13:
                let dots=(0..<3).contains { CGRect(x:159,y:181+$0*8,width:3,height:3).contains(p) }
                let corner=CGRect(x:154,y:207,width:2,height:8).contains(p) || CGRect(x:154,y:213,width:kind==13 ? 20:12,height:2).contains(p)
                bar=(kind != 11 && dots) || corner
            case 8:bar=CGRect(x:154,y:207,width:2,height:8).contains(p) || CGRect(x:154,y:213,width:12,height:2).contains(p)
            case 12:bar=CGRect(x:140,y:207,width:40,height:3).contains(p) || (0..<3).contains { CGRect(x:159,y:181+$0*8,width:3,height:3).contains(p) }
            case 14:bar=CGRect(x:153,y:207,width:14,height:3).contains(p) || (0..<3).contains { CGRect(x:159,y:181+$0*8,width:3,height:3).contains(p) }
            case 15,16,17,18,19:bar=false
            case 20...24:bar=false
            case 25:bar=CGRect(x:159,y:177,width:1,height:78).contains(p)
            case 26:bar=CGRect(x:158,y:177,width:4,height:78).contains(p)
            default:bar=CGRect(x:158,y:177,width:3,height:78).contains(p)
            }
            let dotBorder=kind >= 9 && kind != 11 && (0..<3).contains { CGRect(x:159,y:181+$0*8,width:3,height:3).insetBy(dx:-2,dy:-2).contains(p) }
            let cornerBorder=kind==12 ? CGRect(x:140,y:205,width:40,height:7).contains(p) : kind >= 9 && (CGRect(x:154,y:207,width:2,height:8).insetBy(dx:-2,dy:-2).contains(p) || CGRect(x:154,y:213,width:kind==13 ? 20:12,height:2).insetBy(dx:-2,dy:-2).contains(p))
            let c:[Int]
            if (20...24).contains(kind) {
                let stem=kind != 21 && CGRect(x:158,y:kind==24 ? 83:177,width:4,height:kind==24 ? 20:24).contains(p)
                let dot=CGRect(x:kind==22 ? 145:158,y:kind==24 ? 75:205,width:4,height:4).contains(p)
                let paper=[105+Int((p.y-100)*0.1),65,135]
                c=fill || stem ? [252,254,253]:dot ? (kind==23 ? [165,165,165]:[252,254,253]):paper
            } else if kind >= 25 {
                c=bar || outline && !fill ? [252,254,253]:fill ? [15,50,120]:[100,130,170]
            } else if (15...19).contains(kind) {
                let stem=kind != 19 && CGRect(x:158,y:kind>=18 ? 181:175,width:4,height:kind>=18 ? 19:25).contains(p)
                let dot=CGRect(x:158,y:205,width:4,height:4).contains(p)
                let halo=(kind>=18 && CGRect(x:140,y:178,width:40,height:33).contains(p)) || CGRect(x:156,y:171,width:8,height:33).contains(p) ||
                    (kind != 17 && CGRect(x:156,y:203,width:8,height:8).contains(p))
                let open=kind==16 && CGRect(x:140,y:181,width:40,height:31).contains(p)
                c=fill || stem || dot || open ? [15,50,120]:outline || halo ? [252,254,253]:[100,130,170]
            } else if kind >= 9 {
                c=bar || fill ? [252,254,253] : cornerBorder && kind==10 ? [180,40,100] : (kind==14 && CGRect(x:140,y:196,width:40,height:11).contains(p)) || outline || dotBorder || (kind != 14 && cornerBorder) ? [15,50,120]:[100,130,170]
            } else {
                c=bar ? (kind==5 ? [245,228,240]:[252,254,253]) : fill ? [15,50,120] : outline ? [252,254,253] : [100,130,170]
            }
            let cell=(y*side+x)*4
            for k in 0..<3 { bytes[cell+k]=UInt8(c[k]) }
        } }
        return NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
    }
    var markValues=[Float](repeating:0,count:side*side),foreignMarkRuns:[NativeOCRDetectorSeedEvidence.Run]=[]
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        let fill=(0..<4).contains { CGRect(x:153,y:103+$0*20,width:14,height:12).contains(p) }
        let dot=(0..<3).contains { CGRect(x:159,y:181+$0*8,width:3,height:3).contains(p) }
        let corner=CGRect(x:154,y:207,width:2,height:8).contains(p) || CGRect(x:154,y:213,width:12,height:2).contains(p)
        if fill { markValues[y*side+x]=1 }
        else if dot || corner { markValues[y*side+x]=0.08 }
        if corner { foreignMarkRuns.append(.init(y:y,x:x,count:1)) }
    } }
    let markMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:markValues)
    let blankMarkMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:[Float](repeating:0,count:side*side))
    let markSupport=rect(150,100,20,120).map(turn)
    let neutralCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(7),
        detectorSupport:markSupport,probability:markMap,pixelThreshold:0.05)
    check(neutralCorner != nil,"detector-supported neutral marks can continue after a source-rooted dot trail")
    if let q=neutralCorner {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 54 && end <= 62,"a neutral corner's complete visible cap survives at every angle")
    }
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(7),
        detectorSupport:markSupport,probability:blankMarkMap,pixelThreshold:0.05)==nil,
        "RGB alone cannot certify an unowned short neutral mark")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(8),
        detectorSupport:markSupport,probability:markMap,pixelThreshold:0.05)==nil,
        "an isolated white corner has no observed source-foreground chain")
    // These source components include the observed print border, as a real
    // full-CC detector packet does; the earlier fixture owns only the fill.
    var borderedRuns:[E.Run]=[]
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if (0..<4).contains(where:{ CGRect(x:151,y:101+$0*20,width:18,height:16).contains(p) }) {
            borderedRuns.append(.init(y:y,x:x,count:1))
        }
    } }
    let borderedEvidence=E(ownerID:"fixture-bordered-core",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[.init(seed:borderedRuns[0].y*side+borderedRuns[0].x,pixelCount:borderedRuns.count,meanProbability:1,runs:borderedRuns)],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let borderedSource=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,detectorSeedEvidence:borderedEvidence)
    let borderedCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],frame:neutralOutlineImage(9),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(borderedCorner != nil,"an observed matching print border can prove a source-rooted compact chain without DB mark cells")
    let noPrivateEvidence=E(ownerID:"fixture-observed-source",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:borderedEvidence.components,candidateComponents:[])
    let observedOnlyBox=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,detectorSeedEvidence:noPrivateEvidence)
    let observedAnchors=borderedRuns.map { CGPoint(x:CGFloat($0.x)+0.5,y:CGFloat($0.y)+0.5) }
    let sourceOnlyCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[observedOnlyBox],
        frame:neutralOutlineImage(9),probability:blankMarkMap,pixelThreshold:0.05,observedSourceInk:observedAnchors)
    check(sourceOnlyCorner==borderedCorner && sourceOnlyCorner != nil,
        "separately certified source pixels prove the same cap without inventing private detector cells")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[observedOnlyBox],
        frame:neutralOutlineImage(9),probability:blankMarkMap,pixelThreshold:0.05)==nil,
        "a factory with no private cells and no observed source proof still cannot grow a terminal")
    let normalBodyEvidence=E(ownerID:"fixture-normal-source",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],
        candidateComponents:borderedEvidence.components.map { c in
            .init(component:c,competingOwnerIDs:["unretained-neighbour"],outsideCompetingCells:[c.pixelCount*9/10])
        })
    let normalBodyBox=rect(145,98,30,105).map(turn)
    let normalBodyPlans=NativeOCRContextualColumnRecovery.retainedNormalTrims(boxes:[
        .init(polygon:normalBodyBox,score:0.65,detectorSeedEvidence:normalBodyEvidence)],frame:neutralOutlineImage(9),
        probability:blankMarkMap,inkStyles:[.init(colors:[[252,254,253],[15,50,120]])],retained:[0],
        peerPolygons:[0:normalBodyBox],excluding:[])
    check(normalBodyPlans.count==1 && normalBodyPlans[0].sourceTailCompletion && normalBodyPlans[0].sourceTerminalProof != nil,
        "the actual normal-refinement caller forwards map scope and source proof to recover an otherwise unmodelled closing corner")
    var trueCornerBytes=neutralOutlineImage(9).bytes
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if CGRect(x:148,y:203,width:24,height:22).contains(p) {
            let core=CGRect(x:154,y:207,width:2,height:8).contains(p) || CGRect(x:154,y:213,width:12,height:2).contains(p)
            let rim=CGRect(x:151,y:204,width:8,height:14).contains(p) || CGRect(x:151,y:210,width:18,height:8).contains(p)
            let colour=core ? [252,254,253]:rim ? [15,50,120]:[100,130,170]
            for c in 0..<3 { trueCornerBytes[(y*side+x)*4+c]=UInt8(colour[c]) }
        }
    } }
    for inverted in [false,true] {
        var bytes=trueCornerBytes
        if inverted {
            for p in stride(from:0,to:bytes.count,by:4) {
                if bytes[p]==252 && bytes[p+1]==254 && bytes[p+2]==253 {
                    for c in 0..<3 { bytes[p+c]=0 }
                } else if bytes[p]==15 && bytes[p+1]==50 && bytes[p+2]==120 {
                    for c in 0..<3 { bytes[p+c]=[252,254,253][c] }
                }
            }
        }
        var actualCollar:[CGPoint]=[]
        _=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[observedOnlyBox],
            frame:NativeOCRRGBAFrame(width:side,height:side,bytes:bytes)!,probability:blankMarkMap,pixelThreshold:0.05,
            inkStyle:inverted ? .init([0,0,0]):nil,observedSourceInk:observedAnchors,
            terminalInkObserver:{actualCollar+=$0})
        check(!actualCollar.isEmpty,"finite actual terminal collars are measured for either ink polarity under every rotation")
        let cap=actualCollar.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max() ?? 0
        check(cap >= 56,"terminal footprint includes the real outer collar beyond the white or black inner stroke")
        let retainedCapPlans=NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[borderedSource],
            frame:NativeOCRRGBAFrame(width:side,height:side,bytes:bytes)!,probability:blankMarkMap,
            inkStyles:[inverted ? .init([0,0,0]):.init([252,254,253])],retained:[0],
            peerPolygons:[0:polygon],excluding:[])
        check(retainedCapPlans.count==1 && retainedCapPlans[0].measuredTerminalOnly &&
            retainedCapPlans[0].sourceTailCompletion && retainedCapPlans[0].sourceTerminalProof != nil,
            "a strong retained word with no width or padding repair still nominates its actual source-proven terminal")
        if let plan=retainedCapPlans.first,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(plan.polygon) {
            let old=f.bounds(polygon)
            check(f.rect.minY <= old.minY+1e-6 && f.rect.maxY >= old.maxY-1e-6,
                "terminal completion preserves both ends of the entire old reading span")
            let end=plan.polygon.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max() ?? 0
            check(end >= 56,"retained terminal path carries the full measured source collar, not just the inner stroke")
            let groupBefore=NativeCoreMLRecognizedRegion(sourceIndex:999,polygon:polygon,text:"…あい",confidence:0.9)
            let wholeMember=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:plan.polygon,text:"…あい」",confidence:0.95)
            let groupAfter=NativeOCRContextualColumnRecovery.retainedTerminalGroup(prior:groupBefore,candidate:wholeMember,threshold:0.4)
            check(groupAfter?.sourceIndex==999 && groupAfter?.polygon==plan.polygon,
                "a complete terminal read retains its existing multi-source identity rather than discarding fragment owners")
            check(NativeOCRContextualColumnRecovery.retainedTerminalGroup(prior:groupBefore,
                candidate:.init(sourceIndex:0,polygon:plan.polygon,text:"…あう」",confidence:0.95),threshold:0.4)==nil,
                "group ownership cannot transfer to a different recognized word")
            check(NativeOCRContextualColumnRecovery.retainedTerminalGroup(prior:groupBefore,
                candidate:.init(sourceIndex:0,polygon:rect(150,160,20,40).map(turn),text:"…あい」",confidence:0.95),threshold:0.4)==nil,
                "matching text cannot transfer group ownership when the crop omits its earlier source extent")

            check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[borderedSource],
                frame:NativeOCRRGBAFrame(width:side,height:side,bytes:bytes)!,probability:blankMarkMap,
                inkStyles:[inverted ? .init([0,0,0]):.init([252,254,253])],retained:[0],
                peerPolygons:[0:polygon],excluding:[],representedSpans:[0:[plan.polygon]]).isEmpty,
                "a retained multi-source read that already encloses the terminal cannot be replaced by a member-only read")
            check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[borderedSource],
                frame:NativeOCRRGBAFrame(width:side,height:side,bytes:bytes)!,probability:blankMarkMap,
                inkStyles:[inverted ? .init([0,0,0]):.init([252,254,253])],retained:[0],
                peerPolygons:[0:polygon],excluding:[],representedSpans:[0:[polygon]]).count==1,
                "mere membership in a source group cannot veto a terminal that its existing read also clips")

        }
        check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[borderedSource],
            frame:NativeOCRRGBAFrame(width:side,height:side,bytes:bytes)!,probability:blankMarkMap,
            inkStyles:[inverted ? .init([0,0,0]):.init([252,254,253])],retained:[0],
            peerPolygons:[0:polygon],excluding:[0]).isEmpty,
            "terminal fallback cannot overwrite another already accepted geometry proof")

    }
    if let q=borderedCorner {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 54 && end <= 62,"unmodelled two-colour marks keep their actual cap at every angle")
    }
    check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[borderedSource],
        frame:neutralOutlineImage(0),probability:blankMarkMap,inkStyles:[.init([15,50,120])],
        retained:[0],peerPolygons:[0:polygon],excluding:[]).isEmpty,
        "a general long white track cannot become a compact retained-word punctuation completion")
    var onlyPointBytes=neutralOutlineImage(9).bytes
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if CGRect(x:148,y:203,width:24,height:22).contains(p) {
            for c in 0..<3 { onlyPointBytes[(y*side+x)*4+c]=[100,130,170][c] }
        }
    } }
    check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[borderedSource],
        frame:NativeOCRRGBAFrame(width:side,height:side,bytes:onlyPointBytes)!,probability:blankMarkMap,
        inkStyles:[.init([252,254,253])],retained:[0],peerPolygons:[0:polygon],excluding:[]).isEmpty,
        "a partial same-palette dot train remains with the point-train kernel, not an arbitrarily stopped compact cap")

    let fragmentWordQuad=rect(150,100,20,80).map(turn)
    let fragmentRawQuad=rect(149,190,22,49).map(turn)
    let fragmentKeptQuad=rect(149,213,22,26).map(turn)
    let fragmentBoxes:[NativeCoreMLDetectionBox]=[
        .init(polygon:fragmentWordQuad,score:0.95,detectorSeedEvidence:contextEvidence(81,CGRect(x:150,y:100,width:20,height:80))),
        .init(polygon:fragmentRawQuad,score:0.95,detectorSeedEvidence:contextEvidence(82,CGRect(x:149,y:190,width:22,height:49)))]
    let fragmentReads:[NativeCoreMLRecognizedRegion]=[
        .init(sourceIndex:0,polygon:fragmentWordQuad,text:"あい",confidence:0.9),
        .init(sourceIndex:1,polygon:fragmentKeptQuad,text:"♡",confidence:0.7)]
    let fragmentScope=rect(135,90,50,160).map(turn)
    var fragmentRF=NativeRFDETRLayoutPrimitive(queryID:81,semanticClass:.text,confidence:0.9,
        sourceBounds:NativeOCRDirectionGeometry.bounds(fragmentScope))
    fragmentRF.supportPolygon=fragmentScope
    let fragmentLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[fragmentRF])
    func fragmentImage(withInk:Bool)->NativeOCRRGBAFrame {
        var pixels=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let c=withInk && CGRect(x:153,y:194,width:15,height:12).contains(p) ? [156,67,123]:[40,40,40]
            for k in 0..<3 { pixels[(y*side+x)*4+k]=UInt8(c[k]) }
        } }
        return .init(width:side,height:side,bytes:pixels)!
    }

    let glyphBase=rect(148,100,24,100).map(turn)
    let glyphEvidence=contextEvidence(91,CGRect(x:150,y:120,width:20,height:24))
    let glyphBox=NativeCoreMLDetectionBox(polygon:glyphBase,score:0.95,detectorSeedEvidence:glyphEvidence)
    func closedGlyphImage(root:Bool=true,open:Bool=false)->NativeOCRRGBAFrame {
        var pixels=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let known=root && CGRect(x:150,y:120,width:20,height:24).contains(p)
            let next=(open ? CGRect(x:130,y:202,width:60,height:100):CGRect(x:150,y:202,width:20,height:24)).contains(p)
            let c=known || next ? [156,67,123]:[40,40,40]
            for k in 0..<3 { pixels[(y*side+x)*4+k]=UInt8(c[k]) }
        } }
        return .init(width:side,height:side,bytes:pixels)!
    }

    func competingGlyphImage()->NativeOCRRGBAFrame {
        var pixels=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let first=CGRect(x:150,y:120,width:10,height:24).contains(p) || CGRect(x:150,y:190,width:10,height:24).contains(p)
            let second=CGRect(x:162,y:120,width:10,height:24).contains(p) || CGRect(x:162,y:206,width:10,height:24).contains(p)
            let c=first ? [156,67,123]:second ? [70,140,180]:[40,40,40]
            for k in 0..<3 { pixels[(y*side+x)*4+k]=UInt8(c[k]) }
        } }
        return .init(width:side,height:side,bytes:pixels)!
    }
    let competingGlyphs=NativeOCRContextualColumnRecovery.retainedGlyphTerminals(boxes:[glyphBox],frame:competingGlyphImage(),
        inkStyles:[.init(colors:[[156,67,123],[70,140,180]])],retained:[0],peerPolygons:[0:glyphBase],excluding:[])
    check(competingGlyphs.count==1,"closed font observations with a clipped first component still nominate a completion")
    if let q=competingGlyphs.first?.polygon,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(glyphBase) {
        check(f.bounds(q).maxY < f.bounds(rect(162,206,10,24).map(turn)).maxY-5,
            "ink crossing the current cut outranks a detached following font repetition despite its closer start")
    }
    let glyphPlans=NativeOCRContextualColumnRecovery.retainedGlyphTerminals(boxes:[glyphBox],frame:closedGlyphImage(),
        inkStyles:[.init([156,67,123])],retained:[0],peerPolygons:[0:glyphBase],excluding:[])
    check(glyphPlans.count==1 && glyphPlans[0].measuredTerminalOnly && glyphPlans[0].sourceTailCompletion && !glyphPlans[0].sourceHeadCompletion,
        "a privately rooted repeated closed shape nominates one source edge completion at every rotation")
    if let q=glyphPlans.first?.polygon,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(glyphBase) {
        check(f.bounds(q).maxY >= f.bounds(rect(150,202,20,24).map(turn)).maxY,
            "the proposed glyph crop encloses all measured terminal source ink")
        let prior=NativeCoreMLRecognizedRegion(sourceIndex:99,polygon:glyphBase,text:"あいう",confidence:0.95)
        let next=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:q,text:"あいうえ",confidence:0.96)
        check(NativeOCRContextualColumnRecovery.retainedTerminalGroup(prior:prior,candidate:next,threshold:0.4)==nil,
            "the existing punctuation-only group certificate cannot admit an unproved letter")
        let unchanged=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:q,text:"あいう",confidence:0.96)
        check(NativeOCRContextualColumnRecovery.retainedTerminalGroup(prior:prior,candidate:unchanged,threshold:0.4)?.sourceIndex==99,
            "completing existing printed edges preserves the complete group's original source identity")
    }
    check(NativeOCRContextualColumnRecovery.retainedGlyphTerminals(boxes:[glyphBox],frame:closedGlyphImage(root:false),
        inkStyles:[.init([156,67,123])],retained:[0],peerPolygons:[0:glyphBase],excluding:[]).isEmpty,
        "unrelated closed paint without a private source font root cannot nominate text")
    check(NativeOCRContextualColumnRecovery.retainedGlyphTerminals(boxes:[glyphBox],frame:closedGlyphImage(open:true),
        inkStyles:[.init([156,67,123])],retained:[0],peerPolygons:[0:glyphBase],excluding:[]).isEmpty,
        "an open same-colour surface is not a closed endpoint glyph")
    let glyphPeer=NativeCoreMLDetectionBox(polygon:rect(150,202,20,24).map(turn),score:0.95,
        detectorSeedEvidence:contextEvidence(92,CGRect(x:150,y:202,width:20,height:24)))
    check(NativeOCRContextualColumnRecovery.retainedGlyphTerminals(boxes:[glyphBox,glyphPeer],frame:closedGlyphImage(),
        inkStyles:[.init([156,67,123]),nil],retained:[0],peerPolygons:[0:glyphBase,1:glyphPeer.polygon],excluding:[]).isEmpty,
        "a repeated printed glyph owned by another retained source cannot be acquired")
    let fragmentPlans=NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:fragmentBoxes,reads:fragmentReads,
        layout:fragmentLayout,frame:fragmentImage(withInk:true),inkStyles:[.init([255,255,255]),.init([156,67,123])],threshold:0.4)
    check(fragmentPlans.count==1 && fragmentPlans[0].maximumInsertedGlyphs==2,
        "a clipped retained fragment head is nominated in its writing frame despite differing fill/outline palettes")
    check(NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:fragmentBoxes,reads:fragmentReads,
        layout:fragmentLayout,frame:fragmentImage(withInk:false),inkStyles:[.init([255,255,255]),.init([156,67,123])],threshold:0.4).isEmpty,
        "detector padding with no original ink cannot nominate an intervening glyph")
    check(NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:fragmentBoxes,reads:fragmentReads,
        layout:fragmentLayout,frame:fragmentImage(withInk:true),inkStyles:[.init([255,255,255]),.init([40,40,40])],threshold:0.4).isEmpty,
        "a local paper-colour palette cannot create missing text from the background")
    let fullPageRF=NativeRFDETRLayoutPrimitive(queryID:82,semanticClass:.text,confidence:0.99,
        sourceBounds:CGRect(x:0,y:0,width:side,height:side))
    check(NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:fragmentBoxes,reads:fragmentReads,
        layout:.init(sourceWidth:side,sourceHeight:side,primitives:[fullPageRF]),frame:fragmentImage(withInk:true),
        inkStyles:[.init([255,255,255]),.init([156,67,123])],threshold:0.4).isEmpty,
        "a whole-page RF text envelope does not establish a local source-fragment relation")
    let bridgeSymbolQuad=rect(149,225,22,26).map(turn),bridgeQuad=rect(150,190,20,30).map(turn)
    let bridgeBoxes:[NativeCoreMLDetectionBox]=[fragmentBoxes[0],
        .init(polygon:bridgeSymbolQuad,score:0.95,detectorSeedEvidence:contextEvidence(84,CGRect(x:149,y:225,width:22,height:26))),
        .init(polygon:bridgeQuad,score:0.85,detectorSeedEvidence:contextEvidence(85,CGRect(x:150,y:190,width:20,height:30)))]
    let bridgeReads:[NativeCoreMLRecognizedRegion]=[fragmentReads[0],
        .init(sourceIndex:1,polygon:bridgeSymbolQuad,text:"♡",confidence:0.7)]
    func bridgeSource(_ ink:Bool,open:Bool=false,shared:Bool=false)->NativeOCRRGBAFrame {
        var pixels=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let head=ink && CGRect(x:153,y:194,width:15,height:12).contains(p)
            let paint=(open ? CGRect(x:135,y:225,width:50,height:80):CGRect(x:150,y:225,width:20,height:38)).contains(p) || (shared && CGRect(x:125,y:235,width:30,height:5).contains(p))
            let c=head ? [156,67,123]:paint ? [230,95,175]:[40,40,40]
            for k in 0..<3 { pixels[(y*side+x)*4+k]=UInt8(c[k]) }
        } }
        return .init(width:side,height:side,bytes:pixels)!
    }
    let bridgePlans=NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:bridgeBoxes,reads:bridgeReads,
        layout:fragmentLayout,frame:bridgeSource(true),inkStyles:[.init([255,255,255]),.init([156,67,123]),nil],threshold:0.4)
    check(bridgePlans.count==1 && bridgePlans[0].additionalSources==Set([2]) && bridgePlans[0].maximumInsertedGlyphs==1,
        "a privately detected but unread intervening glyph connects the two retained reads without losing its source owner")
    if let q=bridgePlans.first?.polygon,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(fragmentWordQuad) {
        check(f.bounds(q).maxY >= f.bounds(rect(150,225,20,38).map(turn)).maxY,
            "finite original paint includes the complete symbol beyond its previously clipped REC crop")
    }
    let openBridge=NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:bridgeBoxes,reads:bridgeReads,
        layout:fragmentLayout,frame:bridgeSource(true,open:true),inkStyles:[.init([255,255,255]),.init([156,67,123]),nil],threshold:0.4)
    check(openBridge.count==1,"an open adjacent paint surface does not invalidate the independent detected glyph bridge")
    if let q=openBridge.first?.polygon,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(fragmentWordQuad) {
        check(f.bounds(q).maxY < f.bounds(rect(149,225,22,26).map(turn)).maxY+6,
            "an unbounded same-hue surface cannot enlarge the retained symbol's source envelope")
    }
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(fragmentWordQuad) {
        let base=f.bounds(fragmentWordQuad).union(f.bounds(bridgeSymbolQuad)).union(f.bounds(bridgeQuad))
        let peer=rect(125,225,20,26).map(turn)
        let owned=NativeOCRContextualColumnRecovery.fragmentPaintBounds(fragment:bridgeSymbolQuad,base:base,basis:f,
            frame:bridgeSource(true,shared:true),palette:[[156,67,123]],glyph:22,peers:[peer])
        check(owned != nil && owned!.maxY >= f.bounds(rect(150,225,20,38).map(turn)).maxY-1,
            "a same-colour rim touching another detector-owned column retains its own complete terminal at every angle")
        check(owned != nil && owned!.minX >= base.minX-0.01 && owned!.maxX <= base.maxX+0.01,
            "a shared rim connector cannot establish an independent normal edge beyond the original column")
        let unowned=NativeOCRContextualColumnRecovery.fragmentPaintBounds(fragment:bridgeSymbolQuad,base:base,basis:f,
            frame:bridgeSource(true,shared:true),palette:[[156,67,123]],glyph:22)
        check(unowned == nil,"an open surface without an independently owned neighbour remains rejected")
        let paper=NativeOCRContextualColumnRecovery.fragmentPaintBounds(fragment:bridgeSymbolQuad,base:base,basis:f,
            frame:bridgeSource(true,open:true),palette:[[156,67,123]],glyph:22,peers:[peer])
        check(paper == nil,"a neighbour cannot excuse a longitudinally open colour surface")
    }
    check(NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:bridgeBoxes,reads:bridgeReads,
        layout:fragmentLayout,frame:bridgeSource(false),inkStyles:[.init([255,255,255]),.init([156,67,123]),nil],threshold:0.4).isEmpty,
        "a false intermediate detector box with no matching original ink cannot create a join")
    check(NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:bridgeBoxes,
        reads:bridgeReads+[.init(sourceIndex:2,polygon:bridgeQuad,text:"っ",confidence:0.9)],
        layout:fragmentLayout,frame:bridgeSource(true),inkStyles:[.init([255,255,255]),.init([156,67,123]),nil],threshold:0.4).isEmpty,
        "an independently retained intervening word is not consumed as an unread glyph bridge")
    func colouredDirectedExclamation(withStem:Bool)->NativeOCRRGBAFrame {
        var pixels=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let glyphs=(0..<4).map { CGRect(x:153,y:105+$0*20,width:14,height:12) }
            let glyph=glyphs.contains { $0.contains(p) },glyphRim=glyphs.contains { $0.insetBy(dx:-4,dy:-4).contains(p) }
            let shifted=CGPoint(x:p.x-(p.y-185)*0.08,y:p.y)
            let stem=withStem && CGRect(x:157,y:185,width:7,height:29).contains(shifted)
            let stemRim=withStem && CGRect(x:157,y:185,width:7,height:29).insetBy(dx:-4,dy:-4).contains(shifted)
            let dot=CGRect(x:160,y:223,width:7,height:7).contains(p)
            let dotRim=CGRect(x:160,y:223,width:7,height:7).insetBy(dx:-4,dy:-4).contains(p)
            let c=stem || glyph || dot ? [156,67,123]:stemRim || glyphRim || dotRim ? [255,255,255]:[60,45,70]
            for k in 0..<3 { pixels[(y*side+x)*4+k]=UInt8(c[k]) }
        } }
        return .init(width:side,height:side,bytes:pixels)!
    }
    let directedWord=rect(145,98,40,122).map(turn)
    let directedBox=NativeCoreMLDetectionBox(polygon:directedWord,score:0.9,
        detectorSeedEvidence:contextEvidence(73,CGRect(x:145,y:98,width:40,height:122)))
    let directedPlans=NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[directedBox],
        frame:colouredDirectedExclamation(withStem:true),probability:blankMarkMap,
        inkStyles:[.init(colors:[[156,67,123],[255,255,255]])],retained:[0],peerPolygons:[0:directedWord],
        excluding:[],exclamationParents:[0])
    if directedPlans.isEmpty {
        print("DIRECTED FIXTURE FAILURE ANGLE",degrees)
        let diagnostic=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[directedBox],
            frame:colouredDirectedExclamation(withStem:true),probability:blankMarkMap,
            inkStyle:.init(colors:[[156,67,123],[255,255,255]]),audit:{ print($0) },
            terminalMarkObserver:{ print("COMPACT FIXTURE",$0) },recognizesExclamation:true)
        print("DIRECTED FIXTURE PROOF",String(describing:diagnostic))
    }
    check(directedPlans.count==1 && directedPlans[0].sourceTailCompletion,
        "a retained exclamation uses its actual coloured stem direction even when the white outline joins stem and dot: \(degrees)")
    check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[directedBox],
        frame:colouredDirectedExclamation(withStem:true),probability:blankMarkMap,
        inkStyles:[.init(colors:[[156,67,123],[255,255,255]])],retained:[0],peerPolygons:[0:directedWord],
        excluding:[]).isEmpty,"a coloured stem/dot pair does not grant a new punctuation interpretation without the retained exclamation")
    check(NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[directedBox],
        frame:colouredDirectedExclamation(withStem:false),probability:blankMarkMap,
        inkStyles:[.init(colors:[[156,67,123],[255,255,255]])],retained:[0],peerPolygons:[0:directedWord],
        excluding:[],exclamationParents:[0]).isEmpty,"retained punctuation alone cannot turn an isolated same-colour spot into a terminal")
    let partialBorderSupport=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],
        frame:neutralOutlineImage(9),detectorSupport:borderedSource.polygon,probability:blankMarkMap,pixelThreshold:0.05)
    check(partialBorderSupport != nil,
        "adding a partial weak DB corridor cannot revoke an independently observed source-border cap")
    if let q=partialBorderSupport,let original=borderedCorner {
        check(zip(q,original).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<1e-6 },
            "the same source-proven cap has identical geometry with absent or partial DB support at every angle")
    }
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],
        frame:neutralOutlineImage(7),detectorSupport:joined.polygon,probability:blankMarkMap,pixelThreshold:0.05)==nil,
        "a partial DB corridor grants no outside-corridor access to an unproven neutral mark")
    var nextLetterBytes=neutralOutlineImage(9).bytes
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if CGRect(x:150,y:201,width:21,height:22).contains(p) {
            let border=CGRect(x:152,y:204,width:17,height:16).contains(p)
            let letter=CGRect(x:155,y:207,width:2,height:10).contains(p) ||
                [207,211,215].contains { CGRect(x:155,y:CGFloat($0),width:11,height:2).contains(p) }
            let colour=letter ? [252,254,253]:border ? [15,50,120]:[100,130,170]
            for k in 0..<3 { nextLetterBytes[(y*side+x)*4+k]=UInt8(colour[k]) }
        }
    } }
    let nextLetterFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:nextLetterBytes)!
    let nextLetterCap=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],
        frame:nextLetterFrame,detectorSupport:borderedSource.polygon,probability:blankMarkMap,pixelThreshold:0.05)
    check(nextLetterCap == nil || nextLetterCap!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "a matching font border cannot turn an out-of-corridor neighboring letter fragment into a punctuation cap")
    let otherBorder=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],frame:neutralOutlineImage(10),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(otherBorder == nil || otherBorder!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "a different print border cannot borrow the source's compact chain")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],frame:neutralOutlineImage(11),
        probability:blankMarkMap,pixelThreshold:0.05)==nil,"matching border alone cannot cross a missing source chain")
    let croppedRule=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],frame:neutralOutlineImage(12),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(croppedRule == nil || croppedRule!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "a white rule continuing outside the source lane has no resolved compact cap")
    let sideCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],frame:neutralOutlineImage(13),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(sideCorner != nil,"a real corner touching the crop side is resolved from surrounding source pixels")
    if let q=sideCorner {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! >= 54,
            "side-touching punctuation keeps its actual longitudinal cap")
    }
    let openPaper=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],frame:neutralOutlineImage(14),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(openPaper == nil || openPaper!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "matching coloured paper beside a white rule is open, not enclosed glyph fill")
    let quotePeerEvidence=NativeOCRDetectorSeedEvidence(ownerID:"independent-neutral-mark",parentBoxIndex:1,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,
        sourceWidth:side,sourceHeight:side,components:[.init(seed:foreignMarkRuns[0].y*side+foreignMarkRuns[0].x,
            pixelCount:foreignMarkRuns.count,meanProbability:0.99,runs:foreignMarkRuns)],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let quotePeer=NativeCoreMLDetectionBox(polygon:rect(153,205,15,12).map(turn),score:0.99,detectorSeedEvidence:quotePeerEvidence)
    func neutralPrintImage(_ kind:Int,wrongTerminal:Bool=false,swapFill:Bool=true)->NativeOCRRGBAFrame {
        var bytes=neutralOutlineImage(kind).bytes
        for y in 0..<side { for x in 0..<side {
            let i=(y*side+x)*4,c=(0..<3).map { Int(bytes[i+$0]) }
            let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
            let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
            let ink=wrongTerminal && p.y > 201 ? [90,90,90]:[7,9,10]
            let replacement = c == [15,50,120] ? (swapFill ? [252,254,253]:ink):
                (c == [252,254,253] && swapFill ? ink:c)
            for k in 0..<3 { bytes[i+k]=UInt8(replacement[k]) }
        } }
        return .init(width:side,height:side,bytes:bytes)!
    }
    let neutralPrintStyle=NativeOCRRFPrimaryEnsemble.EndpointInkStyle([7,9,10])
    let neutralPrintCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],
        frame:neutralPrintImage(9),detectorSupport:borderedSource.polygon,probability:blankMarkMap,
        inkStyle:neutralPrintStyle)
    check(neutralPrintCorner != nil,
        "a repeatedly measured achromatic private print can establish a complete white-collared corner at every angle")
    if let q=neutralPrintCorner {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 56 && end <= 63,"a neutral printed corner includes its measured outer white collar without following the paper")
    }
    let wrongNeutralCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],
        frame:neutralPrintImage(9,wrongTerminal:true),detectorSupport:borderedSource.polygon,probability:blankMarkMap,
        inkStyle:neutralPrintStyle)
    check(wrongNeutralCorner == nil || wrongNeutralCorner!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "a neutral neighbouring mark of a different measured ink cannot inherit the source corner proof")
    let neutralPaper=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource],
        frame:neutralPrintImage(14,swapFill:false),detectorSupport:borderedSource.polygon,probability:blankMarkMap,
        inkStyle:neutralPrintStyle)
    check(neutralPaper == nil || neutralPaper!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "dark paper around a white rule is not a closed source-ink corner")
    let ownedNeutralCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[borderedSource,quotePeer],
        frame:neutralPrintImage(9),detectorSupport:borderedSource.polygon,probability:blankMarkMap,
        inkStyle:neutralPrintStyle)
    check(ownedNeutralCorner == nil || ownedNeutralCorner!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "the neutral companion hypothesis cannot acquire an independent detector's private corner")
    let withoutPeerCorner=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined,quotePeer],
        frame:neutralOutlineImage(7),detectorSupport:markSupport,probability:markMap,pixelThreshold:0.05)
    if let q=withoutPeerCorner {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
            "an independent peer's private neutral pixels cannot be annexed")
    } else { check(true,"withholding unsupported neutral expansion preserves peer ownership") }
    let clippedCorner=NativeCoreMLDetectionBox(polygon:rect(154,205,2,6).map(turn),score:0.99,
        detectorSeedEvidence:quotePeerEvidence)
    let cornerGroupBox=NativeCoreMLDetectionBox(polygon:rect(150,100,20,111).map(turn),score:0.9)
    let cornerGroup=NativeOCRRFPrimaryEnsemble.Group(index:2,members:[0,1],evidence:[borderedEvidence,quotePeerEvidence])
    let cornerGroupCrop=NativeOCRRFPrimaryEnsemble.recognitionCrop(index:2,
        boxes:[borderedSource,clippedCorner,cornerGroupBox],layout:layout,frame:neutralOutlineImage(9),
        probability:blankMarkMap,pixelThreshold:0.05,mode:"db+pixel",
        inkStyles:[.init(colors:[[15,50,120],[252,254,253]]),nil,nil],groups:[cornerGroup])
    check(cornerGroupCrop.map { q in
        q.polygon.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! >= 54
    } ?? false,"an established fragment group observes a narrow terminal member's whole corner in its common local frame")
    let foreignCorner=NativeCoreMLDetectionBox(polygon:quotePeer.polygon,score:0.99,
        detectorSeedEvidence:contextEvidence(85,CGRect(x:154,y:207,width:12,height:8)))
    let blockedGroupCrop=NativeOCRRFPrimaryEnsemble.recognitionCrop(index:2,
        boxes:[borderedSource,clippedCorner,cornerGroupBox,foreignCorner],layout:layout,frame:neutralOutlineImage(9),
        probability:blankMarkMap,pixelThreshold:0.05,mode:"db+pixel",
        inkStyles:[.init(colors:[[15,50,120],[252,254,253]]),nil,nil,nil],groups:[cornerGroup])
    check(blockedGroupCrop.map { q in
        q.polygon.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 54
    } ?? true,"whole-group terminal observation never exempts an independent word's private ink")
    let connectedHalo=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(15),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(connectedHalo != nil,"a bounded private-colour fill retains a cap even when its white halo is one tall component")
    if let q=connectedHalo {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 49 && end <= 55,"paired fill recovery stops at the measured dot cap at every angle")
    }
    for kind in [16,17] {
        let wrong=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(kind),
            probability:blankMarkMap,pixelThreshold:0.05)
        check(wrong == nil || wrong!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
            "an open coloured surface or a fill without the source's white collar cannot become a terminal dot")
    }
    var dotRuns:[E.Run]=[]
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let point=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        if CGRect(x:158,y:205,width:4,height:4).contains(point) { dotRuns.append(.init(y:y,x:x,count:1)) }
    } }
    let dotEvidence=E(ownerID:"independent-coloured-dot",parentBoxIndex:1,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[.init(seed:dotRuns[0].y*side+dotRuns[0].x,pixelCount:dotRuns.count,meanProbability:0.99,runs:dotRuns)],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let dotPeer=NativeCoreMLDetectionBox(polygon:rect(157,204,6,6).map(turn),score:0.99,detectorSeedEvidence:dotEvidence)
    check(NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:0,boxes:[joined,dotPeer],
        frame:pointTrainImage(white:true,shift:17),inkStyle:.init([255,255,255])) == nil,
        "a repeated point train cannot annex another detector's private punctuation")
    let excludedDot=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined,dotPeer],frame:neutralOutlineImage(15),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(excludedDot == nil || excludedDot!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "an independently owned coloured dot is not annexed by matching print colours")
    var measuredFillCaps=0
    let sharedWhite=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(18),
        probability:blankMarkMap,pixelThreshold:0.05,audit:{ row in
            if let mark=row["neutralCompactAccepted"] as? [String:Any],mark["companionFill"] as? Bool == true { measuredFillCaps+=1 }
        })
    check(sharedWhite != nil && measuredFillCaps > 0,"a source-coloured dot can have a complete cap inside a laterally open white halo")
    if let q=sharedWhite {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 49 && end <= 55,"shared white paper cannot replace the actually bounded coloured dot endpoint")
    }
    let isolatedFill=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(19),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(isolatedFill == nil || isolatedFill!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "a matching coloured dot without a source-rooted component chain stays unowned")
    let ownedFill=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined,dotPeer],frame:neutralOutlineImage(18),
        probability:blankMarkMap,pixelThreshold:0.05)
    check(ownedFill == nil || ownedFill!.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 45,
        "an open halo never grants ownership of another detector's coloured dot")
    let whiteInk=NativeOCRRFPrimaryEnsemble.EndpointInkStyle([252,254,253])
    let whiteDot=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(20),
        probability:blankMarkMap,inkStyle:whiteInk)
    check(whiteDot != nil,"a source-white terminal dot does not require its changing paper colour as a second ink")
    if let q=whiteDot {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! >= 49,
            "the white dot retains its actual cap at every scene angle")
    }
    for kind in [21,22,23] {
        check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(kind),
            probability:blankMarkMap,inkStyle:whiteInk)==nil,
            "white-dot proof rejects absent stem, lateral unrelated mark and wrong source colour")
    }
    let whiteHeadDot=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(24),
        probability:blankMarkMap,inkStyle:whiteInk)
    check(whiteHeadDot != nil,"the same source-white stem/dot rule also works at the leading endpoint")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined,dotPeer],frame:neutralOutlineImage(20),
        probability:blankMarkMap,inkStyle:whiteInk)==nil,"a matching white dot cannot take an independent detector owner")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(25))==nil,
        "a surface seam thinner than the observed source outline is not a terminal")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(26)) != nil,
        "a real white terminal at the observed source stroke weight remains available")
    let neutralTail=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(0))
    check(neutralTail != nil,"a neutral outline terminal can be owned beside private coloured source glyphs")
    if let q=neutralTail {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end >= 94 && end <= 102,"neutral outline proof ends at its actual cap at every angle")
    }
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(1))==nil,
        "a broad bright surface cannot become a neutral terminal")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(2))==nil,
        "a remote white rule has no private glyph root")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(3))==nil,
        "an unresolved neutral line at the search boundary has no measured cap")
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(5))==nil,
        "a pale coloured stripe cannot borrow the source's opaque white outline colour")
    let paddedNeutral=NativeCoreMLDetectionBox(polygon:rect(140,100,40,85).map(turn),score:0.9,detectorSeedEvidence:evidence)
    check(NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[paddedNeutral],frame:neutralOutlineImage(6))==nil,
        "a wide crop alone cannot establish attachment to a nearby thin white line")
    let neutralHead=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[joined],frame:neutralOutlineImage(4))
    check(neutralHead != nil,"neutral source-terminal ownership is symmetric at the head")
    let shortSource=NativeCoreMLDetectionBox(polygon:rect(150,100,20,35).map(turn),score:0.9,detectorSeedEvidence:evidence)
    let shortTerminal=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[shortSource],layout:layout,
        frame:image(bar:false,opposite:false,shortCoreTail:true),terminalOnly:true)
    check(shortTerminal != nil,"private source ink can certify a terminal beyond a short two-row crop")
    if let q=shortTerminal {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! > 53,
            "a crop shorter than two source widths still reaches its measured source-owned cap")
    }
    let unsupportedShort=NativeCoreMLDetectionBox(polygon:shortSource.polygon,score:0.99)
    check(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[unsupportedShort],layout:layout,
        frame:image(bar:false,opposite:false,shortCoreTail:true)) == nil,
        "a short source needs original private ownership, not only high detector confidence")
    let chainedTail=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,splitTailChain:true),terminalOnly:true)
    check(chainedTail != nil,"a fragmented terminal retains its source anchor")
    if let q=chainedTail {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! > 98,
            "a terminal chain reaches its measured cap across a printing gap beyond RF")
    }
    let chainWithoutArt=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,shortChainWithArt:true))
    check(chainWithoutArt != nil,"split terminal fragments retain a measured endpoint before nearby art")
    if let q=chainWithoutArt {
        let cap=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(cap >= 64 && cap < 77,"terminal fragments cannot inflate glyph pitch and bridge later artwork")
    }
    let chainedHead=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,splitHeadChain:true),terminalOnly:true)
    check(chainedHead != nil,"a fragmented head retains its source anchor")
    if let q=chainedHead {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.min()! < -99,
            "terminal fragment chaining is symmetric at both source endpoints")
    }
    let junctionTerminal=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,junctionTail:true),terminalOnly:true)
    check(junctionTerminal != nil,"a cut glyph junction retains its connected source terminal")
    if let q=junctionTerminal {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! > 83,
            "a wide glyph junction cannot discard the measured narrow terminal beyond it")
    }
    let splitTerminal=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,splitHead:true),terminalOnly:true)
    check(splitTerminal != nil,"a short thin terminal fragment can connect across a sub-stroke gap")
    if let q=splitTerminal {
        let first=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.min()!
        check(first < -78 && first > -87,"fragmented head retains its measured cap at every angle")
    }
    let overlapHeadBox=NativeCoreMLDetectionBox(polygon:rect(150,95,20,90).map(turn),score:0.9,
        detectorSeedEvidence:evidence)
    let overlapHead=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[overlapHeadBox],layout:layout,
        frame:image(bar:false,opposite:false,splitHead:true),terminalOnly:true)
    check(overlapHead != nil,"a fragment partly inside the source still links across its outside gap")
    if let q=overlapHead {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.min()! < -78,
            "partial source overlap cannot disable fragmented terminal ownership")
    }
    let blueContinuation=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,blue:true,continuationWords:true),terminalOnly:true)
    check(blueContinuation != nil,"source-style-certified glyphs can continue beyond a short RF enclosure")
    if let q=blueContinuation {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! > 94,
            "the source-style continuation reaches the actual final glyph beyond RF")
    }
    let neutralIsland=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,weakIsland:true))
    if let q=neutralIsland {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 35,
            "an unowned neutral island cannot become a source continuation solely by colour mixture")
    } else { check(true,"unowned neutral island has no endpoint proof") }
    let weakStroke=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:true,opposite:false,antialiasedBar:true))
    check(weakStroke != nil,"thin antialiased neutral strokes are not discarded by an exact colour gate")
    if let q=weakStroke {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! >= 64,
            "local-background mixtures recover the actual thin terminal cap")
    }
    let textureNoise=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,noiseTail:true))
    if let q=textureNoise {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 35,
            "unresolved isolated texture pixels cannot pull an endpoint across a glyph-sized gap")
    } else { check(true,"isolated texture noise has no endpoint authority") }
    let offsetContact=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,offsetStroke:true))
    if let q=offsetContact {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! >= 64,
            "a source-connected terminal stroke may lie off-centre within its character lane")
    } else { check(false,"source-connected offset stroke must not disappear") }
    let attachedArtwork=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:true,opposite:false,artworkTail:true))
    check(attachedArtwork != nil,"private source stroke remains measurable beside attached artwork")
    if let q=attachedArtwork {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end>=63 && end<75,"connected artwork of another ink family cannot become the source endpoint")
    }
    let joinedNext=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:layout,
        frame:image(bar:false,opposite:false,connectedWord:true,nextWord:true))
    if let q=joinedNext {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 30,
            "a lane junction is unknown, not a measured cap that authorizes a partial extension")
    } else { check(true,"next-word junction abstains") }
    let peerPolygon=rect(145,180,30,90).map(turn)
    func peerEvidence(_ source:CGRect)->E {
        let bounds=NativeOCRDirectionGeometry.bounds(NativeOCRDirectionGeometry.corners(source).map(turn))
        var runs:[E.Run]=[]
        for y in Int(floor(bounds.minY))..<Int(ceil(bounds.maxY)) {
            var pixels:[Int]=[]
            for x in Int(floor(bounds.minX))..<Int(ceil(bounds.maxX)) {
                let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
                if source.contains(CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)) { pixels.append(x) }
            }
            if let first=pixels.first,let last=pixels.last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let component=E.Component(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
        return E(ownerID:"peer",parentBoxIndex:1,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[component],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let distantPeer=NativeCoreMLDetectionBox(polygon:peerPolygon,score:0.9,
        detectorSeedEvidence:peerEvidence(CGRect(x:153,y:240,width:14,height:12)))
    let harmless=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box,distantPeer],layout:layout,
        frame:image(bar:true,opposite:false,foreign:true))
    check(harmless != nil,"a peer's empty bbox padding cannot block a measured terminal stroke")
    if let q=harmless {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! >= 64,
            "peer padding must retain the true terminal endpoint")
    }
    let touchingPeer=NativeCoreMLDetectionBox(polygon:peerPolygon,score:0.9,
        detectorSeedEvidence:peerEvidence(CGRect(x:158,y:203,width:3,height:12)))
    let conflict=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box,touchingPeer],layout:layout,
        frame:image(bar:true,opposite:false))
    if let q=conflict {
        check(q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()! < 64,
            "actual peer ink must still block attribution of its stroke")
    } else { check(true,"actual peer conflict abstains") }
    for outlined in [false,true] {
        for primitives in [[rf],[]] {
            let scope=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:primitives)
            let recovered=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[joined],layout:scope,
                frame:image(bar:false,opposite:false,connectedWord:true,outlined:outlined))
            check(recovered != nil,"a connected word and its stroke cannot be discarded as an oversized glyph")
            if let q=recovered {
                let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
                check(end>=94 && end<=106,"owned word/outline decomposition keeps the connected terminal stroke")
            }
        }
    }
    let loose=NativeCoreMLDetectionBox(polygon:rect(150,60,20,165).map(turn),score:0.9)
    let core=rect(153,103,14,72).map(turn)
    let shortPadding=NativeCoreMLDetectionBox(polygon:rect(150,100,20,90).map(turn),score:0.9,
        detectorSeedEvidence:evidence)
    let smallTrim=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[shortPadding],layout:layout,
        frame:image(bar:false,opposite:false),protectedInk:core,protectedEvidence:evidence)
    check(smallTrim != nil,"measured empty padding smaller than three quarters of a glyph must be removable")
    if let q=smallTrim {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end<25 && end>=15,"small padding trim retains the last real source glyph")
    }
    let finalSmallTrim=NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:0,boxes:[shortPadding],
        polygon:shortPadding.polygon,layout:layout,frame:image(bar:false,opposite:false))
    let finalSmallEnd=finalSmallTrim.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
    check(finalSmallEnd<25 && finalSmallEnd>=15,
        "resolved empty native padding is removable even below a glyph-fraction floor")
    let crossedInk=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:shortPadding.polygon,
        candidate:rect(150,110,20,59).map(turn),frame:image(bar:false,opposite:false),inkStyle:.init(colors:[[0,0,0],[255,255,255]]))
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(shortPadding.polygon) {
        let r=f.bounds(crossedInk)
        check(r.minY <= 3 && r.maxY >= 75,
            "a trim crossing a real source component restores its full head and tail at every angle")
        check(r.minY >= f.rect.minY && r.maxY <= f.rect.maxY,
            "source-connected trim caps cannot acquire pixels beyond the old retained word")
    }
    let mixedEndInk=NativeOCRRFPrimaryEnsemble.preservingMixedEndpointSource(baseline:shortPadding.polygon,
        candidate:rect(150,110,20,95).map(turn),frame:image(bar:false,opposite:false),
        inkStyle:.init(colors:[[0,0,0],[255,255,255]]))
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(shortPadding.polygon) {
        check(abs(f.bounds(mixedEndInk).minY)<1e-6,
            "a newly grown opposite end cannot certify a crop that slices through an already visible leading source stroke")
        check(abs(f.bounds(mixedEndInk).maxY-105)<1e-6,
            "restoring the clipped source end preserves the independently measured opposite growth at every angle")
    }
    let detachedInk=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:shortPadding.polygon,
        candidate:rect(150,130,20,40).map(turn),frame:image(bar:false,opposite:false),
        inkStyle:.init(colors:[[0,0,0],[255,255,255]]),preserveDetached:true)
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(shortPadding.polygon) {
        check(f.bounds(detachedInk).minY <= 3 && f.bounds(detachedInk).maxY >= 75,
            "a new fallback cannot erase a complete retained source stroke just because it does not cross the proposed cut")
    }
    let emptyOnly=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:shortPadding.polygon,
        candidate:rect(150,101,20,77).map(turn),frame:image(bar:false,opposite:false),inkStyle:.init(colors:[[0,0,0],[255,255,255]]))
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(shortPadding.polygon) {
        let r=f.bounds(emptyOnly)
        check(abs(r.minY-1)<0.001 && abs(r.maxY-78)<0.001,
            "source paper spanning the lane cannot veto a genuinely empty endpoint trim")
    }
    var borderBytes=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        let border=CGRect(x:150,y:163,width:4,height:21).contains(p) ||
            CGRect(x:150,y:179,width:20,height:5).contains(p)
        let colour=border ? [255,255,255]:[80,50,30]
        for k in 0..<3 { borderBytes[(y*side+x)*4+k]=UInt8(colour[k]) }
    } }
    let borderFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:borderBytes)!
    let retainedBorder=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:shortPadding.polygon,
        candidate:rect(150,100,20,80).map(turn),frame:borderFrame,inkStyle:.init([255,255,255]))
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(shortPadding.polygon) {
        check(f.bounds(retainedBorder).maxY >= 83 && f.bounds(retainedBorder).maxY <= 89,
            "a sparse bracket outline touching the old normal edges keeps its complete terminal cap")
    }
    var sharedHaloBytes=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        let p=CGPoint(x:160+dx*cosine+dy*sine,y:160-dx*sine+dy*cosine)
        var colour=[80,50,30]
        if CGRect(x:153,y:150,width:14,height:39).contains(p) { colour=[255,255,255] }
        if CGRect(x:157,y:156,width:6,height:8).contains(p) { colour=[0,0,0] }
        if CGRect(x:157,y:179,width:6,height:7).contains(p) { colour=[120,0,100] }
        for k in 0..<3 { sharedHaloBytes[(y*side+x)*4+k]=UInt8(colour[k]) }
    } }
    let sharedHaloFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:sharedHaloBytes)!
    let haloCut=rect(150,100,20,71).map(turn)
    let sharedHalo=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:shortPadding.polygon,
        candidate:haloCut,frame:sharedHaloFrame,inkStyle:.init(colors:[[0,0,0],[255,255,255]]),
        competingInkStyles:[.init([120,0,100])])
    let unresolvedHalo=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:shortPadding.polygon,
        candidate:haloCut,frame:sharedHaloFrame,inkStyle:.init(colors:[[0,0,0],[255,255,255]]),
        competingInkStyles:[.init([0,0,0])])
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(shortPadding.polygon) {
        check(f.bounds(sharedHalo).maxY >= 71 && f.bounds(sharedHalo).maxY < 84,
            "a connected shared outline retains its own side without reacquiring a differently printed peer at every angle")
        check(f.bounds(unresolvedHalo).maxY >= 88,
            "without distinct measured ink on both sides a connected cap remains protected")
    }
    let skewRead=[CGPoint(x:150,y:70),CGPoint(x:170,y:70),CGPoint(x:174,y:225),CGPoint(x:154,y:225)].map(turn)
    if let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(skewRead) {
        let shortened=NativeOCRRFPrimaryEnsemble.resizingReadSpan(skewRead,head:20,tail:125)
        check(zip(skewRead,shortened).allSatisfy { abs(f.project($0).x-f.project($1).x)<0.001 },
            "an end resize preserves each skew corner's original normal coordinate at every angle")
        let r=f.bounds(shortened)
        check(abs(r.minY-20)<0.001 && abs(r.maxY-125)<0.001,
            "a skew quad receives exactly the measured along-axis span without rectangularizing its corners")
    }
    let weakPadding=NativeCoreMLDetectionBox(polygon:shortPadding.polygon,score:0.7,detectorSeedEvidence:evidence)
    check(NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:0,boxes:[weakPadding],
        polygon:weakPadding.polygon,layout:layout,frame:image(bar:false,opposite:false))==weakPadding.polygon,
        "weak detector crops remain unchanged before a word has actually been recognized")
    let observedWeakTrim=NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:0,boxes:[weakPadding],
        polygon:weakPadding.polygon,layout:layout,frame:image(bar:false,opposite:false),observedWord:true)
    let weakEnd=observedWeakTrim.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
    check(weakEnd<25 && weakEnd>=15,
        "a retained word can nominate measured empty padding despite a weaker detector score")
    let weakTrimProposals=NativeOCRContextualColumnRecovery.retainedWordTrims(boxes:[weakPadding],
        frame:image(bar:false,opposite:false),layout:layout,inkStyles:nil,retained:[0],
        peerPolygons:[0:weakPadding.polygon],excluding:[])
    check(weakTrimProposals.count==2 && weakTrimProposals.allSatisfy(\.measuredTrimOnly),
        "late measured trimming nominates exact-end and normal-context paired reads through word-identical admission")
    let marginPeer=NativeCoreMLDetectionBox(polygon:rect(146,125,3,15).map(turn),score:0.9,
        detectorSeedEvidence:peerEvidence(CGRect(x:146,y:130,width:3,height:8)))
    let blockedNormalTrim=NativeOCRContextualColumnRecovery.retainedWordTrims(boxes:[weakPadding,marginPeer],
        frame:image(bar:false,opposite:false),layout:layout,inkStyles:nil,retained:[0],
        peerPolygons:[0:weakPadding.polygon,1:marginPeer.polygon],excluding:[])
    check(blockedNormalTrim.count==1 && blockedNormalTrim[0].polygon==weakTrimProposals[0].polygon,
        "normal REC context cannot borrow another owner's private cells beyond the original reading strip")
    if let proposal=weakTrimProposals.first,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(weakPadding.polygon) {
        check(proposal.samplings.allSatisfy { q in
            let r=f.bounds(q)
            return r.minY >= f.rect.minY-0.001 && r.maxY <= f.rect.maxY+0.001
        },"a retained-word trim never samples beyond the old recognized reading span")
        let nominal=f.bounds(proposal.polygon),sample=f.bounds(proposal.samplings[0])
        check(abs(nominal.minY-sample.minY)<0.001 && abs(nominal.maxY-sample.maxY)<0.001,
            "the final nominal trim itself must be decoded, not merely two larger padded crops")

    }
    let bothEndPadding=NativeCoreMLDetectionBox(polygon:loose.polygon,score:0.9,detectorSeedEvidence:evidence)
    let independentTrims=NativeOCRContextualColumnRecovery.retainedWordTrims(boxes:[bothEndPadding],
        frame:image(bar:false,opposite:false),layout:layout,inkStyles:nil,retained:[0],
        peerPolygons:[0:bothEndPadding.polygon],excluding:[],fallbackParents:[0])
    check(NativeOCRContextualColumnRecovery.retainedWordTrims(boxes:[bothEndPadding],
        frame:image(bar:false,opposite:false),layout:layout,inkStyles:nil,retained:[0],
        peerPolygons:[0:bothEndPadding.polygon],excluding:[]).isEmpty,
        "a strong retained word without a rejected first-pass trim keeps its verified reading window")
    check(independentTrims.count==6,"two measured empty ends nominate each independent end with two kinds of paired context at every angle")
    if independentTrims.count==6,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(bothEndPadding.polygon) {
        let whole=f.bounds(independentTrims[0].polygon),tail=f.bounds(independentTrims[2].polygon),head=f.bounds(independentTrims[4].polygon)
        check(abs(tail.minY-f.rect.minY)<0.001 && abs(tail.maxY-whole.maxY)<0.001,
            "a failed head recognition can fall back to the measured tail without moving the old head")
        check(abs(head.maxY-f.rect.maxY)<0.001 && abs(head.minY-whole.minY)<0.001,
            "a failed tail recognition can fall back to the measured head without moving the old tail")
        check(independentTrims.allSatisfy { proposal in
            let measured=f.bounds(proposal.polygon),first=f.bounds(proposal.samplings[0])
            return abs(measured.minY-first.minY)<0.001 && abs(measured.maxY-first.maxY)<0.001 && proposal.measuredTrimOnly
        },"every independent end requires its exact final endpoints to be recognized")
        check([1,3,5].allSatisfy { index in
            let measured=f.bounds(independentTrims[index].polygon)
            return independentTrims[index].samplings.allSatisfy { sample in
                let r=f.bounds(sample)
                return abs(r.minY-measured.minY)<0.001 && abs(r.maxY-measured.maxY)<0.001 && r.width>measured.width
            }
        },"normal context never adds along-axis room that could conceal a clipped first or last glyph")
    }

    let trimmed=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[loose],layout:layout,
        frame:image(bar:false,opposite:false),protectedInk:core)
    check(trimmed != nil,"measured empty margins may shrink: \(degrees)")
    if let q=trimmed {
        let points=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }
        check(points.min()! <= -57 && points.max()! >= 15,"all private core cells survive trimming")
        check(points.max()!-points.min()! < 100,"empty crop margin is removed")
    }
    let clipped=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[loose],layout:layout,
        frame:image(bar:false,opposite:false,rimMark:true),protectedInk:core)
    if let q=clipped {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end>=59,"rim-rejected foreground must still veto deletion: \(degrees)")
    } else { check(true,"no trimming is safer than deleting a clipped mark") }
    let backgroundPrint=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[loose],layout:layout,
        frame:image(bar:false,opposite:false,faint:true),protectedInk:core,protectedEvidence:evidence)
    check(backgroundPrint != nil,"private black glyph palette can reject faint unrelated print")
    if let q=backgroundPrint {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end<30,"background print cannot enlarge the private glyph endpoint")
    }
    let translucent=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[loose],layout:layout,
        frame:image(bar:false,opposite:false,faint:true,blue:true),protectedInk:core,protectedEvidence:evidence)
    if let q=translucent {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end>=59,"a chromatic alpha mixture must veto deletion of faint source ink")
    } else { check(true,"abstention preserves faint source ink") }
    let noRF=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[])
    let compactPrivate=NativeCoreMLDetectionBox(polygon:rect(150,100,20,55).map(turn),score:0.9,
        detectorSeedEvidence:evidence)
    check(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[compactPrivate],layout:noRF,
        frame:image(bar:false,opposite:false)) != nil,
        "three measured private glyphs can establish an RF-free lane below three padded source widths")
    let bareRail=NativeCoreMLDetectionBox(polygon:rect(150,95,20,145).map(turn),score:0.9)
    check(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[bareRail],layout:noRF,
        frame:image(bar:false,opposite:false,barOnly:true)) == nil,
        "long thin rules alone cannot bootstrap RF-free font continuation")
    let longTail=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box],layout:noRF,
        frame:image(bar:true,opposite:false,farBar:true))
    check(longTail != nil,"RF-free continuous bar may exceed the old one-glyph budget")
    if let q=longTail {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end>=94 && end<=103,"long bar endpoint measured without screen-axis assumptions")
    }
    let beyondRF=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box],layout:layout,
        frame:image(bar:true,opposite:false,farBar:true))
    check(beyondRF != nil,"RF scope ending early must not clip a continuous source bar")
    if let q=beyondRF {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end>=94 && end<=103,"actual bar endpoint wins over a short RF enclosure")
    }
    let shortSupport=rect(140,90,40,110).map(turn)
    var shortRF=NativeRFDETRLayoutPrimitive(queryID:3,semanticClass:.text,confidence:0.9,
        sourceBounds:NativeOCRDirectionGeometry.bounds(shortSupport))
    shortRF.supportPolygon=shortSupport
    let shortLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[shortRF])
    let beyondShortRF=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box],layout:shortLayout,
        frame:image(bar:true,opposite:false,farBar:true))
    check(beyondShortRF != nil,"a continuous source bar requires terminal context beyond a prematurely ending RF")
    if let q=beyondShortRF {
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end>=94 && end<=103,"search clipping must not erase a long continuous terminal stroke")
    }
    let extended=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box],layout:layout,frame:image(bar:true,opposite:false))
    check(extended != nil,"thin long terminal bar must survive: \(degrees)")
    if let q=extended {
        let original=polygon.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        let end=q.map { ($0.x-160)*(-sine)+($0.y-160)*cosine }.max()!
        check(end-original>35 && end-original<48,"bar measured in owner axis: \(degrees)")
    }
    let stopped=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[box],layout:layout,frame:image(bar:false,opposite:true))
    if let q=stopped {
        let end=zip(q,polygon).map { ($0.x-$1.x)*(-sine)+($0.y-$1.y)*cosine }.max()!
        check(end<4,"opposite-polarity artwork cannot be a tail: \(degrees)")
    } else { check(true,"abstention") }
}
// Weak DB ink far beyond a blank glyph-sized band must not enlarge the crop.
let db=NativeCoreMLDetectionBox(polygon:rect(120,100,20,100),score:0.9)
let rf=NativeRFDETRLayoutPrimitive(queryID:2,semanticClass:.text,confidence:0.9,sourceBounds:CGRect(x:110,y:90,width:40,height:150))
let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[rf])
func dbMap(_ rows:Range<Int>)->NativeMainEnsembleOCRProbability.Sample {
    var v=[Float](repeating:0,count:side*side)
    for y in rows { for x in 126..<134 { v[y*side+x]=0.1 } }
    return .init(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:v)
}
check(NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index:0,boxes:[db],layout:layout,width:side,height:side,
    probability:dbMap(223..<225),pixelThreshold:0.05)==nil,"remote weak island beyond blank band is not continuation")
check(NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index:0,boxes:[db],layout:layout,width:side,height:side,
    probability:dbMap(205..<212),pixelThreshold:0.05) != nil,"nearby weak continuation remains eligible")

// A secondary artwork colour is not the private source's printed family.
// Rotate the whole observation, including private detector runs, rather than
// testing only a vertical positive case.
for degrees in stride(from:0,through:345,by:15) {
    let radians=Double(degrees)*Double.pi/180,c=CGFloat(cos(radians)),s=CGFloat(sin(radians))
    func turn(_ p:CGPoint)->CGPoint {
        let x=p.x-160,y=p.y-160
        return .init(x:160+x*c-y*s,y:160+x*s+y*c)
    }
    func local(_ x:Int,_ y:Int)->CGPoint {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        return .init(x:160+dx*c+dy*s,y:160-dx*s+dy*c)
    }
    let glyphs=[CGRect(x:151,y:105,width:18,height:25),CGRect(x:151,y:140,width:18,height:25),
        CGRect(x:151,y:175,width:18,height:15)]
    let stray=CGRect(x:154,y:237,width:7,height:3),art=CGRect(x:147,y:211,width:26,height:23)
    var bytes=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let p=local(x,y),colour:[UInt8]
        if glyphs.contains(where:{$0.contains(p)}) || stray.contains(p) { colour=[190,30,110] }
        else if art.contains(p) { colour=[65,95,70] }
        else { colour=[235,235,235] }
        let offset=(y*side+x)*4
        for k in 0..<3 { bytes[offset+k]=colour[k] }
    } }
    let image=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
    func evidence(includeStray:Bool,partial:Bool = false,includeArt:Bool = true)->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in 0..<side {
            var first:Int?,last:Int?
            for x in 0..<side {
                let p=local(x,y)
                if (partial ? Array(glyphs.prefix(1)):glyphs).contains(where:{$0.insetBy(dx:3,dy:3).contains(p)}) ||
                    (includeStray && stray.contains(p)) || (includeArt && art.insetBy(dx:5,dy:5).contains(p)) {
                    if first==nil { first=x };last=x
                }
            }
            if let first,let last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let part=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
            pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
        return .init(ownerID:"source",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[part],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let observedTail=rect(151,230,18,9).map(turn)
    check(!NativeOCRContextualColumnRecovery.retainsObservedSource(observedTail,
        candidate:rect(125,130,100,30).map(turn),uncertainty:2),
        "a crossing horizontal word cannot consume a vertical source terminal at \(degrees)")
    check(NativeOCRContextualColumnRecovery.retainsObservedSource(observedTail,
        candidate:rect(145,95,30,160).map(turn),uncertainty:2),
        "the complete source crop retains its own terminal at \(degrees)")
    let polygon=rect(145,95,30,160).map(turn)
    let style=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[190,30,110],[65,95,70]])
    let box=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,detectorSeedEvidence:evidence(includeStray:false))
    let proposals=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[box],frame:image,
        inkStyles:[style],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(proposals.count==2,"private source family separates artwork from a retained word at \(degrees)")
    if let proposal=proposals.first {
        let end=proposal.polygon.map { (p:CGPoint)->CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 190 && end < 205,"family trim retains the final printed glyph, not the detached island at \(degrees)")
    }
    let outlined=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[255,255,255],[190,30,110],[65,95,70]])
    check(NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[box],frame:image,
        inkStyles:[outlined],retained:[0],peerPolygons:[0:polygon],excluding:[]).count==2,
        "a measured coloured fill distinguishes a white outline from white paper at \(degrees)")
    var similarArtBytes=bytes
    for y in 0..<side { for x in 0..<side where art.contains(local(x,y)) {
        let k=(y*side+x)*4
        for channel in 0..<3 { similarArtBytes[k+channel]=[UInt8(225),65,145][channel] }
    } }
    let similarArt=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:similarArtBytes)!
    let outlinedProposals=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[box],frame:similarArt,
        inkStyles:[outlined],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(outlinedProposals.count==2,"a measured white-print companion cannot bridge to nearby similarly hued artwork at \(degrees)")
    if let candidate=outlinedProposals.first {
        let end=candidate.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 190 && end < 205,"the stricter companion observation preserves the final glyph at \(degrees)")
    }
    // The original word is thick white ink; an unowned illustration uses
    // the same white colour but a much thinner outline after the detector.
    func whiteImage(connectedBar:Bool)->NativeOCRRGBAFrame {
        var pixels=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let p=local(x,y)
            let line=connectedBar && CGRect(x:158,y:185,width:2,height:60).contains(p)
            let graphicBounds=CGRect(x:147,y:200,width:26,height:34)
            let graphic=graphicBounds.contains(p) && !graphicBounds.insetBy(dx:1,dy:1).contains(p)
            let value:UInt8=glyphs.contains(where:{$0.contains(p)}) || line || graphic ? 250:80
            let k=(y*side+x)*4
            for channel in 0..<3 { pixels[k+channel]=value }
        } }
        return .init(width:side,height:side,bytesPerRow:side*4,bytes:pixels)!
    }
    let whiteStyle=NativeOCRRFPrimaryEnsemble.EndpointInkStyle([250,250,250])
    let originalWord=rect(145,95,30,110).map(turn)
    // Keep the graphic unowned. Combining its rows with the word in one
    // synthetic run can otherwise paint false private cells between them
    // after rotation, which correctly vetoes a source-preserving trim.
    let whiteBox=NativeCoreMLDetectionBox(polygon:originalWord,score:0.9,
        detectorSeedEvidence:evidence(includeStray:false,includeArt:false))
    let whiteProposals=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[whiteBox],frame:whiteImage(connectedBar:false),
        inkStyles:[whiteStyle],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(whiteProposals.count==2,"private white stroke depth excludes a thinner illustration at \(degrees)")
    for proposal in whiteProposals {
        let end=proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 205-1e-6 && end < 211,"white family trimming preserves the immutable detector end at \(degrees)")
    }
    let grownLaneBox=NativeCoreMLDetectionBox(polygon:rect(145,95,30,145).map(turn),score:0.9,
        detectorSeedEvidence:evidence(includeStray:false,includeArt:false))
    let laneProposals=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[grownLaneBox],frame:whiteImage(connectedBar:false),
        inkStyles:[whiteStyle],retained:[0],peerPolygons:[0:polygon],excluding:[],
        terminalProofs:[0:grownLaneBox.polygon],immutableSourcePolygons:[0:originalWord])
    check(laneProposals.count==2,"earlier lane growth cannot replace immutable DB ingress in the white family proof at \(degrees)")
    for proposal in laneProposals {
        let end=proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 205-1e-6 && end < 211,"a proof inside an earlier lane proposal cannot resurrect unowned graphic growth at \(degrees)")
    }
    let barProposals=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[whiteBox],frame:whiteImage(connectedBar:true),
        inkStyles:[whiteStyle],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(barProposals.allSatisfy { proposal in
        proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()! >= 244
    },"a connected thin white terminal cannot be removed by a thickness nomination at \(degrees)")
    // A coloured print border may fade before the white glyph's real tip.
    // Its connected private white fill must survive a companion-based trim.
    var fadingWhitePixels=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let p=local(x,y),white=glyphs.contains(where:{$0.insetBy(dx:4,dy:4).contains(p)}) ||
            CGRect(x:158,y:184,width:4,height:36).contains(p)
        let colour:[UInt8]=white ? [250,250,250]:(glyphs.contains(where:{$0.contains(p)}) ? [190,30,110]:[80,80,80])
        let k=(y*side+x)*4
        for channel in 0..<3 { fadingWhitePixels[k+channel]=colour[channel] }
    } }
    let fadingWhite=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:fadingWhitePixels)!
    let fadingBox=NativeCoreMLDetectionBox(polygon:originalWord,score:0.9,
        detectorSeedEvidence:evidence(includeStray:false,includeArt:false))
    let fadingProposals=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[fadingBox],frame:fadingWhite,
        inkStyles:[outlined],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(!fadingProposals.isEmpty,"a private white-fill tip remains eligible without its full coloured border at \(degrees)")
    check(fadingProposals.allSatisfy { proposal in
        let end=proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        return end >= 220 && end < 227
    },"companion-based trimming cannot cut the retained connected white glyph at \(degrees)")
    var terminalPixels=fadingWhitePixels
    let terminalDot=CGRect(x:156,y:229,width:8,height:8)
    for y in 0..<side { for x in 0..<side where terminalDot.contains(local(x,y)) {
        for channel in 0..<3 { terminalPixels[(y*side+x)*4+channel]=250 }
    } }
    let terminalImage=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:terminalPixels)!
    let terminalMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,
        resizedWidth:side,resizedHeight:side,region:CGRect(x:0,y:0,width:side,height:side),
        width:side,height:side,values:[Float](repeating:0,count:side*side))
    let terminalTrims=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[fadingBox],frame:terminalImage,
        inkStyles:[outlined],retained:[0],peerPolygons:[0:polygon],excluding:[],probability:terminalMap,exclamationParents:[0])
    check(!terminalTrims.isEmpty,"known source punctuation remains eligible for a bounded trim at \(degrees)")
    check(terminalTrims.allSatisfy { proposal in
        let end=proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        return end >= 237 && end < 245
    },"terminal verification in the proposed crop preserves an already observed stem/dot at \(degrees)")
    let earlierRead=rect(145,50,30,175).map(turn)
    let boundedTrims=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[fadingBox],frame:terminalImage,
        inkStyles:[outlined],retained:[0],peerPolygons:[0:earlierRead],excluding:[],probability:terminalMap,exclamationParents:[0])
    check(!boundedTrims.isEmpty,"terminal keep-constraints still allow removing a distant blank head at \(degrees)")
    check(boundedTrims.allSatisfy { proposal in
        proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()! <= 225
    },"a trim cannot acquire a punctuation dot outside its original admitted read at \(degrees)")
    let partialBox=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,
        detectorSeedEvidence:evidence(includeStray:false,partial:true))
    check(NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[partialBox],frame:image,
        inkStyles:[style],retained:[0],peerPolygons:[0:polygon],excluding:[]).count==2,
        "a private first glyph can anchor the complete coherent observed word at \(degrees)")
    let anchoredStray=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,
        detectorSeedEvidence:evidence(includeStray:true))
    check(NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[anchoredStray],frame:image,
        inkStyles:[style],retained:[0],peerPolygons:[0:polygon],excluding:[]).isEmpty,
        "a remote privately detected primary glyph vetoes a family trim at \(degrees)")
    let detachedHead=CGRect(x:154,y:98,width:12,height:1)
    let detachedStyle=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[102,103,102],[13,13,13]])
    var detachedBytes=[UInt8](repeating:255,count:side*side*4),weakValues=Data(repeating:0,count:side*side)
    for y in 0..<side { for x in 0..<side {
        let p=local(x,y),colour:[UInt8]=detachedHead.contains(p) ? [13,13,13]:
            (glyphs.contains(where:{$0.contains(p)}) ? [102,103,102]:[235,235,235])
        for channel in 0..<3 { detachedBytes[(y*side+x)*4+channel]=colour[channel] }
        if detachedHead.contains(p) { weakValues[y*side+x]=128 }
    } }
    let detachedImage=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:detachedBytes)!
    var weakHeadEvidence=evidence(includeStray:false,includeArt:false)
    func weakROI(_ values:Data)->NativeOCRSourceROIProbabilityEvidence {
        .init(version:1,sourceWidth:side,sourceHeight:side,sourceDigest:String(repeating:"0",count:64),
            roi:.init(x:0,y:0,width:side,height:side),
            detector:.init(originX:0,originY:0,width:side,height:side,fullWidth:side,fullHeight:side),upperBounds:values)
    }
    weakHeadEvidence.sourceProbabilityROI=weakROI(weakValues)
    let weakHeadBox=NativeCoreMLDetectionBox(polygon:originalWord,score:0.9,detectorSeedEvidence:weakHeadEvidence)
    let weakHead=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[weakHeadBox],frame:detachedImage,
        inkStyles:[detachedStyle],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(!weakHead.isEmpty,"a weak-map detached glyph part keeps the source eligible at \(degrees)")
    check(weakHead.allSatisfy { proposal in
        proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.min()! <= 98
    },"same-word recognition cannot authorize dropping a detached DB-supported head stroke at \(degrees)")
    weakHeadEvidence.sourceProbabilityROI=weakROI(Data(repeating:0,count:side*side))
    let unsupportedHeadBox=NativeCoreMLDetectionBox(polygon:originalWord,score:0.9,detectorSeedEvidence:weakHeadEvidence)
    let unsupportedHead=NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:[unsupportedHeadBox],frame:detachedImage,
        inkStyles:[detachedStyle],retained:[0],peerPolygons:[0:polygon],excluding:[])
    check(unsupportedHead.allSatisfy { proposal in
        proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.min()! > 100
    },"an unsupported same-colour island cannot use the detached glyph keep-constraint at \(degrees)")
}

func familyRead(_ text:String,_ confidence:Double,_ tokens:[(String,Double)])->NativeCoreMLRecognizedRegion {
    .init(sourceIndex:0,polygon:rect(10,10,20,60),text:text,confidence:confidence,
        tokenObservations:tokens.map { .init(text:$0.0,confidence:$0.1) })
}
let uncertainFamily=familyRead("abc",0.75,[("a",0.99),("b",0.99),("c",0.3)])
let correctedFamily=familyRead("abd",0.95,[("a",0.99),("b",0.99),("d",0.8)])
check(NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:correctedFamily,
    baseline:uncertainFamily,threshold:0.4),"a physical source proof may resolve one non-majority CTC letter")
check(!NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:correctedFamily,
    baseline:familyRead("abc",0.75,[("a",0.99),("b",0.99),("c",0.9)]),threshold:0.4),
    "source-family trimming cannot replace a confident baseline letter")
check(!NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:familyRead("ab",0.99,[("a",0.99),("b",0.99)]),
    baseline:uncertainFamily,threshold:0.4),"source-family trimming cannot delete a token")
check(!NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:familyRead("ab!",0.99,[("a",0.99),("b",0.99),("!",0.99)]),
    baseline:uncertainFamily,threshold:0.4),"source-family trimming cannot substitute punctuation")
check(!NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:familyRead("abd",0.74,[("a",0.99),("b",0.99),("d",0.8)]),
    baseline:uncertainFamily,threshold:0.4),"source-family correction must improve overall real confidence")
check(!NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:familyRead("abd",0.95,[("a",0.99),("b",0.99),("d",0.45)]),
    baseline:uncertainFamily,threshold:0.4),"the replacement token needs majority support")
check(!NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(candidate:familyRead("abd",0.95,[("a",0.99),("b",0.99),("e",0.8)]),
    baseline:uncertainFamily,threshold:0.4),"token evidence must describe the candidate's actual decoded text")

let dotBaseline=familyRead("a…b",0.95,[("a",0.99),("…",0.9),("b",0.99)])
check(NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:"a.b",baseline:dotBaseline,threshold:0.4),
    "CTC may retokenize a real dot run without changing its word slot")
check(!NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:"ab",baseline:dotBaseline,threshold:0.4),
    "a word-identical trim cannot erase a confident ellipsis")
check(!NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:"ab.",baseline:dotBaseline,threshold:0.4),
    "an observed internal dot cannot move to the tail")
check(!NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:".ab",baseline:dotBaseline,threshold:0.4),
    "an observed internal dot cannot move to the head")
check(NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:"a．b",baseline:dotBaseline,threshold:0.4),
    "full-width dot spelling preserves the same observed mark")
check(NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:"ab",
    baseline:familyRead("a…b",0.75,[("a",0.99),("…",0.3),("b",0.99)]),threshold:0.4),
    "a non-majority false dot is not promoted to a mandatory mark")
check(!NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(candidate:"1.23",
    baseline:familyRead("12.3",0.95,[("1",0.99),("2",0.99),(".",0.95),("3",0.99)]),threshold:0.4),
    "decimal point position cannot silently change")

// A source-rooted white track in paper is not a printed extension merely
// because it has the same brightness and stroke width as the word outline.
for degrees in stride(from:0,through:345,by:15) {
    let a=Double(degrees)*Double.pi/180,c=CGFloat(cos(a)),s=CGFloat(sin(a))
    func turn(_ p:CGPoint)->CGPoint {
        let x=p.x-160,y=p.y-160
        return .init(x:160+x*c-y*s,y:160+x*s+y*c)
    }
    func local(_ x:Int,_ y:Int)->CGPoint {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        return .init(x:160+dx*c+dy*s,y:160-dx*s+dy*c)
    }
    let cores=[CGRect(x:151,y:110,width:18,height:20),CGRect(x:151,y:150,width:18,height:20)]
    let root=CGRect(x:155,y:178,width:7,height:12)
    func image(fillContinues:Bool)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let p=local(x,y),colour:[UInt8]
            if cores.contains(where:{$0.contains(p)}) || root.contains(p) ||
                (fillContinues && CGRect(x:159,y:190,width:7,height:65).contains(p)) { colour=[190,30,110] }
            else if cores.contains(where:{$0.insetBy(dx:-3,dy:-3).contains(p)}) ||
                CGRect(x:151,y:185,width:8,height:70).contains(p) { colour=[255,255,255] }
            else { colour=[170,160,150] }
            let i=(y*side+x)*4
            for k in 0..<3 { bytes[i+k]=colour[k] }
        } }
        return .init(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
    }
    var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
    for y in 0..<side {
        var first:Int?,last:Int?
        for x in 0..<side {
            let p=local(x,y)
            if cores.contains(where:{$0.contains(p)}) || root.contains(p) {
                if first==nil { first=x };last=x
            }
        }
        if let first,let last { runs.append(.init(y:y,x:first,count:last-first+1)) }
    }
    let component=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
        pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
    let e=NativeOCRDetectorSeedEvidence(ownerID:"outlined",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[component],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let polygon=rect(145,100,30,100).map(turn)
    let box=NativeCoreMLDetectionBox(polygon:polygon,score:0.9,detectorSeedEvidence:e)
    let style=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[190,30,110],[255,255,255]])
    let middleCut=NativeCoreMLDetectionBox(polygon:rect(145,100,30,125).map(turn),score:0.9,detectorSeedEvidence:e)
    let continued=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[middleCut],
        frame:image(fillContinues:true),inkStyle:style)
    check(continued != nil,"a privately rooted long stroke may cross a crop edge far from its own start at \(degrees)")
    if let continued {
        let end=continued.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 252,"the middle-cut source retains its complete long terminal at \(degrees)")
    }
    let seam=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[box],frame:image(fillContinues:false),inkStyle:style)
    let seamEnd=seam.map { $0.map { p -> CGFloat in
        let dx=p.x-160,dy=p.y-160
        return 160-dx*s+dy*c
    }.max()! } ?? 200
    check(seamEnd <= 203,"a white paper seam cannot inherit a coloured word's terminal at \(degrees)")
    let printed=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[box],frame:image(fillContinues:true),inkStyle:style)
    check(printed != nil,"a real two-colour long printed terminal retains its proof at \(degrees)")
    if let printed {
        let end=printed.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 252,"source-fill collar reaches the true long printed terminal at \(degrees)")
    }
}

for degrees in stride(from:0,through:345,by:15) {
    let angle=Double(degrees)*Double.pi/180,c=CGFloat(cos(angle)),s=CGFloat(sin(angle))
    func turn(_ p:CGPoint)->CGPoint {
        let x=p.x-160,y=p.y-160
        return .init(x:160+x*c-y*s,y:160+x*s+y*c)
    }
    func local(_ x:Int,_ y:Int)->CGPoint {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        return .init(x:160+dx*c+dy*s,y:160-dx*s+dy*c)
    }
    let glyph=CGRect(x:150,y:120,width:20,height:25),readRect=CGRect(x:145,y:105,width:30,height:110)
    func image(closed:Bool,collar:Bool)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let p=local(x,y),centre=160+max(0,p.y-190)*0.35
            let inStroke=p.y >= 175 && p.y < (closed ? 262:440) && abs(p.x-centre) <= 5
            let fillContinues=collar || p.y <= readRect.maxY
            let colour:[UInt8]
            if glyph.insetBy(dx:3,dy:3).contains(p) || (inStroke && abs(p.x-centre) <= 2) { colour=[255,255,255] }
            else if glyph.contains(p) || (inStroke && fillContinues) { colour=[190,30,110] }
            else { colour=[120,100,80] }
            let k=(y*side+x)*4
            for i in 0..<3 { bytes[k+i]=colour[i] }
        } }
        return .init(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
    }
    func evidence(_ region:CGRect,owner:String,index:Int)->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in 0..<side {
            var first:Int?,last:Int?
            for x in 0..<side where region.contains(local(x,y)) {
                if first==nil { first=x };last=x
            }
            if let first,let last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let part=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
            pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
        return .init(ownerID:owner,parentBoxIndex:index,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[part],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let box=NativeCoreMLDetectionBox(polygon:NativeOCRDirectionGeometry.corners(readRect).map(turn),score:0.9,
        detectorSeedEvidence:evidence(glyph,owner:"word",index:0))
    let read=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:box.polygon,text:"あー",confidence:0.95,
        tokenObservations:[.init(text:"あ",confidence:0.99),.init(text:"ー",confidence:0.91)])
    let style=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[190,30,110],[255,255,255]])
    let proposals=NativeOCRContextualColumnRecovery.retainedCurvedStrokeTerminals(boxes:[box],reads:[read],
        frame:image(closed:true,collar:true),inkStyles:[style],excluding:[],threshold:0.4)
    check(proposals.count==2,"a decoded source-paired curved stroke has a measured cap at \(degrees)")
    for proposal in proposals {
        let localPoints=proposal.polygon.map { p -> CGPoint in
            let dx=p.x-160,dy=p.y-160
            return .init(x:160+dx*c+dy*s,y:160-dx*s+dy*c)
        }
        check(proposal.samplings.count==2 && proposal.samplings.allSatisfy {
            NativeOCRDirectionGeometry.area($0)+1e-6 >= NativeOCRDirectionGeometry.area(proposal.polygon) &&
            NativeOCRContextualColumnRecovery.retainsObservedSource(proposal.polygon,candidate:$0,uncertainty:0.01)
        },"CTC context contains the exact measured curved cap without inflating the output bbox at \(degrees)")
        check(localPoints.map(\.y).max()! >= 261,"the curved printed endpoint survives at \(degrees)")
        check(localPoints.map(\.x).max()! > 185,"the normal envelope follows the bent stroke at \(degrees)")
        check(NativeOCRContextualColumnRecovery.retainsObservedSource(box.polygon,candidate:proposal.polygon,uncertainty:1),
            "curved completion keeps the full prior source crop at \(degrees)")
    }
    check(NativeOCRContextualColumnRecovery.retainedCurvedStrokeTerminals(boxes:[box],reads:[read],
        frame:image(closed:false,collar:true),inkStyles:[style],excluding:[],threshold:0.4).isEmpty,
        "an observation boundary cannot masquerade as a curved cap at \(degrees)")
    check(NativeOCRContextualColumnRecovery.retainedCurvedStrokeTerminals(boxes:[box],reads:[read],
        frame:image(closed:true,collar:false),inkStyles:[style],excluding:[],threshold:0.4).isEmpty,
        "a white paper line without the observed fill is not source continuation at \(degrees)")
    let shiftedPolygon=Array(box.polygon.dropFirst())+[box.polygon[0]]
    let shiftedBox=NativeCoreMLDetectionBox(polygon:shiftedPolygon,score:0.9,detectorSeedEvidence:box.detectorSeedEvidence)
    let shiftedRead=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:shiftedPolygon,text:read.text,
        confidence:read.confidence,tokenObservations:read.tokenObservations)
    let shifted=NativeOCRContextualColumnRecovery.retainedCurvedStrokeTerminals(boxes:[shiftedBox],reads:[shiftedRead],
        frame:image(closed:true,collar:true),inkStyles:[style],excluding:[],threshold:0.4)
    check(shifted.count==2,"a long first edge uses the same curved source kernel at \(degrees)")
    if let q=shifted.first?.polygon {
        let old=CGPoint(x:shiftedPolygon[1].x-shiftedPolygon[0].x,y:shiftedPolygon[1].y-shiftedPolygon[0].y)
        let new=CGPoint(x:q[1].x-q[0].x,y:q[1].y-q[0].y)
        let dot=(old.x*new.x+old.y*new.y)/(hypot(old.x,old.y)*hypot(new.x,new.y))
        check(dot > 0.999,"curved completion preserves the recognizer's first-edge pole at \(degrees)")
    }
    let peerRect=CGRect(x:175,y:241,width:16,height:13)
    let peer=NativeCoreMLDetectionBox(polygon:NativeOCRDirectionGeometry.corners(peerRect).map(turn),score:0.9,
        detectorSeedEvidence:evidence(peerRect,owner:"peer",index:1))
    let peerRead=NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:peer.polygon,text:"い",confidence:0.99)
    check(NativeOCRContextualColumnRecovery.retainedCurvedStrokeTerminals(boxes:[box,peer],reads:[read,peerRead],
        frame:image(closed:true,collar:true),inkStyles:[style,style],excluding:[],threshold:0.4).isEmpty,
        "curved source completion cannot acquire another retained word's private ink at \(degrees)")
}
// Re-observe an admitted word, rather than increasing the original
// RF-free search budget or weakening the source's colour fit. The last
// partly clipped glyph has a veiled version of the same print contrast.
for degrees in stride(from:0,through:345,by:15) {
    let radians=Double(degrees)*Double.pi/180,c=CGFloat(cos(radians)),s=CGFloat(sin(radians))
    func turn(_ p:CGPoint)->CGPoint {
        let x=p.x-160,y=p.y-160
        return .init(x:160+x*c-y*s,y:160+x*s+y*c)
    }
    func local(_ x:Int,_ y:Int)->CGPoint {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        return .init(x:160+dx*c+dy*s,y:160-dx*s+dy*c)
    }
    let glyphs=[CGRect(x:151,y:90,width:18,height:20),CGRect(x:151,y:120,width:18,height:20),
        CGRect(x:151,y:150,width:18,height:20),CGRect(x:151,y:185,width:18,height:20),
        CGRect(x:151,y:215,width:18,height:30)]
    var pixels=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let p=local(x,y),paint=glyphs.contains(where:{$0.contains(p)}),veiled=p.y >= 175
        let colour:[UInt8]=paint ? (veiled ? [89,59,122]:[20,90,160]):(veiled ? [132,88,137]:[235,235,235])
        let k=(y*side+x)*4
        for channel in 0..<3 { pixels[k+channel]=colour[channel] }
    } }
    let image=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:pixels)!
    func evidence(_ regions:[CGRect],owner:String,index:Int)->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in 0..<side {
            var first:Int?,last:Int?
            for x in 0..<side where regions.contains(where:{$0.insetBy(dx:2,dy:2).contains(local(x,y))}) {
                if first==nil {first=x};last=x
            }
            if let first,let last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let part=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
            pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
        return .init(ownerID:owner,parentBoxIndex:index,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[part],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let box=NativeCoreMLDetectionBox(polygon:rect(145,80,30,95).map(turn),score:0.95,
        detectorSeedEvidence:evidence(Array(glyphs.prefix(3)),owner:"word",index:0))
    let read=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:rect(145,80,30,150).map(turn),text:"abcde",confidence:0.852,
        tokenObservations:[.init(text:"a",confidence:0.99),.init(text:"b",confidence:0.99),
            .init(text:"c",confidence:0.99),.init(text:"d",confidence:0.99),.init(text:"e",confidence:0.3)])
    let style=NativeOCRRFPrimaryEnsemble.EndpointInkStyle([20,90,160])
    let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[])
    let proposals=NativeOCRContextualColumnRecovery.retainedObservedWeakTerminals(boxes:[box],reads:[read],
        frame:image,layout:layout,inkStyles:[style],excluding:[],threshold:0.4)
    check(proposals.count==1,"a strong observed prefix can finish its weak veiled last glyph at \(degrees)")
    if let proposal=proposals.first {
        check(proposal.observedWeakTerminal && proposal.measuredTerminalOnly && proposal.sourceTailCompletion,
            "weak-end completion carries its explicit pixel-proof admission path at \(degrees)")
        check(NativeOCRContextualColumnRecovery.retainsObservedSource(read.polygon,candidate:proposal.polygon,uncertainty:1),
            "weak-end completion cannot shrink any retained source at \(degrees)")
        let end=proposal.polygon.map { p -> CGFloat in
            let dx=p.x-160,dy=p.y-160
            return 160-dx*s+dy*c
        }.max()!
        check(end >= 245 && end <= 250,"the veiled glyph's measured cap, not a padded search window, sets its end at \(degrees)")
    }
    let strong=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:read.polygon,text:"abcde",confidence:0.99,
        tokenObservations:read.tokenObservations.map { .init(text:$0.text,confidence:0.99) })
    check(NativeOCRContextualColumnRecovery.retainedObservedWeakTerminals(boxes:[box],reads:[strong],frame:image,
        layout:layout,inkStyles:[style],excluding:[],threshold:0.4).isEmpty,
        "a fully confident word is not given speculative extra glyphs at \(degrees)")
    let peerRegion=CGRect(x:151,y:233,width:18,height:12)
    let peer=NativeCoreMLDetectionBox(polygon:rect(145,231,30,18).map(turn),score:0.95,
        detectorSeedEvidence:evidence([peerRegion],owner:"peer",index:1))
    let peerRead=NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:peer.polygon,text:"z",confidence:0.99)
    check(NativeOCRContextualColumnRecovery.retainedObservedWeakTerminals(boxes:[box,peer],reads:[read,peerRead],frame:image,
        layout:layout,inkStyles:[style,style],excluding:[],threshold:0.4).isEmpty,
        "observed-word completion cannot acquire a retained peer's private glyph at \(degrees)")
}

// A narrow punctuation crop may contain a long connected print border,
// while its closing corner is wider than the crop. The middle private DB
// observations must remain a connectivity root, never new ink by themselves.
for degrees in stride(from:0,to:360,by:15) {
    let side=360,angle=Double(degrees)*Double.pi/180,c=cos(angle),s=sin(angle)
    func turn(_ p:CGPoint)->CGPoint {
        let x=p.x-180,y=p.y-180
        return .init(x:180+x*c-y*s,y:180+x*s+y*c)
    }
    func local(_ x:Int,_ y:Int)->CGPoint {
        let dx=Double(x)+0.5-180,dy=Double(y)+0.5-180
        return .init(x:180+dx*c+dy*s,y:180-dx*s+dy*c)
    }
    let original=rect(169.5,90,21,180).map(turn)
    func rootEvidence(_ peer:Bool,adjacent:Bool = false)->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in 0..<side {
            var first:Int?,last:Int?
            for x in 0..<side {
                let p=local(x,y)
                let own=CGRect(x:172,y:142,width:10,height:10).contains(p) ||
                    CGRect(x:172,y:170,width:10,height:10).contains(p)
                if peer ? CGRect(x:147,y:274,width:49,height:23).contains(p):(adjacent ? CGRect(x:155,y:142,width:10,height:12).contains(p):own) {
                    if first==nil {first=x};last=x
                }
            }
            if let first,let last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let component=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
            pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
        return .init(ownerID:peer ? "separate-cap":"private-point-column",parentBoxIndex:peer ? 1:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:[component],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    func picture(_ corner:Bool)->NativeOCRRGBAFrame {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for y in 0..<side { for x in 0..<side {
            let p=local(x,y)
            let body=CGRect(x:163,y:86,width:28,height:188).contains(p)
            let rim=corner ? (CGRect(x:147,y:274,width:9,height:23).contains(p) ||
                CGRect(x:147,y:288,width:49,height:9).contains(p)):
                CGRect(x:147,y:274,width:49,height:23).contains(p)
            let cap=corner ? (CGRect(x:152,y:279,width:3,height:13).contains(p) ||
                CGRect(x:152,y:289,width:39,height:3).contains(p)):
                CGRect(x:152,y:279,width:39,height:13).contains(p)
            let dots=(0..<12).contains { i in CGRect(x:176,y:102+i*14,width:4,height:4).contains(p) }
            let colour:[UInt8]=(cap || dots) ? [250,250,250]:((body || rim) ? [220,90,5]:[70,70,70])
            let k=(y*side+x)*4
            for channel in 0..<3 {bytes[k+channel]=colour[channel]}
        } }
        return NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
    }
    let map=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
        region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:[Float](repeating:0,count:side*side))
    let box=NativeCoreMLDetectionBox(polygon:original,score:0.9,detectorSeedEvidence:rootEvidence(false))
    let style=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:[[220,90,5],[250,250,250]])
    let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original)!
    var marks:[[CGPoint]]=[]
    _ = NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[box],frame:picture(true),
        probability:map,inkStyle:style,terminalMarkObserver:{marks.append($0)})
    check(marks.contains { basis.bounds($0).maxY >= basis.rect.maxY+20 },
        "private middle ink can link a wider complete closing corner at \(degrees)")
    let proposals=NativeOCRContextualColumnRecovery.retainedTerminals(boxes:[box],frame:picture(true),
        probability:map,inkStyles:[style],retained:[0],peerPolygons:[0:original],excluding:[],
        pointTrainParents:[0],symbolicParents:[0])
    check(proposals.contains { proposal in
        proposal.symbolicTerminalOnly && proposal.samplings.first == proposal.polygon &&
            basis.bounds(proposal.polygon).maxY >= basis.rect.maxY+20 &&
            basis.bounds(proposal.polygon).minX < basis.rect.minX-10
    },"a measured cap alone can certify a symbolic proposal including its actual normal extent at \(degrees)")
    if let proposal=proposals.first {
        check(!proposal.sourceTerminalInk.isEmpty &&
            !NativeOCRContextualColumnRecovery.samplesObservedGlyph(proposal.sourceTerminalInk,
                peerPolygon:rect(155,142,10,12).map(turn),evidence:rootEvidence(false,adjacent:true),excludingPolygon:original),
            "empty corners of the widened bbox do not acquire a neighbour's private glyph at \(degrees)")
        check(NativeOCRContextualColumnRecovery.samplesObservedGlyph(proposal.sourceTerminalInk,
            peerPolygon:rect(147,274,49,23).map(turn),evidence:rootEvidence(true),excludingPolygon:original),
            "a terminal physically on another owner's private ink still reports acquisition at \(degrees)")
    }
    let peer=NativeCoreMLDetectionBox(polygon:rect(147,274,49,23).map(turn),score:0.99,detectorSeedEvidence:rootEvidence(true))
    var foreign:[[CGPoint]]=[]
    _ = NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[box,peer],frame:picture(true),
        probability:map,inkStyle:style,terminalMarkObserver:{foreign.append($0)})
    check(!foreign.contains { basis.bounds($0).maxY >= basis.rect.maxY+20 },
        "a wider corner belonging to another private source cannot be acquired at \(degrees)")
    var rectangle:[[CGPoint]]=[]
    _ = NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:0,boxes:[box],frame:picture(false),
        probability:map,inkStyle:style,terminalMarkObserver:{rectangle.append($0)})
    check(!rectangle.contains { basis.bounds($0).maxY >= basis.rect.maxY+20 },
        "a collared rectangular neighbour is not a closing corner at \(degrees)")
}

// A private first/last glyph may have its own detector ID while two actual
// whole-word crops already contain its cells. Never alias a newly acquired
// neighbour, a middle glyph, punctuation, or a different endpoint reading.
for degrees in stride(from:0.0,to:360,by:15) {
    let angle=CGFloat(degrees)*CGFloat.pi/180
    func turnAlias(_ p:CGPoint)->CGPoint {
        let x=p.x-160,y=p.y-160
        return CGPoint(x:160+x*cos(angle)-y*sin(angle),y:160+x*sin(angle)+y*cos(angle))
    }
    func evidenceAlias(_ polygons:[[CGPoint]])->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for y in 0..<side {
            var start:Int?
            for x in 0...side {
                let inside=x<side && polygons.contains { NativeOCRDirectionGeometry.contains($0,CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)) }
                if inside,start==nil {start=x}
                if !inside,let first=start {runs.append(.init(y:y,x:first,count:x-first));start=nil}
            }
        }
        let c=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,
            pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.95,runs:runs)
        return .init(ownerID:"independent-boundary-glyph",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,
            sourceWidth:side,sourceHeight:side,components:[c],ownershipVersion:2,
            completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let word=rect(120,70,30,150).map(turnAlias),grown=rect(120,70,30,170).map(turnAlias)
    let first=evidenceAlias([rect(124,75,22,20).map(turnAlias)])
    let last=evidenceAlias([rect(124,195,22,20).map(turnAlias)])
    func alias(_ e:NativeOCRDetectorSeedEvidence,_ old:String="いる",_ new:String="いる…",
        _ fragment:String="い",_ base:[CGPoint]?=nil,_ output:[CGPoint]?=nil)->Bool {
        NativeOCRRFPrimaryEnsemble.retainsObservedBoundaryGlyph(child:e,fragment:fragment,
            baselineText:old,candidateText:new,baseline:base ?? word,container:output ?? grown)
    }
    check(alias(first),"complete separately detected initial glyph is already in both observed words at \(degrees)")
    check(alias(last,"るい","るい"),"complete terminal glyph alias at \(degrees)")
    check(!alias(first,"るい","るい"),"matching text at wrong physical endpoint stays independent at \(degrees)")
    check(!alias(first,"ある","いる"),"newly introduced first-letter spelling cannot certify a prior glyph at \(degrees)")
    check(!alias(first,"いる","ある"),"changed paired spelling cannot consume the observed glyph at \(degrees)")
    check(!alias(first,"いる","いる…","い",rect(120,100,30,120).map(turnAlias)),
        "padding that first borrows preceding glyph is never an alias at \(degrees)")
    check(!alias(first,"いる","いる…","い",nil,rect(120,100,30,140).map(turnAlias)),
        "candidate must retain the original complete glyph at \(degrees)")
    check(!alias(evidenceAlias([rect(124,130,22,20).map(turnAlias)])),
        "matching middle glyph cannot steal an endpoint at \(degrees)")
    check(!alias(first,"…いる","…いる","…"),"punctuation is not an independently observed letter alias at \(degrees)")
    check(!alias(evidenceAlias([rect(124,75,22,20).map(turnAlias),rect(124,130,22,20).map(turnAlias)])),
        "all private source cells must belong to one boundary glyph at \(degrees)")
}


// Closed paint at a cut word edge, in both horizontal and vertical scenes.
// An observation boundary and unowned artwork cannot manufacture a cap.
for degrees in stride(from:0.0,to:360,by:15) {
    let a=CGFloat(degrees)*CGFloat.pi/180,c=cos(a),s=sin(a)
    func worldContour(_ p:CGPoint)->CGPoint {
        let x=p.x-160,y=p.y-160
        return .init(x:160+x*c-y*s,y:160+x*s+y*c)
    }
    func localContour(_ x:Int,_ y:Int)->CGPoint {
        let dx=CGFloat(x)+0.5-160,dy=CGFloat(y)+0.5-160
        return .init(x:160+dx*c+dy*s,y:160-dx*s+dy*c)
    }
    let base=CGRect(x:140,y:90,width:30,height:140),quad=NativeOCRDirectionGeometry.corners(base).map(worldContour)
    func sceneContour(_ opened:Bool,_ tail:Bool,_ panel:Bool=false,_ hollow:Bool=false)->(NativeOCRRGBAFrame,NativeOCRDetectorSeedEvidence) {
        let y:CGFloat=tail ? 210:98
        let horizontal=CGRect(x:panel ? 145:(opened ? 80:130),y:y,width:panel ? 17:(opened ? 75:25),height:5)
        let vertical=CGRect(x:panel ? 157:150,y:y,width:5,height:22)
        var pixels=[UInt8](repeating:255,count:side*side*4),runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy),paint=horizontal.contains(p) || vertical.contains(p)
            let k=(yy*side+xx)*4
            let rim=paint && [CGPoint(x:p.x-2,y:p.y),CGPoint(x:p.x+2,y:p.y),CGPoint(x:p.x,y:p.y-2),CGPoint(x:p.x,y:p.y+2)].contains {
                !horizontal.contains($0) && !vertical.contains($0)
            }
            let ink=paint && (!hollow || rim)
            let paper=panel && CGRect(x:130,y:93,width:47,height:34).contains(p)
            for channel in 0..<3 {pixels[k+channel]=panel ? (paint ? 20:(paper ? 245:70)):(ink ? 140:20)}
            if paint && base.contains(p) {
                if let last=runs.last,last.y==yy,last.x+last.count==xx {
                    runs[runs.count-1] = .init(y:yy,x:last.x,count:last.count+1)
                } else {runs.append(.init(y:yy,x:xx,count:1))}
            }
        }}
        let e=NativeOCRDetectorSeedEvidence(ownerID:"owned-contour",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        return (NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:pixels)!,e)
    }
    let (picture,e)=sceneContour(false,false)
    let measured=NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[e],frame:picture,head:true)
    check(measured != nil,"closed private initial stroke recovered at \(degrees)")
    for bright in [true,false] {
        var bytes=picture.bytes
        for k in 0..<(side*side) {
            let ink=picture.bytes[k*4]==140
            let colour:[UInt8]=ink ? (bright ? [250,250,250]:[15,15,15]):[188,162,134]
            for channel in 0..<3 {bytes[k*4+channel]=colour[channel]}
        }
        let colouredPaper=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
        check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[e],frame:colouredPaper,head:true) != nil,
            "open chromatic background in detector cells cannot veto neutral glyph completion at \(degrees), bright\(bright)")
    }
    if let measured,let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(quad) {
        let required=basis.bounds(rect(130,98,25,22).map(worldContour))
        check(measured.insetBy(dx:-2,dy:-2).contains(required),"all closed initial paint kept at \(degrees)")
        check(measured.width<45 && measured.height<40,"search window is not returned as paint at \(degrees)")
    }

    for shift in [0,1] {
        let ordered=(0..<4).map {quad[($0+shift)%4]}
        let box=NativeCoreMLDetectionBox(polygon:ordered,score:0.99,detectorSeedEvidence:e)
        let read=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:ordered,text:"かた",confidence:0.99)
        let proposals=NativeOCRContextualColumnRecovery.retainedEndpointGlyphContours(boxes:[box],reads:[read],groups:[],frame:picture,threshold:0.4)
        check(proposals.count==3,"actual contour sampling proposal at \(degrees),corner shift\(shift)")
        let group=NativeOCRRFPrimaryEnsemble.Group(index:1,members:[0],evidence:[e])
        let whole=NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:ordered,text:"かた",confidence:0.99)
        let grouped=NativeOCRContextualColumnRecovery.retainedEndpointGlyphContours(
            boxes:[box,box],reads:[read,whole],groups:[group],frame:picture,threshold:0.4)
        check(grouped.count==3 && grouped.allSatisfy {$0.parent==1},
            "retained whole word owns contour correction instead of a fragment at \(degrees),shift\(shift)")
        let unretained=NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:ordered,text:"かた",confidence:0.1)
        let member=NativeOCRContextualColumnRecovery.retainedEndpointGlyphContours(
            boxes:[box,box],reads:[read,unretained],groups:[group],frame:picture,threshold:0.4)
        check(member.count==3 && member.allSatisfy {$0.parent==0},
            "failed group cannot veto real independent member contour at \(degrees),shift\(shift)")
        check(proposals.dropFirst().allSatisfy { $0.retainedGlyphWordConfirmation && $0.samplings.last==ordered && $0.polygon==proposals.first?.polygon },
            "unchanged-word confirmation samples the exact retained source at \(degrees),shift\(shift)")
        if let proposal=proposals.first {
            let first=CGPoint(x:ordered[1].x-ordered[0].x,y:ordered[1].y-ordered[0].y)
            for sample in proposal.samplings {
                let edge=CGPoint(x:sample[1].x-sample[0].x,y:sample[1].y-sample[0].y)
                check(abs(first.x*edge.y-first.y*edge.x)<0.0001 && first.x*edge.x+first.y*edge.y>0,
                    "rerec crop preserves horizontal/vertical first-edge identity at \(degrees),shift\(shift)")
            }
        }
    }

    let (openPicture,openEvidence)=sceneContour(true,false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[openEvidence],frame:openPicture,head:true)==nil,
        "open artwork reaching observation edge abstains at \(degrees)")
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[],frame:picture,head:true)==nil,
        "unowned closed mark has no source certificate at \(degrees)")

    let (paperPicture,paperEvidence)=sceneContour(false,false,true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[paperEvidence],frame:paperPicture,head:true)==nil,
        "closed paper panel outside the ink is not a glyph at \(degrees)")
    let (hollowPicture,hollowEvidence)=sceneContour(false,false,false,true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[hollowEvidence],frame:hollowPicture,head:true) != nil,
        "closed outline retains actual print even with background-coloured interior at \(degrees)")

    let (tailPicture,tailEvidence)=sceneContour(false,true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[tailEvidence],frame:tailPicture,head:false) != nil,
        "same normal-side stroke completion at the other word end at \(degrees)")

    func competingContour(_ strongOwned:Bool)->(NativeOCRRGBAFrame,NativeOCRDetectorSeedEvidence) {
        var pixels=[UInt8](repeating:255,count:side*side*4),runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy)
            let strong=CGRect(x:142,y:98,width:18,height:5).contains(p) ||
                CGRect(x:155,y:98,width:5,height:22).contains(p)
            let weak=CGRect(x:164,y:96,width:24,height:4).contains(p) ||
                CGRect(x:164,y:96,width:4,height:22).contains(p)
            let at=(yy*side+xx)*4
            for c in 0..<3 {pixels[at+c]=strong ? 140:(weak ? 230:20)}
            let owned=(strongOwned && strong) || (weak && CGRect(x:164,y:101,width:3,height:5).contains(p))
            if owned {
                if let last=runs.last,last.y==yy,last.x+last.count==xx {
                    runs[runs.count-1] = .init(y:yy,x:last.x,count:last.count+1)
                } else {runs.append(.init(y:yy,x:xx,count:1))}
            }
        }}
        let e=NativeOCRDetectorSeedEvidence(ownerID:"competing-contour",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        return (NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:pixels)!,e)
    }
    let (stablePicture,stableEvidence)=competingContour(true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[stableEvidence],frame:stablePicture,head:true)==nil,
        "complete strongest owned glyph defeats weaker expanding island at \(degrees)")
    let (weakPicture,weakEvidence)=competingContour(false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[weakEvidence],frame:weakPicture,head:true) != nil,
        "measured expansion remains eligible when it is the actual owned glyph at \(degrees)")

    func layeredCounter(_ sideIsland:Bool,_ unownedOutline:Bool)->(NativeOCRRGBAFrame,NativeOCRDetectorSeedEvidence) {
        var bytes=[UInt8](repeating:255,count:side*side*4),runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy)
            let outerX:CGFloat=sideIsland ? 175:153
            let shell=pow((p.x-outerX)/14,2)+pow((p.y-101.5)/17.5,2) <= 1
            let fill=pow((p.x-153)/10,2)+pow((p.y-103)/12,2) <= 1
            let value:UInt8=fill ? 140:(shell ? 250:20)
            for channel in 0..<3 {bytes[(yy*side+xx)*4+channel]=value}
            // Leave more than one detector-cell footprint between the
            // unowned rim and the certified fill; cell rasterization itself
            // legitimately certifies a rim immediately beside an owned cell.
            let fillCore=unownedOutline ?
                pow((p.x-153)/7,2)+pow((p.y-103)/9,2) <= 1:fill
            let own=base.contains(p) && (fillCore || (shell && !unownedOutline))
            if own {
                if let last=runs.last,last.y==yy,last.x+last.count==xx {
                    runs[runs.count-1] = .init(y:yy,x:last.x,count:last.count+1)
                } else {runs.append(.init(y:yy,x:xx,count:1))}
            }
        }}
        let e=NativeOCRDetectorSeedEvidence(ownerID:"nested-glyph-layer",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},
                meanProbability:0.99,runs:runs)],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        return (NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!,e)
    }
    let (nestedImage,nestedEvidence)=layeredCounter(false,false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[nestedEvidence],frame:nestedImage,head:true) != nil,
        "strong in-crop fill cannot veto its independently owned surrounding outline at \(degrees)")
    let (islandImage,islandEvidence)=layeredCounter(true,false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[islandEvidence],frame:islandImage,head:true)==nil,
        "a neighbouring differently coloured island is not a nested print layer at \(degrees)")
    let (unownedLayerImage,unownedLayerEvidence)=layeredCounter(false,true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[unownedLayerEvidence],frame:unownedLayerImage,head:true)==nil,
        "a surrounding contour without its own detector support cannot borrow the fill's ownership at \(degrees)")

    func smallerTerminal(_ weak:Bool)->(NativeOCRRGBAFrame,NativeOCRDetectorSeedEvidence) {
        var bytes=[UInt8](repeating:255,count:side*side*4),runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy)
            let body=CGRect(x:142,y:105,width:18,height:5).contains(p) || CGRect(x:155,y:105,width:5,height:22).contains(p)
            let tip=CGRect(x:142,y:86,width:10,height:3).contains(p) || CGRect(x:149,y:86,width:3,height:14).contains(p)
            for channel in 0..<3 {bytes[(yy*side+xx)*4+channel]=(body || tip) ? 140:20}
            let own=body || (tip && base.contains(p) && (!weak || CGRect(x:150,y:96,width:1,height:1).contains(p)))
            if own {
                if let last=runs.last,last.y==yy,last.x+last.count==xx {
                    runs[runs.count-1] = .init(y:yy,x:last.x,count:last.count+1)
                } else {runs.append(.init(y:yy,x:xx,count:1))}
            }
        }}
        let e=NativeOCRDetectorSeedEvidence(ownerID:"smaller-owned-terminal",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        return (NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!,e)
    }
    let (smallOwned,smallOwnedEvidence)=smallerTerminal(false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[smallOwnedEvidence],frame:smallOwned,head:true) != nil,
        "dominant complete glyph cannot suppress independently owned smaller terminal at \(degrees)")
    let (smallWeak,smallWeakEvidence)=smallerTerminal(true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[smallWeakEvidence],frame:smallWeak,head:true)==nil,
        "weak same-colour island cannot borrow stronger complete glyph ownership at \(degrees)")

    // The detector owns a thin core of a compact printed terminal.
    let largeBase=CGRect(x:110,y:90,width:90,height:140)
    let largeQuad=NativeOCRDirectionGeometry.corners(largeBase).map(worldContour)
    func privateSmallTerminal(_ weak:Bool,_ nudge:CGFloat=0)->(NativeOCRRGBAFrame,NativeOCRDetectorSeedEvidence) {
        var bytes=[UInt8](repeating:255,count:side*side*4),runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy)
            let body=CGRect(x:125,y:125,width:52,height:9).contains(p) ||
                CGRect(x:165,y:125,width:12,height:56).contains(p)
            let tip=pow((p.x-150)/20,2)+pow((p.y-89-nudge)/15,2) <= 1
            let colour:[UInt8]=(body || tip) ? [220,40,150]:[20,20,20]
            for channel in 0..<3 {bytes[(yy*side+xx)*4+channel]=colour[channel]}
            let core=weak ? CGRect(x:149,y:99+nudge,width:1,height:1):CGRect(x:142,y:98+nudge,width:16,height:3)
            let own=body || (tip && core.contains(p))
            if own {
                if let last=runs.last,last.y==yy,last.x+last.count==xx {
                    runs[runs.count-1] = .init(y:yy,x:last.x,count:last.count+1)
                } else {runs.append(.init(y:yy,x:xx,count:1))}
            }
        }}
        let e=NativeOCRDetectorSeedEvidence(ownerID:"thin-private-small-terminal",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},
                meanProbability:0.99,runs:runs)],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        return (NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!,e)
    }
    let (subWordTip,subWordEvidence)=privateSmallTerminal(false,12)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:largeQuad,evidence:[subWordEvidence],frame:subWordTip,head:true) != nil,
        "small terminal novelty uses its own scale with the same pixel floor at \(degrees)")
    let (thinTip,thinTipEvidence)=privateSmallTerminal(false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:largeQuad,evidence:[thinTipEvidence],frame:thinTip,head:true) != nil,
        "a privately witnessed small terminal survives dominant-font size and quarter-mass gates at \(degrees)")
    let (weakTip,weakTipEvidence)=privateSmallTerminal(true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:largeQuad,evidence:[weakTipEvidence],frame:weakTip,head:true)==nil,
        "a few private pixels cannot borrow the dominant glyph's colour for an outside island at \(degrees)")

    func haloScene(_ neighbour:Bool,_ muted:Bool=false)->(NativeOCRRGBAFrame,NativeOCRDetectorSeedEvidence) {
        let shift:CGFloat=neighbour ? 0:(muted ? -12:-8)
        var pixels=[UInt8](repeating:255,count:side*side*4),runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy)
            let first=CGRect(x:142+shift,y:98,width:21,height:8).contains(p) ||
                CGRect(x:155+shift,y:98,width:8,height:24).contains(p)
            let pink=CGRect(x:145+shift,y:101,width:15,height:3).contains(p) ||
                CGRect(x:158+shift,y:101,width:3,height:18).contains(p)
            let second=neighbour && (CGRect(x:174,y:98,width:16,height:8).contains(p) ||
                CGRect(x:182,y:98,width:8,height:24).contains(p))
            let blue=neighbour && (CGRect(x:177,y:101,width:10,height:3).contains(p) ||
                CGRect(x:185,y:101,width:3,height:18).contains(p))
            let bridge=neighbour && CGRect(x:161,y:100,width:16,height:4).contains(p)
            let core:[UInt8]=muted ? [231,155,215]:[220,60,160]
            let halo:[UInt8]=muted ? [202,167,203]:[255,255,255]
            let colour:[UInt8]=pink ? core:(blue ? [60,160,220]:((first || second || bridge) ? halo:[20,20,20]))
            let at=(yy*side+xx)*4
            for c in 0..<3 {pixels[at+c]=colour[c]}
            if first && base.contains(p) {
                if let last=runs.last,last.y==yy,last.x+last.count==xx {
                    runs[runs.count-1] = .init(y:yy,x:last.x,count:last.count+1)
                } else {runs.append(.init(y:yy,x:xx,count:1))}
            }
        }}
        let e=NativeOCRDetectorSeedEvidence(ownerID:"owned-halo",parentBoxIndex:0,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        return (NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:pixels)!,e)
    }
    let (borrowedHalo,borrowedEvidence)=haloScene(true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[borrowedEvidence],frame:borrowedHalo,head:true)==nil,
        "white halo cannot borrow a different-colour neighbouring glyph at \(degrees)")
    let (ownedHalo,ownedHaloEvidence)=haloScene(false)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[ownedHaloEvidence],frame:ownedHalo,head:true) != nil,
        "white halo can finish its actual private chromatic source at \(degrees)")
    let (mutedHalo,mutedEvidence)=haloScene(true,true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[mutedEvidence],frame:mutedHalo,head:true)==nil,
        "desaturated shadow inside RGB tolerance cannot corroborate its own outside growth at \(degrees)")
    let (mutedSource,mutedSourceEvidence)=haloScene(false,true)
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[mutedSourceEvidence],frame:mutedSource,head:true) != nil,
        "actual chromatic stroke remains recoverable beside a muted shadow at \(degrees)")
    var neutralBytes=[UInt8](repeating:255,count:side*side*4),neutralRuns:[NativeOCRDetectorSeedEvidence.Run]=[]
    for yy in 0..<side {for xx in 0..<side {
        let p=localContour(xx,yy)
        let outer=CGRect(x:130,y:98,width:33,height:13).contains(p) || CGRect(x:150,y:98,width:13,height:33).contains(p)
        let fill=CGRect(x:131,y:99,width:31,height:11).contains(p) || CGRect(x:151,y:99,width:11,height:31).contains(p)
        let colour:[UInt8]=fill ? [250,250,250]:(outer ? [136,0,42]:[20,20,20])
        for channel in 0..<3 {neutralBytes[(yy*side+xx)*4+channel]=colour[channel]}
        if outer && base.contains(p) {
            if let last=neutralRuns.last,last.y==yy,last.x+last.count==xx {
                neutralRuns[neutralRuns.count-1] = .init(y:yy,x:last.x,count:last.count+1)
            } else {neutralRuns.append(.init(y:yy,x:xx,count:1))}
        }
    }}
    let neutralEvidence=NativeOCRDetectorSeedEvidence(ownerID:"neutral-fill-coloured-rim",parentBoxIndex:0,
        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
        mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
        components:[.init(seed:neutralRuns[0].y*side+neutralRuns[0].x,pixelCount:neutralRuns.reduce(0){$0+$1.count},
            meanProbability:0.99,runs:neutralRuns)],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    let neutralFrame=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:neutralBytes)!
    check(NativeOCRContextualColumnRecovery.endpointGlyphContour(polygon:quad,evidence:[neutralEvidence],frame:neutralFrame,head:true) != nil,
        "thin coloured rim cannot veto its strongly rooted neutral glyph body at \(degrees)")

    let bareFontBox=NativeCoreMLDetectionBox(polygon:rect(140,95,30,130).map(worldContour),score:0.95)
    let emptyRF=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[])
    for realGlyph in [false,true] {
        var bytes=[UInt8](repeating:255,count:side*side*4)
        for yy in 0..<side {for xx in 0..<side {
            let p=localContour(xx,yy)
            func glyph(_ y:CGFloat)->Bool {
                CGRect(x:145,y:y,width:14,height:5).contains(p) || CGRect(x:154,y:y,width:5,height:20).contains(p)
            }
            let body=[CGFloat(100),135,170,205].contains {glyph($0)}
            let added=realGlyph ? glyph(65):[CGFloat(65),80,90].contains {
                CGRect(x:150,y:$0,width:3,height:3).contains(p)
            }
            for channel in 0..<3 {bytes[(yy*side+xx)*4+channel]=(body || added) ? 30:245}
        }}
        let frame=NativeOCRRGBAFrame(width:side,height:side,bytesPerRow:side*4,bytes:bytes)!
        let completed=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[bareFontBox],layout:emptyRF,frame:frame)
        let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(bareFontBox.polygon)!
        let start=completed.map {f.bounds($0).minY} ?? f.rect.minY
        check(realGlyph ? start <= -25:start >= -5,
            "RF-free contrast lane accepts a resolved glyph but rejects a same-colour speck chain at \(degrees), glyph\(realGlyph)")
    }
}

print("Endpoint continuation checks passed: \(assertions) checks across 24 angles")
'''
cache=root/'build/endpoint-continuation-smoke';cache.mkdir(parents=True,exist_ok=True)
(cache/'main.swift').write_text(stubs+production+checks)
subprocess.run(['swiftc','-O','-module-cache-path',str(root/'build/image-translation-host/rf-primary-module-cache'),str(cache/'main.swift'),'-o',str(cache/'checks')],check=True)
subprocess.run([str(cache/'checks')],check=True)
