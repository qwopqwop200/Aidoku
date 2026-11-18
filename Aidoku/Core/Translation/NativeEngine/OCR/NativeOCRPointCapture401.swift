import Foundation
import CoreGraphics

extension NativeOCRPointObligation401 {
    struct MemberPoints {
        let sourceOrdinal:Int
        let actualExplicitCaps:[CGPoint]? // exact capsForSource result; nil never becomes complete-empty
        let originalOwnedSupport:[CGPoint]
        let measurementGuardPoints:[CGPoint]
        let restoredPrivateHull:[CGPoint]
        let nativeCellCenters:[CGPoint]
        let explicitlyProtectedMarks:[CGPoint] // only actual typed protected semantics, never DB geometry
    }
    /// Replaces ONLY flattening of point provenance at captureLive. It does not
    /// change any source measurement, graph, native footprint or candidate support.
    static func capture(actualOld:[CGPoint],members:[MemberPoints],priorConstructorUntypedSupport:[CGPoint],
                        sessions:[Int:SourceSession])throws->Observation {
        guard !members.isEmpty,members.count<=64,Set(members.map{$0.sourceOrdinal}).count==members.count else{throw Invalid(reason:"invalid-member-point-provenance")}
        var points:[Point]=[]
        func append(_ values:[CGPoint],_ source:Int,_ role:Role,_ provenance:String) {
            for p in values {points.append(.init(ordinal:points.count,sourceOrdinal:source,position:p,role:role,provenance:provenance))}
        }
        for m in members {
            append(m.actualExplicitCaps ?? [],m.sourceOrdinal,.explicitEndpointCap,"capsForSource(actualMeasurement)")
            append(m.explicitlyProtectedMarks,m.sourceOrdinal,.explicitProtectedMark,"actual-explicit-protected-semantics")
            append(m.originalOwnedSupport,m.sourceOrdinal,.originalOwnedUntypedSupport,"originalOwnedSupport(source)")
            append(m.measurementGuardPoints,m.sourceOrdinal,.measurementDBGuard,"Measurement.guardPoints: every owned DB center in polygon")
            append(m.restoredPrivateHull,m.sourceOrdinal,.privateHullVertex,"Measurement.privateHull.map(actualMeasurement.restore)")
            append(m.nativeCellCenters,m.sourceOrdinal,.nativeRLECell,"actual native full-footprint cell centers")
        }
        append(priorConstructorUntypedSupport,-1,.inheritedUntypedSupport,"prior.candidate.supportPoints: origin not typed; independently inspect all actual member source sessions")
        return try observe(actualOld:actualOld,points:points,sessions:sessions,
            explicitCapsComplete:members.allSatisfy{$0.actualExplicitCaps != nil})
    }
}
