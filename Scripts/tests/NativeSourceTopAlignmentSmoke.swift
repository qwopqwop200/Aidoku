// Maintained native smoke fixtures; all implementation under test comes from MAIN.
// No datasets, OCR, translation service, network, or experimental implementation oracle.
import CoreGraphics
import Foundation

@main struct NativeSourceTopAlignmentSmoke {
    static func main() async throws {
        typealias R = NativeTranslationRenderer
        typealias A = NativeWidthFinalArtifactAdmission
        var alignmentChecks = 0, transactionChecks = 0
        func check(_ condition: Bool, _ name: String, transaction: Bool = false) {
            precondition(condition, name)
            if transaction { transactionChecks += 1 } else { alignmentChecks += 1 }
        }
        let source: [CGFloat] = [20, 21.5, 22], body: [CGFloat] = [40, 31.5, 52]
        let natural: [CGFloat] = [6, 8, 10]
        let clearance = R.sourceTopSharedClearance(sourceTops: source, bodyTops: body, naturalClearances: natural, band: 6)!
        check(clearance == 8, "natural margin, not incumbent minimum10")
        let target = source.map { $0 + clearance }
        for i in source.indices { for j in source.indices {
            check(target[i] - target[j] == source[i] - source[j], "preserve source stagger")
        } }
        for order in [[0,1,2], [2,1,0], [1,0,2], [2,0,1], [1,2,0], [0,2,1]] {
            check(R.sourceTopSharedClearance(sourceTops: order.map { source[$0] }, bodyTops: order.map { body[$0] },
                naturalClearances: order.map { natural[$0] }, band: 6) == clearance, "all group orders")
        }
        check(R.sourceTopSharedClearance(sourceTops: [0,5,10], bodyTops: [30,25,40], naturalClearances: [2,2,2], band: 6) == nil,
            "transitive chain rejected")
        check(R.sourceTopSharedClearance(sourceTops: [0,1], bodyTops: [.nan,10], naturalClearances: [2,2], band: 6) == nil,
            "unknown body not filled")
        check(R.sourceTopSharedClearance(sourceTops: [0], bodyTops: [10], naturalClearances: [2], band: 6) == nil &&
            R.sourceTopSharedClearance(sourceTops: [0,1], bodyTops: [1,11], naturalClearances: [6,8], band: 6) == 1,
            "singleton rejected and incumbent only no-farther cap")
        var payload: [String: Any] = ["id": "a", "text": "Test", "x": 10, "y": 10, "width": 40, "height": 80,
            "fontSize": 8, "lineHeight": 12, "paddingTop": 2, "paddingLeft": 2, "paddingRight": 2, "paddingBottom": 2,
            "sourceTextOnly": false, "sourceVertical": true, "sourceBounds": [0.07,0.09,0.26,0.72], "sourceFrame": [0,0,150,110]]
        func item(_ p: [String: Any]) throws -> NativeTranslationLayoutItem {
            try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: p))
        }
        check(R.sourceTopIdentityEligible(try item(payload)), "ordinary caption identity")
        let interior: [String: Any] = ["rect": [0.1,0.1,0.2,0.4], "center": [0.2,0.3], "spans": [], "contourVerified": true]
        payload["balloonInterior"] = interior
        check(!R.sourceTopIdentityEligible(try item(payload)), "known balloon excluded")
        payload.removeValue(forKey: "balloonInterior")
        payload["balloonUnit"] = ["members": ["a","b"], "order": 0, "interior": interior]
        check(!R.sourceTopIdentityEligible(try item(payload)), "separate meaning unit excluded")
        payload.removeValue(forKey: "balloonUnit")
        for peer in [false, true] {
            var work = 1_000_000
            let grid = R.TextDomainGrid(bounds: CGRect(x: 0,y: 0,width: 20,height: 20), width: 20,height: 20,pdfDeviceScale: 1.75)
            let certificate = try R.certifyTextDomainTiled(grid: grid, remainingWork: &work, maximumScratchBytes: 1_000_000,
                requiresPointwiseAlphaSafety: true, evidence: { _, tile in
                    let alpha = try tile.alpha { c in
                        if peer { c.setFillColor(CGColor(gray: 1,alpha: 1)); c.fill(CGRect(x: 10.4,y: 8,width: 0.1,height: 2)) }
                    }
                    return (0..<tile.rowCount).map { row in
                        let range = (row + tile.halo) * 20..<(row + tile.halo + 1) * 20
                        let full = [UInt8](repeating: 255,count: 20), empty = [UInt8](repeating: 0,count: 20)
                        return R.TextDomainEvidenceRow(observedSafeAlpha: full,modelSafeAlpha: empty,supportKnown: full,
                            protectionAlpha: empty,protectionKnown: full,peerUnionAlpha: Array(alpha[range]),peerKnown: full,ownBaselineAlpha: empty)
                    }
                }, paintRaw: { c,_ in c.setFillColor(CGColor(gray: 1,alpha: 1)); c.fill(CGRect(x: 10,y: 8,width: 2,height: 2)) },
                paintCandidate: { c,_ in c.setFillColor(CGColor(gray: 1,alpha: 1)); c.fill(CGRect(x: 10,y: 8,width: 2,height: 2)) })
            check(peer ? certificate.verdict != .observedPass : certificate.verdict == .observedPass, "actual tiny future-peer alpha")
        }
        precondition(alignmentChecks == 24)

        let bounds = CGRect(x: 0,y: 0,width: 150,height: 110)
        var cards: [R.Card] = []
        for (id, x) in [("a",10),("b",80)] {
            payload["id"] = id; payload["x"] = x
            let i = try item(payload)
            let style = NativeTranslationTypography.Style(fontScript: "latin",fontSize: 8,lineHeight: 12)
            var card = R.Card(item: i,typography: NativeTranslationTypography.layout(text: i.text,in: i.contentRect.size,style: style),
                style: style,drawsPanel: true,background: CGColor(gray: 1,alpha: 1),usesFallbackVeil: false,
                lightSurface: true,heavyStrokeWidth: 0,finalFontSize: 8)
            card.sourceBackgroundKind = "solid-text-box"; card.sourcePlateOwnerRect = i.rect
            cards.append(card)
        }
        let layout = NativeTranslationLayout(imageSize: bounds.size,sourceRect: bounds,viewport: bounds.size,items: cards.map(\.item))
        let settings = IPhoneOverlaySettings(visible: true,mode: .translateOnly,colorMode: .white,opacity: 1,
            textPlacement: .replace,subtitlePosition: .bottom,subtitleMaxLines: 3,subtitleContextSentences: 0)
        let plan = R.PreparedRender(inputLayout: layout,layout: layout,image: nil,source: nil,restoration: .init(),cards: cards,
            glossCards: [],gloss: .init(),settings: settings,bounds: bounds,pixels: bounds.size,scale: 1,composeSource: false,
            capturePDF: true,pdfDeviceScale: 1,sourcePatches: [],sourcePieces: [],limitations: [],diagnosticData: nil)
        var first = cards
        first[0].textShift.y -= 4
        for i in first.indices { first[i].harmonyRecord["widthRequiresRetainedArtifact"] = true }
        var second = first
        second[0].textShift.y -= 4; second[1].textShift.y -= 4
        func session(allowance: Int = 8) -> A { A(plan: plan,keptOwners: [],groupBudget: .init(ownerAllowance: allowance)) }
        func seed(_ s: A) {
            precondition(s.admission(before: cards,after: first,ids: ["a"]) == true)
        }
        let failed = session(); seed(failed)
        let priorPDF = failed.accepted!.data, priorDocuments = try JSONSerialization.data(withJSONObject: failed.documentReceipts,options: [.sortedKeys])
        let failResult = failed.admitGroup(ids: ["a","b"]) { id, budget in
            if id == "b" { return false }
            return try failed.certify(plan: plan,before: first,after: second,ids: [id],keptOwners: [],budget: &budget)
        }
        check(failResult == false && failed.accepted!.data == priorPDF, "second-owner failure rolls back receipt",transaction: true)
        check(try JSONSerialization.data(withJSONObject: failed.documentReceipts,options: [.sortedKeys]) == priorDocuments,
            "failure rolls back receipt witnesses",transaction: true)
        check(failed.groupBudget.remainingOwners == 6 && failed.groupBudget.resources.documentCaptures < 96 * 8,
            "failed work and aggregate slots remain charged",transaction: true)
        let unknown = failed.admitGroup(ids: ["a","b"]) { _,_ in nil }
        check(unknown == nil && failed.accepted!.data == priorPDF && failed.groupBudget.remainingOwners == 4,
            "unknown remains unknown and rolls back",transaction: true)
        enum ProbeFailure: Error { case expected }
        let error = failed.admitGroup(ids: ["a","b"]) { _,_ in throw ProbeFailure.expected }
        check(error == nil && failed.accepted!.data == priorPDF && failed.groupBudget.remainingOwners == 2,
            "error rolls back without quota refund",transaction: true)
        let bounded = session(allowance: 2)
        check(bounded.admission(before: cards,after: second,ids: ["a","b"]) == true, "real group all owner PDFs pass",transaction: true)
        let acceptedPDF = bounded.accepted!.data
        let resources = bounded.groupBudget.resources
        var calls = 0
        let denied = bounded.admitGroup(ids: ["a","b"]) { _,_ in calls += 1; return true }
        check(denied == nil && calls == 0 && bounded.accepted!.data == acceptedPDF,
            "next group cannot reset cumulative page allowance",transaction: true)
        check(bounded.groupBudget.resources.documentCaptures == resources.documentCaptures &&
            bounded.groupBudget.resources.deviceSamples == resources.deviceSamples &&
            bounded.groupBudget.resources.comparisonSamples == resources.comparisonSamples,
            "denial does not fabricate measurements",transaction: true)
        check(resources.maximumLiveManagedBytes == A.Budget().maximumLiveManagedBytes && resources.maximumPixels == A.Budget().maximumPixels,
            "old live-byte and pixel ceilings unchanged",transaction: true)
        let exhausted = A(plan: plan,keptOwners: [],groupBudget: .init(ownerAllowance: 0))
        check(exhausted.admission(before: cards,after: second,ids: ["a","b"]) == nil && exhausted.accepted == nil,
            "zero page allowance unknown, never measured false/pass",transaction: true)
        let cancelled = session(); seed(cancelled)
        let cancelResult = cancelled.admitGroup(ids: ["a","b"]) { id,budget in
            if id == "b" { throw CancellationError() }
            return try cancelled.certify(plan: plan,before: first,after: second,ids: [id],keptOwners: [],budget: &budget)
        }
        check(cancelResult == nil && cancelled.accepted == nil && cancelled.documentReceipts.isEmpty,
            "mid-group cancellation cannot resurrect incumbent or partial receipt",transaction: true)
        check(cancelled.admission(before: cards,after: first,ids: ["a"]) == nil,
            "cancelled session cannot resume admission",transaction: true)
        do { _ = try cancelled.publishOwned(diagnosticData: nil); preconditionFailure("cancelled publication") }
        catch is CancellationError { check(true,"cancelled publication throws",transaction: true) }
        let incoming = session(); seed(incoming)
        let incomingTask = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return incoming.admission(before: cards,after: second,ids: ["a","b"]) == nil
        }
        let incomingResult = await incomingTask.value
        check(incomingResult && incoming.accepted == nil && incoming.groupBudget.remainingOwners == 8,
            "already-cancelled task invalidates without spending a new group",transaction: true)
        let sealed = try bounded.publishOwned(diagnosticData: nil)
        check(sealed?.retainedWidthArtifact?.data == acceptedPDF && acceptedPDF != nil,
            "publication retains exact admitted document",transaction: true)
        print("{\"alignmentControls\":\(alignmentChecks),\"transactionControls\":\(transactionChecks),\"passed\":true}")
    }
}
