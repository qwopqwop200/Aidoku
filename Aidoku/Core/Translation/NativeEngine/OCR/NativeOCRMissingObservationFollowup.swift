import Foundation
import CoreGraphics

/// Post-output capture only. Never calls Bank.observe, changes its caches,
/// associates new private owners, manufactures a Measurement, or grants admission.
@available(iOS 18.0, *)
enum NativeOCRMissingObservationFollowup {
    typealias F = NativeOCRSourceLocalJoint369
    typealias B = NativeOCRSourceAuthenticatedBodyEvidence
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    typealias K = NativeOCRSharedBoundary396
    typealias Graph = NativeOCRSourceLocalJoint369Capture.FinalGraph

    struct Enrichment {
        // All genuine canonical metadata survive, including non-measured sources.
        let measurements: [Int:M]
        let unavailable: [Int:String]
        let records: [[String:Any]]
    }
    struct Plan {
        let window: B.Window
        let queryQuad: [CGPoint]
        let receipt: [String:Any]
    }
    struct Capture {
        let measurement: M?
        let measurements: [Int:M]
        let peers: F.PeerEvidence?
        let live: F.LiveObservation?
        // Missing native body is nil, not an all-zero negative foreground mask.
        // This separate source-only family may nominate enclosing geometry only.
        let alternate: K.Output?
        let records: [[String:Any]]
        let unavailableReason: String?
    }

    static func enrich(canonical: [Int:M], width: Int, height: Int,
                       genuineRecapture: (Int,M) -> M?) -> Enrichment {
        var view = canonical, unavailable: [Int:String] = [:], records: [[String:Any]] = []
        for index in canonical.keys.sorted() {
            let old = canonical[index]!
            if NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(old,width:width,height:height) {
                records.append(["sourceIndex":index,"status":"reused-genuine-native-private-observation"])
                continue
            }
            guard let fresh = genuineRecapture(index,old) else {
                unavailable[index] = "genuine-context-recapture-returned-nil"
                records.append(["sourceIndex":index,"status":unavailable[index]!,"canonicalMetadataRetained":true])
                continue
            }
            let different = NativeOCRSourceLocalJoint369Capture.metadataDifferences392(old,fresh)
            guard different.isEmpty else {
                unavailable[index] = "genuine-recapture-canonical-metadata-mismatch"
                records.append(["sourceIndex":index,"status":unavailable[index]!,"differentFields":different,
                    "canonicalStatus":old.status,"freshStatus":fresh.status,"canonicalMetadataRetained":true])
                continue
            }
            guard NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(fresh,width:width,height:height) else {
                unavailable[index] = "genuine-private-evidence-still-unavailable"
                records.append(["sourceIndex":index,"status":unavailable[index]!,"nativeMeasurementStatus":fresh.status,
                    "retainedOriginalFootprintAvailable":fresh.privateObservation?.footprint != nil,
                    "canonicalMetadataRetained":true,"privateObservationFabricated":false])
                continue
            }
            var enhanced = old
            enhanced.privateObservation = fresh.privateObservation
            view[index] = enhanced
            records.append(["sourceIndex":index,"status":"genuine-private-only-enrichment",
                "ordinaryMetadataExact":true,"cacheOrOwnershipWritten":false])
        }
        return Enrichment(measurements:view,unavailable:unavailable,records:records)
    }

    /// One actual-current-prior window covering EVERY member's original source
    /// basis probe. The query rectangle is a read budget, never foreground.
    /// No smaller window is silently substituted on budget or frame failure.
    static func plan(actualPrior: [CGPoint], sources: [M], frameSize: B.FrameSize) -> Plan? {
        guard F.valid(actualPrior), !sources.isEmpty, sources.count <= 64,
              frameSize.width > 0, frameSize.height > 0,
              actualPrior.allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                  $0.x <= CGFloat(frameSize.width) && $0.y <= CGFloat(frameSize.height)}) else {return nil}
        var points = actualPrior
        for m in sources {
            let width = m.rect.width
            guard width.isFinite,width >= 3,[m.origin,m.normal,m.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  abs(hypot(m.normal.x,m.normal.y)-1) < 1e-6,
                  abs(hypot(m.along.x,m.along.y)-1) < 1e-6,
                  abs(m.normal.x*m.along.x+m.normal.y*m.along.y) < 1e-6 else {return nil}
            let pp = actualPrior.map(m.project)
            let n0 = pp.map(\.x).min()!-width,n1 = pp.map(\.x).max()!+width
            let a0 = pp.map(\.y).min()!-width,a1 = pp.map(\.y).max()!+width
            points += [CGPoint(x:n0,y:a0),CGPoint(x:n1,y:a0),CGPoint(x:n1,y:a1),CGPoint(x:n0,y:a1)].map(m.restore)
        }
        // Bound read extents, not four independently clamped oblique corners
        // which can collapse into an invalid quad at a real image boundary.
        let x0 = max(0,min(CGFloat(frameSize.width),points.map(\.x).min()!))
        let x1 = max(0,min(CGFloat(frameSize.width),points.map(\.x).max()!))
        let y0 = max(0,min(CGFloat(frameSize.height),points.map(\.y).min()!))
        let y1 = max(0,min(CGFloat(frameSize.height),points.map(\.y).max()!))
        guard x1 > x0,y1 > y0 else {return nil}
        let quad = [CGPoint(x:x0,y:y0),CGPoint(x:x1,y:y0),CGPoint(x:x1,y:y1),CGPoint(x:x0,y:y1)]
        guard let window = B.Window.make(sourceQuads:[actualPrior,quad],frameSize:frameSize),
              window.width > 2,window.height > 2,window.width <= 600_000/window.height else {return nil}
        return Plan(window:window,queryQuad:quad,receipt:["actualPrior":actualPrior.map{[Double($0.x),Double($0.y)]},
            "memberCount":sources.count,"nativeSourceWidths":sources.map{Double($0.rect.width)},
            "window":[window.left,window.top,window.width,window.height],
            "memberNativeBasisProbeUnionCovered":true,"queryRectangleIsForeground":false,
            "sourceWidthReplacedByCurrentPriorWidth":false,"candidatePaddingChanged":false])
    }

    static func capture(root: Int, graph: Graph, canonical: [Int:M],
                        originals: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
                        originalFrame: NativeOCRRGBAFrame,
                        genuineRecapture: (Int,M) -> M?, capsForSource: (M) -> [CGPoint]?,
                        originalOwnedSupport: (Int) -> [CGPoint]) -> Capture {
        var records: [[String:Any]] = []
        var view = canonical
        func failure(_ why: String, peers: F.PeerEvidence? = nil, alternate: K.Output? = nil) -> Capture {
            records.append(["family":"missing-observation-followup","sourceIndex":root,"status":why,
                "geometryProposed":alternate?.proposals.isEmpty == false,"nativeAdmissionPassed":false,
                "privateObservationFabricated":false,"canonicalMetadataRetained":true])
            return Capture(measurement:view[root],measurements:view,peers:peers,live:nil,
                           alternate:alternate,records:records,unavailableReason:why)
        }
        guard let prior = graph.prior(root),let oldRoot = canonical[root] else {
            return failure("actual-current-graph-prior-or-canonical-metadata-absent")
        }
        let indices = [root]+prior.consumedIndices
        guard Set(indices).count == indices.count,indices.count <= 64,
              indices.allSatisfy({canonical[$0]?.index == $0}) else {
            return failure("actual-root-member-canonical-metadata-absent")
        }
        let fw=originalFrame.width,fh=originalFrame.height,stride=originalFrame.bytesPerRow
        guard fw > 0,fh > 0,fw <= Int.max/4,stride >= fw*4,fh <= Int.max/stride,
              originalFrame.bytes.count >= fh*stride else {return failure("invalid-original-frame")}
        // Only incomplete required members are recaptured here; peer metadata is
        // retained and unknown peers stay unknown in the unchanged native gates.
        let required = Dictionary(uniqueKeysWithValues:indices.map{($0,canonical[$0]!)})
        let enriched = enrich(canonical:required,width:fw,height:fh,genuineRecapture:genuineRecapture)
        for (i,m) in enriched.measurements {view[i]=m}
        records += enriched.records
        let size = B.FrameSize(width:fw,height:fh)
        guard let plan = plan(actualPrior:prior.polygon,sources:indices.map{view[$0]!},frameSize:size) else {
            return failure("current-prior-native-basis-probe-uncovered-or-over-budget")
        }
        records.append(plan.receipt)
        let window=plan.window,roi=CGRect(x:CGFloat(window.left),y:CGFloat(window.top),
            width:CGFloat(window.width),height:CGFloat(window.height))
        let certification = NativeOCRSourceLocalJoint369Capture.localPeerEvidence(root:root,graph:graph,
            measurements:view,originals:originals,frameSize:size,probeROI:roi,layout:layout)
        records.append(certification.record)
        guard let peers=certification.evidence else {return failure("actual-local-peer-certification-unavailable")}
        let scopes=(layout?.primitives ?? []).filter{$0.sourceBounds.intersects(roi)}.map{
            F.Scope(rect:$0.sourceBounds,semanticClass:$0.semanticClass.rawValue,confidence:Double($0.confidence))
        }
        if enriched.unavailable.isEmpty {
            var prepared:[B.Prepared]=[],mandatory=prior.candidate?.supportPoints ?? []
            for i in indices {
                let m=view[i]!
                guard let caps=capsForSource(m),let p=B.prepare(m,inherited:prior.polygon,
                    frameSize:size,enabled:true,sharedWindow:window).prepared else {
                    return failure("actual-native-body-preparation-or-source-caps-unavailable",peers:peers)
                }
                prepared.append(p)
                mandatory += caps+originalOwnedSupport(i)+m.guardPoints+m.privateHull.map(m.restore)
            }
            guard window.width*window.height <= 3_000_000/indices.count,
                  let source=B.read(prepared[0],frameProvider:{originalFrame}) else {
                return failure("actual-native-body-read-budget-unavailable",peers:peers)
            }
            var bodies:[B.Evidence]=[]
            for p in prepared {
                let result=B.observe(p,source:source)
                guard let body=result.evidence,body.uniqueMaskPixels > 0 else {
                    return failure("genuine-native-body-observation-empty-or-unavailable",peers:peers)
                }
                bodies.append(body)
            }
            var peerBodies:[Int:B.Evidence]=[:],cost=indices.count*window.width*window.height
            for peer in peers.peers {
                guard let m=peer.measurement,NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(m,width:fw,height:fh),
                      cost+window.width*window.height <= 3_000_000 else {continue}
                cost += window.width*window.height
                guard let p=B.prepare(m,inherited:plan.queryQuad,frameSize:size,enabled:true,sharedWindow:window).prepared,
                      let body=B.observe(p,source:source).evidence else {continue}
                peerBodies[peer.sourceIndex]=body
            }
            let live=F.LiveObservation(window:window,rgba:source.rgba,sources:indices.map{view[$0]!},
                bodies:bodies,mandatory:mandatory,peerBodies:peerBodies,scopes:scopes)
            records.append(["family":"missing-observation-followup","sourceIndex":root,
                "status":"genuine-current-prior-live-recaptured","nativeBodyCount":bodies.count,
                "ordinaryMetadataExact":true,"nativeSourceWidthsUnchanged":true,
                "windowReadCount":1,"admissionGranted":false])
            return Capture(measurement:view[root],measurements:view,peers:peers,live:live,
                           alternate:nil,records:records,unavailableReason:nil)
        }
        // Genuine remeasurement failed. Do not install source-role components as
        // private measurements: route to the existing explicit nonexclusive observer.
        var bytes:[UInt8]=[];bytes.reserveCapacity(window.width*window.height*4)
        for y in window.top..<(window.top+window.height) {
            let offset=y*stride+window.left*4
            bytes.append(contentsOf:originalFrame.bytes[offset..<(offset+window.width*4)])
        }
        let rgba=K.RGBA(bytes:bytes,width:window.width,height:window.height,
                        bytesPerRow:window.width*4,origin:CGPoint(x:CGFloat(window.left),y:CGFloat(window.top)))
        var detectors:[K.Detector]=[],rf:[K.RF]=[]
        guard originals.count <= 4096 else {return failure("original-detector-inventory-budget-exceeded",peers:peers)}
        for (ordinal,box) in originals.enumerated() {
            guard F.valid(box.polygon),F.bounds(box.polygon).intersects(roi) else {continue}
            guard let packet=box.detectorSeedEvidence,packet.isValid,packet.parentBoxIndex == ordinal,
                  packet.sourceWidth == fw,packet.sourceHeight == fh else {continue}
            guard detectors.count < 64 else {return failure("local-original-detector-budget-exceeded",peers:peers)}
            let sx=CGFloat(fw)/CGFloat(packet.mapFullWidth),sy=CGFloat(fh)/CGFloat(packet.mapFullHeight)
            var runs:[[Int]]=[]
            for c in packet.components {for run in c.runs {
                if CGFloat(run.y+1)*sy <= roi.minY || CGFloat(run.y)*sy >= roi.maxY {continue}
                let lo=max(run.x,Int(floor(roi.minX/sx))),hi=min(run.x+run.count,Int(ceil(roi.maxX/sx)))
                if hi > lo {runs.append([run.y,lo,hi-lo])}
            }}
            guard let cells=K.PrivateRLE(width:packet.mapFullWidth,height:packet.mapFullHeight,
                scaleX:sx,scaleY:sy,runs:runs) else {return failure("invalid-original-detector-local-RLE",peers:peers)}
            detectors.append(.init(ordinal:ordinal,owner:packet.ownerID,nativeRoot:false,cells:cells))
        }
        for (query,p) in (layout?.primitives ?? []).enumerated()
            where p.sourceBounds.intersects(roi) && p.semanticClass.rawValue == 0 {
            guard rf.count < 160 else {return failure("local-RF-budget-exceeded",peers:peers)}
            let b=p.sourceBounds
            rf.append(.init(query:query,confidence:Double(p.confidence),bounds:[b.minX,b.minY,b.maxX,b.maxY]))
        }
        // [] is the existing observer's explicit missing-body representation, not
        // an asserted empty body. It never reads privateAt/nativeCellCenters.
        let e=K.Evidence(rgba:rgba,body:[],privateAt:{_ in false},nativeCellCenters:[],detectors:detectors,rf:rf)
        let alternate=NativeOCRRepair402MissingObservation.generate(actualOld:prior.polygon,
            basis:.init(origin:oldRoot.origin,normal:oldRoot.normal,along:oldRoot.along),
            nativeW:oldRoot.rect.width,evidence:e)
        records.append(["family":"missing-observation-followup","sourceIndex":root,
            "missingNativeSources":enriched.unavailable.keys.sorted(),"sourceOnlyReceipt":alternate.receipt,
            "rawSourceObservationOffers":alternate.proposals.map{p in
                ["key":p.suffix,"polygon":p.polygon.map{[Double($0.x),Double($0.y)]},
                 "sourceReceipt":p.receipt,"obligations":p.obligations,
                 "admissionGranted":false,"sourceRoleIsPrivateOwnership":false] as [String:Any]},
            "actualNativeBodyAvailable":false,"strictNativeGuardWaived":false,
            "originalDetectorPackets":detectors.count,"actualRFQueries":rf.count,
            "noObservationIsNegativePixelEvidence":false])
        return failure("source-role-observation-only-genuine-private-evidence-still-unavailable",peers:peers,alternate:alternate)
    }
}
