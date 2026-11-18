import Foundation
import CryptoKit

/// Independent physical source observations. Never a learned input or G.Refinement.
@available(iOS 18.0, *)
enum NativeOCRSourceOwnedRailGeometry {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias Kernel = NativeOCRSourceOwnedRailPartition
    static let environmentKey = "AIDOKU_OCR_SOURCE_OWNED_RAIL"
    static let schema = "native-source-owned-rail-v1"
    // Replaced only with the authoritative Agent4 frozen native codec receipt.
    static let nativeReceiptABI = "native-sorted-json-fullseed-subset-byte-receipt-v1"
    static var enabled: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }
    enum Failure: Error { case invalidFrame, sourceIndexOverflow, invalidNamespaceReservation }
    struct LaneProof: Codable, Sendable {
        let originalArrayIndex: Int
        let laneOrdinal: Int
        let sourceObservationID: String
        let parentOwnerID: String
        let fullOriginalSeedSHA256: String
        let sourceCellSubsetSHA256: String
        let fullOriginalSeedEncodedBytes: Data
        let sourceCellSubsetEncodedBytes: Data
        let componentCellSubsets: [Kernel.Subset]
        let sourceOwnedCells: Int
        let fullOriginalEvidence: NativeOCRDetectorSeedEvidence
        let fullOriginalEvidenceUnchanged: Bool
        let record: G.Record
        var emitted = false
    }
    struct ParentDecision: Codable, Sendable {
        let originalArrayIndex: Int
        let reason: String?
        let computedLaneObservations: Int
        let admittedRecords: Int
        let diagnostics: [String: Double]
    }
    struct Report: Codable, Sendable {
        let schema: String
        let enabled: Bool
        let requestID: String
        let kernelABI: String
        let sourceRGBABI: String
        let nativeReceiptABI: String
        let canonicalRGBAVisibleSHA256: String?
        let rawOriginals: Int
        let reservedMaximumSourceIndex: Int
        let reservedTailSlots: Int
        let computedPartitions: Int
        let computedLaneObservations: Int
        let admittedCount: Int
        let decisions: [ParentDecision]
        var lanes: [LaneProof]
        var emittedCount = 0
        var notFoundAfterEmit: [G.Record] = []
        var finalized = false
        var finalIndividualCount: Int? = nil
    }
    struct Production: Sendable {
        let records: [G.Record]
        let report: Report
        func finalized(actualOutput: [G.Individual]) -> Report {
            let present = Set(actualOutput.flatMap(\.provenance).map(token))
            var result = report
            for i in result.lanes.indices { result.lanes[i].emitted = present.contains(token(result.lanes[i].record)) }
            result.emittedCount = result.lanes.filter(\.emitted).count
            result.notFoundAfterEmit = records.filter { !present.contains(token($0)) }
            result.finalized = true; result.finalIndividualCount = actualOutput.count
            return result
        }
    }
    private struct Token: Hashable { let request: String; let index: Int; let alternative: String; let polygon: [G.Point] }
    private static func token(_ record: G.Record) -> Token {
        .init(request:record.requestID,index:record.sourceIndex,alternative:record.alternativeID,polygon:record.polygon)
    }
    /// Pass complete CURRENT originals; IDs are raw array positions, never seed.parentBoxIndex.
    /// reservedTailSlots conservatively protects the full CNN slot budget above all computed IDs.
    static func produce(requestID: String, frame: NativeOCRRGBAFrame, originals: [Kernel.Original],
                        reservedSourceIndices: [Int] = [], reservedRecords: [G.Record] = [], reservedTailSlots: Int = 0,
                        enabledOverride: Bool? = nil) throws -> Production {
        guard enabledOverride ?? enabled else { return .init(records:[],report:.init(schema:schema,enabled:false,requestID:requestID,
            kernelABI:Kernel.abi,sourceRGBABI:Kernel.canonicalRGBABI,nativeReceiptABI:nativeReceiptABI,
            canonicalRGBAVisibleSHA256:nil,rawOriginals:originals.count,reservedMaximumSourceIndex:-1,reservedTailSlots:0,
            computedPartitions:0,computedLaneObservations:0,admittedCount:0,decisions:[],lanes:[])) }
        guard !requestID.isEmpty,frame.width > 0,frame.height > 0,frame.width <= Int.max/4,
              frame.bytesPerRow >= frame.width*4,frame.bytesPerRow <= Int.max/frame.height,
              frame.bytes.count >= frame.bytesPerRow*frame.height else { throw Failure.invalidFrame }
        guard reservedTailSlots >= 0 else { throw Failure.invalidNamespaceReservation }
        let recordIDs = reservedRecords.flatMap { [$0.sourceIndex,$0.sourceParent] + Array($0.sourceMembers) + ($0.originalDetectorIndex.map{[$0]} ?? []) }
        let maximum = max((reservedSourceIndices + recordIDs).filter{$0>=0}.max() ?? -1, originals.count-1)
        let afterTail = maximum.addingReportingOverflow(reservedTailSlots)
        let start = afterTail.partialValue.addingReportingOverflow(1)
        let budget = originals.count.multipliedReportingOverflow(by:2)
        let end = afterTail.partialValue.addingReportingOverflow(budget.partialValue)
        guard !afterTail.overflow,!start.overflow,!budget.overflow,!end.overflow else { throw Failure.sourceIndexOverflow }
        let source = Kernel.Frame(width:frame.width,height:frame.height,bytesPerRow:frame.bytesPerRow,rgba:frame.bytes)
        var records: [G.Record] = [],lanes: [LaneProof] = [],decisions: [ParentDecision] = [],partitions = 0,computed = 0
        var ownerCounts: [String: Int] = [:]
        for original in originals { if let seed = original.detectorSeedEvidence { ownerCounts[seed.ownerID,default:0] += 1 } }
        for (index,original) in originals.enumerated() {
            guard let seed = original.detectorSeedEvidence,!seed.ownerID.isEmpty,ownerCounts[seed.ownerID] == 1 else {
                decisions.append(.init(originalArrayIndex:index,reason:"missing-or-nonunique-actual-ownerID",computedLaneObservations:0,admittedRecords:0,diagnostics:[:]))
                continue
            }
            let result = try Kernel.partition(frame:source,original:original)
            computed += result.lanes.count
            var added = 0,reason = result.reason
            if !result.lanes.isEmpty {
                if result.lanes.count == 2,let seed = original.detectorSeedEvidence,
                   result.lanes.allSatisfy({ $0.fullOriginalEvidence == seed && $0.parentOwnerID == seed.ownerID &&
                       $0.sourceOwnedCells > 0 && !$0.componentCellSubsets.isEmpty && valid($0.polygon,frame:frame) &&
                       digest($0.fullOriginalSeedEncodedBytes) == $0.fullOriginalSeedSHA256 &&
                       digest($0.sourceCellSubsetEncodedBytes) == $0.sourceCellSubsetSHA256 }) {
                    partitions += 1
                    for (laneOrdinal,lane) in result.lanes.enumerated() {
                        let record = G.Record(requestID:requestID,sourceIndex:start.partialValue+index*2+laneOrdinal,
                            sourceParent:index,sourceMembers:[index],
                            alternativeID:"source-owned-rail/\(index)/\(lane.sourceCellSubsetSHA256)",origin:.corrected,
                            originalDetectorIndex:index,polygon:lane.polygon.map{.init(x:$0[0],y:$0[1])})
                        records.append(record);added += 1
                        lanes.append(.init(originalArrayIndex:index,laneOrdinal:laneOrdinal,
                            sourceObservationID:lane.sourceObservationID,parentOwnerID:lane.parentOwnerID,
                            fullOriginalSeedSHA256:lane.fullOriginalSeedSHA256,sourceCellSubsetSHA256:lane.sourceCellSubsetSHA256,
                            fullOriginalSeedEncodedBytes:lane.fullOriginalSeedEncodedBytes,
                            sourceCellSubsetEncodedBytes:lane.sourceCellSubsetEncodedBytes,
                            componentCellSubsets:lane.componentCellSubsets,sourceOwnedCells:lane.sourceOwnedCells,
                            fullOriginalEvidence:lane.fullOriginalEvidence,fullOriginalEvidenceUnchanged:true,record:record))
                    }
                } else { reason = "invalid-two-lane-current-source-proof" }
            }
            decisions.append(.init(originalArrayIndex:index,reason:reason,computedLaneObservations:result.lanes.count,
                admittedRecords:added,diagnostics:result.diagnostics))
        }
        var hash = SHA256()
        for y in 0..<frame.height { hash.update(data:Data(frame.bytes[(y*frame.bytesPerRow)..<(y*frame.bytesPerRow+frame.width*4)])) }
        let frameHash = hash.finalize().map{String(format:"%02x",$0)}.joined()
        return .init(records:records,report:.init(schema:schema,enabled:true,requestID:requestID,
            kernelABI:Kernel.abi,sourceRGBABI:Kernel.canonicalRGBABI,nativeReceiptABI:nativeReceiptABI,
            canonicalRGBAVisibleSHA256:frameHash,rawOriginals:originals.count,reservedMaximumSourceIndex:maximum,
            reservedTailSlots:reservedTailSlots,computedPartitions:partitions,computedLaneObservations:computed,
            admittedCount:records.count,decisions:decisions,lanes:lanes))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    private static func valid(_ q: [[Double]],frame: NativeOCRRGBAFrame) -> Bool {
        guard q.count == 4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite) && $0[0]>=0 && $0[1]>=0 && $0[0]<=Double(frame.width) && $0[1]<=Double(frame.height)}) else{return false}
        let t=(0..<4).map{i -> Double in let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4];return (b[0]-a[0])*(c[1]-b[1])-(b[1]-a[1])*(c[0]-b[0])}
        return t.allSatisfy{$0>0} || t.allSatisfy{$0<0}
    }
}
