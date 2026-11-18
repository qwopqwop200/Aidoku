"""Exercise the production pure original-peer palette recovery, not renderer stubs."""
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[2]
ensemble = repo / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
source = (ensemble / 'NativeOriginalSourcePalette.swift').read_text()
def declaration(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
carrier = '''import Foundation
enum PaletteCarrier {
    struct Observation {
        let originalFill: [Double]?
        let originalStroke: [Double]?
        let evidence: NativeSourceInkSelection.Evidence?
        let selected: NativeSourceInkSelection.Selection
        let rawPrediction: [String:Any]?
        let unknownReason: String?
    }
'''
carrier += declaration('    static func corroboratedStackedMembers(') + '\n'
carrier += declaration('    static func corroboratedGroupCores(') + '\n'
carrier += declaration('    static func corroboratedNativePeerMembers(') + '\n'
carrier += declaration('    static func memoDependencies(') + '\n'
carrier += declaration('    static func combineMembers(')
carrier += r'''
}
func observation(_ color:[Double], raw:[String:Any]? = nil) -> PaletteCarrier.Observation {
    .init(originalFill:color,originalStroke:nil,evidence:nil,
        selected:.init(color:color,role:"sourceFill",neutralExteriorSuppressed:false),rawPrediction:raw,unknownReason:nil)
}
let orange=observation([205,95,22])
func pale(_ shellColor:[Double] = [220,89,4], rays:Int = 456) -> PaletteCarrier.Observation {
    observation([254,253,246],raw:["multiscale":["native":[
        "foreground":[254.0,250,241],"stroke":shellColor,
        "gradientShellRecovery":["rgb":shellColor,"rays":rays,"spatialSupport":17],
        "sourceInkDominance":["fillPixels":2911,"strokePixels":17405,"fillShapePixels":2899,
            "strokeShapePixels":17140,"fillRepeatedTiles":17,"strokeRepeatedTiles":22,
            "fillEnclosedPixels":0,"strokeEnclosedPixels":0]]]])
}
let members:[[String:Any]]=[["id":"first"],["id":"second"]]
func accepted(_ a:[PaletteCarrier.Observation], recovery:Bool) -> Bool {
    let value=PaletteCarrier.combineMembers(a,members:members,inkOnly:true,recoverStackedShell:recovery)
    return (value.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["accepted"] as? Bool == true
}
precondition(!accepted([orange,pale()],recovery:false))
precondition(accepted([orange,pale()],recovery:true))
precondition(accepted([pale(),orange],recovery:true))
precondition(!accepted([orange,pale(rays:2)],recovery:true))
precondition(!accepted([observation([0,0,0]),pale()],recovery:true))
precondition(!accepted([orange,pale([0,140,220])],recovery:true))
precondition(!accepted([orange,observation([254,253,246])],recovery:true))
precondition(accepted([orange,orange],recovery:false))
let columnRecovered=PaletteCarrier.combineMembers([orange,pale()],members:members,inkOnly:true,recoverColumnShell:true)
precondition((columnRecovered.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["accepted"] as? Bool == true)
let columnUnsupported=PaletteCarrier.combineMembers([orange,pale(rays:2)],members:members,inkOnly:true,recoverColumnShell:true)
precondition((columnUnsupported.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["accepted"] as? Bool == false)
let agreeing=PaletteCarrier.combineMembers([orange,orange],members:members,inkOnly:true,recoverColumnShell:true)
precondition(agreeing.selected.color==orange.selected.color)
precondition((agreeing.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["columnNativeShellRecoveryAttempted"] as? Bool == false)
func nativeObservation(_ coarse:[Double], _ fill:[Double], stroke:[Double]? = nil,
                       confidence:Double = 0.66, shape:Double = 40, repeated:Double = 6,
                       omit:String? = nil) -> PaletteCarrier.Observation {
    var topology:[String:Any] = ["fillPixels":60.0,"strokePixels":stroke == nil ? 0.0 : 240.0,
        "fillShapePixels":shape,"strokeShapePixels":stroke == nil ? 0.0 : shape*5,
        "fillRepeatedTiles":repeated,"strokeRepeatedTiles":stroke == nil ? 0.0 : repeated,
        "fillEnclosedPixels":0.0,"strokeEnclosedPixels":0.0]
    if let omit {topology.removeValue(forKey:omit)}
    var native:[String:Any] = ["foreground":fill,"confidence":["foreground":confidence,"stroke":confidence],
        "sourceInkDominance":topology]
    if let stroke {native["stroke"]=stroke}
    return observation(coarse,raw:["multiscale":["native":native]])
}
func consensus(_ value:PaletteCarrier.Observation) -> [String:Any] {
    value.rawPrediction!["memberPaletteConsensus"] as! [String:Any]
}
func combineNative(_ a:[PaletteCarrier.Observation], enabled:Bool = true) -> PaletteCarrier.Observation {
    PaletteCarrier.combineMembers(a,members:a.indices.map{["id":"m\($0)"]},inkOnly:true,recoverNativePeers:enabled)
}
func isAccepted(_ value:PaletteCarrier.Observation) -> Bool {
    consensus(value)["accepted"] as? Bool == true
}
let dark=nativeObservation([54,53,70],[2,1,1])
let darkPeer=observation([3,2,2])
let recoveredDark=combineNative([dark,darkPeer])
precondition(!isAccepted(combineNative([dark,darkPeer],enabled:false)))
precondition(isAccepted(recoveredDark))
let darkMembers=consensus(recoveredDark)["members"] as! [[String:Any]]
precondition(darkMembers[0]["selected"] as? [Double] == [2,1,1],"copied peer RGB instead of native measurement")
precondition(consensus(recoveredDark)["nativePeerRecoveredMembers"] as? [String] == ["m0"])
let nativeTrace=darkMembers[0]["nativePeerRecovery"] as! [String:Any]
precondition((nativeTrace["priorCoarse"] as! [String:Any])["selectedOriginalInk"] as? [Double] == [54,53,70])
precondition((nativeTrace["nativeMeasurement"] as! [String:Any])["foreground"] as? [Double] == [2,1,1])
let pink=nativeObservation([29,29,31],[155,68,121],confidence:0.64)
precondition(isAccepted(combineNative([pink,observation([155,67,121])])) )
let nativeStroke=nativeObservation([29,29,31],[250,250,250],stroke:[155,68,121])
let strokeRecovered=PaletteCarrier.corroboratedNativePeerMembers([nativeStroke,observation([155,67,121])])
precondition(strokeRecovered[0].selected.role=="sourceStroke")
precondition(strokeRecovered[0].originalStroke==[155,68,121])

let negatives:[PaletteCarrier.Observation] = [
    nativeObservation([54,53,70],[2,1,1],confidence:0.49),
    nativeObservation([54,53,70],[2,1,1],repeated:3),
    nativeObservation([54,53,70],[2,1,1],shape:11),
    nativeObservation([54,53,70],[150,20,10]),
    observation([54,53,70]),
    nativeObservation([54,53,70],[2,1,1],omit:"strokeEnclosedPixels"),
    nativeObservation([54,53,70],[2,1,1],shape:-1),
    nativeObservation([54,53,70],[Double.nan,1,1]),
    nativeObservation([54,53,70],[256,1,1]),
    nativeObservation([54,53,70],[2,1,1],confidence:Double.nan),
    nativeObservation([54,53,70],[2,1,1],shape:Double.infinity)
]
for (index,bad) in negatives.enumerated() {
    let checked=PaletteCarrier.corroboratedNativePeerMembers([bad,darkPeer])
    precondition(checked[0].selected.color==bad.selected.color,"negative \(index) changed original selection")
    precondition(checked[0].rawPrediction?["nativePeerCorroboration"]==nil)
    precondition(!isAccepted(combineNative([bad,darkPeer])),"negative \(index) admitted")
}
// A strong UNUSED fill population cannot certify a weak selected stroke.
let weakStroke=nativeObservation([29,29,31],[250,250,250],stroke:[155,68,121],repeated:3)
precondition(!isAccepted(combineNative([weakStroke,observation([155,67,121])])))
// Already agreeing observations must survive even when native measurements differ.
let already=[nativeObservation([3,2,2],[160,20,10]),darkPeer]
let baseline=combineNative(already,enabled:false), enabled=combineNative(already)
precondition(isAccepted(baseline) && isAccepted(enabled))
precondition(enabled.selected.color==baseline.selected.color && enabled.selected.role==baseline.selected.role)
precondition(enabled.originalFill==baseline.originalFill && enabled.originalStroke==baseline.originalStroke)
let beforeMembers=consensus(baseline)["members"] as! [[String:Any]]
let afterMembers=consensus(enabled)["members"] as! [[String:Any]]
precondition(NSDictionary(dictionary:["m":beforeMembers]).isEqual(to:["m":afterMembers]))
precondition(consensus(enabled)["nativePeerRecoveryAttempted"] as? Bool == false)
precondition(PaletteCarrier.corroboratedNativePeerMembers(already)[0].rawPrediction?["nativePeerCorroboration"]==nil)
// Newly recovered values cannot anchor another member's recovery.
let chain=[nativeObservation([50,50,50],[105,105,105]),nativeObservation([100,100,100],[110,110,110])]
let fixedAnchors=PaletteCarrier.corroboratedNativePeerMembers(chain)
precondition(fixedAnchors[0].selected.color==[105,105,105])
precondition(fixedAnchors[1].selected.color==[100,100,100],"recovered peer self-certified next member")
let noAnchor=[nativeObservation([50,50,50],[2,1,1]),nativeObservation([150,150,150],[2,1,1])]
precondition(!isAccepted(combineNative(noAnchor)),"two new native observations certified each other")
// Matching one peer never removes the full group's required spread check.
precondition(!isAccepted(combineNative([dark,darkPeer,observation([160,160,160])])) )
// Native recovery runs only after legacy column shell recovery still disagrees.
let shellAndNative=PaletteCarrier.combineMembers([orange,pale()],members:members,inkOnly:true,
    recoverColumnShell:true,recoverNativePeers:true)
precondition(isAccepted(shellAndNative))
precondition(consensus(shellAndNative)["nativePeerRecoveryAttempted"] as? Bool == false)
// Dependency identity includes the policy flag, recursively, with version 6.
var geometry:[String:Any] = ["sourceTextBlockMemberPalette":true,"agent02MemberItems":members]
let oldKey=try PaletteCarrier.memoDependencies(geometry)!
geometry["sourceTextBlockNativePeerRecovery"]=true
let newKey=try PaletteCarrier.memoDependencies(geometry)!
precondition(oldKey != newKey)
let descriptor=try JSONSerialization.jsonObject(with:newKey) as! [String:Any]
precondition(descriptor["version"] as? Int==6 && descriptor["nativePeerRecovery"] as? Bool==true)
var nested:[String:Any]=["sourceTextBlockMemberPalette":true,"agent02MemberItems":[geometry,["id":"other"]]]
let nestedOn=try PaletteCarrier.memoDependencies(nested)!
geometry["sourceTextBlockNativePeerRecovery"]=false
nested["agent02MemberItems"]=[geometry,["id":"other"]]
let nestedOff=try PaletteCarrier.memoDependencies(nested)!
precondition(nestedOn != nestedOff)
print("PASS stacked/column palette regressions + native peer positives, 12 weak/invalid/missing negatives, fixed anchors, unchanged consensus, full-group spread and memo v6")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-stacked-palette-') as folder:
    root = Path(folder)
    (root / 'main.swift').write_text(carrier)
    started = time.monotonic()
    subprocess.run(['swiftc', '-module-cache-path', str(root / 'module-cache'),
                    str(ensemble / 'NativeSourceInkSelection.swift'), str(root / 'main.swift'), '-o', str(root / 'check')], check=True)
    print(f'Swift compile seconds: {time.monotonic() - started:.3f}', flush=True)
    started = time.monotonic()
    subprocess.run([str(root / 'check')], check=True)
    print(f'Fixture execution seconds: {time.monotonic() - started:.3f}', flush=True)
