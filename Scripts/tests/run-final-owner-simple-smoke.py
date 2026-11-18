#!/usr/bin/env python3
"""Run actual final resolver+pipeline+membership code without images or models.

Private stand-ins contain unrelated region styling fields only. Original packet
binding, metadata unions, geometry overlap, filtering and alias transport are
the actual production sources. Synthetic cases are regressions, not GT quality.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Aidoku/Core/Translation'
OCR = BASE / 'NativeEngine/OCR'
SUPPORT = r'''
import Foundation
import CoreGraphics
struct NativeOCRDetectorSeedEvidence: Equatable, Sendable {
    static func preservingUnion(_ values: [[Self]?]) -> [Self]? {
        precondition(values.allSatisfy {$0 == nil}); return nil
    }
}
struct ReaderTranslationRegion {
    var id:String; var rect:CGRect; var source:String
    var sourceColumnRecognition:Int?=nil; var sourceRFParagraphRecognition:Int?=nil
    var translation:String?=nil; var keepsClassifiedSFXSource=false; var rendersUnchangedSymbols=false
    var polygon:[CGPoint]; var confidence:Double; var sourceImageAspectRatio:Double?=nil
    var translationOrder:Int?=nil; var translationOrderVersion:String?=nil
    var sourceOrientation:BrowserOCRSourceOrientation = .unknown; var sourceSingleVerticalColumn:Bool?=nil
    var translationReuseIdentity:String?=nil; var translationRecoveryFailure:String?=nil
    var auxiliaryInkRects:[CGRect]=[]; var auxiliaryInkPolygons:[[CGPoint]]=[]
    var detectorSeedEvidence:[NativeOCRDetectorSeedEvidence]?=nil
    var acceptedSource:NativeOCRSourceMetadata = .init(); var sourceOCRAlternatives:[Int]=[]
    var sourceRoleEvidence:Int?=nil; var balloonInterior:Int?=nil; var unitMemberRects:[CGRect]=[]
    var isOccludedFinePrint=false; var isRecoveredLine=false
}
enum NativeParagraphFragmentGrouping {
    static func preservingOriginalAngle(_ region: inout ReaderTranslationRegion, useLayout: Bool) {}
}
'''
CHECK = r'''
import Foundation
import CoreGraphics
typealias D=NativeFinalOutputDuplicateResolver
func points(_ x:CGFloat=0)->[CGPoint] {[
    .init(x:x,y:0),.init(x:x+10,y:0),.init(x:x+10,y:10),.init(x:x,y:10)]}
func polygon(_ x:Double=0)->[D.F.Point] {points(CGFloat(x)).map {.init(x:Double($0.x),y:Double($0.y))}}
func table(_ positions:[CGFloat],layout:Bool=false)->NativeOCRAcceptedSource.PacketTable {
    .init(packets:positions.map {x in .init(polygon:points(x),text:"source",score:0.9,orientation:.vertical,
        orientationIsEstimated:false,sourceTileBounds:nil,erasurePolygons:[points(x)],detectorSeedEvidence:nil,
        layoutPolygon:layout ? points(x):nil)},width:100,height:100)
}
func region(_ ordinal:Int,_ confidence:Double,_ t:NativeOCRAcceptedSource.PacketTable)->ReaderTranslationRegion {
    var r=ReaderTranslationRegion(id:"owner-\(ordinal)",rect:.init(x:0,y:0,width:0.1,height:0.1),
        source:"same decoded source",polygon:points().map {.init(x:$0.x/100,y:$0.y/100)},confidence:confidence)
    r.acceptedSource = .init(.init(table:t,body:[ordinal],readings:[],unknownDedup:[],hasUntrackedInputs:false))
    r.auxiliaryInkPolygons=[points(CGFloat(ordinal))]
    r.sourceOCRAlternatives=[ordinal]
    return r
}
@main struct Check {
    static func main() {
        let originals=table([0,0.6,1.2])
        let input=[region(0,0.9,originals),region(1,0.8,originals),region(2,0.7,originals)]
        let first=D.applying(input)
        precondition(first.suppressed == 1 && first.regions.map(\.id)==["owner-0","owner-2"])
        let retained=first.regions[0].acceptedSource.membership!
        precondition(retained.table === originals && retained.table.packets.count == 3)
        precondition(retained.body == [0,1] && retained.unknownDedup == [1])
        precondition(first.regions[0].auxiliaryInkPolygons.count==2 && first.regions[0].sourceOCRAlternatives==[0,1])
        let second=D.applying(first.regions)
        precondition(second.suppressed==0 && second.regions.map(\.id)==["owner-0","owner-2"],
            "An acquired erasure alias became a voter on the next pass")
        let allRefs=second.regions.reduce(into:Set<Int>()) {ids,r in
            let m=r.acceptedSource.membership!; ids.formUnion(m.body.union(m.readings).union(m.unknownDedup))
        }
        precondition(allRefs==[0,1,2],"Original source/erasure ancestry was dropped")
        let compound: [D.Observation] = [
            .init(polygon:polygon(),confidence:0.9,body:[0],readings:[],table:0,eligible:true),
            .init(polygon:polygon(),confidence:0.8,body:[1,2],readings:[],table:0,eligible:true)]
        let physical=[0:[polygon(),polygon(0.2),polygon(30)]]
        precondition(D.selectOriginalWitness(compound,sourceTables:physical).keep==[true,true],
            "One original witness incorrectly erased a distinct compound constituent")
        precondition(D.selectOriginalWitness(compound,sourceTables:physical,
            configuration:.init(requireOriginalWitness:false)).keep==[true,false])
        let differentTables: [D.Observation] = [
            .init(polygon:polygon(),confidence:0.9,body:[0],readings:[],table:0,eligible:true),
            .init(polygon:polygon(),confidence:0.8,body:[0],readings:[],table:1,eligible:true)]
        precondition(D.selectOriginalWitness(differentTables,sourceTables:[0:[polygon()],1:[polygon()]]).keep==[true,true])
        var reading=compound
        reading[1] = .init(polygon:polygon(),confidence:0.8,body:[1],readings:[2],table:0,eligible:true)
        precondition(D.selectOriginalWitness(reading,sourceTables:physical).keep==[true,true])
        var bad=compound
        bad[0] = .init(polygon:polygon(),confidence:0.9,body:[0],readings:[],table:0,eligible:true,nonVotingSourcePackets:[999])
        bad[1] = .init(polygon:polygon(),confidence:0.8,body:[1],readings:[],table:0,eligible:true)
        precondition(D.selectOriginalWitness(bad,sourceTables:physical).keep==[true,true])
        precondition(D.select(bad,sourceTables:physical,sourceAgreement:[0:[1,1,1]]).keep==[true,true],
            "Invalid physical/nonvoting reference failed to abstain on the layout path")
        bad[0] = .init(polygon:polygon(),confidence:0.9,body:[0],readings:[],table:0,eligible:true,nonVotingSourcePackets:[0])
        precondition(D.select(bad,sourceTables:physical,sourceAgreement:[0:[1,1,1]]).keep==[true,true],
            "All-nonvoting legacy owner was allowed to witness a deletion")
        let legacyTable=table([0,0.2],layout:true)
        let a=region(0,0.9,legacyTable),b=region(1,0.8,legacyTable)
        final class Capture: @unchecked Sendable {
            var reasons:[String]=[]
            func receive(_ result:D.Result) {reasons=result.aliases.compactMap(\.reason)}
        }
        let capture=Capture()
        let legacy=D.$observer.withValue({capture.receive($0)}) {D.applying([a,b])}
        precondition(legacy.suppressed==1 && capture.reasons==["original-packet-witness"],
            "Layout-bearing legacy input lost its explicit compatibility path")
        let legacyChainTable=table([0,0.6,1.2],layout:true)
        let legacyChain=[region(0,0.9,legacyChainTable),region(1,0.8,legacyChainTable),region(2,0.7,legacyChainTable)]
        let legacyFirst=D.applying(legacyChain)
        precondition(legacyFirst.suppressed==1 && legacyFirst.regions.map(\.id)==["owner-0","owner-2"])
        let legacyMember=legacyFirst.regions[0].acceptedSource.membership!
        precondition(legacyMember.body==[0,1] && legacyMember.unknownDedup==[1],
            "Equal-text layout alias did not retain physical BODY with a nonvoting mark")
        let legacySecond=D.applying(legacyFirst.regions)
        precondition(legacySecond.suppressed==0 && legacySecond.regions.map(\.id)==["owner-0","owner-2"],
            "Layout compatibility path used an acquired alias as a second-pass witness")
        let legacyRefs=legacySecond.regions.reduce(into:Set<Int>()) {ids,r in
            let m=r.acceptedSource.membership!; ids.formUnion(m.body.union(m.readings).union(m.unknownDedup))
        }
        precondition(legacyRefs==[0,1,2],"Layout compatibility path lost source/erasure ancestry")
        let metadata=NativeOCRSourceMetadata(.init(table:originals,body:[0],readings:[1],unknownDedup:[],hasUntrackedInputs:false))
        let guest=NativeOCRSourceMetadata(.init(table:originals,body:[0,2],readings:[1],unknownDedup:[0,2],hasUntrackedInputs:false))
        for exact in [false,true] {
            let acquired=metadata.retainingDuplicate(guest,exactContentWitness:exact).membership!
            precondition(acquired.table === originals && acquired.body==[0,2] && acquired.readings==[1])
            precondition(acquired.unknownDedup==[2],"Guest alias revoked an anchor's original shared packet vote")
            let selfAlias=metadata.retainingDuplicate(metadata,exactContentWitness:exact).membership!
            precondition(selfAlias.unknownDedup.isEmpty,"Self/shared original references became acquired aliases")
        }
        let prior=NativeOCRSourceMetadata(.init(table:originals,body:[0,1],readings:[],unknownDedup:[1],hasUntrackedInputs:false))
        let next=prior.retainingDuplicate(guest,exactContentWitness:true).membership!
        precondition(next.unknownDedup==[1,2],"Prior acquired alias was resurrected as an original vote")
        print("PASS actual final original-witness NMS/pipeline: composite originals, readings, cross-table abstain, repeated-pass aliases, erasure/aux ancestry and legacy-layout dispatch")
    }
}
'''


def main():
    pipeline = (OCR / 'NativeCoreMLOCRPipeline.swift').read_text()
    line = pipeline[pipeline.index('struct NativeCoreMLOCRLine:'):
        pipeline.index('@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics')]
    with tempfile.TemporaryDirectory(prefix='aidoku-final-owner-simple-') as directory:
        work=Path(directory)
        support=work/'Support.swift';support.write_text(SUPPORT+'\n'+line)
        check=work/'Check.swift';check.write_text(CHECK)
        binary=work/'check'
        source=[OCR/'BrowserOCRSourceOrientation.swift',OCR/'NativeOCRAcceptedSource.swift',
            OCR/'NativeOCRPremergeCandidateFeatures.swift',BASE/'NativeFinalOutputDuplicateResolver.swift',
            BASE/'NativeFinalOutputDuplicateResolver+Pipeline.swift',support,check]
        # The orientation enum lives in the shared overlay value layer.
        source[0]=next((ROOT/'Aidoku').rglob('BrowserOCRSourceOrientation.swift'))
        subprocess.run(['swiftc','-O','-swift-version','6','-module-cache-path',str(work/'modules'),
            *map(str,source),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)


if __name__=='__main__':
    main()
