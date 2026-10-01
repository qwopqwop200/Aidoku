import Foundation
import CoreGraphics
final class Candidate: NativeFinalRestorationCandidate {
 var trialSurface: NativeResidualTopology.Surface
 init(_ value: NativeResidualTopology.Surface) { trialSurface = value }
}
@main struct Probe {
 static func snapshot(_ s: NativeResidualTopology.Surface) -> [String:Any] {
  ["rgba":s.rgba,"safe":s.safe,"luminance":s.luminance,"revision":s.surfaceRevision,"enclosedSpecks":s.enclosedSpecks as Any? ?? NSNull(),"coreClear":s.coreClear as Any? ?? NSNull(),"innerCoreClear":s.innerCoreClear as Any? ?? NSNull(),"residualLettering":s.residualLettering as Any? ?? NSNull()]
 }
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  var actual: [Any] = []
  for f in fixtures {
   func number(_ k:String)->Double { (f[k] as! NSNumber).doubleValue }
   func flag(_ k:String)->Bool { f[k] as! Bool }
   func array(_ k:String)->[Double] { (f[k] as! [NSNumber]).map(\.doubleValue) }
   func rects(_ k:String)->[[Double]] { (f[k] as! [[NSNumber]]).map { $0.map(\.doubleValue) } }
   func bytes(_ k:String)->[UInt8] { (f[k] as! [Int]).map(UInt8.init) }
   func rect(_ a:[Double])->CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
   let w = f["w"] as! Int, h = f["h"] as! Int
   let candidate = Candidate(.init(width:w,height:h,rgba:bytes("rgba"),safe:bytes("safe"),luminance:bytes("luminance"),surfaceRevision:f["revision"] as! Int,coreClear:flag("coreClear"),innerCoreClear:flag("innerCoreClear"),residualLettering:true))
   let size = array("imageSize"), crop = array("crop"), scale = array("scale")
   let geometry = NativeFinalRestorationTrial.Geometry(imageSize:CGSize(width:size[0],height:size[1]),frame:rect(array("frame")),cropOrigin:CGPoint(x:crop[0],y:crop[1]),scale:CGSize(width:scale[0],height:scale[1]),sourceBounds:array("sourceBounds"),auxiliaryInkRects:rects("aux"),sourceFontSize:number("sourceFont"))
   let parent = f["parent"] as! String
   if f["op"] as! String == "short" {
    let input = NativeFinalRestorationTrial.ShortCaptionInput(geometry:geometry,plate:rect(array("plate")),inpaintingEnabled:flag("inpainting"),opacity:number("opacity"),erasureComplete:flag("erasureComplete"),provisional:flag("provisional"),partialErasureCertified:flag("partial"),rotation:number("rotation"),sourceSingleColumn:flag("single"),text:f["text"] as! String,sourceRemainingInk:(f["remaining"] as? NSNumber)?.doubleValue,canvasConnected:flag("canvasConnected"),nodePresent:flag("nodePresent"),plateCount:f["plateCount"] as! Int,parentIsRoot:parent == "root",parentIsPlate:parent == "plate",otherSourceRects:rects("otherRects").map(rect),fontSize:number("font"))
    let outcome = NativeFinalRestorationTrial.shortCaption(candidate:candidate,input:input)
    actual.append(["surface":snapshot(candidate.trialSurface),"outcome":["accepted":outcome.accepted,"unsafe":outcome.unsafe as Any? ?? NSNull(),"strokeWidth":outcome.strokeWidth as Any? ?? NSNull(),"enclosedSpecks":outcome.enclosedSpecks as Any? ?? NSNull()]])
   } else {
    var trace: [String] = [], connected = flag("canvasConnected"), provisional = flag("provisional"), filled = Double.nan
    let input = NativeFinalRestorationTrial.BalloonInput(geometry:geometry,plate:rect(array("plate")),budgetAvailable:flag("budget"),erasureComplete:flag("erasureComplete"),partialErasureCertified:flag("partial"),provisional:provisional,localProposalDetached:flag("localProposal") && !connected,canvasConnected:connected,canvasOwnedByRoot:flag("canvasOwned"),canvasHidden:flag("canvasHidden"),sourcePanelAlreadyReleased:flag("alreadyReleased"),rotation:number("rotation"),balancedColumn:flag("balanced"),nodePresent:flag("nodePresent"),plateConnected:flag("plateConnected"),nodeHidden:flag("nodeHidden"),nodeScaled:flag("nodeScaled"),parentIsRoot:parent == "root",parentIsPlate:parent == "plate",sourceErasureRestored:flag("certified"),residualRefusedOnCurrentSurfaceAndPlate:flag("refused"))
    let budget = NativeFinalRestorationTrial.BalloonBudget();budget.searches = f["searches"] as! Int
    let callbacks = NativeFinalRestorationTrial.BalloonCallbacks(restorationFitEligible:{
     trace.append("eligible");return NativeResidualTopology.restoredErasureCovers(safe:candidate.trialSurface.safe,width:w,height:h,regions:rects("regions"),glyphSize:number("glyph"),core:rects("core"))
    },completeResidualErasure:{
     trace.append("residual");if !flag("residualAllowed") { return nil }
     let previous = candidate.trialSurface
     for i in f["residualIndices"] as! [Int] {
      candidate.trialSurface.safe[i] = 1;candidate.trialSurface.luminance[i] = 255
      candidate.trialSurface.rgba.replaceSubrange((i*4)..<(i*4+4),with:[255,255,255,255])
     }
     candidate.trialSurface.surfaceRevision += 1;filled = number("residualFilled")
     return { trace.append("undo-residual");let rev = candidate.trialSurface.surfaceRevision + 1;candidate.trialSurface = previous;candidate.trialSurface.surfaceRevision = rev }
    },sourceResidualFilled:{filled},fitBalloon:{
     trace.append("fit");return !flag("fitFails") && NativeResidualTopology.mainbodyCellsClear(safe:candidate.trialSurface.safe,width:w,height:h,regions:rects("glyphRects"))
    },liftNodeFromPlate:{trace.append("lift")},restoreNodeToPlate:{trace.append("restore")},attachProposal:{trace.append("attach");connected = true},detachProposal:{trace.append("detach");connected = false},commitRestorationFit:{_,local in if local { provisional = false };trace.append("commit");trace.append("remove-backing")})
    let result = NativeFinalRestorationTrial.balloonSafeFit(candidate:candidate,input:input,budget:budget,callbacks:callbacks)
    actual.append(["surface":snapshot(candidate.trialSurface),"outcome":["accepted":result.accepted,"searched":result.searched,"enclosedSpecks":result.enclosedSpecks as Any? ?? NSNull(),"localProposalCommitted":result.localProposalCommitted],"trace":trace,"searches":budget.searches,"successfulFits":budget.successfulFits,"canvasConnected":connected,"provisional":provisional])
   }
  }
  try JSONSerialization.data(withJSONObject:actual,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
