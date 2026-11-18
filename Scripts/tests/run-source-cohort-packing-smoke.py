"""Actual shared interval optimizer and capacity-aware source-cluster anchors."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2];base=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
program=r'''
import Foundation
import CoreGraphics
typealias O=NativeSourceCohortPacking.Option
// A wide cheap option must lose to a feasible intermediate width before it
// pushes the adjacent caption beyond the source-near motion budget.
let sourceNear=NativeSourceCohortPacking.sourceNearOption(
 O(index:0,extent:200,lower:0,upper:800,preferred:0,unit:40,cost:0),sourceCentre:400,anchorDelta:0)!
precondition(sourceNear.lower==200 && sourceNear.upper==400)
let nearPacked=NativeSourceCohortPacking.pack([[sourceNear]],gap:0)!
precondition(nearPacked.origins[0]==200)
precondition(NativeSourceCohortPacking.sourceNearOption(sourceNear,sourceCentre:400,anchorDelta:81)==nil)
let limited=O(index:1,extent:500,lower:0,upper:10,preferred:0,unit:40,cost:0)
precondition(NativeSourceCohortPacking.sourceNearOption(limited,sourceCentre:500,anchorDelta:0)==nil)
let boundedChoices=[CGFloat(100),CGFloat(300)].map { centre in
 [CGFloat(300),CGFloat(140)].enumerated().compactMap { index,width in
  NativeSourceCohortPacking.sourceNearOption(
   O(index:index,extent:width,lower:-1000,upper:1000,preferred:centre-width/2,unit:20,cost:index==0 ? 0:0.1),
   sourceCentre:centre,anchorDelta:0)
 }
}
let intermediate=NativeSourceCohortPacking.pack(boundedChoices,gap:10)!
precondition(intermediate.indices == [1,1])
precondition(intermediate.origins[0]+140+10<=intermediate.origins[1])
let members=(0..<2).map { i in [
 O(index:0,extent:200,lower:0,upper:150,preferred:i==0 ? 20:180,unit:50,cost:0),
 O(index:1,extent:140,lower:0,upper:210,preferred:i==0 ? 20:180,unit:50,cost:0.05)] }
let packed=NativeSourceCohortPacking.pack(members,gap:10)!
precondition(packed.indices == [1,1] && packed.origins == [20,180])
precondition(packed.origins[0]+140+10<=packed.origins[1])
precondition(NativeSourceCohortPacking.pack([[O(index:0,extent:400,lower:0,upper:-50,preferred:0,unit:1,cost:0)]],gap:0)==nil)
let page=CGRect(x:0,y:0,width:500,height:500)
let packet=NativeSourceClusterAlignment(groupID:"cohort",axis:.top,anchorNormalized:0.4,anchorPolicy:"source-near-final-alpha")
let guides:[NativeTextPlacementGuide?]=[
 .init(rectNormalized:[0.1,0.4,0.2,0.1],horizontal:.center,vertical:.center),
 .init(rectNormalized:[0.6,0.4,0.2,0.1],horizontal:.center,vertical:.center)]
let bounds=[CGRect(x:50,y:0,width:100,height:100),CGRect(x:300,y:0,width:100,height:100)]
func policy(_ rect:[Double],inside:Bool=false)->NativeTextExpansionPolicy {
 .init(allowedRectNormalized:rect,candidates:[rect],maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:40,
  kind:inside ? "inside-balloon-mask":"source-near-limited-expansion",
  maskRectNormalized:inside ? [0,0,1,1]:nil,maskSpansNormalized:inside ? [0,1,0,1]:nil)
}
// A source-start policy is valid only for the complete exterior cohort.
var startPacket=packet;startPacket.anchorsToSourceStart=true
let starts=try NativeSourceClusterAlignment.targets([startPacket,startPacket],bounds:bounds,page:page,
 guides:guides,capacities:[policy([0,0,1,1]),policy([0,0,1,1])])
precondition(starts == [200,200])
let mixed=try NativeSourceClusterAlignment.targets([startPacket,packet],bounds:bounds,page:page,
 guides:guides,capacities:[policy([0,0,1,1]),policy([0,0,1,1])])
let insideStarts=try NativeSourceClusterAlignment.targets([startPacket,startPacket],bounds:bounds,page:page,
 guides:guides,capacities:[policy([0,0,1,1],inside:true),policy([0,0,1,1])])
precondition(mixed == [175,175] && insideStarts == mixed)
let oldPacket=try NativeSourceClusterAlignment.decode(["groupID":"cohort","axis":"top","anchorNormalized":0.4])!
precondition(oldPacket.anchorsToSourceStart == nil)
let legacyPalette=policy([0,0,1,1])
precondition(legacyPalette.candidateIndices(ordinary:true) == [0])
var extendedPalette=NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],
 candidates:[[0,0,0.5,1],[0,0,0.75,1]],maskCoverage:[1,1],backgroundRisk:[0,0],sourceFontPixels:40,
 kind:"source-near-limited-expansion",maskRectNormalized:nil,maskSpansNormalized:nil,ordinaryCandidateIndices:[0])
precondition(extendedPalette.valid && extendedPalette.candidateIndices(ordinary:false) == [0,1])
precondition(extendedPalette.candidateIndices(ordinary:true) == [0])
extendedPalette.ordinaryCandidateIndices=[1,1];precondition(!extendedPalette.valid)
extendedPalette.ordinaryCandidateIndices=[2];precondition(!extendedPalette.valid)
extendedPalette.ordinaryCandidateIndices=[];precondition(!extendedPalette.valid)
var anchored=policy([0,0,1,1],inside:true);anchored.sourceAnchorLimitEm=3
let leading=NativeTextPlacementGuide(rectNormalized:[0.1,0.1,0.4,0.1],horizontal:.left,vertical:.top)
precondition(anchored.valid)
precondition(anchored.sourceAnchorAllows(CGRect(x:60,y:50,width:100,height:40),page:page,guide:leading))
precondition(!anchored.sourceAnchorAllows(CGRect(x:300,y:50,width:100,height:40),page:page,guide:leading))
anchored=policy([0.5,0.5,0.5,0.5],inside:true);anchored.sourceAnchorLimitEm=3
precondition(anchored.sourceAnchorAllows(CGRect(x:300,y:300,width:100,height:40),page:page,guide:leading))
let tall=CGRect(x:0,y:0,width:100,height:300),flat=CGRect(x:0,y:0,width:400,height:40)
precondition(!policy([0,0,1,1],inside:true).allowsRefinementShape(original:tall,proposed:flat,font:40))
precondition(policy([0,0,1,1]).allowsRefinementShape(original:tall,proposed:flat,font:40))
precondition(policy([0,0,1,1],inside:true).allowsRefinementShape(original:tall,proposed:CGRect(x:0,y:0,width:130,height:200),font:40))
func observed(_ id:String,_ offset:CGFloat,_ font:CGFloat=40)->NativeSourceCohortPacking.Placement {
 let s=CGRect(x:id=="a" ? 100:300,y:100,width:80,height:200)
 return .init(owner:id,group:"pair",source:s,paint:s.offsetBy(dx:offset,dy:0),referenceFont:40,displayFont:font,wrapPenalty:0)
}
precondition(NativeSourceCohortPacking.regressedGroups(before:[observed("a",0),observed("b",0)],
 after:[observed("a",160),observed("b",0)]) == ["pair"])
precondition(NativeSourceCohortPacking.regressedGroups(before:[observed("a",160),observed("b",0)],
 after:[observed("a",40),observed("b",40)]).isEmpty)
precondition(NativeSourceCohortPacking.regressedGroups(before:[observed("a",160)],after:[observed("a",0,36)]) == ["pair"])
var wordWorse=observed("a",0);wordWorse.wordCuts=1
precondition(NativeSourceCohortPacking.regressedGroups(before:[observed("a",160)],after:[wordWorse]) == ["pair"])
var narrow=NativeSourceCohortPacking.Placement(owner:"paragraph",group:"exterior",source:CGRect(x:100,y:100,width:80,height:600),
 paint:CGRect(x:100,y:100,width:80,height:500),referenceFont:40,displayFont:40,wrapPenalty:0,wordCuts:4,reflowAxis:.top)
var readable=NativeSourceCohortPacking.Placement(owner:narrow.owner,group:narrow.group,source:narrow.source,
 paint:CGRect(x:60,y:100,width:160,height:250),referenceFont:40,displayFont:40,wrapPenalty:0,wordCuts:1,reflowAxis:.top)
precondition(NativeSourceCohortPacking.regressedGroups(before:[narrow],after:[readable]).isEmpty)
let distant=NativeSourceCohortPacking.Placement(owner:narrow.owner,group:narrow.group,source:narrow.source,
 paint:readable.paint.offsetBy(dx:80,dy:0),referenceFont:40,displayFont:40,wrapPenalty:0,wordCuts:1,reflowAxis:.top)
precondition(NativeSourceCohortPacking.regressedGroups(before:[narrow],after:[distant]) == ["exterior"])
var noBenefit=readable;noBenefit.wordCuts=4
precondition(NativeSourceCohortPacking.regressedGroups(before:[narrow],after:[noBenefit]) == ["exterior"])
var noPermission=narrow;noPermission.reflowAxis=nil
var noPermissionAfter=readable;noPermissionAfter.reflowAxis=nil
precondition(NativeSourceCohortPacking.regressedGroups(before:[noPermission],after:[noPermissionAfter]) == ["exterior"])
// Contour-admitted word reflow can slightly move the body centre. A near-zero
// old source error is not a reason to restore cut words inside the same balloon.
func contained(_ dx:CGFloat=0,_ dy:CGFloat=0,cuts:Int=1)->NativeSourceCohortPacking.Placement {
 .init(owner:"contained",group:"balloon",source:CGRect(x:100,y:100,width:80,height:600),
  paint:CGRect(x:70+dx,y:250+dy,width:140,height:300),referenceFont:40,displayFont:40,
  wrapPenalty:0,wordCuts:cuts,allowsContainedReflow:true)
}
let containedBefore=contained(cuts:4),containedAfter=contained(0,12)
precondition(NativeSourceCohortPacking.regressedGroups(before:[containedBefore],after:[containedAfter]).isEmpty)
precondition(NativeSourceCohortPacking.regressedGroups(before:[containedBefore],after:[contained(40,12)]) == ["balloon"])
precondition(NativeSourceCohortPacking.regressedGroups(before:[containedBefore],after:[contained(0,12,cuts:5)]) == ["balloon"])
var shortBefore=narrow;shortBefore.wordCuts=0;shortBefore.softRows=2
var shortAfter=readable;shortAfter.wordCuts=0;shortAfter.softRows=1
precondition(NativeSourceCohortPacking.regressedGroups(before:[shortBefore],after:[shortAfter]).isEmpty)
var longerEqualQuality=shortAfter;longerEqualQuality.softRows=5
precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[shortBefore],after:[longerEqualQuality]) == ["paragraph"])
precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[shortBefore],after:[shortAfter]).isEmpty)
var tradeA=narrow
tradeA.wordCuts=0;tradeA.softRows=4
var tradeB=NativeSourceCohortPacking.Placement(owner:"peer",group:tradeA.group,source:tradeA.source.offsetBy(dx:300,dy:0),
 paint:tradeA.paint.offsetBy(dx:300,dy:0),referenceFont:40,displayFont:40,wrapPenalty:0,reflowAxis:.top,softRows:7)
let tradedA=NativeSourceCohortPacking.Placement(owner:tradeA.owner,group:tradeA.group,source:tradeA.source,
 paint:tradeA.paint.offsetBy(dx:-20,dy:0),referenceFont:40,displayFont:40,wrapPenalty:0,reflowAxis:.top,softRows:5)
let tradedB=NativeSourceCohortPacking.Placement(owner:tradeB.owner,group:tradeB.group,source:tradeB.source,
 paint:tradeB.paint.offsetBy(dx:20,dy:0),referenceFont:40,displayFont:40,wrapPenalty:0,reflowAxis:.top,softRows:4)
precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[tradeA,tradeB],after:[tradedA,tradedB]) == [tradeA.owner])
precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[tradeA,tradeB],after:[tradedA,tradedB],allowGroupRowTrade:true).isEmpty)
precondition(NativeSourceCohortPacking.regressedGroups(before:[tradeA,tradeB],after:[tradedA,tradedB],allowGroupRowTrade:true).isEmpty)
do {
    let columnA=NativeSourceCohortPacking.Placement(owner:"column",group:"natural-columns",source:CGRect(x:100,y:20,width:80,height:500),
     paint:CGRect(x:80,y:20,width:220,height:220),referenceFont:40,displayFont:40,wrapPenalty:0,reflowAxis:.top,softRows:4)
    let columnB=NativeSourceCohortPacking.Placement(owner:"neighbour",group:columnA.group,source:CGRect(x:380,y:20,width:100,height:400),
     paint:CGRect(x:380,y:20,width:160,height:400),referenceFont:40,displayFont:40,wrapPenalty:0,reflowAxis:.top,softRows:7)
    func resizedColumn(_ p:NativeSourceCohortPacking.Placement,_ paint:CGRect,_ rows:Int)->NativeSourceCohortPacking.Placement {
        .init(owner:p.owner,group:p.group,source:p.source,paint:paint,referenceFont:p.referenceFont,displayFont:p.displayFont,
            wrapPenalty:p.wrapPenalty,wordCuts:p.wordCuts,reflowAxis:p.reflowAxis,softRows:rows)
    }
    let naturalA=resizedColumn(columnA,CGRect(x:80,y:20,width:180,height:340),6)
    let naturalB=resizedColumn(columnB,CGRect(x:320,y:20,width:260,height:220),4)
    precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[columnA,columnB],after:[naturalA,naturalB]) == [columnA.owner])
    precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[columnA,columnB],after:[naturalA,naturalB],allowGroupRowTrade:true).isEmpty)
    precondition(NativeSourceCohortPacking.regressedGroups(before:[columnA,columnB],after:[naturalA,naturalB],allowGroupRowTrade:true).isEmpty)
    let overheight=resizedColumn(naturalA,CGRect(x:80,y:20,width:180,height:510),6)
    precondition(!NativeSourceCohortPacking.qualityRegressedOwners(before:[columnA,columnB],after:[overheight,naturalB],allowGroupRowTrade:true).isEmpty)
    var tooMany=naturalA;tooMany.softRows=7
    precondition(!NativeSourceCohortPacking.qualityRegressedOwners(before:[columnA,columnB],after:[tooMany,naturalB],allowGroupRowTrade:true).isEmpty)
    var shortBefore=columnA;shortBefore.softRows=1
    var shortAfter=naturalA;shortAfter.softRows=3
    precondition(!NativeSourceCohortPacking.qualityRegressedOwners(before:[shortBefore,columnB],after:[shortAfter,naturalB],allowGroupRowTrade:true).isEmpty)
}
var badTrade=tradedB;badTrade.wordCuts=1
precondition(!NativeSourceCohortPacking.qualityRegressedOwners(before:[tradeA,tradeB],after:[tradedA,badTrade],allowGroupRowTrade:true).isEmpty)
badTrade=tradedB;badTrade.softRows=6
precondition(NativeSourceCohortPacking.qualityRegressedOwners(before:[tradeA,tradeB],after:[tradedA,badTrade],allowGroupRowTrade:true) == [tradeA.owner])
func reflowMember(_ id:String,x:CGFloat,dx:CGFloat=0,dy:CGFloat=0,cuts:Int=2,axis:NativeSourceClusterAlignment.Axis? = .top,
                  unaligned:Bool=false)->NativeSourceCohortPacking.Placement {
 let source=CGRect(x:x,y:100,width:80,height:300)
 return .init(owner:id,group:"reflow",source:source,paint:source.offsetBy(dx:dx,dy:dy),referenceFont:40,
              displayFont:40,wrapPenalty:0,wordCuts:cuts,reflowAxis:axis,softRows:4,allowsUnalignedReflow:unaligned)
}
let pairBefore=[reflowMember("near",x:100),reflowMember("wide",x:400)]
let pairAfter=[reflowMember("near",x:100,dx:5,cuts:1),reflowMember("wide",x:400,dx:160,cuts:0)]
precondition(NativeSourceCohortPacking.rejectedRefinementOwners(before:pairBefore,after:pairAfter,candidates:["near","wide"]) == ["wide"])
let growingNeighbour=NativeSourceCohortPacking.Placement(owner:"wide",group:"reflow",source:pairBefore[1].source,
 paint:CGRect(x:300,y:100,width:280,height:300),referenceFont:40,displayFont:40,wrapPenalty:0,wordCuts:0,reflowAxis:.top,softRows:4)
let displacedOlder=[reflowMember("near",x:100,dx:120,cuts:1),growingNeighbour]
precondition(NativeSourceCohortPacking.rejectedRefinementOwners(before:pairBefore,after:displacedOlder,candidates:["near","wide"]) == ["near"])
precondition(NativeSourceCohortPacking.rejectedRefinementOwners(before:pairBefore,after:displacedOlder,candidates:["near","wide"],preferExpansion:true) == ["wide"])
precondition(NativeSourceCohortPacking.regressedGroups(before:pairBefore,
 after:[reflowMember("near",x:100,dy:64,cuts:0),reflowMember("wide",x:400,dy:64,cuts:0)]).isEmpty)
precondition(NativeSourceCohortPacking.regressedGroups(before:[reflowMember("free",x:100,axis:nil,unaligned:true)],
 after:[reflowMember("free",x:100,dx:8,cuts:0,axis:nil,unaligned:true)]).isEmpty)
let caps:[NativeTextExpansionPolicy?]=[policy([0,0.1,0.5,0.25]),policy([0.5,0.05,0.5,0.5])]
let original=try NativeSourceClusterAlignment.targets([packet,packet],bounds:bounds,page:page,guides:guides)
let constrained=try NativeSourceClusterAlignment.targets([packet,packet],bounds:bounds,page:page,guides:guides,capacities:caps)
precondition(original == [175,175] && constrained == [75,75])

// Compare bounded weighted packing with exhaustive integer search, including
// unequal weights, clipped preferred points and per-pair gaps.
for seed in 0..<180 {
 let count=2+seed%2
 let opts=(0..<count).map { i in
  O(index:i,extent:CGFloat(1+(seed+i)%2),lower:CGFloat((seed+i*3)%3),upper:CGFloat(5+(seed+i)%4),
    preferred:CGFloat((seed*3+i*5)%13-3),unit:CGFloat(1+(seed+i)%3),cost:0)
 }
 let gaps=(0..<(count-1)).map {CGFloat((seed+$0)%2)}
 var best=Double.infinity
 func enumerate(_ values:[CGFloat]) {
  let i=values.count
  if i==count {
   let cost=zip(values,opts).reduce(0.0) {$0+pow(Double(($1.0-$1.1.preferred)/$1.1.unit),2)}
   best=min(best,cost);return
  }
  for x in Int(ceil(opts[i].lower))...Int(floor(opts[i].upper)) {
   if i>0 && CGFloat(x)<values[i-1]+ceil(opts[i-1].extent)+ceil(gaps[i-1]) {continue}
   enumerate(values+[CGFloat(x)])
  }
 }
 enumerate([])
 let actual=NativeSourceCohortPacking.quadraticOrigins(opts,gaps:gaps)
 if !best.isFinite {precondition(actual==nil);continue}
 guard let actual else {fatalError("lost feasible packing seed \(seed)")}
 let cost=zip(actual,opts).reduce(0.0) {$0+pow(Double(($1.0-$1.1.preferred)/$1.1.unit),2)}
 precondition(abs(cost-best)<1e-8,"nonoptimal seed \(seed): \(cost) != \(best)")
}
let invalid=O(index:0,extent:1,lower:3,upper:2,preferred:0,unit:1,cost:0)
precondition(NativeSourceCohortPacking.quadraticOrigins([invalid],gaps:[])==nil)
let gutterMembers=(0..<2).map { i in
 NativeAdaptiveTextGutter.Member(owner:"g\(i)",group:"g",axis:.top,
 source:CGRect(x:i==0 ? 100:197,y:0,width:100,height:30),
 painted:CGRect(x:i==0 ? 100:206,y:50,width:100,height:30),
 capacity:CGRect(x:0,y:0,width:500,height:200),preferred:CGPoint(x:i==0 ? 100:197,y:0),referenceFont:40,displayFont:40)
}
let plans=NativeAdaptiveTextGutter.plans(gutterMembers)
precondition(plans.count==1 && plans[0].targetGap>6)
precondition(plans[0].after.distance<=plans[0].before.distance+0.7)
let edgeMembers=[
 NativeAdaptiveTextGutter.Member(owner:"edge-a",group:"edge",axis:.top,source:CGRect(x:335,y:50,width:60,height:30),
  painted:CGRect(x:300,y:50,width:80,height:30),capacity:CGRect(x:0,y:0,width:500,height:200),preferred:CGPoint(x:325,y:50),referenceFont:40,displayFont:40),
 NativeAdaptiveTextGutter.Member(owner:"edge-b",group:"edge",axis:.top,source:CGRect(x:440,y:50,width:40,height:30),
  painted:CGRect(x:420,y:50,width:80,height:30),capacity:CGRect(x:0,y:0,width:500,height:200),preferred:CGPoint(x:420,y:50),referenceFont:40,displayFont:40)]
let edgePlan=NativeAdaptiveTextGutter.plans(edgeMembers).first!
precondition(edgePlan.origins["edge-b"]!.x+80<=494)
precondition(edgePlan.targetGap<edgePlan.oldGap && edgePlan.targetGap>=14)
// Retaining the observed paragraph gap may trade a bounded source offset
// for page-edge padding, with no shape, font or shared-baseline changes.
precondition(edgePlan.after.squared<edgePlan.before.squared && edgePlan.after.distance<=edgePlan.before.distance+0.7)
precondition(edgePlan.origins["edge-b"]!.x-edgePlan.origins["edge-a"]!.x-80>=30)
precondition(NativeAdaptiveTextGutter.clearance(CGRect(x:0,y:0,width:10,height:10),CGRect(x:9,y:9,width:10,height:10))==0)
// Source-centered captions still need clearance: exact source location is a
// soft preference, while font, common baseline and safe capacity stay fixed.
for scale:CGFloat in [0.5,1,2] {
 let tight=(0..<2).map {i in
  let r=CGRect(x:CGFloat(100+i*106)*scale,y:50*scale,width:100*scale,height:30*scale)
  return NativeAdaptiveTextGutter.Member(owner:"t\(i)",group:"tight",axis:.top,
   source:r,painted:r,capacity:CGRect(x:0,y:0,width:500*scale,height:200*scale),
   preferred:r.origin,referenceFont:40*scale,displayFont:40*scale)
 }
 let widened=NativeAdaptiveTextGutter.plans(tight)
 precondition(widened.count==1 && widened[0].targetGap>=14*scale)
 precondition(widened[0].after.distance>widened[0].before.distance)
 let old=Dictionary(uniqueKeysWithValues:tight.map {($0.owner,$0.painted)})
 let new=Dictionary(uniqueKeysWithValues:tight.map {($0.owner,CGRect(origin:widened[0].origins[$0.owner]!,size:$0.painted.size))})
 precondition(NativeAdaptiveTextGutter.allowsMotion(tight,before:old,after:new))
 var excessive=new
 excessive["t0"]=tight[0].painted.offsetBy(dx:-40*scale,dy:0)
 precondition(!NativeAdaptiveTextGutter.allowsMotion(tight,before:old,after:excessive))
 var baselineChanged=new
 baselineChanged["t0"]=new["t0"]!.offsetBy(dx:0,dy:scale)
 precondition(!NativeAdaptiveTextGutter.allowsMotion(tight,before:old,after:baselineChanged))
}

// Expanded paragraphs must retain visible separation from distinct source
// columns. The rule is pair-local, symmetric across axes and scale-aware.
for scale:CGFloat in [0.5,1,2] {
 for axis:NativeSourceClusterAlignment.Axis in [.top,.left] {
  func rect(_ x:CGFloat,_ width:CGFloat)->CGRect {
   axis == .top ? CGRect(x:x*scale,y:0,width:width*scale,height:100*scale):
    CGRect(x:0,y:x*scale,width:100*scale,height:width*scale)
  }
  let separated=(0..<2).map {i in
   NativeAdaptiveTextGutter.Member(owner:"s\(i)",group:"separated",axis:axis,
    source:rect(i==0 ? 100:280,100),painted:rect(i==0 ? 60:237,160),
    capacity:CGRect(x:0,y:0,width:600*scale,height:600*scale),preferred:rect(i==0 ? 70:250,160).origin,
    referenceFont:48*scale,displayFont:48*scale)
  }
  precondition(NativeAdaptiveTextGutter.desiredGap(separated[0],separated[1])>=52*scale)
  let restored=NativeAdaptiveTextGutter.plans(separated).first!
  let a=restored.origins["s0"]!,b=restored.origins["s1"]!
  precondition((axis == .top ? b.x-a.x:b.y-a.y)-160*scale>=51*scale)
 }
}

// Distant captions on the same baseline cannot veto a local pair's gutter.
let localPair=(0..<2).map { i in
 NativeAdaptiveTextGutter.Member(owner:"local\(i)",group:"wide",axis:.top,
  source:CGRect(x:i==0 ? 100:280,y:0,width:100,height:100),
  painted:CGRect(x:i==0 ? 60:237,y:0,width:160,height:100),
  capacity:CGRect(x:0,y:0,width:2000,height:200),preferred:CGPoint(x:i==0 ? 70:250,y:0),referenceFont:48,displayFont:48)
}
let remote=NativeAdaptiveTextGutter.Member(owner:"remote",group:"wide",axis:.top,
 source:CGRect(x:1500,y:0,width:100,height:100),painted:CGRect(x:1100,y:0,width:100,height:100),
 capacity:CGRect(x:0,y:0,width:2000,height:200),preferred:CGPoint(x:1500,y:0),referenceFont:48,displayFont:48)
let localPlans=NativeAdaptiveTextGutter.plans(localPair+[remote])
precondition(localPlans.contains {$0.origins.count==2 && $0.origins["local0"] != nil && $0.targetGap>=52})

// Source-offset preservation keeps staggered starts but must not let wider
// translated paragraphs collide or visually fuse. Verify uses identical targets.
do {
 let page=CGRect(x:0,y:0,width:600,height:400)
 let guides:[NativeTextPlacementGuide?]=[
  .init(rectNormalized:[100.0/600,0.2,50.0/600,0.4],horizontal:.center,vertical:.top),
  .init(rectNormalized:[220.0/600,0.3,50.0/600,0.4],horizontal:.center,vertical:.top)]
 let packet=NativeBalloonPlacement(crossAlignment:.start,bodyID:"body",rectNormalized:[0.1,0.1,0.8,0.8],
  preserveSourceOffsets:true,finalReadabilityGaps:true,biasNormalized:[0,0],flow:.row,paddingEm:0.25,gapEm:1.2,maskSHA256:String(repeating:"a",count:64),order:0)
 var second=packet;second.order=1
 let bounds=[CGRect(x:0,y:0,width:130,height:100),CGRect(x:0,y:0,width:120,height:120)]
 var legacyA=packet,legacyB=second;legacyA.finalReadabilityGaps=nil;legacyB.finalReadabilityGaps=nil
 let legacy=try NativeBalloonPlacement.targets([legacyA,legacyB],bounds:bounds,fonts:[24,24],page:page,guides:guides)
 precondition(legacy[1]!.x-legacy[0]!.x-130 == -5)
 let shifts=try NativeBalloonPlacement.targets([packet,second],bounds:bounds,fonts:[24,24],page:page,guides:guides)
 let placed=zip(bounds,shifts).map {$0.offsetBy(dx:$1!.x,dy:$1!.y)}
 precondition(placed[1].minX-placed[0].maxX>=9)
 precondition(placed[0].minY==80 && placed[1].minY==120)
 let verified=try NativeBalloonPlacement.targets([packet,second],bounds:placed,fonts:[24,24],page:page,guides:guides)
 precondition(verified.allSatisfy {$0 == CGPoint.zero})
 let narrow=bounds.map {CGRect(origin:$0.origin,size:CGSize(width:40,height:$0.height))}
 let wideGap=try NativeBalloonPlacement.targets([packet,second],bounds:narrow,fonts:[24,24],page:page,guides:guides)
 precondition(wideGap[0]!.x==105 && wideGap[1]!.x==225)
}

// Paragraph clearance uses visible row envelopes, including staggered starts,
// rather than the empty corners of a whole paragraph rectangle.
do {
 typealias R=NativeInkContourClearance.Row
 let a=[R(y:0,left:0,right:10)],b=[R(y:4,left:12,right:22)]
 precondition(abs(NativeInkContourClearance.peerMargin(rows:a,peer:b,limit:9)-sqrt(13))<1e-9)
 precondition(NativeInkContourClearance.peerMargin(rows:a,peer:b,dy:4,limit:9)==2)
 for seed in 0..<20 {
  let own=(0..<12).map {R(y:$0*2,left:(seed+$0)%3,right:10+(seed*$0)%5)}
  let peer=(0..<13).map {R(y:$0*2+1,left:15+(seed+$0)%4,right:30+(seed*$0)%5)}
  let dx=seed%7-3,dy=seed%9-4
  var exact:CGFloat=9
  for r in own {for p in peer {
   let x=max(0,max(p.left-r.right-dx,r.left+dx-p.right)),y=max(0,abs(r.y+dy-p.y)-1)
   exact=min(exact,hypot(CGFloat(x),CGFloat(y)))
  }}
  precondition(abs(NativeInkContourClearance.peerMargin(rows:own,peer:peer,dx:dx,dy:dy,limit:9)-exact)<1e-9)
 }
}


let contourPolicy=policy([0.16,0.16,0.33,0.54],inside:true)
let contourPaint=CGRect(x:100,y:100,width:140,height:230)
let contourSource=CGRect(x:100,y:100,width:100,height:200)
let contourGuide=NativeTextPlacementGuide(rectNormalized:[0.2,0.2,0.2,0.4],horizontal:.left,vertical:.top)
let contourPlans=NativeContourTextClearance.plans(paint:contourPaint,source:contourSource,
 policy:contourPolicy,guide:contourGuide,font:48,page:page)
precondition(!contourPlans.isEmpty && contourPlans[0].margin==10)
precondition(contourPlans[0].sourceCostAfter<contourPlans[0].sourceCostBefore)
let movedContour=CGRect(origin:contourPlans[0].origin,size:contourPaint.size)
precondition(contourPolicy.allows(movedContour.insetBy(dx:-10,dy:-10),page:page))
precondition(NativeContourTextClearance.plans(paint:contourPaint,source:contourPaint,
 policy:contourPolicy,guide:contourGuide,font:48,page:page).isEmpty)
precondition(NativeContourTextClearance.plans(paint:contourPaint,source:contourSource,
 policy:policy([0,0,1,1]),guide:contourGuide,font:48,page:page).isEmpty)


let curved=NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],
 maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:48,kind:"inside-balloon-mask",
 maskRectNormalized:[0,0,1,1],maskSpansNormalized:[0.3,0.7,0.2,0.8])
let sparseBounds=CGRect(x:120,y:100,width:260,height:201)
let cornerRows:[NativeInkContourClearance.Row]=[.init(y:100,left:200,right:250),
 .init(y:100,left:280,right:300),.init(y:300,left:120,right:380)]
let cornerEnvelope=NativeInkContourClearance.envelope(cornerRows)
precondition(cornerEnvelope.count==2 && cornerEnvelope[0].left==200 && cornerEnvelope[0].right==300)
precondition(NativeContourTextClearance.margin(sparseBounds,policy:curved,page:page,limit:10)==0)
precondition(NativeInkContourClearance.margin(rows:cornerEnvelope,bounds:sparseBounds,policy:curved,page:page,limit:10)==10)
let sparseSource=sparseBounds.offsetBy(dx:10,dy:0)
let sparseGuide=NativeTextPlacementGuide(rectNormalized:[0.26,0.2,0.52,0.402],horizontal:.left,vertical:.top)
precondition(NativeInkContourClearance.plans(rows:cornerEnvelope,bounds:sparseBounds,source:sparseSource,
 policy:curved,guide:sparseGuide,font:48,page:page).isEmpty)
let closeRows:[NativeInkContourClearance.Row]=[.init(y:100,left:151,right:300),.init(y:300,left:120,right:380)]
let sparsePlans=NativeInkContourClearance.plans(rows:closeRows,bounds:sparseBounds,source:sparseSource,
 policy:curved,guide:sparseGuide,font:48,page:page)
precondition(!sparsePlans.isEmpty && sparsePlans[0].oldMargin==1 && sparsePlans[0].margin==10)
precondition(sparsePlans[0].origin==CGPoint(x:129,y:100) && sparsePlans[0].sourceCostAfter<sparsePlans[0].sourceCostBefore)
for row in closeRows {
 let rect=CGRect(x:row.left+9,y:row.y,width:row.right-row.left,height:1).insetBy(dx:-10,dy:-10)
 precondition(curved.allows(rect,page:page))
}


precondition(NativeInkContourClearance.plans(rows:closeRows,bounds:sparseBounds,source:sparseBounds,
 policy:curved,guide:sparseGuide,font:48,page:page).isEmpty)
let driftPlans=NativeInkContourClearance.plans(rows:closeRows,bounds:sparseBounds,source:sparseBounds,
 policy:curved,guide:sparseGuide,font:48,page:page,maximumSourceDriftEm:0.1)
precondition(!driftPlans.isEmpty && driftPlans[0].margin==5 && driftPlans[0].origin==CGPoint(x:124,y:100))
precondition(sqrt(driftPlans[0].sourceCostAfter)-sqrt(driftPlans[0].sourceCostBefore)<=4.8)


let roundedCurve=NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],
 maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:48,kind:"inside-balloon-mask",
 maskRectNormalized:[0,0,1,1],maskSpansNormalized:[0.3+1e-14,0.7-1e-14,0.2,0.8])
precondition(NativeInkContourClearance.margin(rows:closeRows,bounds:sparseBounds,policy:roundedCurve,page:page,limit:10)==1)

// Disjoint lobes: exact integer feasibility must retain the hole, including
// zero-margin admission. Envelopes remain conservative for multiple alpha runs.
do {
 typealias C=NativeInkContourClearance
 typealias R=C.Row
 let page=CGRect(x:0,y:0,width:100,height:100)
 var lobes=policy([0,0,1,1],inside:true)
 lobes.maskIntervalRowsNormalized=[[0.1,0.4,0.6,0.9],[0.1,0.4,0.6,0.9]]
 let bounds=CGRect(x:35,y:20,width:5,height:2)
 let rows=[R(y:20,left:35,right:40),R(y:21,left:35,right:40)]
 precondition(lobes.valid)
 precondition(C.feasibleIntervals(rows:rows,bounds:bounds,dy:0,margin:0,policy:lobes,page:page) == [-25...0,25...50])
 precondition(C.interval(rows:rows,bounds:bounds,dy:0,margin:0,policy:lobes,page:page) == -25...0)
 precondition(C.margin(rows:rows,bounds:bounds,policy:lobes,page:page,limit:10)==0)
 let inGap=CGRect(x:45,y:20,width:10,height:2)
 let gapRows=[R(y:20,left:45,right:55),R(y:21,left:45,right:55)]
 precondition(C.interval(rows:gapRows,bounds:inGap,dy:0,margin:0,policy:lobes,page:page) == -35 ... -15)
 let gapGuide=NativeTextPlacementGuide(rectNormalized:[0.45,0.2,0.1,0.02],horizontal:.center,vertical:.center)
 precondition(C.plans(rows:gapRows,bounds:inGap,source:inGap,policy:lobes,guide:gapGuide,font:20,page:page).isEmpty)
 // Source preference is in the other feasible lobe: considering only the
 // compatibility interval would lose this genuinely admissible improvement.
 let source=bounds.offsetBy(dx:30,dy:0)
 let guide=NativeTextPlacementGuide(rectNormalized:[0.65,0.2,0.05,0.02],horizontal:.center,vertical:.center)
 let plans=C.plans(rows:rows,bounds:bounds,source:source,policy:lobes,guide:guide,font:20,page:page)
 precondition(!plans.isEmpty && plans[0].margin==4 && plans[0].origin==CGPoint(x:64,y:20))
 for plan in plans {
  let dx=plan.origin.x-bounds.minX,dy=plan.origin.y-bounds.minY
  for row in rows {
   let expanded=CGRect(x:CGFloat(row.left)+dx,y:CGFloat(row.y)+dy,width:CGFloat(row.right-row.left),height:1)
    .insetBy(dx:-CGFloat(plan.margin),dy:-CGFloat(plan.margin))
   precondition(lobes.allows(expanded,page:page))
  }
 }
 // Independent hard-admission oracle covers both bands, holes, endpoints,
 // asymmetric lobes, and vertical shifts crossing a band boundary.
 lobes.maskIntervalRowsNormalized=[[0.1,0.4,0.6,0.9],[0.15,0.35,0.65,0.95]]
 for dy in [0,28,29,30,31,60] {
  for margin in 0...4 {
   let ranges=C.feasibleIntervals(rows:rows,bounds:bounds,dy:dy,margin:margin,policy:lobes,page:page)
   for dx in -40...65 {
    let expected=rows.allSatisfy {row in
     lobes.allows(CGRect(x:row.left+dx,y:row.y+dy,width:row.right-row.left,height:1)
      .insetBy(dx:-CGFloat(margin),dy:-CGFloat(margin)),page:page)
    }
    precondition(ranges.contains {$0.contains(dx)} == expected)
   }
  }
 }
 // A supplied empty band must not fall back to the legacy span.
 lobes.maskIntervalRowsNormalized=[[],[]]
 precondition(C.feasibleIntervals(rows:rows,bounds:bounds,dy:0,margin:0,policy:lobes,page:page).isEmpty)
}

// Exact zero-margin boundaries have no soft-distance epsilon.
do {
 let bounds=CGRect(x:150,y:100,width:10,height:1)
 let rows=[NativeInkContourClearance.Row(y:100,left:150,right:160)]
 precondition(!roundedCurve.allows(bounds,page:page))
 precondition(NativeInkContourClearance.feasibleIntervals(rows:rows,bounds:bounds,dy:0,margin:0,
  policy:roundedCurve,page:page) == [1...189])
 // Nil interval rows and explicit single-span rows preserve legacy results.
 var explicit=curved;explicit.maskIntervalRowsNormalized=[[0.3,0.7],[0.2,0.8]]
 for dy in [-10,0,10] {for margin in 0...10 {
  let a=NativeInkContourClearance.feasibleIntervals(rows:closeRows,bounds:sparseBounds,dy:dy,margin:margin,policy:curved,page:page)
  let b=NativeInkContourClearance.feasibleIntervals(rows:closeRows,bounds:sparseBounds,dy:dy,margin:margin,policy:explicit,page:page)
  precondition(a==b && a.count<=1)
  precondition(NativeInkContourClearance.interval(rows:closeRows,bounds:sparseBounds,dy:dy,margin:margin,policy:curved,page:page)==a.first)
 }}
 let explicitPlans=NativeInkContourClearance.plans(rows:closeRows,bounds:sparseBounds,source:sparseSource,
  policy:explicit,guide:sparseGuide,font:48,page:page)
 precondition(explicitPlans.count==sparsePlans.count)
 for (a,b) in zip(explicitPlans,sparsePlans) {
  precondition(a.origin==b.origin && a.margin==b.margin && a.oldMargin==b.oldMargin &&
   a.sourceCostBefore==b.sourceCostBefore && a.sourceCostAfter==b.sourceCostAfter)
 }
}

// Three individually valid bands can fragment the intersection beyond 128.
// Two bands retain all 127 intervals; the third must fail closed.
do {
 let page=CGRect(x:0,y:0,width:2000,height:2000)
 var fragmented=policy([0,0,1,1],inside:true)
 // Six legacy bands keep mask validation and row pitch explicit.
 fragmented=NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],
  maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:40,kind:"inside-balloon-mask",
  maskRectNormalized:[0,0,1,1],maskSpansNormalized:Array(repeating:[0.0,1.0],count:6).flatMap {$0})
 let bands=(0..<3).map {band -> [Double] in
  var values=[0.0]
  for j in 0..<63 {
   let hole=Double(10+9*j+3*band)
   values.append(hole/2000);values.append((hole+1)/2000)
  }
  values.append(1);return values
 }
 fragmented.maskIntervalRowsNormalized=[bands[0],bands[0],bands[1],bands[1],bands[2],bands[2]]
 precondition(fragmented.valid)
 let rows=[NativeInkContourClearance.Row(y:10,left:0,right:1),.init(y:710,left:0,right:1),.init(y:1410,left:0,right:1)]
 let bounds=CGRect(x:0,y:10,width:1,height:1401)
 let two=NativeInkContourClearance.feasibleIntervals(rows:Array(rows.prefix(2)),bounds:bounds,dy:0,margin:0,policy:fragmented,page:page)
 precondition(two.count==127)
 precondition(NativeInkContourClearance.feasibleIntervals(rows:rows,bounds:bounds,dy:0,margin:0,policy:fragmented,page:page).isEmpty)
 precondition(NativeInkContourClearance.interval(rows:rows,bounds:bounds,dy:0,margin:0,policy:fragmented,page:page)==nil)
}

print("PASS joint width choice, interval spacing, impossible capacity, source-anchor shared capacity clamp, disjoint-mask feasibility and bounded fragmentation")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-cohort-pack-')as tmp:
 p=Path(tmp);(p/'main.swift').write_text(program)
 files=['NativeBalloonPlacement.swift','NativeInkContourClearance.swift','NativeContourTextClearance.swift','NativeAdaptiveTextGutter.swift', 'NativeReadablePeerGutter.swift','NativeSourceCohortPacking.swift','NativeSourceClusterAlignment.swift','NativeTextPlacementGuide.swift','NativeTextExpansionPolicy.swift']
 subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(p/'module-cache'),*[str(base/n)for n in files],str(p/'main.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
