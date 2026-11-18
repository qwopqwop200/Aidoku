"""Exercise the shared native colour harmonizer with JSON-decoded source observations."""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
engine = root/'Aidoku/Core/Translation/NativeEngine/Ensemble'
declaration = (engine/'NativeOperationalAppearance.swift').read_text().split('static let bindingKeys: Set<String> = [', 1)[1].split(']', 1)[0]
program = 'import Foundation\nenum NativeOperationalAppearance { static let bindingKeys:Set<String> = ['+declaration+'] }\n'
program += r'''
let binding=Dictionary(uniqueKeysWithValues:NativeOperationalAppearance.bindingKeys.map {($0,String(repeating:"a",count:64))})
func source(_ id:String,_ fill:[Double],font:Double=48,bold:Bool=false,present:Bool=false,support:Double=0.99)->[String:Any] {
 let raw:[String:Any]=["id":id,"sourceAppearanceBinding":binding,"sourceFontSize":font,
  "sourceFontWeight":bold ? "bold":"regular","renderBold":bold,
  "sourceAppearance":["sourceOnly":true,"inferenceUsesGT":false,"fill":["rgb":fill],"outline":["present":present,"rgb":[255.0,255.0,253.0],"widthPx":present ? 5.0:0.0],
    "background":["rgb":[255.0,255.0,253.0],"observedContextWeights":[support,1-support]]]]
 // Match the real JSON/NSNumber carrier, rather than Swift literal cast rules.
 return try! JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:raw)) as! [String:Any]
}
let inputs=[source("a",[223,96,68]),source("b",[222,96,68],font:74,bold:true,present:true),
 source("purple",[156,65,123]),source("uncertain",[8,138,220],support:0.6)]
let snapshot=try! JSONSerialization.data(withJSONObject:inputs,options:[.sortedKeys])
let result=NativeSourceStyleConsistency.harmonized(inputs)
precondition(result[0]["renderSourceFillRGB"]as?[Double] == result[1]["renderSourceFillRGB"]as?[Double])
precondition(result[0]["sourceColourGroupID"]as?String == result[1]["sourceColourGroupID"]as?String)
precondition(result[0]["sourceStyleGroupID"]as?String != result[1]["sourceStyleGroupID"]as?String)
precondition(result[0]["sourceColourGroupID"]as?String != result[2]["sourceColourGroupID"]as?String)
precondition(result[0]["renderSourceDisplayStrokeRGB"]as?[Double] == [255,255,255])
precondition(result[1]["renderSourceDisplayStrokeRGB"] == nil)
precondition(result[3]["renderSourceDisplayStrokeRGB"] == nil)
for i in inputs.indices {
 precondition(NSDictionary(dictionary:inputs[i]["sourceAppearance"]as![String:Any]).isEqual(to:result[i]["sourceAppearance"]as![String:Any]))
 precondition(inputs[i]["sourceFontSize"]as?Double == result[i]["sourceFontSize"]as?Double)
 precondition(inputs[i]["renderBold"]as?Bool == result[i]["renderBold"]as?Bool)
}
precondition(snapshot == (try! JSONSerialization.data(withJSONObject:inputs,options:[.sortedKeys])))
let again=NativeSourceStyleConsistency.harmonized(result)
precondition((try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])) == (try! JSONSerialization.data(withJSONObject:again,options:[.sortedKeys])))
var unsigned=inputs[0];unsigned.removeValue(forKey:"sourceAppearanceBinding")
precondition(NativeSourceStyleConsistency.harmonized([unsigned])[0]["renderSourceFillRGB"] == nil)
var outlined=source("source-orange",[255,254,250],present:true)
var prediction=outlined["sourceAppearance"]as![String:Any]
prediction["sourceOnly"]=true;prediction["inferenceUsesGT"]=false
prediction["outline"]=["present":true,"rgb":[221.0,90.0,5.0],"widthPx":5.0,"probability":0.99,
 "measurementEvidence":["reliable":true,"usableRays":200]]as[String:Any]
prediction["pixelRoleEvidence"]=["roles":["outline":["confidentSamples":100,
 "observedColours":[["rgb":[221.0,90.0,5.0],"observedMass":0.98]]]]]
outlined["sourceAppearance"]=prediction
let faithful=NativeSourceStyleConsistency.harmonized([outlined])[0]
precondition(faithful["renderSourceDisplayStrokeRGB"]as?[Double] == [255,255,255])
precondition(faithful["renderSourceOutlineRGB"]as?[Double] == [221,90,5])
precondition(NativeSourceStyleConsistency.sourceOutlineEndpoint(prediction,fill:[254,244,222]) == [255,255,255])
for nonNeutral:[Double] in [[255,230,150],[190,180,170],[240,170,220]] {
 precondition(NativeSourceStyleConsistency.sourceOutlineEndpoint(prediction,fill:nonNeutral) == nil)
}
var uncertain=prediction;var invalidOutline=prediction["outline"]as![String:Any]
invalidOutline["observedLayers"]=[[String:Any](),[String:Any]()];uncertain["outline"]=invalidOutline
precondition(NativeSourceStyleConsistency.sourceOutlineEndpoint(uncertain,fill:[255,254,250]) == nil)
uncertain=prediction;uncertain["sourceOnly"]=false
precondition(NativeSourceStyleConsistency.sourceOutlineEndpoint(uncertain,fill:[255,254,250]) == nil)
precondition(NativeSourceStyleConsistency.sourceOutlineEndpoint(prediction,fill:[180,170,160]) == nil)
print("PASS native source colour: cross-size/weight colour family, distinct ink, faithful neutral halo, uncertain background, immutable source and idempotence")
var uncertainNeutral:[String:Any]=["sourceOnly":true,"inferenceUsesGT":false,
 "outline":["present":true,"rgb":[254.0,254,254],"measurementEvidence":["reliable":false]],
 "pixelRoleEvidence":["roles":["fill":["confidentSamples":100,
 "observedColours":[["rgb":[254.0,254,254],"observedMass":0.98]]]]]]
precondition(NativeSourceStyleConsistency.sourceNeutralContrastEndpoint(uncertainNeutral,fill:[254,254,254]) == [0,0,0])
uncertainNeutral["outline"]=["present":true,"rgb":[28.0,19,0],"measurementEvidence":["reliable":false]]
uncertainNeutral["pixelRoleEvidence"]=["roles":["fill":["confidentSamples":100,
 "observedColours":[["rgb":[4.0,5,0],"observedMass":0.64],["rgb":[19.0,13,0],"observedMass":0.13],["rgb":[25.0,18,0],"observedMass":0.10]]]]]
precondition(NativeSourceStyleConsistency.sourceNeutralContrastEndpoint(uncertainNeutral,fill:[1,0,0]) == [255,255,255])
precondition(NativeSourceStyleConsistency.sourceNeutralContrastEndpoint(prediction,fill:[255,254,250]) == nil)
var liveNeutral=source("neutral-counter",[1,0,0],present:true)
var livePrediction=uncertainNeutral
livePrediction["fill"]=["rgb":[1.0,0,0]]
var liveOutline=livePrediction["outline"]as![String:Any];liveOutline["widthPx"]=2.0;livePrediction["outline"]=liveOutline
liveNeutral["sourceAppearance"]=livePrediction
let liveBefore=try! JSONSerialization.data(withJSONObject:liveNeutral,options:[.sortedKeys])
let liveResult=NativeSourceStyleConsistency.harmonized([liveNeutral])[0]
precondition(liveResult["renderSourceDisplayStrokeRGB"]as?[Double] == [255,255,255])
precondition((try! JSONSerialization.data(withJSONObject:liveNeutral,options:[.sortedKeys])) == liveBefore)
uncertainNeutral["sourceOnly"]=false
precondition(NativeSourceStyleConsistency.sourceNeutralContrastEndpoint(uncertainNeutral,fill:[1,0,0]) == nil)
let pale:[Double]=[255,247,211],orange:[Double]=[248,133,12]
let blended:[String:Any]=["sourceOnly":true,"inferenceUsesGT":false,
 "fill":["rgb":pale],
 "outline":["present":true,"rgb":[254.0,255,254],"widthPx":2.0,"measurementEvidence":["reliable":false]],
 "pixelRoleEvidence":["roles":[
  "fill":["confidentSamples":327,"observedColours":[["rgb":pale,"observedMass":0.15],["rgb":orange,"observedMass":0.07]]],
  "outline":["confidentSamples":762,"observedColours":[["rgb":[254.0,255,255],"observedMass":1.0]]],
  "background":["observedColours":[["rgb":[121.0,182,173],"observedMass":0.16]]]]]]
precondition(NativeSourceStyleConsistency.sourceUnblendedFill(blended,fill:pale) == orange)
var blendLive=source("observed-chromatic-core",pale,present:true);blendLive["sourceAppearance"]=blended
let blendSnapshot=try! JSONSerialization.data(withJSONObject:blendLive,options:[.sortedKeys])
let recovered=NativeSourceStyleConsistency.harmonized([blendLive])[0]
precondition(recovered["renderSourceFillRGB"]as?[Double] == orange)
precondition((try! JSONSerialization.data(withJSONObject:blendLive,options:[.sortedKeys])) == blendSnapshot)
var rejected=blended;rejected["sourceOnly"]=false
precondition(NativeSourceStyleConsistency.sourceUnblendedFill(rejected,fill:pale) == nil)
var roles=(blended["pixelRoleEvidence"]as![String:Any])["roles"]as![String:Any]
roles["fill"]=["confidentSamples":327,"observedColours":[["rgb":pale,"observedMass":0.9],["rgb":orange,"observedMass":0.07]]]
rejected=blended;rejected["pixelRoleEvidence"]=["roles":roles]
precondition(NativeSourceStyleConsistency.sourceUnblendedFill(rejected,fill:pale) == nil)
roles=(blended["pixelRoleEvidence"]as![String:Any])["roles"]as![String:Any]
roles["background"]=["observedColours":[["rgb":orange,"observedMass":0.2]]]
rejected=blended;rejected["pixelRoleEvidence"]=["roles":roles]
precondition(NativeSourceStyleConsistency.sourceUnblendedFill(rejected,fill:pale) == nil)
let chromatic:[String:Any]=["sourceOnly":true,"inferenceUsesGT":false,
 "fill":["rgb":[249.0,248,247]],
 "outline":["present":false,"rgb":[235.0,230,230],"widthPx":0.0,"measurementEvidence":["reliable":false]],
 "background":["rgb":[244.0,245,246],"colors":[[140.0,40,40],[220.0,222,224],[248.0,249,250]],
  "observedContextWeights":[0.03,0.42,0.55]],
 "pixelRoleEvidence":["roles":[
  "fill":["confidentSamples":100,"observedColours":[["rgb":[148.0,41,40],"observedMass":0.16],["rgb":[120.0,56,53],"observedMass":0.12]]],
  "background":["observedColours":[["rgb":[245.0,245,245],"observedMass":0.9]]]]]]
let paleCore:[Double]=[249,248,247],observedCore:[Double]=[148,41,40]
precondition(NativeSourceStyleConsistency.sourceObservedChromaticFill(chromatic,fill:paleCore) == observedCore)
precondition(NativeSourceStyleConsistency.sourceUnblendedFill(chromatic,fill:paleCore) == observedCore)
var coreLive=source("observed-without-rim",paleCore,present:false);coreLive["sourceAppearance"]=chromatic
let coreBefore=try! JSONSerialization.data(withJSONObject:coreLive,options:[.sortedKeys])
let coreResult=NativeSourceStyleConsistency.harmonized([coreLive])
precondition(coreResult[0]["renderSourceFillRGB"]as?[Double] == observedCore)
precondition((try! JSONSerialization.data(withJSONObject:coreLive,options:[.sortedKeys])) == coreBefore)
precondition((try! JSONSerialization.data(withJSONObject:NativeSourceStyleConsistency.harmonized(coreResult),options:[.sortedKeys])) ==
 (try! JSONSerialization.data(withJSONObject:coreResult,options:[.sortedKeys])))
var coreRejected=chromatic
coreRejected["outline"]=["present":true,"rgb":observedCore,"measurementEvidence":["reliable":true]]
precondition(NativeSourceStyleConsistency.sourceObservedChromaticFill(coreRejected,fill:paleCore) == nil)
let coreRoles=(chromatic["pixelRoleEvidence"]as![String:Any])["roles"]as![String:Any]
for second in [[40.0,148,41],[255.0,60,60],[30.0,40,180]] {
 var changed=coreRoles
 changed["fill"]=["confidentSamples":100,"observedColours":[["rgb":observedCore,"observedMass":0.16],["rgb":second,"observedMass":0.12]]]
 coreRejected=chromatic;coreRejected["pixelRoleEvidence"]=["roles":changed]
 precondition(NativeSourceStyleConsistency.sourceObservedChromaticFill(coreRejected,fill:paleCore) == nil)
}
for mass in [Double.nan,Double.infinity,-0.1,1.1] {
 var changed=coreRoles
 changed["fill"]=["confidentSamples":100,"observedColours":[["rgb":observedCore,"observedMass":mass]]]
 coreRejected=chromatic;coreRejected["pixelRoleEvidence"]=["roles":changed]
 precondition(NativeSourceStyleConsistency.sourceObservedChromaticFill(coreRejected,fill:paleCore) == nil)
}
for strong in [false,true] {
 var changed=coreRoles
 if strong {
  changed["fill"]=["confidentSamples":100,"observedColours":[["rgb":observedCore,"observedMass":0.3],["rgb":paleCore,"observedMass":0.5]]]
 }else{
  changed["background"]=["observedColours":[["rgb":[120.0,56,53],"observedMass":0.05]]]
 }
 coreRejected=chromatic;coreRejected["pixelRoleEvidence"]=["roles":changed]
 precondition(NativeSourceStyleConsistency.sourceObservedChromaticFill(coreRejected,fill:paleCore) == nil)
}
var paletteGuard:[String:Any]=["sourceOnly":true,"inferenceUsesGT":false,"outline":["present":false],
 "background":["rgb":[244.0,248,249],"colors":[[225.0,217,227],[244.0,248,249]],"observedContextWeights":[0.1,0.9]]]
let guardFill:[Double]=[133,53,55]
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == [255,255,255])
var guardBackground=paletteGuard["background"]as![String:Any]
guardBackground["colors"]=[[244.0,248,249],[225.0,217,227]]
guardBackground["observedContextWeights"]=[0.9,0.1];paletteGuard["background"]=guardBackground
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == [255,255,255])
guardBackground["observedContextWeights"]=[0.1,0.9];paletteGuard["background"]=guardBackground
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == nil)
guardBackground["colors"]=[[225.0,217,227],[244.0,248,249]]
guardBackground["observedContextWeights"]=[0.9,0.1];paletteGuard["background"]=guardBackground
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == nil)
for invalidPalette:Any in [NSNull(),[],[[244.0,248,249]],[[225.0,217,227],[256.0,248,249]]] {
 guardBackground["colors"]=invalidPalette;paletteGuard["background"]=guardBackground
 precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == nil)
}
guardBackground.removeValue(forKey:"colors");paletteGuard["background"]=guardBackground
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == [255,255,255])
paletteGuard["sourceOnly"]=false
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == nil)
paletteGuard["sourceOnly"]=true;paletteGuard["inferenceUsesGT"]=true
precondition(NativeSourceStyleConsistency.sourceBackgroundEndpoint(paletteGuard,fill:guardFill) == nil)
print("PASS observed chromatic-core recovery; strong-fill, unsigned-source and background-colour guards")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-source-colour-') as temp:
    folder = Path(temp); source = folder/'main.swift'; source.write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-O', str(engine/'NativeSourceStyleConsistency.swift'), str(source), '-o', str(folder/'check')], check=True)
    subprocess.run([str(folder/'check')], check=True)
