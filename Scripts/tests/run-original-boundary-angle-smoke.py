#!/usr/bin/env python3
"""Focused production tests: packet boundaries, immutable inventory and rotation."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Scripts'))
from swift_replay_cache import compile_replay

carrier = ROOT/'Scripts/tests/run-paragraph-fragment-pipeline-smoke.py'
ns = {'__file__': str(carrier)}
exec(carrier.read_text().split('tests =')[0], ns)
support = ns['support'].replace('    var translation: String?',
    '    var sourceRoleEvidence: NativeTranslationRoleEvidence?\n    var translation: String?')
old = (ROOT/'Scripts/tests/run-packet-owned-blocks-smoke.py').read_text()
helper = 'func rowPacket('+old.split('func rowPacket(', 1)[1].split('\nfor fault in 0...5 {', 1)[0]
translation = ROOT/'Aidoku/Core/Translation'
ocr = translation/'NativeEngine/OCR'
sources = [ocr/(name+'.swift') for name in ['BrowserOCRSourceOrientation', 'NativeOCRDetectorSeedEvidence',
    'NativeOCRSourceROIProbabilityEvidence', 'NativeOCRAcceptedSource']]
sources += [translation/'NativeParagraphFragmentGrouping.swift', translation/'NativeParagraphFragmentGrouping+Pipeline.swift',
            translation/'NativeEngine/Translation/TranslationBackgroundRolePolicy.swift']
main = support + 'typealias G = NativeParagraphFragmentGrouping\ntypealias E = NativeOCRDetectorSeedEvidence\n' + helper + r'''
func regions(_ packets: [NativeOCRAcceptedSource.Packet], _ groups: [[Int]]) -> [ReaderTranslationRegion] {
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    return groups.enumerated().map { i, group in
        let points = group.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var r = ReaderTranslationRegion(id: "test-\(i)", rect: CGRect(x: xs.min()!/1000, y: ys.min()!/1000,
            width: (xs.max()!-xs.min()!)/1000, height: (ys.max()!-ys.min()!)/1000),
            source: group.map { packets[$0].text }.joined())
        r.sourceOrientation = packets[group[0]].orientation; r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: Set(group), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
}
let common = G.TextScope(owner: 1, box: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)
let shortHeading=[rowPacket(0,x:315,y:186,width:51,height:144,text:"短い頭",vertical:true),
    rowPacket(1,x:314,y:383,width:48,height:510,text:"続く長い本文です",vertical:true)]
precondition(G.reconcilingObservations(regions(shortHeading,[[0],[1]]),scopes:[]).count==1,
    "a unique short heading continues into a long column without an RF-owner shortcut")
let rubyHosts=[G.Atom(index:0,source:"漢字",box:CGRect(x:100,y:100,width:40,height:130),orientation:.vertical,owner:nil),
    G.Atom(index:1,source:"続く本文",box:CGRect(x:100,y:210,width:40,height:220),orientation:.vertical,owner:nil)]
let longRuby=G.Atom(index:2,source:"かんじつづく",box:CGRect(x:145,y:105,width:16,height:220),orientation:.vertical,owner:nil)
precondition(G.intercolumnRubyHost(longRuby,columns:rubyHosts)==0,
    "one ruby rail can span overlapping fragments of one body column")
let outsideRuby=G.Atom(index:2,source:longRuby.source,box:CGRect(x:145,y:105,width:16,height:400),orientation:.vertical,owner:nil)
precondition(G.intercolumnRubyHost(outsideRuby,columns:rubyHosts)==nil,"ruby still needs full host containment")
// Latin crop padding cannot turn a large owned-ink blank band into leading.
let paragraphs = [rowPacket(0,x:100,y:100,width:180,height:18,text:"FIRST ROW"),
    rowPacket(1,x:100,y:132,width:170,height:18,text:"SECOND ROW"),
    rowPacket(2,x:100,y:300,width:180,height:18,text:"THIRD ROW"),
    rowPacket(3,x:100,y:332,width:170,height:18,text:"FOURTH ROW")]
let splitParagraphs = G.reconcilingObservations(regions(paragraphs,[[0,1,2,3]]),scopes:[common])
precondition(splitParagraphs.count==2,"original ink blank band must split padded paragraph envelopes")
precondition(Set(splitParagraphs.map { $0.acceptedSource.membership!.body })==Set([Set([0,1]),Set([2,3])]))
precondition(G.reconcilingObservations(regions(paragraphs,[[0,1],[2,3]]),scopes:[common]).count==2,
    "a shared broad RF scope must not rejoin an empty paragraph band")
precondition(G.reconcilingObservations(regions(Array(paragraphs.prefix(2)),[[0,1]]),scopes:[common]).count==1,
    "ordinary Latin leading remains one paragraph")
for degrees in stride(from:0.0,to:360.0,by:15) {
    let a=degrees*Double.pi/180
    let rotated=paragraphs.enumerated().map { id, packet -> NativeOCRAcceptedSource.Packet in
        let source=packet.polygon.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
        let inkSource=source.insetBy(dx:3,dy:6)
        let quad=packet.polygon.map { p in CGPoint(x:500+(p.x-200)*cos(a)-(p.y-200)*sin(a),
            y:500+(p.x-200)*sin(a)+(p.y-200)*cos(a)) }
        let box=quad.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
        var runs:[E.Run]=[]
        for y in Int(floor(box.minY))..<Int(ceil(box.maxY)) {
            var row:[Int]=[]
            for x in Int(floor(box.minX))..<Int(ceil(box.maxX)) {
                let dx=CGFloat(x)+0.5-500,dy=CGFloat(y)+0.5-500
                if inkSource.contains(CGPoint(x:200+dx*cos(a)+dy*sin(a),y:200-dx*sin(a)+dy*cos(a))) { row.append(x) }
            }
            if let first=row.first,let last=row.last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let first=runs.first!
        let component=E.Component(seed:first.y*1000+first.x,pixelCount:runs.reduce(0){$0+$1.count},
            meanProbability:1,runs:runs)
        let seed=E(ownerID:"rotated:\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",
            threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:1000,mapFullHeight:1000,
            sourceWidth:1000,sourceHeight:1000,components:[component],ownershipVersion:2,
            completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        precondition(seed.isValid)
        let directed = id % 2 == 0 ? quad : [quad[2],quad[3],quad[0],quad[1]]
        return .init(polygon:directed,text:packet.text,score:packet.score,orientation:.horizontal,
            orientationIsEstimated:false,sourceTileBounds:nil,erasurePolygons:[],detectorSeedEvidence:[seed])
    }
    let split=G.reconcilingObservations(regions(rotated,[[0,1,2,3]]),scopes:[common])
    precondition(Set(split.map { $0.acceptedSource.membership!.body })==Set([Set([0,1]),Set([2,3])]),
        "owned-ink paragraph bands must be rotation invariant: \(degrees)")
    precondition(G.reconcilingObservations(regions(Array(rotated.prefix(2)),[[0,1]]),scopes:[common]).count==1,
        "thin DB cores cannot turn ordinary leading into a paragraph band: \(degrees)")
}
print("Owned-ink paragraph-band checks passed: 24 full-scene rotations")
// A terminal mark may be narrower than the ordinary font. It still needs a unique column.
let tail = [rowPacket(0, x: 100, y: 100, width: 24, height: 200, text: "body", vertical: true),
            rowPacket(1, x: 107, y: 302, width: 10, height: 20, text: "!", vertical: true)]
let tailResult = G.reconcilingObservations(regions(tail, [[0], [1]]), scopes: [common])
precondition(tailResult.count == 1 && tailResult[0].source == "body!")
let rows = [rowPacket(0, x: 100, y: 100, width: 200, height: 30, text: "上段本文"),
            rowPacket(1, x: 140, y: 140, width: 120, height: 30, text: "下段本文")]
precondition(G.reconcilingObservations(regions(rows, [[0], [1]]), scopes: [common]).count == 1)
for (height, y) in [(24, 140), (30, 165)] {
    let independent = [rows[0], rowPacket(1, x: 140, y: y, width: 120, height: height, text: "下段本文")]
    let separate = G.reconcilingObservations(regions(independent, [[0], [1]]), scopes: [common])
    precondition(separate.count == 2)
    let splitRows = G.reconcilingObservations(regions(independent, [[0, 1]]), scopes: [common])
    precondition(splitRows.count == 2)
    precondition(Set(splitRows.flatMap { $0.acceptedSource.membership!.body }) == [0, 1])
    precondition(splitRows.allSatisfy { $0.acceptedSource.membership!.body.count == 1 })
}
let latin = [rowPacket(0, x: 100, y: 100, width: 200, height: 30, text: "CAPITALS"),
             rowPacket(1, x: 140, y: 165, width: 120, height: 24, text: "mixed case")]
precondition(G.reconcilingObservations(regions(latin, [[0, 1]]), scopes: [common]).count == 1)
let ownedRows = [rows[0], rowPacket(1, x: 140, y: 165, width: 120, height: 30, text: "下段本文")]
var withInk = regions(ownedRows, [[0, 1]])
let ownedInk = ownedRows[1].polygon.map { CGPoint(x: $0.x/1000, y: $0.y/1000) }
withInk[0].auxiliaryInkPolygons = [ownedInk]
let inkSplit = G.reconcilingObservations(withInk, scopes: [common])
precondition(inkSplit.count == 2)
precondition(inkSplit.flatMap(\.auxiliaryInkPolygons) == [ownedInk])
precondition(inkSplit.first { $0.acceptedSource.membership!.body.contains(1) }!.auxiliaryInkPolygons == [ownedInk])
let interrupted = [rowPacket(0, x: 100, y: 100, width: 20, height: 100, text: "upper", vertical: true),
    rowPacket(1, x: 100, y: 330, width: 20, height: 100, text: "lower", vertical: true),
    rowPacket(2, x: 95, y: 212, width: 30, height: 106, text: "middle", vertical: true)]
let repaired = G.reconcilingObservations(regions(interrupted, [[1, 0], [2]]), scopes: [common])
precondition(repaired.count == 1 && repaired[0].source == "uppermiddlelower")
precondition(repaired[0].acceptedSource.membership!.body == [0, 1, 2])
func tilted(_ id: Int, x: Int, y: Int, angle: CGFloat) -> NativeOCRAcceptedSource.Packet {
    let p = rowPacket(id, x: x, y: y, width: 20, height: 160, text: id == 0 ? "A" : "B", vertical: true)
    let center = CGPoint(x: x + 10, y: y + 80)
    let quad = p.polygon.map { q in
        CGPoint(x: center.x + cos(angle)*(q.x-center.x)-sin(angle)*(q.y-center.y),
                y: center.y + sin(angle)*(q.x-center.x)+cos(angle)*(q.y-center.y))
    }
    return .init(polygon: quad, text: p.text, score: p.score, orientation: p.orientation,
        orientationIsEstimated: false, sourceTileBounds: nil, erasurePolygons: [], detectorSeedEvidence: p.detectorSeedEvidence)
}
let slanted = [tilted(0, x: 100, y: 100, angle: -0.2), tilted(1, x: 200, y: 400, angle: -0.3)]
let input = regions(slanted, [[0, 1]])
let tight = [G.TextScope(owner: 2, box: CGRect(x: 0.099, y: 0.099, width: 0.022, height: 0.162), confidence: 0.8),
             G.TextScope(owner: 3, box: CGRect(x: 0.199, y: 0.399, width: 0.022, height: 0.162), confidence: 0.8)]
let split = G.reconcilingObservations(input, scopes: [common] + tight)
precondition(split.count == 2)
for r in split {
    let id = r.acceptedSource.membership!.body.first!
    for (a, b) in zip(r.polygon, slanted[id].polygon) {
        precondition(abs(a.x-b.x/1000) < 1e-12 && abs(a.y-b.y/1000) < 1e-12)
    }
}
precondition(G.reconcilingObservations(input, scopes: [common]).count == 1)
let sameDirection = [rowPacket(0,x:100,y:100,width:20,height:200,text:"本文一",vertical:true),
    rowPacket(1,x:130,y:130,width:20,height:200,text:"本文二",vertical:true),
    rowPacket(2,x:160,y:160,width:20,height:200,text:"本文三",vertical:true)]
let fragments = sameDirection.enumerated().map { i,p in
    let b=p.polygon.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
    return G.TextScope(owner:i,box:b.applying(.init(scaleX:0.001,y:0.001)),confidence:0.9)
}
let notSplit=G.reconcilingObservations(regions(sameDirection,[[0,1,2]]),scopes:fragments)
precondition(notSplit.count==1,"fragmented RF scopes alone cannot split a coherent original writing direction")
let paragraphsAcross=[100,130,172,202,244,274].enumerated().map { i,x in
    rowPacket(i,x:x,y:100,width:20,height:200,text:"本文\(i)。",vertical:true)
}
let separateAcross=G.reconcilingObservations(regions(paragraphsAcross,[[0,1],[2,3],[4,5]]),scopes:[])
precondition(Set(separateAcross.map { $0.acceptedSource.membership!.body })==Set([Set([0,1]),Set([2,3]),Set([4,5])]),
    "wide unowned gutters cannot chain closed independent same-leading utterances")
let marker=rowPacket(2,x:95,y:212,width:30,height:106,text:"middle")
let q=marker.polygon
let cyclicMarker=NativeOCRAcceptedSource.Packet(polygon:[q[3],q[0],q[1],q[2]],text:marker.text,
    score:marker.score,orientation:.horizontal,orientationIsEstimated:false,sourceTileBounds:nil,
    erasurePolygons:[],detectorSeedEvidence:marker.detectorSeedEvidence)
let mixed=G.reconcilingObservations(regions([interrupted[0],interrupted[1],cyclicMarker],[[0,1],[2]]),scopes:[common])
precondition(mixed.count==1,"inline mark remains in its original column")
let side=CGPoint(x:mixed[0].polygon[1].x-mixed[0].polygon[0].x,
                 y:mixed[0].polygon[1].y-mixed[0].polygon[0].y)
precondition(abs(side.y)<1e-12,"a cyclic horizontal inline marker cannot rotate the vertical body's envelope")
// Already merged input must be repaired too; all cyclic/reversed quad orders
// must give the same enclosure, including estimated-vertical inline fragments.
let upright = [rowPacket(0,x:100,y:100,width:20,height:300,text:"本文甲",vertical:true),
    rowPacket(1,x:130,y:100,width:20,height:300,text:"本文乙",vertical:true),
    rowPacket(2,x:160,y:310,width:8,height:75,text:"mark",vertical:true)]
var reference: [CGPoint] = []
for reversed in [false,true] { for shift in 0..<4 {
    let originals = upright.enumerated().map { i,p -> NativeOCRAcceptedSource.Packet in
        let base = reversed ? Array(p.polygon.reversed()) : p.polygon
        let q = (0..<4).map { base[($0+shift+i)%4] }
        return .init(polygon:q,text:p.text,score:p.score,orientation:p.orientation,
            orientationIsEstimated:true,sourceTileBounds:nil,erasurePolygons:[],detectorSeedEvidence:p.detectorSeedEvidence)
    }
    var retained = regions(originals,[[0,1,2]])
    retained[0].polygon = [CGPoint(x:0.1,y:0.1),CGPoint(x:0.2,y:0.2),
                           CGPoint(x:0.1,y:0.5),CGPoint(x:0,y:0.4)]
    let repaired = G.reconcilingObservations(retained,scopes:[common])
    precondition(repaired.count==1 && repaired[0].acceptedSource.membership!.body==Set([0,1,2]))
    let q = repaired[0].polygon
    precondition(abs(q[1].y-q[0].y)<1e-12,"retained composite must not keep a stale diagonal")
    if reference.isEmpty { reference=q }
    for (a,b) in zip(q,reference) {
        precondition(abs(a.x-b.x)<1e-12 && abs(a.y-b.y)<1e-12,"cyclic/reversed ordering cannot change enclosure")
    }
} }
print("Original boundaries: terminal marks, centered rows, closed insertion, nested owners, inventory and exact split angles passed")
let raised = [rowPacket(0,x:453,y:38,width:27,height:49,text:"反応",vertical:true),
    rowPacket(1,x:370,y:54,width:23,height:73,text:"本文甲",vertical:true),
    rowPacket(2,x:399,y:52,width:27,height:99,text:"本文乙",vertical:true)]
let raisedScopes = [G.TextScope(owner:0,box:CGRect(x:0.450,y:0.035,width:0.033,height:0.055),confidence:0.9),
    G.TextScope(owner:1,box:CGRect(x:0.367,y:0.049,width:0.062,height:0.105),confidence:0.9)]
let raisedOutput=G.reconcilingObservations(regions(raised,[[0,1,2]]),scopes:raisedScopes)
precondition(Set(raisedOutput.map { $0.acceptedSource.membership!.body })==Set([Set([0]),Set([1,2])]),
    "an independently RF-owned raised short response cannot bridge the aligned body columns")
let aboveTitle = [rowPacket(0,x:238,y:861,width:19,height:12,text:"反応",vertical:true),
    rowPacket(1,x:149,y:886,width:155,height:34,text:"横組みの見出し")]
var titleInput=regions(aboveTitle,[[0,1]])
titleInput[0].auxiliaryInkPolygons=[aboveTitle[1].polygon.map { CGPoint(x:$0.x/1000,y:$0.y/1000) }]
let titleOutput=G.reconcilingObservations(titleInput,scopes:[common])
precondition(titleOutput.count==2 && titleOutput.flatMap(\.auxiliaryInkPolygons).count==1,
    "a mixed-direction external callout is not an inline title fragment; keep its original auxiliary ink")
let cellA=E.Component(seed:100100,pixelCount:4,meanProbability:1,
    runs:[.init(y:100,x:100,count:2),.init(y:101,x:100,count:2)])
let cellB=E.Component(seed:100110,pixelCount:4,meanProbability:1,
    runs:[.init(y:100,x:110,count:2),.init(y:101,x:110,count:2)])
func aliasPacket(_ id:Int,_ cells:[E.Component],_ text:String,_ small:Bool=false)->NativeOCRAcceptedSource.Packet {
    let p=rowPacket(id,x:100,y:100,width:small ? 2 : 20,height:small ? 2 : 80,text:text,vertical:true)
    let evidence=E(ownerID:"exact-alias-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",
        threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:1000,mapFullHeight:1000,
        sourceWidth:1000,sourceHeight:1000,components:cells,ownershipVersion:2,
        completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    precondition(evidence.isValid)
    return .init(polygon:p.polygon,text:text,score:p.score,orientation:p.orientation,orientationIsEstimated:false,
        sourceTileBounds:nil,erasurePolygons:[],detectorSeedEvidence:[evidence])
}
let aliases=[aliasPacket(0,[cellA,cellB],"AB"),rowPacket(1,x:130,y:100,width:20,height:80,text:"CD",vertical:true),
    aliasPacket(2,[cellA],"X",true)]
let aliasOutput=G.reconcilingObservations(regions(aliases,[[0,1],[2]]),scopes:[common])
precondition(aliasOutput.count==1 && aliasOutput[0].source=="ABCD" &&
    aliasOutput[0].acceptedSource.membership!.readings.contains(2),
    "complete exact-run aliases may change ownership flags but cannot append duplicate OCR text")
print("RF-owned callouts, mixed-direction external ink and exact connected-component alias checks passed")
// Eight glyphs over 200px give a 25px advance compatible with the 20px face.
let corroborated=[rowPacket(0,x:100,y:100,width:20,height:200,text:"本文の第一列です",vertical:true),
    rowPacket(1,x:144,y:100,width:20,height:200,text:"本文の第二列です",vertical:true),
    rowPacket(2,x:188,y:100,width:20,height:200,text:"本文の第三列です",vertical:true)]
let separateRF=corroborated.enumerated().map { i,p in
    G.TextScope(owner:i,box:p.polygon.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
        .applying(.init(scaleX:0.001,y:0.001)),confidence:0.9)
}
precondition(G.reconcilingObservations(regions(corroborated,[[0],[1],[2]]),scopes:separateRF).count==1,
    "three independent RF columns plus the same private-ink baseline can corroborate one paragraph")
precondition(G.reconcilingObservations(regions(Array(corroborated.prefix(2)),[[0],[1]]),scopes:Array(separateRF.prefix(2))).count==2,
    "two merely nearby independently owned columns cannot borrow the native three-column certificate")
// Extending one sampling box through the next paragraph must not move its
// private glyphs into that paragraph. Test the complete scene at every 15°.
for degrees in stride(from:0.0,to:360.0,by:15) {
    let a=degrees*Double.pi/180
    func rotate(_ p:CGPoint)->CGPoint {
        .init(x:500+(p.x-150)*cos(a)-(p.y-275)*sin(a),
              y:500+(p.x-150)*sin(a)+(p.y-275)*cos(a))
    }
    func quad(_ b:CGRect)->[CGPoint] {
        [CGPoint(x:b.minX,y:b.minY),CGPoint(x:b.maxX,y:b.minY),
         CGPoint(x:b.maxX,y:b.maxY),CGPoint(x:b.minX,y:b.maxY)].map(rotate)
    }
    let ink=[CGRect(x:100,y:100,width:40,height:100),CGRect(x:150,y:100,width:40,height:100),
             CGRect(x:100,y:350,width:40,height:100),CGRect(x:50,y:350,width:40,height:100)]
    let packets=ink.enumerated().map { id,b -> NativeOCRAcceptedSource.Packet in
        let crop=id == 0 ? CGRect(x:100,y:100,width:40,height:330):b
        let box=quad(b).reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
        var runs:[E.Run]=[]
        for y in Int(floor(box.minY))..<Int(ceil(box.maxY)) {
            var row:[Int]=[]
            for x in Int(floor(box.minX))..<Int(ceil(box.maxX)) {
                let dx=CGFloat(x)+0.5-500,dy=CGFloat(y)+0.5-500
                if b.contains(CGPoint(x:150+dx*cos(a)+dy*sin(a),y:275-dx*sin(a)+dy*cos(a))) { row.append(x) }
            }
            if let first=row.first,let last=row.last { runs.append(.init(y:y,x:first,count:last-first+1)) }
        }
        let first=runs.first!,component=E.Component(seed:first.y*1000+first.x,
            pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
        let seed=E(ownerID:"padding:\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",
            threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:1000,mapFullHeight:1000,
            sourceWidth:1000,sourceHeight:1000,components:[component],ownershipVersion:2,
            completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
        precondition(seed.isValid)
        return .init(polygon:quad(crop),text:["上の第一列","上の第二列","下の第一列","下の第二列"][id],score:0.99,
            orientation:.vertical,orientationIsEstimated:false,sourceTileBounds:nil,erasurePolygons:[],detectorSeedEvidence:[seed])
    }
    let scopes=[CGRect(x:90,y:90,width:110,height:120),CGRect(x:40,y:340,width:110,height:120)].enumerated().map { i,b in
        G.TextScope(owner:i,box:quad(b).reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
            .applying(.init(scaleX:0.001,y:0.001)),confidence:0.9)
    }
    let result=G.reconcilingObservations(regions(packets,[[0,2],[1],[3]]),scopes:scopes)
    precondition(Set(result.map { $0.acceptedSource.membership!.body })==Set([Set([0,1]),Set([2,3])]),
        "padding must not borrow another RF-owned paragraph: \(degrees)")
    precondition(result.first { $0.acceptedSource.membership!.body.contains(0) }!.rect.maxY >=
        packets[0].polygon.map(\.y).max()!/1000-1e-9,"the edited enclosure must still be retained")
}
print("Sampling-padding source separation passed: 24 full-scene rotations")
// A small symbol detached from the wrong column can reattach through its
// actual same-column neighbor; the provisional split is not a paragraph veto.
for oversized in [false,true] {
    let pieces=[rowPacket(0,x:125,y:100,width:25,height:120,text:"左上本文",vertical:true),
        rowPacket(1,x:125,y:250,width:25,height:120,text:"左下本文",vertical:true),
        rowPacket(2,x:164,y:230,width:16,height:oversized ? 80:19,text:"♡"),
        rowPacket(3,x:160,y:100,width:25,height:120,text:"右上本文",vertical:true),
        rowPacket(4,x:160,y:250,width:25,height:120,text:"右下本文",vertical:true)]
    let scope=G.TextScope(owner:1,box:CGRect(x:0.11,y:0.09,width:0.09,height:0.3),confidence:0.95)
    let output=G.reconcilingObservations(regions(pieces,[[0,1,2],[3,4]]),scopes:[scope])
    if oversized {
        precondition(output.count>1,"a large independent horizontal face keeps its split boundary")
    }else{
        precondition(output.count==1 && output[0].acceptedSource.membership!.body==Set(0...4),
            "a measured inline symbol may find its real column without losing its containing paragraph")
        precondition(output[0].source.filter { $0 == "♡" }.count==1,"reattachment cannot duplicate symbol text")
    }
}
'''
cache = ROOT/'build/original-boundary-angle-smoke'
cache.mkdir(parents=True, exist_ok=True)
main = main.replace('precondition(', 'checked(#line,')
main = r'''
func checked(_ line: Int, _ condition: @autoclosure () -> Bool,
             _ message: @autoclosure () -> String = "regression invariant") {
    if !condition() {
        FileHandle.standardError.write(Data("Regression line \(line): \(message())\n".utf8))
        fatalError("regression failed")
    }
}
''' + main
compile_replay(cache, sources, main, cache/'smoke')
subprocess.run([str(cache/'smoke')], check=True)
