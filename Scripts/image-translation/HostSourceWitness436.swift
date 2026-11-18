import Foundation
import CoreGraphics
import CryptoKit

/// Host-owned file exporter. App transports genuine immutable typed objects only.
@available(macOS 15.0, *)
enum HostSourceWitness436 {
    typealias C = NativeOCRSourceAdmissionWitness436
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
    }
    static func runs(_ cells: [Int], width: Int) -> [[Int]] {
        var out: [[Int]]=[]
        for i in cells.sorted() {
            let y=i/width,x=i%width
            if let last=out.last,last[0]==y,last[1]+last[2]==x { out[out.count-1][2] += 1 }
            else { out.append([y,x,1]) }
        }
        return out
    }
    static func gzip(_ data: Data, _ file: URL) throws -> [String: Any] {
        try data.write(to:file,options:.atomic)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/gzip")
        process.arguments=["-k","-n","-f",file.path];try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else { throw NSError(domain:"Witness436.gzip",code:1) }
        let gz=file.appendingPathExtension("gz")
        let verify=Process();verify.executableURL=URL(fileURLWithPath:"/usr/bin/gzip");verify.arguments=["-d","-c",gz.path]
        let pipe=Pipe();verify.standardOutput=pipe;try verify.run()
        let decoded=pipe.fileHandleForReading.readDataToEndOfFile();verify.waitUntilExit()
        guard verify.terminationStatus==0,decoded==data else { throw NSError(domain:"Witness436.roundtrip",code:2) }
        // User lossless policy: retire raw only AFTER exact decoded-byte parity.
        try FileManager.default.removeItem(at:file)
        return ["path":gz.path,"compression":"gzip","bytes":data.count,
            "uncompressedSHA256":hash(data),"gzipSHA256":hash(try Data(contentsOf:gz)),"decompressedBytesVerified":true]
    }
    static func components(_ packet:C.Packet, ordinal:Int) -> [[String:Any]] {
        let body=packet.live.bodies[ordinal],m=packet.live.sources[ordinal],r=packet.live.rgba
        let mask=body.sourceAuthenticatedContrastBodyMask,fp=body.actualFullFootprint
        var seen=[Bool](repeating:false,count:mask.count),result:[[String:Any]]=[]
        for seed in mask.indices where mask[seed] != 0 && !seen[seed] {
            var queue=[seed],cursor=0,owned=0;seen[seed]=true
            var minN=CGFloat.infinity,maxN = -CGFloat.infinity,minA=CGFloat.infinity,maxA = -CGFloat.infinity
            var low=[255,255,255],high=[0,0,0]
            while cursor<queue.count {
                let i=queue[cursor];cursor += 1
                let x=i%r.width,y=i/r.width,p=CGPoint(x:r.origin.x+CGFloat(x)+0.5,y:r.origin.y+CGFloat(y)+0.5)
                let z=m.project(p);minN=min(minN,z.x);maxN=max(maxN,z.x);minA=min(minA,z.y);maxA=max(maxA,z.y)
                if fp.contains(p) {owned += 1}
                let k=y*r.bytesPerRow+x*4
                for c in 0..<3 { low[c]=min(low[c],Int(r.bytes[k+c]));high[c]=max(high[c],Int(r.bytes[k+c])) }
                for yy in max(0,y-1)...min(r.height-1,y+1) {for xx in max(0,x-1)...min(r.width-1,x+1) {
                    let next=yy*r.width+xx
                    if mask[next] != 0 && !seen[next] {seen[next]=true;queue.append(next)}
                }}
            }
            result.append(["componentOrdinal":result.count,"actualGGPixels":queue.count,
                "actualOriginalNativeCellSupportedPixels":owned,"localPixelRuns":runs(queue,width:r.width),
                "normalBounds":[Double(minN),Double(maxN)],"alongBounds":[Double(minA),Double(maxA)],
                "normalSpanNativeWidths":Double((maxN-minN+1)/m.rect.width),
                "alongSpanNativeWidths":Double((maxA-minA+1)/m.rect.width),
                "RGBMin":low,"RGBMax":high,
                "sourcePositiveDoesNotProvePrimaryTextMembership":true,
                "mainlineMembership":"unqualified-observation-only"])
        }
        return result
    }
    final class Context: @unchecked Sendable {
        let directory:URL
        var perFrameCounts:[String:Int]=[:]
        var manifests:[[String:Any]]=[]
        var attempts:[[String:Any]]=[]
        let requestPages:[[String:Any]]
        init(directory:URL,requestPages:[[String:Any]]) {
            self.directory=directory.appendingPathComponent("capture-"+UUID().uuidString)
            self.requestPages=requestPages
        }
        func receive(_ packet:C.Packet) -> [String:Any] {
            var receipt:[String:Any]
            do {receipt=try autoreleasepool { try export(packet) }}
            catch {receipt=["status":"witness-export-unavailable","error":String(describing:error),
                "nativeAdmissionUnchanged":true,"ownershipChanged":false]}
            receipt["captureAttemptOrdinal"]=attempts.count
            receipt["sourceIndex"]=packet.measurement.index
            receipt["candidateCount"]=packet.candidateRecords.count
            if requestPages.count==1 {
                receipt["requestedPage"]=requestPages[0]["id"] as Any? ?? requestPages[0]["page"] as Any? ?? NSNull()
                receipt["requestedSourceImageSHA256"]=requestPages[0]["sourceSHA256"] as Any? ?? NSNull()
            }
            attempts.append(receipt)
            return receipt
        }
        func export(_ p:C.Packet) throws -> [String:Any] {
            let r=p.live.rgba
            guard r.width>2,r.height>2,r.width<=600_000/r.height,
                  !(r.width==p.frame.width && r.height==p.frame.height),
                  p.live.sources.count==p.live.bodies.count,
                  p.live.sources.map(\.index)==[p.measurement.index]+p.prior.consumedIndices,
                  p.graph.prior(p.measurement.index)?.polygon==p.prior.polygon,
                  p.candidateRecords.count<=8 else {throw NSError(domain:"Witness436.actualRootBinding",code:3)}
            guard r.origin.x>=0,r.origin.y>=0,r.origin.x.rounded()==r.origin.x,r.origin.y.rounded()==r.origin.y,
                  r.origin.x+CGFloat(r.width)<=CGFloat(p.frame.width),
                  r.origin.y+CGFloat(r.height)<=CGFloat(p.frame.height) else {throw NSError(domain:"Witness436.ROI",code:6)}
            for y in 0..<r.height {
                let f=(Int(r.origin.y)+y)*p.frame.bytesPerRow+Int(r.origin.x)*4,local=y*r.bytesPerRow
                guard p.frame.bytes[f..<(f+r.width*4)].elementsEqual(r.bytes[local..<(local+r.width*4)]) else {
                    throw NSError(domain:"Witness436.actualFrameRows",code:7)
                }
            }
            let frameHash=p.candidateRecords.compactMap { ($0["nativeOutcome"] as? [[String:Any]])?.first?["actualSourceRGBA_SHA256"] as? String }.first ?? HostSourceWitness436.hash(Data(p.frame.bytes))
            let count=perFrameCounts[frameHash,default:0]
            guard count<256 else {return ["status":"witness-root-budget-unavailable","budget":256,"nativeAdmissionUnchanged":true]}
            perFrameCounts[frameHash]=count+1
            let root=directory.appendingPathComponent(frameHash).appendingPathComponent("root-\(p.measurement.index)-\(count)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let capture=try HostSourceWitness436.gzip(Data(r.bytes),root.appendingPathComponent("actual-live.rgba"))
            var source:[String:Any]=["sourceIndex":p.measurement.index,"sourceFrameRGBA_SHA256":frameHash,
                "actualLocalRGBA":capture,"rgbaOrigin":[Double(r.origin.x),Double(r.origin.y)],
                "rgbaWidth":r.width,"rgbaHeight":r.height,"rgbaStride":r.bytesPerRow,
                "actualOld":p.prior.polygon.map{[Double($0.x),Double($0.y)]},
                "actualSourceIndices":p.live.sources.map(\.index),"actualCanonicalMeasurement":p.measurement.json,
                "noWholePageImageExported":true,"nativePermissionUnchanged":true]
            var members:[[String:Any]]=[]
            for ordinal in p.live.sources.indices {
                let m=p.live.sources[ordinal],body=p.live.bodies[ordinal],fp=body.actualFullFootprint
                guard body.sourceLocalRGBA.bytes==r.bytes,body.sourceLocalRGBA.origin==r.origin,
                      body.sourceLocalRGBA.width==r.width,body.sourceLocalRGBA.height==r.height,
                      body.prepared.inherited==p.prior.polygon else {throw NSError(domain:"Witness436.memberBinding",code:4)}
                members.append(["memberOrdinal":ordinal,"sourceIndex":m.index,"actualMeasurement":m.json,
                    "originalFullNativeFootprint":["width":fp.width,"height":fp.height,
                        "scaleX":Double(fp.scaleX),"scaleY":Double(fp.scaleY),"runs":HostSourceWitness436.runs(Array(fp.cells),width:fp.width)],
                    "actualGGBodyRuns":HostSourceWitness436.runs(body.sourceAuthenticatedContrastBodyMask.indices.filter{body.sourceAuthenticatedContrastBodyMask[$0] != 0},width:r.width),
                    "actualGGBodyPixelCount":body.uniqueMaskPixels,
                    "actualGGComponentsSourceBasis":HostSourceWitness436.components(p,ordinal:ordinal),
                    "bodyPositivityIsNotPrimaryTextMembership":true])
            }
            source["members"]=members
            // Genuine432 observation is auxiliary/nonexclusive; it never replaces m.
            let aux=AuxiliaryForwardQualifiedObservation432.observe(index:p.measurement.index,
                polygon:p.measurement.polygon,hasInk:p.measurement.hasInk,originals:p.originals,
                prepared:p.prepared,groups:p.groups,actualRFScopes:p.rfScopes,actualFrame:p.frame)
            var forward:[String:Any]=["status":aux.reason,"checkedOriginalCells":aux.checkedCells,
                "excludedForeignCells":aux.excludedForeignCells,"auxiliaryAvailable":aux.auxiliary != nil,
                "canonicalMeasurementReplaced":false,"originalOwnershipMutated":false,
                "derivedRecognitionEvidenceIsNotOriginalOwnedTruth":true]
            forward["genuineOriginalBaseline"]=aux.originalBaseline?.json as Any? ?? NSNull()
            forward["genuineSampledAuxiliary"]=aux.actualSampled?.json as Any? ?? NSNull()
            if let plan=aux.plan {
                forward["actualAllowedCells"]=["width":plan.mapWidth,"height":plan.mapHeight,
                    "runs":HostSourceWitness436.runs(Array(plan.allowedCells),width:plan.mapWidth)]
                forward["unchangedOriginalRolePackets"]=try plan.evidence.map{try HostSourceWitness436.json($0)}
            }
            source["genuine432"]=forward
            var roles408:SourceContrastRole408.Output?
            if let evidence=p.source?.evidence,let basis=p.source?.basis,
               evidence.rgba.bytes==r.bytes,evidence.rgba.origin==r.origin,
               evidence.rgba.width==r.width,evidence.rgba.height==r.height {
                roles408=SourceContrastRole408.assess(evidence:evidence,basis:basis,
                    nativeW:p.measurement.rect.width,seedMode:.originalNativeSupport)
                if let roles=roles408 {
                    source["actual408Roles"]=try HostSourceWitness436.gzip(Data(roles.roles),root.appendingPathComponent("actual-408.roles"))
                    source["actual408Receipt"]=roles.receipt
                    source["actual408Components"]=roles.components.map { c in
                        ["componentID":c.componentID,"actualPixelCount":c.actualPixelCount,
                         "nativeGGAnchorCount":c.nativeGGAnchorCount,"nativeModelSupportCount":c.nativeModelSupportCount,
                         "role":Int(c.role.rawValue),"closedAtCapture":c.closedAtCapture,
                         "outlinedRows":c.outlinedRows,"unoutlinedRows":c.unoutlinedRows,
                         "sampledPixelRolesOnly":c.sampledPixelRolesOnly] as [String:Any]
                    }
                    source["actual408Rows"]=roles.rows.map { row in
                        ["componentID":row.componentID,"along":Double(row.along),"kind":row.kind.rawValue,
                         "seed":row.seed,"actualLowFill":row.low.fill,"actualHighFill":row.high.fill,
                         "actualLowRim":row.low.rimOrAA,"actualHighRim":row.high.rimOrAA,
                         "actualLowOutside":row.low.outside,"actualHighOutside":row.high.outside] as [String:Any]
                    }
                }
                if let roles=p.source?.roles405 {
                    source["actual405Roles"]=try HostSourceWitness436.gzip(Data(roles.roles),root.appendingPathComponent("actual-405.roles"))
                    source["actual405Receipt"]=roles.receipt
                }
            } else {source["actual408Unavailable"]="genuine-source-factory-evidence-not-captured"}
            let terminalCache=NativeOCRLocalJointGGCache387(bodies:p.live.bodies)
            var candidates:[[String:Any]]=[]
            for original in p.candidateRecords {
                guard let key=original["key"] as? String,
                      let candidate=p.proposals.first(where:{$0.key==key}) else {continue}
                let q=candidate.polygon
                var row:[String:Any]=["key":key,"polygon":q.map{[Double($0.x),Double($0.y)]},
                    "originalNativeCandidateRecord":original,"diagnosticOnlyNotAdmission":true,
                    "sourcePositiveNotNecessarilyMainlineMember":true]
                if let observed=p.points,observed.actualOld==p.prior.polygon {
                    let lost=observed.points.filter{!NativeOCRPointObligation401.contains(q,$0.point.position)}
                    row["allLostTypedPoints"]=lost.map{$0.receipt()}
                    row["allLostTypedPointsComplete"]=true
                    row["explicitCapsComplete"]=observed.explicitCapsComplete
                    row["typedMustPreserveLostCount"]=lost.filter(\.mustPreserve).count
                    if let roles=roles408 {
                        row["actual408LostPointRoles"]=lost.map { point -> [String:Any] in
                            let x=Int(floor(point.point.position.x-r.origin.x)),y=Int(floor(point.point.position.y-r.origin.y))
                            let i=y*r.width+x
                            return ["pointOrdinal":point.point.ordinal,"sourceOrdinal":point.point.sourceOrdinal,
                                "pointRole":point.point.role.rawValue,"positiveProofReason":point.pixel.reason,
                                "explicitObservedMark":point.point.role == .explicitProtectedMark,
                                "actual408Role":x>=0 && x<r.width && y>=0 && y<r.height ? Int(roles.roles[i]):-1,
                                "membershipQualifiedByExport":false]
                        }
                    }
                } else {row["allLostTypedPointsComplete"]=false;row["typedPointsUnavailable"]="original425-point-capture-not-returned"}
                var losses:[[String:Any]]=[]
                for ordinal in p.live.sources.indices {
                    let m=p.live.sources[ordinal],b=p.live.bodies[ordinal],pr=b.prepared
                    let normal=p.prior.polygon.map{m.project($0).x}
                    let whole=NativeOCRResidualTurningStrokeGuardHistogram.assess(old:p.prior.polygon,new:q,
                        rgba:r,authenticatedPalettes:pr.actualPalettes,
                        privateRGBSampleCount:m.privateObservation?.privateRGBSamples ?? 0,
                        frameOrigin:m.origin,normal:m.normal,along:m.along,sourceWidth:Double(m.rect.width),
                        inheritedNormalBounds:normal.min()!...normal.max()!)
                    let dense=NativeOCRDensePrivateFootprintGuard.assess(old:p.prior.polygon,proposed:q,
                        rgba:.init(bytes:r.bytes,width:r.width,height:r.height,stride:r.bytesPerRow,origin:r.origin),
                        footprints:[pr.actualFullFootprint],origin:m.origin,normal:m.normal,along:m.along,sourceWidth:m.rect.width)
                    let terminal=terminalCache.terminalObservation(memberOrdinal:ordinal,proposed:q,includeMasks:false)
                    losses.append(["memberOrdinal":ordinal,"sourceIndex":m.index,
                        "whole":try HostSourceWitness436.json(whole),"dense":try HostSourceWitness436.json(dense),
                        "terminal":try terminal.map{try HostSourceWitness436.json($0)} ?? NSNull(),
                        "unconditionallyEvaluatedForDiagnosisDespiteNativeEarlyReject":true,
                        "noNativeVerdictChanged":true])
                }
                row["allActualMemberLossWitnesses"]=losses;candidates.append(row)
            }
            source["candidates"]=candidates
            source["sharedEvidenceWarning"]="caps/whole/dense/terminal may reuse same originalRGB, palettes, native footprint and GG; correlated witnesses are not independent confirmation"
            source["primaryTextMembershipNotInferredFromNNOrGG"]=true
            let evidence=try HostSourceWitness436.gzip(try JSONSerialization.data(withJSONObject:source,options:[.sortedKeys]),root.appendingPathComponent("actual-witnesses.json"))
            let manifest:[String:Any]=["status":"actual-source-witness436-exported","sourceIndex":p.measurement.index,
                "sourceFrameRGBA_SHA256":frameHash,"localRGBA":capture,"witnesses":evidence,
                "candidateCount":candidates.count,"actual432AuxiliaryAvailable":aux.auxiliary != nil,
                "actual408Available":roles408 != nil,"sourceOnlyFailureFilter":true,
                "nativeAdmissionUnchanged":true,"originalOwnershipUnchanged":true]
            try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("manifest.json"),options:.atomic)
            manifests.append(manifest);return manifest
        }
    }
    static func controls(directory:URL) throws -> [String:Any] {
        let first=Context(directory:directory,requestPages:[]),second=Context(directory:directory,requestPages:[])
        guard first.directory != second.directory else {throw NSError(domain:"Witness436.uniqueJobDirectory",code:8)}
        try FileManager.default.createDirectory(at:first.directory,withIntermediateDirectories:true)
        let original=Data((0..<4096).map{UInt8($0%251)})
        let path=first.directory.appendingPathComponent("literal-transport-control.bin")
        let proof=try gzip(original,path)
        guard !FileManager.default.fileExists(atPath:path.path),proof["decompressedBytesVerified"] as? Bool==true else {
            throw NSError(domain:"Witness436.losslessTransport",code:9)
        }
        let cap:[String:Any]=["nativeAssessmentRun":true,"nativeAdmissionPassed":false,
            "nativeOutcome":[["hardRejections":["lost-actual-cap-guard-or-explicit-support"]]]]
        var passed=cap;passed["nativeAdmissionPassed"]=true
        var unrun=cap;unrun["nativeAssessmentRun"]=false
        guard C.wants(cap),!C.wants(passed),!C.wants(unrun),C.sink==nil,C.pointObserver==nil else {
            throw NSError(domain:"Witness436.readOnlyFailurePredicate",code:10)
        }
        enum ExpectedScopeFailure: Error {case nested}
        let originalSink=C.sinkScopeIdentity,originalPoints=C.pointScopeIdentity
        var nestedRestored=false,throwRestored=false,threadIsolated=false
        final class ThreadCheck: @unchecked Sendable {var isolated=false}
        C.withSink({ _ in ["control":"outer"] }) {
            C.withPointObserver({ _ in }) {
                let outerSink=C.sinkScopeIdentity,outerPoints=C.pointScopeIdentity
                C.withSink({ _ in ["control":"inner"] }) {
                    C.withPointObserver({ _ in }) {
                        nestedRestored=C.sinkScopeIdentity != nil && C.pointScopeIdentity != nil &&
                            C.sinkScopeIdentity != outerSink && C.pointScopeIdentity != outerPoints
                    }
                }
                nestedRestored=nestedRestored && C.sinkScopeIdentity==outerSink && C.pointScopeIdentity==outerPoints
                do {
                    try C.withSink({ _ in ["control":"throwing-inner"] }) {
                        try C.withPointObserver({ _ in }) {throw ExpectedScopeFailure.nested}
                    }
                } catch ExpectedScopeFailure.nested {
                    throwRestored=C.sinkScopeIdentity==outerSink && C.pointScopeIdentity==outerPoints
                } catch {throwRestored=false}
                let check=ThreadCheck(),done=DispatchSemaphore(value:0)
                Thread.detachNewThread {
                    check.isolated=C.sink==nil && C.pointObserver==nil
                    done.signal()
                }
                threadIsolated=done.wait(timeout: .now()+10) == .success && check.isolated
            }
        }
        guard nestedRestored,throwRestored,threadIsolated,
              C.sinkScopeIdentity==originalSink,C.pointScopeIdentity==originalPoints,
              C.sink==nil,C.pointObserver==nil else {throw NSError(domain:"Witness436.scopedObserverRestoration",code:11)}
        return ["status":"pass","transport":proof,"requestDirectoriesUnique":true,
            "rawRemovedOnlyAfterDecodedByteParity":true,"sourceOnlyPredicateControls":true,
            "actualScopedSinkAndPointObserverEntered":true,"nestedScopeRestored":nestedRestored,
            "throwingScopeRestoredByDefer":throwRestored,"otherThreadDidNotInheritObservers":threadIsolated,
            "observerSlotsNilAfterCLIControl":true,
            "noNNOrGGOrNativePermissionSimulated":true,"detectorCalls":0,"recognizerCalls":0]
    }
    static func run(input:URL,output:URL,directory:URL) throws -> Int32 {
        let request=try JSONSerialization.jsonObject(with:Data(contentsOf:input)) as? [String:Any]
        let audit=request?["sourceLiveCandidateAudit"] as? [String:Any]
        guard (audit?["families"] as? [String] ?? []).contains("source-regression435-witness436") else {
            throw NSError(domain:"Witness436.explicitOptInRequired",code:5)
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let requested=request?["pages"] as? [[String:Any]] ?? []
        let context=Context(directory:directory,requestPages:requested)
        try FileManager.default.createDirectory(at:context.directory,withIntermediateDirectories:true)
        var status:Int32=1,invocationError:Error?
        do {
            status=try C.withSink({ context.receive($0) }) {
                try HostDirectionAudit.planEndpoints(input:input,output:output)
            }
        } catch { invocationError=error }
        let document=(try? Data(contentsOf:output)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        let actualPages=document?["pages"] as? [[String:Any]] ?? []
        let index:[[String:Any]]=requested.enumerated().map { ordinal,page in
            let id=page["id"] as? String ?? page["page"] as? String ?? ""
            let actual=actualPages.first { ($0["page"] as? String ?? $0["id"] as? String)==id }
            let records=actual?["residualCandidates"] as? [[String:Any]] ?? []
            let raw=records.filter { $0["family"] as? String=="source-regression435-qualified425" }
            let coverage=records.first { $0["summary"] as? Bool==true && $0["attemptedRoots"] != nil }
            let exports=raw.compactMap { $0["sourceWitness436"] as? [String:Any] }
            let successful=exports.filter { $0["status"] as? String=="actual-source-witness436-exported" }
            return ["requestedPageOrdinal":ordinal,"page":id,
                "sourceImageSHA256":page["sourceSHA256"] as Any? ?? NSNull(),
                "actualOutputPagePresent":actual != nil,
                "actualLiveRootCount":coverage?["actualCurrentLiveRootCount"] as Any? ?? NSNull(),
                "allRootAttemptCount":coverage?["attemptedRoots"] as Any? ?? NSNull(),
                "raw435RootRecordCount":raw.count,"captureAttemptCount":exports.count,
                "captureSuccessCount":successful.count,"captureFailureOrBudgetCount":exports.count-successful.count,
                "captureReceipts":exports] as [String:Any]
        }
        let success=context.attempts.filter { $0["status"] as? String=="actual-source-witness436-exported" }.count
        let summary:[String:Any]=["status":invocationError==nil ? "actual-witness436-capture-complete":"actual-witness436-run-failed",
            "requestedPageCount":requested.count,"requestedPageIndex":index,
            "allCaptureAttempts":context.attempts,"captureAttemptCount":context.attempts.count,
            "captureSuccessCount":success,"captureFailureOrBudgetCount":context.attempts.count-success,
            "invocationError":invocationError.map{String(describing:$0)} as Any? ?? NSNull(),
            "GTReadOrUsedForFilter":false,"nativeAdmissionPolicyChanged":false,
            "noHostSymbolsInApp":true,"noOriginalOwnershipMutation":true]
        try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:context.directory.appendingPathComponent("CAPTURE-PROOF.json"),options:.atomic)
        if let invocationError {throw invocationError}
        return status
    }
}
