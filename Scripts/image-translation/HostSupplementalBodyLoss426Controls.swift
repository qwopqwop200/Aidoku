import Foundation
import CoreGraphics

// OPTIONAL typed fixture entry; production helper dispatch has no fixture IDs/GT.
@available(macOS 15.0, *)
enum HostSupplementalBodyLoss426Controls {
    private typealias K426 = NativeOCRSharedBoundary396
    private struct ControlFailure: Error { let message: String }
private static func scene426(_ mode:String)->K426.RGBA {
 let w=128,h=160;var bytes=[UInt8](repeating:255,count:w*h*4)
 for y in 0..<h {for x in 0..<w {
  var c=mode=="blurred" ? (x<62 ? [250,252,242]:[250,254,241]):[250,250,250]
  if mode=="outlined" || mode=="twoRows" || mode=="step" {
   c=x<62 ? [50,50,50]:[85,85,85]
   if mode != "step" && (mode=="twoRows" ? y>=79 && y<=80:y>=50 && y<=110) {
    if x==61 || x==63 {c=[252,252,252]};if x==62 {c=[1,1,1]}
   }
  }
  if mode=="blurred" && y>=50 && y<=110 {
   let profile:[[Int]]=[[250,252,242],[248,250,240],[247,249,237],[236,238,226],[207,209,197],[163,165,153],[112,114,99],[71,74,59],[55,57,42],[66,69,54],[105,107,92],[155,157,143],[201,206,190],[236,241,225],[253,255,243],[250,254,241],[250,254,241],[250,254,241]]
   if x>=55 && x<55+profile.count {c=profile[x-55]}
  }
  for k in 0..<3 {bytes[(y*w+x)*4+k]=UInt8(c[k])}
 }}
 return .init(bytes:bytes,width:w,height:h,bytesPerRow:w*4,origin:.zero)
}
    static func run() throws -> [String:Any] {
        func check(_ ok:Bool,_ label:String) throws { if !ok {throw ControlFailure(message:label)} }
        var config=NativeOCRSourceLocalJoint369Capture.ExportConfiguration()
        try check(!config.requestsPositiveLoss426,"426 default OFF")
        config.families=["source-cost426-positive-loss-select"]
        try check(!config.requestsPositiveLoss426 && !config.requestsSourceCost427MixedSelect,"disabled remains OFF")
        config.enabled=true
        try check(config.requestsPositiveLoss426 && config.requestsSourceCost427MixedSelect && config.requestsPositiveLoss424 && config.requestsNativeAdmission425 && config.requestsSourceCostFast422,"426 implies current427/424/425 chain")
        config.families=["source-cost427-mixed-select"]
        try check(config.requestsSourceCost427MixedSelect && config.requestsPositiveLoss424 && !config.requestsPositiveLoss426,"existing427 does not implicitly enable426")
        config.families=["source-cost424-positive-loss-select"]
        try check(config.requestsPositiveLoss424 && !config.requestsPositiveLoss426 && !config.requestsSourceCost427MixedSelect,"existing424 opt-in unchanged")
        let n=CGPoint(x:1,y:0),a=CGPoint(x:0,y:1),q=CGPoint(x:62.5,y:80.5)
        let blurred=scene426("blurred")
        let beforeFill=SourceClosedThinBody424.assess(rgba:blurred,queryPoint:q,normal:n,along:a,nativeW:24)
        let afterFill=SourceClosedFiniteFill426.assess(rgba:blurred,queryPoint:q,normal:n,along:a,nativeW:24)
        try check(!beforeFill.positive && afterFill.positive,"blurred fixed fill palette actual17-unit difference")
        let outline=scene426("outlined")
        let beforeOutline=SourceClosedOutlinedThinBody424.assess(rgba:outline,queryPoint:q,normal:n,along:a,nativeW:10)
        let afterOutline=SourceClosedOutlinedPair426.assess(rgba:outline,queryPoint:q,normal:n,along:a,nativeW:10)
        try check(!beforeOutline.positive && afterOutline.positive,"separately stable different bilateral exteriors")
        for mode in ["blank","twoRows","step"] {
            try check(!SourceClosedOutlinedPair426.assess(rgba:scene426(mode),queryPoint:q,normal:n,along:a,nativeW:10).positive,"abstention "+mode)
        }
        return ["status":"pass","familyDefaultOFF":true,"implies427Mixed":true,
            "plainFill":afterFill.receipt,"outlinedPair":afterOutline.receipt,
            "fixturesCopiedFromFrozen426":true,"actualNativeFrameReplay":false,
            "nativeAdmissionGranted":false,"repairApplied":false,
            "detectorCalls":0,"recognizerCalls":0]
    }
}
