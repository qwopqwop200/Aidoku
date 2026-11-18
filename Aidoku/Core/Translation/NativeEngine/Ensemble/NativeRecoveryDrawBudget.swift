import CoreGraphics
import Foundation

/// One whole-page ledger survives native metrics scopes and pitch families.
/// Counts owner-raster factory draws, not CTLine effect-proof measurements.
enum NativeRecoveryDrawBudget {
    enum Failure:Error {case invalidDraw,additionalOwnerFontLimit(String),additionalPageLimit}
    final class Ledger: @unchecked Sendable {
        struct Key:Hashable {let owner:String;let font:Double}
        private var ordinary:[Key:Int]=[:],recovery:[Key:Int]=[:],stages:[String:Int]=[:]
        private(set) var recoveryActive=false
        private(set) var legacyFailure:Error?
        private(set) var additionalDraws=0
        private var rejected=0
        private let emitAudit=ProcessInfo.processInfo.environment["AIDOKU_RECOVERY_DRAW_AUDIT"] == "1"
        func beginRecovery(after failure:Error) {
            guard !recoveryActive else {return}
            legacyFailure=failure;recoveryActive=true
        }
        func remaining(owner:String,fontPixels:CGFloat)->Int {
            guard recoveryActive,fontPixels.isFinite,fontPixels>0 else {return 0}
            return max(0,min(8-recovery[Key(owner:owner,font:Double(fontPixels)),default:0],128-additionalDraws))
        }
        func chargeDraw(owner:String,fontPixels:CGFloat,stage:String="factory")throws {
            try Task.checkCancellation()
            guard !owner.isEmpty,owner.count<=256,fontPixels.isFinite,fontPixels>0,fontPixels<=2048 else {throw Failure.invalidDraw}
            let key=Key(owner:owner,font:Double(fontPixels))
            if recoveryActive {
                guard additionalDraws<128 else {rejected+=1;throw Failure.additionalPageLimit}
                guard recovery[key,default:0]<8 else {rejected+=1;throw Failure.additionalOwnerFontLimit(owner)}
                recovery[key,default:0]+=1;additionalDraws+=1
                stages[stage,default:0]+=1
            } else {ordinary[key,default:0]+=1}
        }
        var audit:[String:Any] {
            let keys=Set(ordinary.keys).union(recovery.keys).sorted {$0.owner == $1.owner ? $0.font<$1.font:$0.owner<$1.owner}
            let rows:[[String:Any]]=keys.map {k in
                let a=ordinary[k,default:0],b=recovery[k,default:0]
                return ["owner":k.owner,"fontPixels":k.font,"ordinaryDraws":a,"recoveryDraws":b,"totalDraws":a+b]
            }
            let a=ordinary.values.reduce(0,+)
            return ["scope":"whole-page owner-raster frame.draw calls; attempted before nonthrowing draw, including subsequently discarded rasters",
                "ordinaryDraws":a,"recoveryDraws":additionalDraws,"totalDraws":a+additionalDraws,
                "recoveryActive":recoveryActive,"additionalOwnerFontLimit":8,"additionalPageLimit":128,
                "rejectedDrawRequests":rejected,"recoveryStages":stages,"owners":rows,
                "ordinaryAndRecoveryCombinedBudgetUnchanged":false,
                "effectMeasurements":"separate typed-pitch measurement/pixel guards; not owner-raster factory draws"]
        }
        func reportIfRequested() {
            guard emitAudit,let data=try? JSONSerialization.data(withJSONObject:audit,options:.sortedKeys) else{return}
            fputs("recovery-draw-budget "+String(decoding:data,as:UTF8.self)+"\n",stderr)
        }
    }
    @TaskLocal static var current:Ledger?
}
