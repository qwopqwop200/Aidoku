import Foundation
import CoreGraphics

/// Page-local reports and bounded generated word proposals. Source RGB, GT,
/// cross-page identities and on-disk inference caches are never retained.
final class CorpusRenderReferenceCache {
    /// In-memory painter geometry is CGFloat; serialized geometry may be Int
    /// or Double. Normalize numeric values without silently dropping a fit.
    static func numbers(_ value:Any?)->[Double]? {
        guard let raw=value as?[Any]else{return nil}
        let result=raw.compactMap {($0 as?NSNumber)?.doubleValue}
        guard result.count==raw.count,result.allSatisfy(\.isFinite)else{return nil}
        return result
    }
    let enabled:Bool
    let paragraphCompactionEnabled:Bool
    var paragraphFallbackOwners=Set<String>()
    let lexicalWidthsEnabled:Bool
    var lexicalFallbackOwners=Set<String>()
    private var priorLexicalReport:[String:Any]?
    private var priorLexicalCache:CorpusRenderReferenceCache?
    private weak var proposalParent:CorpusRenderReferenceCache?
    private(set) var priorParagraphCache:CorpusRenderReferenceCache?
    private var priorParagraphReport:[String:Any]?
    var completedCapture:(([String:Any])->Void)?
    // The renderer owns this immutable native artifact. Keep the cache usable
    // by the standalone word-shaping runner without a compositor dependency.
    var completedPaint:Any?
    private var reports:[Data:[String:Any]]=[:]
    private var order:[Data]=[]
    private enum Proposal {case rejected,accepted(CorpusWholeWordProposal.Result)}
    private var proposals:[Data:Proposal]=[:]
    private var proposalOrder:[Data]=[]
    private var proposalBytes=0
    private let proposalBudget=64*1024*1024
    private(set) var proposalHits=0
    private(set) var proposalMisses=0
    private(set) var hits=0
    private(set) var misses=0
    init(enabled:Bool=ProcessInfo.processInfo.environment["AIDOKU_RENDER_REFERENCE_CACHE"] != "0",
         paragraphCompactionEnabled:Bool=true,lexicalWidthsEnabled:Bool=true,proposalParent:CorpusRenderReferenceCache?=nil) {
        self.enabled=enabled && ProcessInfo.processInfo.environment["AIDOKU_WORD_WIDTH_TRACE"] != "1"
        self.paragraphCompactionEnabled=paragraphCompactionEnabled
        self.lexicalWidthsEnabled=lexicalWidthsEnabled
        self.proposalParent=proposalParent
    }
    func priorParagraphReference(_ compute:(CorpusRenderReferenceCache)throws->[String:Any])rethrows->[String:Any] {
        // The lexical baseline and current search share the same plain policy.
        // Reuse its completed pixels rather than shaping that policy twice.
        if paragraphCompactionEnabled,!lexicalWidthsEnabled,let parent=proposalParent,parent.lexicalWidthsEnabled {
            let report=try parent.priorParagraphReference(compute)
            priorParagraphCache=parent.priorParagraphCache;return report
        }
        if enabled,let priorParagraphReport{return priorParagraphReport}
        let child=CorpusRenderReferenceCache(enabled:enabled,paragraphCompactionEnabled:false,proposalParent:self)
        let report=try compute(child)
        priorParagraphCache=child
        if enabled {priorParagraphReport=report}
        return report
    }
    func priorLexicalReference(_ compute:(CorpusRenderReferenceCache)throws->[String:Any])rethrows->[String:Any] {
        if enabled,let priorLexicalReport{return priorLexicalReport}
        let child=CorpusRenderReferenceCache(enabled:enabled,paragraphCompactionEnabled:paragraphCompactionEnabled,
            lexicalWidthsEnabled:false,proposalParent:self)
        let report=try compute(child)
        priorLexicalCache=child
        if enabled {priorLexicalReport=report}
        return report
    }
    func wordProposal(for key:Data,compute:()throws->CorpusWholeWordProposal.Result?)rethrows->CorpusWholeWordProposal.Result? {
        if let proposalParent{return try proposalParent.wordProposal(for:key,compute:compute)}
        guard enabled else{return try compute()}
        if let found=proposals[key] {
            proposalHits+=1
            switch found {case .rejected:return nil;case .accepted(let value):return value}
        }
        proposalMisses+=1
        let value=try compute(),bytes=value.map {$0.image.bytesPerRow*$0.image.height} ?? 0
        guard bytes<=proposalBudget else{return value}
        while !proposalOrder.isEmpty && (proposalBytes+bytes>proposalBudget || proposalOrder.count>=512) {
            let oldest=proposalOrder.removeFirst()
            if case .accepted(let removed)?=proposals.removeValue(forKey:oldest) {
                proposalBytes-=removed.image.bytesPerRow*removed.image.height
            }
        }
        proposalOrder.append(key);proposalBytes+=bytes
        proposals[key]=value.map {Proposal.accepted($0)} ?? .rejected
        return value
    }
    func report(for key:Data)->[String:Any]? {
        guard enabled else{return nil}
        if let report=reports[key] {hits+=1;return report}
        misses+=1;return nil
    }
    func store(_ report:[String:Any],for key:Data) {
        guard enabled else{return}
        if reports[key]==nil {
            if order.count>=128 {reports.removeValue(forKey:order.removeFirst())}
            order.append(key)
        }
        reports[key]=report
    }
}
