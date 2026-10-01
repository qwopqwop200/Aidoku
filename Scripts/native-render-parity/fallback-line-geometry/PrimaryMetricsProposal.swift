import CoreGraphics
import CoreText
import Foundation

/// Evidence proposal only; the production typography owner controls adoption.
/// iOS measurements use the selected primary face for every horizontal scalar.
enum PrimaryMetricsProposal {
    struct Metrics { let ascent:CGFloat;let descent:CGFloat;var height:CGFloat {ascent+descent} }
    enum Platform {case observedIOS,macWebKit}
    static func metrics(primary:CTFont,platform:Platform)->Metrics {
        var ascent = CTFontGetAscent(primary),descent = CTFontGetDescent(primary)
        switch platform {
        case .observedIOS:
            // Actual iOS26.5 primaryCanvas and DOM Range captures, correlated
            // with standalone CoreText metrics from the same booted runtime.
            return .init(ascent:ceil(ascent),descent:ceil(descent))
        case .macWebKit:
            // WebKit FontCoreText.cpp platformInit140–145 + FontMetrics.h51–71.
            if descent<3,CTFontGetLeading(primary)>=3,(CTFontCopyFamilyName(primary) as String).hasPrefix("Hiragino") {descent=3}
            ascent = CGFloat(Float(ascent)).rounded(.toNearestOrAwayFromZero)
            descent = CGFloat(Float(descent)).rounded(.toNearestOrAwayFromZero)
            return .init(ascent:max(0,ascent),descent:descent)
        }
    }
    static func baseline(row:Int,rows:Int,height:CGFloat,pitch:CGFloat,metrics:Metrics,alignsToTop:Bool=false)->CGFloat {
        let p=floor(pitch),stackTop=alignsToTop ? 0:(height-CGFloat(rows)*p)/2
        return stackTop+floor((p-metrics.height)/2)+metrics.ascent+CGFloat(row)*p
    }
    static func rangeTop(row:Int,rows:Int,height:CGFloat,pitch:CGFloat,metrics:Metrics,alignsToTop:Bool=false)->CGFloat {
        baseline(row:row,rows:rows,height:height,pitch:pitch,metrics:metrics,alignsToTop:alignsToTop)-metrics.ascent
    }
}
