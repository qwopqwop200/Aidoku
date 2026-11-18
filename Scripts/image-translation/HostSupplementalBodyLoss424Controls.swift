import Foundation
import CoreGraphics

@available(macOS 15.0, *)
extension HostSourceRepairControls {
    private typealias K = NativeOCRSharedBoundary396
    private typealias G = NativeOCRSupplementalBodyLoss424
private static func scene424(angle:CGFloat,width:CGFloat,outlined:Bool=false,flat:Bool=false)->(K.RGBA,K.Basis,[CGPoint],[CGPoint]) {
    let w=128,h=160,stride=w*4+16,origin=CGPoint(x:500,y:700),center=CGPoint(x:564,y:780)
    let major=CGPoint(x:cos(angle),y:sin(angle)),normal=CGPoint(x:-sin(angle),y:cos(angle))
    var bytes=[UInt8](repeating:0,count:h*stride)
    for y in 0..<h {for x in 0..<w {
        let p=CGPoint(x:CGFloat(x)+0.5-64,y:CGFloat(y)+0.5-80)
        let n=p.x*normal.x+p.y*normal.y,a=p.x*major.x+p.y*major.y
        let fill=n>=0 && n<width && abs(a)<=26 && !flat
        let rim=n>=(-3) && n<width+3 && abs(a)<=29 && !flat
        let rgb:[UInt8]=fill ? (outlined ? [250,250,250]:[3,3,3]):
            outlined && rim ? [3,3,3]:outlined ? [120,140,160]:[250,250,250]
        let i=y*stride+x*4;bytes[i]=rgb[0];bytes[i+1]=rgb[1];bytes[i+2]=rgb[2];bytes[i+3]=255
    }}
    let old=[CGPoint(x:524,y:740),CGPoint(x:604,y:740),CGPoint(x:604,y:820),CGPoint(x:524,y:820)]
    let proposed=[CGPoint(x:568,y:740),CGPoint(x:604,y:740),CGPoint(x:604,y:820),CGPoint(x:568,y:820)]
    return (.init(bytes:bytes,width:w,height:h,bytesPerRow:stride,origin:origin),
        .init(origin:center,normal:CGPoint(x:1,y:0),along:CGPoint(x:0,y:1)),old,proposed)
}
    static func runSupplemental424() throws -> [String: Any] {
        struct ControlFailure: Error { let message: String }
        var receipts: [[String: Any]] = []
        func check(_ ok: Bool, _ name: String) throws {
            if !ok { throw ControlFailure(message: name) }
        }
        var config = NativeOCRSourceLocalJoint369Capture.ExportConfiguration()
        try check(!config.requestsPositiveLoss424, "424 default OFF")
        config.families = ["source-cost424-positive-loss-select"]
        try check(!config.requestsPositiveLoss424, "424 disabled remains OFF")
        config.enabled = true
        try check(config.requestsPositiveLoss424 && config.requestsNativeAdmission425 &&
            config.requestsSourceCostFast422 && config.requestsSourceCost418, "424/425/fast chain")
        let angles: [CGFloat] = [0, 0.21, 0.48, .pi/4, 1.2, .pi/2, 2.2, .pi, -.pi/3]
        for angle in angles { for width in [CGFloat(1), 2] { for outlined in [false, true] {
            let (rgba, basis, old, proposed) = scene424(angle: angle, width: width, outlined: outlined)
            let observed = G.assess(actualOld: old, proposed: proposed, basis: basis,
                nativeW: 32, rgba: rgba, maximumQueries: 512)
            let label = "angle=\(angle) width=\(width) outlined=\(outlined)"
            try check(observed.decision == .rejectObservedLoss, "positive source loss " + label + " \(observed.receipt)")
            try check((observed.receipt["actualLostCorePixelCount"] as? Int ?? 0) > 0, "actual core " + label)
            try check(observed.repair != nil && observed.repair!.allSatisfy { K.contains(old, $0) }, "old-bounded nomination " + label)
            try check(observed.receipt["ownershipClaimed"] as? Bool == false &&
                observed.receipt["nativeAdmissionGranted"] as? Bool == false, "no authority " + label)
            receipts.append(["scene": label, "receipt": observed.receipt])
        } } }
        let (rgba, basis, old, proposed) = scene424(angle: 0, width: 1, flat: true)
        let blank = G.assess(actualOld: old, proposed: proposed, basis: basis, nativeW: 32, rgba: rgba, maximumQueries: 512)
        try check(blank.decision == .unresolved, "uniform background remains unresolved")
        let same = G.assess(actualOld: old, proposed: old, basis: basis, nativeW: 32, rgba: rgba, maximumQueries: 512)
        try check(same.decision == .noRemovedPixel, "same box no source pixels removed")
        return ["status": "pass", "sourceScenes": receipts, "blank": blank.receipt,
            "sameBox": same.receipt, "maximumQueries": 512, "syntheticOriginalRGBOnly": true,
            "privateOrGGMaskFabricated": false, "detectorCalls": 0, "recognizerCalls": 0,
            "nativeAdmissionGranted": false, "repairApplied": false]
    }
}
