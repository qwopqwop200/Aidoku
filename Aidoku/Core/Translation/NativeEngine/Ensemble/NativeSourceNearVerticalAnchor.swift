import CoreGraphics
import Foundation

/// Versioned display-placement metric; no inference or sentence ownership.
struct NativeSourceNearVerticalAnchor {
    let sourceTop: Bool
    let topDrift: CGFloat

    static func parse(_ metadata: [String: Any]) -> Self? {
        func number(_ value: Any?) -> Double? {
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil}
            return n.doubleValue
        }
        if number(metadata["version"])==1 {
            guard metadata["verticalAnchorMetric"]==nil,metadata["maxTopDrift"]==nil else{return nil}
            return .init(sourceTop:false,topDrift:0)
        }
        guard number(metadata["version"])==2,metadata["verticalAnchorMetric"] as? String=="source-top",
              let drift=number(metadata["maxTopDrift"]),drift>=0 else{return nil}
        return .init(sourceTop:true,topDrift:CGFloat(drift))
    }

    func center(anchor: CGRect, blockHeight: CGFloat) -> CGFloat {
        sourceTop ? anchor.minY+blockHeight/2 : anchor.midY
    }

    func permits(block: CGRect, anchor: CGRect, centerDrift: CGFloat) -> Bool {
        abs(block.midX-anchor.midX)<=centerDrift+1e-7 &&
            (sourceTop ? abs(block.minY-anchor.minY)<=topDrift+1e-7 : abs(block.midY-anchor.midY)<=centerDrift+1e-7)
    }
}
