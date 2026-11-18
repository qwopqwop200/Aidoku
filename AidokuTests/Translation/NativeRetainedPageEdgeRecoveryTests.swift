import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeRetainedPageEdgeRecoveryTests {
    typealias R = NativeRetainedPageEdgeRecovery
    private let page = CGRect(x: 0, y: 0, width: 120, height: 100)

    private func scene(touchingEdge: Bool = true) throws -> R.Tuple {
        let pixels = Array(repeating: UInt8(255), count: 10 * 10 * 4)
        let image = try NativeMandatoryDisplayStroke.image(pixels, width: 10, height: 10)
        let policy = NativeTextExpansionPolicy(allowedRectNormalized: [0, 0, 1, 1],
            candidates: [[0, 0, 1, 1]], maskCoverage: [1], backgroundRisk: [0],
            sourceFontPixels: 10, kind: "exterior", maskRectNormalized: nil, maskSpansNormalized: nil)
        let fills: [R.Primitive] = (0..<2).map { index in
            var fill = R.Primitive(image: image, frame: CGRect(x: 20 + index * 30, y: 89, width: 10, height: 10),
                fontOutputPixels: 10)
            fill.ownerID = "edge-\(index)"
            fill.hasFinalEffects = true
            fill.textExpansionPolicy = policy
            fill.placementDomain = { [page] in policy.allows($0, page: page) }
            fill.textPlacementGuide = .init(rectNormalized: [Double(20 + index * 30) / 120, 0.89, 10.0 / 120, 0.1],
                horizontal: .left, vertical: .top)
            fill.sourceClusterAlignment = .init(groupID: "coherent-edge", axis: .top, anchorNormalized: 0.89)
            return fill
        }
        var tuple = try NativeFinalTextPaintAdmission.place(fills, page: page)
        if touchingEdge {
            for index in tuple.fills.indices { tuple.fills[index].frame.origin.y += 1 }
        }
        return tuple
    }

    @Test func movesWholeExteriorCohortAndPreservesEveryRasterByte() throws {
        var before = try scene()
        let stateKey = NativeBalloonPlacement.RetainedState.auditKey
        for index in before.audit.indices {
            var state = try #require(before.audit[index][stateKey] as? [String: Any])
            state["provenance"] = "fixedOriginRevalidated"
            state["historicalStateExact"] = false
            state["sourceIdentity"] = "authenticated-edge-fixture"
            before.audit[index][stateKey] = state
        }
        let result = R.recover(before, page: page, boundaryGate: { _, _ in (true, ["evidenceAvailable": true]) })
        #expect(result.changedOwnerIDs == ["edge-0", "edge-1"])
        for index in before.fills.indices {
            let old = before.fills[index], new = result.tuple.fills[index]
            #expect(new.frame == old.frame.offsetBy(dx: 0, dy: -1))
            #expect(new.sourceClusterAlignment == old.sourceClusterAlignment)
            #expect(new.balloonPlacement == old.balloonPlacement)
            #expect(new.balloonTargetRelaxed == old.balloonTargetRelaxed)
            #expect(new.fontOutputPixels == old.fontOutputPixels)
            #expect(try NativeMandatoryDisplayStroke.rgba(new.image) == NativeMandatoryDisplayStroke.rgba(old.image))
            let state = try #require(result.tuple.audit[index][NativeBalloonPlacement.RetainedState.auditKey])
            #expect(try !NativeBalloonPlacement.RetainedState.decode(state, owner: old.ownerID!).requiresFixedOriginRevalidation)
            #expect(try NativeBalloonPlacement.RetainedState.decode(state, owner: old.ownerID!) ==
                NativeBalloonPlacement.RetainedState.decode(before.audit[index][stateKey]!, owner: old.ownerID!))
        }
        #expect(result.metadata["physicalContainmentMeasured"] as? Bool == false)
    }

    @Test func protectedMemberAndBoundaryVetoRetainWholeCohort() throws {
        let before = try scene()
        let protected = R.recover(before, page: page, protectedOwners: ["edge-1"])
        #expect(protected.changedOwnerIDs.isEmpty)
        #expect(protected.tuple.fills.map(\.frame) == before.fills.map(\.frame))
        let vetoed = R.recover(before, page: page, boundaryGate: { _, _ in (false, ["evidenceAvailable": true]) })
        #expect(vetoed.changedOwnerIDs.isEmpty)
        #expect(vetoed.tuple.fills.map(\.frame) == before.fills.map(\.frame))
        #expect(vetoed.metadata["nativeFixedOriginTransactionVerified"] as? Bool == false)
    }

    @Test func alreadyInsetPageIsAnExactNoop() throws {
        let before = try scene(touchingEdge: false)
        let result = R.recover(before, page: page)
        #expect(result.changedOwnerIDs.isEmpty)
        #expect(result.tuple.fills.map(\.frame) == before.fills.map(\.frame))
        for index in before.audit.indices {
            #expect(NSDictionary(dictionary: before.audit[index]).isEqual(to: result.tuple.audit[index]))
        }
    }
}
