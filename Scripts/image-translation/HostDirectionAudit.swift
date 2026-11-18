import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

/// Nominates actual-model A/B inputs by invoking production geometry. No inference,
/// translations or GT are manufactured here; OCR is run separately on nominees.
enum HostDirectionAudit {
    /// Structured host audit only. No page/source/GT-coordinate nomination table.
    static func sourceLiveCandidateAudit369(_ request: [String: Any]) throws -> NativeOCRSourceLocalJoint369Capture.ExportConfiguration {
        guard let raw = request["sourceLiveCandidateAudit"] else { return .init() }
        guard let object = raw as? [String: Any], let enabled = object["enabled"] as? Bool else {
            throw HostError.message("Malformed structured sourceLiveCandidateAudit")
        }
        guard enabled else { return .init() }
        guard request["residualCandidateMeasurementOnly"] as? Bool != true,
              request["sourceComponentMeasurementOnly"] as? Bool != true,
              let families = object["families"] as? [String], !families.isEmpty, families.count <= 16,
              families.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 96 }),
              let maximumRoots = object["maximumRoots"] as? Int, (1...256).contains(maximumRoots) else {
            throw HostError.message("Live candidate audit requires actual368 mode, explicit families and bounded maximumRoots")
        }
        var diagnosticMode = NativeOCRComponentDiagnostics371.Mode.summary
        if let rawMode = object["componentDiagnostics"] {
            guard let modeString = rawMode as? String,
                  let parsed = NativeOCRComponentDiagnostics371.Mode(rawValue: modeString) else {
                throw HostError.message("componentDiagnostics must be summary, packed, or full")
            }
            diagnosticMode = parsed
        }
        if let rawGate = object["necessarySourceGate"], !(rawGate is Bool) {
            throw HostError.message("necessarySourceGate must be Boolean")
        }
        return .init(enabled: true, families: families, maximumRoots: maximumRoots,
                     componentDiagnostics371: diagnosticMode,
                     necessarySourceGate371: object["necessarySourceGate"] as? Bool ?? false)
    }
    /// Explicit bounded host diagnostics only; absent/false performs no extra reads.
    static func privateObservationAuditRequests(_ request: [String: Any], page: [String: Any],
        sourceSHA256: String) throws -> [NativeOCRPrivateObservationAudit.Request] {
        guard request["privateObservationTerminalAuditEnabled"] as? Bool == true else { return [] }
        guard request["residualCandidateMeasurementOnly"] as? Bool == true,
              let entries = request["privateObservationTerminalAuditRequests"] as? [[String: Any]],
              entries.count <= 6,
              let binarySHA = request["privateObservationAuditBinarySHA256"] as? String,
              let observationSHA = request["privateObservationAuditSourceSHA256"] as? String else {
            throw HostError.message("Invalid bounded private-observation export request")
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        guard try digest(executable) == binarySHA,
              try digest(executable.deletingLastPathComponent().appendingPathComponent(
                "sources/NativeOCRPrivateObservation.swift")) == observationSHA else {
            throw HostError.message("Private-observation audit binary/source binding mismatch")
        }
        var seen = Set<String>(), result: [NativeOCRPrivateObservationAudit.Request] = []
        for entry in entries {
            guard let id = entry["page"] as? String, let index = entry["sourceIndex"] as? Int,
                  index >= 0, let tag = entry["tag"] as? String, tag.count <= 128,
                  let sourceSHA = entry["sourceSHA256"] as? String,
                  let before = entry["inherited"] as? [[Double]],
                  let after = entry["proposed"] as? [[Double]], before.count == 4, after.count == 4,
                  (before + after).allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
                  seen.insert("\(id)/\(index)").inserted else {
                throw HostError.message("Malformed or duplicate private-observation audit pair")
            }
            guard id == page["id"] as? String else { continue }
            guard sourceSHA == sourceSHA256 else { throw HostError.message("Audit source SHA mismatch") }
            result.append(.init(identity: .init(requestTag: tag, sourceSHA256: sourceSHA,
                binarySHA256: binarySHA, observationSourceSHA256: observationSHA), sourceIndex: index,
                inherited: before.map { CGPoint(x: $0[0], y: $0[1]) },
                proposed: after.map { CGPoint(x: $0[0], y: $0[1]) }))
        }
        return result
    }
    static func polygon(_ raw: Any?) -> [CGPoint] {
        (raw as? [[String: Any]] ?? []).map {
            CGPoint(x: ($0["x"] as! NSNumber).doubleValue, y: ($0["y"] as! NSNumber).doubleValue)
        }
    }
    static func rect(_ raw: [String: Any]) -> CGRect {
        CGRect(x: (raw["x"] as! NSNumber).doubleValue, y: (raw["y"] as! NSNumber).doubleValue,
               width: (raw["width"] as! NSNumber).doubleValue, height: (raw["height"] as! NSNumber).doubleValue)
    }
    static func componentAdmission(_ polygon:[CGPoint],index:Int,hasInk:Bool,layout:NativeRFDETRLayoutResult?,
                                   boxes:[NativeCoreMLDetectionBox],width:Int,height:Int)->Bool {
        NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
            NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:layout,width:width,height:height)==nil &&
            NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,
                evidence:boxes.indices.contains(index) ? boxes[index].detectorSeedEvidence:nil,
                layout:layout,width:width,height:height,hasSourceInkProof:hasInk)==nil
        }
    }
    /// Exact production endpoint planning, without loading a detector or
    /// recognizer model. Actual recognition/retention must be checked separately.
    static func planEndpoints(input: URL, output: URL) throws -> Int32 {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
        if request["boundaryCalibrationOnly"] as? Bool == true {
            return try calibrateSavedBoundaries(request,output:output)
        }
        let pages = request["pages"] as! [[String: Any]]
        if let paths = request["paths"] as? String { setenv("AIDOKU_OCR_ORIENTED_PATHS", paths, 1) }
        let mode = request["endpointMode"] as? String ?? "db+pixel"
        let preRecognitionOnly = request["preRecognitionOnly"] as? Bool ?? false
        let rawDetectorQueries = request["rawDetectorQueries"] as? Bool ?? false
        guard !rawDetectorQueries || (preRecognitionOnly && request["endpointBaseline"] == nil) else {
            throw HostError.message("Raw geometry planning requires independent pre-recognition inputs")
        }
        func json(_ p: [CGPoint]) -> [[String: Double]] { p.map { ["x": Double($0.x), "y": Double($0.y)] } }
        func admitted(_ rows:[[String:Any]],layout:NativeRFDETRLayoutResult?,frame:NativeOCRRGBAFrame,boxes:[NativeCoreMLDetectionBox])
            ->(rows:[[String:Any]],rejected:[[String:Any]]) {
            if rawDetectorQueries { return (rows, []) }
            var kept:[[String:Any]]=[],rejected:[[String:Any]]=[]
            for row in rows {
                let reason=NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
                    NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon(row["polygon"]),layout:layout,
                        width:frame.width,height:frame.height)
                }
                if let reason {
                    var rejection=row;rejection["roleQueryID"]=reason.queryID
                    rejection["roleConfidence"]=Double(reason.confidence);rejection["reason"]="strong-rf-effect-without-text"
                    rejected.append(rejection)
                } else {
                    let index=row["sourceIndex"] as? Int ?? -1
                    let sparse=NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
                        NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon(row["polygon"]),
                            evidence:boxes.indices.contains(index) ? boxes[index].detectorSeedEvidence:nil,
                            layout:layout,width:frame.width,height:frame.height,
                            hasSourceInkProof:(row["sourceInkColumn"] as? Bool == true) || (row["hasSourceInkProof"] as? Bool == true))
                    }
                    if let sparse {
                        var rejection=row;rejection["sourceEvidenceCells"]=sparse
                        rejection["reason"]="sparse-shared-db-without-rf-text";rejected.append(rejection)
                    } else {kept.append(row)}
                }
            }
            return (kept,rejected)
        }
        var results: [[String: Any]] = []
        var endpointBaseline: [String: [String: Any]] = [:]
        if let path=request["endpointBaseline"] as? String {
            let data=try Data(contentsOf:URL(fileURLWithPath:path))
            let hash=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
            guard preRecognitionOnly,hash == request["endpointBaselineSHA256"] as? String,
                  let document=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let saved=document["pages"] as? [[String:Any]] else {
                throw HostError.message("Endpoint baseline identity mismatch")
            }
            for page in saved {if let id=page["page"] as? String {endpointBaseline[id]=page}}
        }
        let started = Date()
        for page in pages {
            try autoreleasepool {
                let source = try HostDirectionReplay.load(page)
                guard let map = source.map,
                      let decoder = CGImageSourceCreateWithURL(URL(fileURLWithPath: source.source) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil),
                      let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: image),
                      frame.width == source.width, frame.height == source.height else {
                    throw HostError.message("Endpoint plan source/map missing")
                }
                let primitives = (page["primitives"] as? [[String: Any]] ?? []).compactMap { p -> NativeRFDETRLayoutPrimitive? in
                    let classID = p["class"] as! Int
                    guard classID == 1 || classID == 3 else { return nil }
                    let r = rect(p["sourceBounds"] as! [String: Any])
                    return .init(queryID: p["queryID"] as! Int, semanticClass: classID == 1 ? .text : .soundEffect,
                        confidence: (p["confidence"] as! NSNumber).floatValue,
                        normalizedBounds: CGRect(x: r.minX/CGFloat(frame.width), y: r.minY/CGFloat(frame.height),
                            width: r.width/CGFloat(frame.width), height: r.height/CGFloat(frame.height)), sourceBounds: r, mask: nil)
                }
                var layout = NativeRFDETRLayoutResult(imageIdentity: source.sourceSHA256,
                    sourceWidth: frame.width, sourceHeight: frame.height, primitives: primitives,
                    maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0, modelMilliseconds: 0,
                    decodeMilliseconds: 0, computeUnits: "saved", fromCache: true)
                if let path=request["rfCache"] as? String {
                    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
                    let context=try HostRFLayoutReplay.Context(root:root,cache:URL(fileURLWithPath:path),
                        sourceSHA256:source.sourceSHA256,width:frame.width,height:frame.height)
                    guard let exact=try HostRFLayoutReplay.$context.withValue(context,operation:{
                        try HostRFLayoutReplay.read(image:image,maximumMasks:160)
                    }) else { throw HostError.message("Complete saved RF result missing; planning cannot predict it") }
                    layout=exact
                }
                if !endpointBaseline.isEmpty {
                    guard let id=page["id"] as? String,var saved=endpointBaseline[id],
                          saved["sourceSHA256"] as? String == source.sourceSHA256,
                          let baseRows=saved["regions"] as? [[String:Any]],
                          let prepared=saved["preparedBoxes"] as? [[String:Any]],
                          !baseRows.contains(where:{$0["sourceInkColumn"] as? Bool == true}) else {
                        throw HostError.message("Cached endpoint baseline missing or wrong source")
                    }
                    let columns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:source.boxes,
                        existing:baseRows.map{polygon($0["polygon"])},layout:layout,frame:frame,probability:map)
                    let extra=columns.enumerated().map { i,box in
                        ["sourceIndex":prepared.count+i,"polygon":json(box.polygon),"sourceInkColumn":true] as [String:Any]
                    }
                    let selected=admitted(baseRows+extra,layout:layout,frame:frame,boxes:source.boxes)
                    saved["regions"]=selected.rows;saved["sourceInkColumns"]=selected.rows.filter{$0["sourceInkColumn"] as? Bool == true}.count
                    saved["primaryRoleRejections"]=selected.rejected
                    saved["reusedEndpointBaseline"]=true;results.append(saved)
                    print("Source ink columns \(id) complete; cached endpoint geometry reused")
                    return
                }
                let lanes: NativeOCRIndependentLanes.Result
                if rawDetectorQueries {
                    lanes = .init(boxes: source.boxes, changed: [], added: [])
                } else {
                    lanes = try NativeOCRIndependentLanes.refine(boxes: source.boxes, layout: layout,
                        probability: map, width: frame.width, height: frame.height)
                }
                let primary = rawDetectorQueries ? NativeOCRRFPrimaryEnsemble.Plan(boxes: source.boxes,
                    supported: [], stronglySupported: [], groups: [], refinedCrops: []) :
                    NativeOCRRFPrimaryEnsemble.plan(boxes: lanes.boxes, layout: layout,
                    width: frame.width, height: frame.height, probability: map,
                    pixelThreshold: NativeCoreMLDBPostprocessConfiguration.manga.threshold)
                let plan = rawDetectorQueries ? primary :
                    NativeOCRRFPrimaryEnsemble.includingSourceAlignedColumns(primary,layout:layout,frame:frame,
                    independentColumns:{
                        (try? NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:source.boxes,
                            existing:primary.boxes.map(\.polygon),layout:layout,frame:frame,
                            probability:map))?.map(\.polygon) ?? []
                    })
                let fontPeers=NativeOCRRFPrimaryEnsemble.endpointFontPeerPolygons(plan.boxes)
                let inkStyles: [NativeOCRRFPrimaryEnsemble.EndpointInkStyle?] = plan.boxes.map {
                    NativeOCRRFPrimaryEnsemble.endpointInkStyle(box:$0,frame:frame,candidatePeerPolygons:fontPeers)
                }
                let debug = Set(page["debugIndices"] as? [Int] ?? [])
                var cropTrimAudits:[Int:[[String:Any]]]=[:]
                var contextAudits:[Int:[String]]=[:]
                let observed=page["observedReads"] as? [[String:Any]]
                let retained=observed?.filter { ($0["confidence"] as? Double ?? 0) >= 0.4 }
                let active=retained.map { Set($0.compactMap { $0["sourceIndex"] as? Int }) }
                var peerPolygons:[Int:[CGPoint]]=[:]
                for read in retained ?? [] {
                    if let index=read["sourceIndex"] as? Int { peerPolygons[index]=polygon(read["polygon"]) }
                }
                let contextual=preRecognitionOnly ? [] : NativeOCRContextualColumnRecovery.proposals(boxes:plan.boxes,layout:layout,
                    probability:map,frame:frame,inkStyles:inkStyles,activePeers:active,peerPolygons:peerPolygons,audit:{ index,note in
                        if debug.contains(index) { contextAudits[index,default:[]].append(note) }
                    })
                let resolved=Set((retained ?? []).compactMap { read -> Int? in
                    let text=read["text"] as? String ?? ""
                    return text.filter({$0.isLetter || $0.isNumber}).count >= 2 ? read["sourceIndex"] as? Int:nil
                })
                let pointTails=preRecognitionOnly ? [] : NativeOCRContextualColumnRecovery.retainedPointTails(boxes:plan.boxes,
                    frame:frame,inkStyles:inkStyles,retained:resolved,peerPolygons:peerPolygons,excluding:[],layout:layout,groups:plan.groups,
                    audit:{ index,note in if debug.contains(index) { contextAudits[index,default:[]].append(note) } })
                let crops = plan.boxes.indices.compactMap { index -> (Int, NativeOCRRFPrimaryEnsemble.EndpointCrop)? in
                    NativeOCRRFPrimaryEnsemble.recognitionCrop(index: index, boxes: plan.boxes,
                        layout: layout, frame: frame, probability: map,
                        pixelThreshold: NativeCoreMLDBPostprocessConfiguration.manga.threshold, mode: mode, inkStyles:inkStyles,groups:plan.groups,
                        trimAudit:debug.contains(index) ? { cropTrimAudits[index,default:[]].append($0) }:nil).map { (index,$0) }
                }
                let endpointReconciled = NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(crops.map { $0.1.polygon },
                    bases: crops.map { $0.1.baseline ?? plan.boxes[$0.0].polygon },
                    pixelProofs: crops.map { $0.1.pixelProof },
                    inkStyles: crops.map { inkStyles[$0.0] },
                    pixelInkProofs: crops.map { $0.1.pixelInkProof },
                    pointTerminalProofs:crops.map { $0.1.pointTerminalProof })
                let reconciled=try NativeOCRRFPrimaryEnsemble.reconcilingSourceGroupAxes(endpointReconciled,
                    indices:crops.map{$0.0},groups:plan.groups,boxes:source.boxes,layout:layout,
                    frame:frame,probability:map)
                var rows: [[String: Any]] = []
                for (entry, polygon) in zip(crops,reconciled) {
                    let (index,crop) = entry
                    var row: [String: Any] = ["sourceIndex": index, "polygon": json(polygon)]
                    if debug.contains(index) {
                        row["contextDiagnostics"]=contextAudits[index] ?? []
                        row["pointTailProposals"]=pointTails.filter { $0.parent==index }.map { json($0.polygon) }
                        row["contextProposals"]=contextual.filter { $0.parent==index }.map { json($0.polygon) }
                    }
                    row["hasSourceInkProof"] = crop.pixelInkProof != nil || crop.terminalProof != nil || crop.pointTerminalProof != nil
                    row["baseline"] = crop.baseline.map { json($0) as Any } ?? NSNull()
                    row["terminalProof"] = crop.terminalProof.map { json($0) as Any } ?? NSNull()
                    row["pointTerminalProof"] = crop.pointTerminalProof.map { json($0) as Any } ?? NSNull()
                    row["measuredAlternative"] = crop.baseline.flatMap {
                        NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(candidate:polygon,baseline:$0,
                            terminalProof:crop.terminalProof)
                    }.map { json($0) as Any } ?? NSNull()
                    if debug.contains(index) {
                        row["cropPolygon"] = json(crop.polygon)
                        row["pixelInkProof"] = crop.pixelInkProof.map { json($0) as Any } ?? NSNull()
                        row["cropTrimObservations"] = cropTrimAudits[index] ?? []
                        row["preparedPolygon"] = json(plan.boxes[index].polygon)
                        row["inkStyle"] = inkStyles[index]?.colors
                        row["privateOwners"] = plan.boxes[index].detectorSeedEvidence.map { [$0.ownerID] } ?? []
                        var observations: [[String: Any]] = []
                        row["pixelProposal"] = NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: index,
                            boxes: plan.boxes, layout: layout, frame: frame,probability:map,
                            audit: { observations.append($0) },inkStyles:inkStyles).map { json($0) as Any } ?? NSNull()
                        row["pixelObservations"] = observations
                        var trimObservations: [[String: Any]] = []
                        row["directTrim"] = json(NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:index,
                            boxes:plan.boxes,polygon:crop.baseline ?? plan.boxes[index].polygon,
                            layout:layout,frame:frame,inkStyles:inkStyles,audit:{ trimObservations.append($0) }))
                        row["trimObservations"] = trimObservations
                        row["terminalProposal"] = NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: index,
                            boxes: plan.boxes, layout: layout, frame: frame,probability:map,terminalOnly: true,inkStyles:inkStyles).map { json($0) as Any } ?? NSNull()
                    }
                    rows.append(row)
                }
                let inkColumns = try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes: source.boxes,
                    existing: reconciled, layout: layout, frame: frame, probability: map)
                for (i, box) in inkColumns.enumerated() {
                    rows.append(["sourceIndex": plan.boxes.count+i, "polygon": json(box.polygon), "sourceInkColumn": true])
                }
                let selected=admitted(rows,layout:layout,frame:frame,boxes:source.boxes)
                let calibrationInputs=selected.rows.map { row in
                    NativeOCRCommonBoundaryCalibration.Input(index:row["sourceIndex"] as! Int,polygon:polygon(row["polygon"]),
                        baseline:polygon(row["baseline"]).count==4 ? polygon(row["baseline"]):nil,
                        terminal:polygon(row["terminalProof"]).count==4 ? polygon(row["terminalProof"]):nil,
                        pointTerminal:polygon(row["pointTerminalProof"]).count==4 ? polygon(row["pointTerminalProof"]):nil,
                        hasInk:row["hasSourceInkProof"] as? Bool == true,independent:row["sourceInkColumn"] as? Bool == true)
                }
                let calibrated=NativeOCRCommonBoundaryCalibration.calibrate(calibrationInputs,originals:source.boxes,
                    prepared:plan.boxes,groups:Dictionary(uniqueKeysWithValues:plan.groups.map {($0.index,$0.members)}))
                let componentScopes=layout.primitives.compactMap { p -> NativeOCRSourceComponentMeasurements.Scope? in
                    guard p.semanticClass == .text,p.confidence>=0.5 else {return nil}
                    return .init(rect:p.sourceBounds,confidence:Double(p.confidence))
                }
                let componentAdjusted=NativeOCRSourceComponentBounds.refine(calibrated,
                    indices:calibrationInputs.map(\.index),hasInk:calibrationInputs.map(\.hasInk),
                    baselines:calibrationInputs.map(\.baseline),terminalProofs:calibrationInputs.map(\.terminal),
                    pointProofs:calibrationInputs.map(\.pointTerminal),originals:source.boxes,
                    prepared:plan.boxes,groups:Dictionary(uniqueKeysWithValues:plan.groups.map {($0.index,$0.members)}),
                    scopes:componentScopes,frameProvider:{frame},accepts:{index,q in
                        if rawDetectorQueries { return true }
                        return componentAdmission(q,index:index,hasInk:calibrationInputs.first(where:{$0.index==index})?.hasInk ?? false,
                            layout:layout,boxes:source.boxes,width:frame.width,height:frame.height)
                    })
                if rawDetectorQueries {
                    let measuredRows = zip(selected.rows, componentAdjusted).map { row, quad -> [String: Any] in
                        var row = row
                        row["polygon"] = json(quad)
                        return row
                    }
                    results.append(["page": page["id"]!, "sourceSHA256": source.sourceSHA256,
                        "regions": measuredRows, "rawDetectorQueries": true,
                        "recognitionInputs": false, "roleAdmissionApplied": false,
                        "sourceInkColumns": inkColumns.count,
                        "preparedGroups": [], "originalPreparedGroups": [], "suppressedSources": [],
                        "preparedBoxes": source.boxes.enumerated().map { index, box in
                            ["sourceIndex": index, "polygon": json(box.polygon), "score": box.score] as [String: Any]
                        }])
                    print("Raw-source physical plan \(page["id"]!) complete")
                    return
                }
                let residual=NativeOCRResidualCandidateBank.evaluate(componentAdjusted,indices:calibrationInputs.map(\.index),
                    hasInk:calibrationInputs.map(\.hasInk),baselines:calibrationInputs.map(\.baseline),
                    terminalProofs:calibrationInputs.map(\.terminal),pointProofs:calibrationInputs.map(\.pointTerminal),
                    originals:source.boxes,prepared:plan.boxes,
                    groups:Dictionary(uniqueKeysWithValues:plan.groups.map {($0.index,$0.members)}),
                    layout:layout,scopes:componentScopes,frameProvider:{frame},
                    exporting:request["residualCandidateMeasurementOnly"] as? Bool == true,
                    auditCandidatePrefix: request["residualPrivateNormalCandidateMeasurementOnly"] as? Bool == true ? "source-normal-private-v1-" :
                        request["residualSourceBodyCandidateMeasurementOnly"] as? Bool == true ? "source-body-cc-v3-" :
                        request["residualGeometryEnvelopeCandidateMeasurementOnly"] as? Bool == true ? "prior-envelope-" :
                        request["residualPriorEnvelopeCandidateMeasurementOnly"] as? Bool == true ? "prior-envelope-v1-" :
                        request["residualStrongPrimaryCandidateMeasurementOnly"] as? Bool == true ? "strong-primary-twoaxis-v1-" :
                        request["residualNormalFootprintCandidateMeasurementOnly"] as? Bool == true ? "private-pca-normal-footprint-v1-" :
                        request["residualPrivatePCACandidateMeasurementOnly"] as? Bool == true ? "private-pca-normal1-" :
                        request["residualRFTextAlongCandidateMeasurementOnly"] as? Bool == true ? "rf-text-along-v1-" :
                        request["residualAnglePaddingCandidateMeasurementOnly"] as? Bool == true ? "angle-padding-v1-" :
                        request["residualAngleCandidateMeasurementOnly"] as? Bool == true ? "angle-envelope-v1-" :
                        (request["residualPeerChainCandidateMeasurementOnly"] as? Bool == true ? "peer-chain-v1-" :
                        (request["residualForwardedCandidateMeasurementOnly"] as? Bool == true ? "evidence-forward-v1-" : nil)),
                    liveCandidateAudit369: try sourceLiveCandidateAudit369(request),
                    privateObservationAuditRequests: try privateObservationAuditRequests(request, page: page,
                        sourceSHA256: source.sourceSHA256),
                    accepts:{index,q in componentAdmission(q,index:index,
                        hasInk:calibrationInputs.first(where:{$0.index==index})?.hasInk ?? false,
                        layout:layout,boxes:source.boxes,width:frame.width,height:frame.height)})
                let retention = NativeOCRResidualRetention.State(consumed: residual.consumed, associations: residual.associations,
                    groups: Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.index, $0.members) }))
                let originalPreparedGroups = plan.groups.map { group -> [String: Any] in
                    ["index": group.index, "members": group.members,
                     "pointFragments": group.pointFragments.sorted(), "sourcePixelLane": group.sourcePixelLane]
                }
                let calibratedRows=zip(selected.rows,residual.polygons).filter { !retention.suppressed.contains($0.0["sourceIndex"] as! Int) }.map { row,q -> [String:Any] in
                    var row=row;row["polygon"]=json(q);return row
                }
                results.append(["page": page["id"]!, "sourceSHA256": source.sourceSHA256, "regions": calibratedRows,
                    "primaryRoleRejections":selected.rejected,"residualCandidates":residual.records,"residualGroups":residual.associations,
                    "sourceInkColumns": inkColumns.count,
                    "preparedGroups": retention.preparedGroups(originalPreparedGroups),
                    "originalPreparedGroups": originalPreparedGroups,
                    "suppressedSources": retention.suppressed.sorted(),
                    "independentLaneChanges": lanes.changed.sorted(),
                    "preparedBoxes": plan.boxes.enumerated().map { i,b in
                        ["sourceIndex": i, "polygon": json(b.polygon), "score": b.score] as [String: Any]
                    }])
                print("Endpoint plan \(page["id"]!) complete")
            }
        }
        try JSONSerialization.data(withJSONObject: ["pages": results, "seconds": Date().timeIntervalSince(started),
            "detector_model_calls": 0, "recognizer_model_calls": 0,
            "scope": "geometry planning only; no accepted OCR results"], options: [.sortedKeys])
            .write(to: output, options: .atomic)
        return 0
    }
    /// Replay only the common boundary stage on authenticated pre-calibration
    /// geometry. The app uses the identical kernel before its first OCR call.
    static func calibrateSavedBoundaries(_ request:[String:Any],output:URL) throws -> Int32 {
        guard request["preRecognitionOnly"] as? Bool == true,
              let path=request["boundaryFoundation"] as? String,
              let expected=request["boundaryFoundationSHA256"] as? String,
              let pages=request["pages"] as? [[String:Any]] else {throw HostError.message("Missing boundary-stage input")}
        let data=try Data(contentsOf:URL(fileURLWithPath:path))
        guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==expected,
              let document=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              document["GTsuppliedToRuntime"] as? Bool == false,
              document["sharedParameterSearch"] == nil,
              let saved=document["pages"] as? [[String:Any]] else {throw HostError.message("Invalid pre-calibration foundation")}
        let byPage=Dictionary(uniqueKeysWithValues:saved.map {($0["page"] as! String,$0)})
        func json(_ q:[CGPoint])->[[String:Double]] {q.map {["x":Double($0.x),"y":Double($0.y)]}}
        func optional(_ value:Any?)->[CGPoint]? {let q=polygon(value);return q.count==4 ? q:nil}
        let started=Date()
        var results:[[String:Any]]=[]
        for page in pages {
            try autoreleasepool {
                let source=try HostDirectionReplay.load(page,loadProbability:false)
                guard let id=page["id"] as? String,var saved=byPage[id],
                      saved["sourceSHA256"] as? String==source.sourceSHA256,
                      let rows=saved["regions"] as? [[String:Any]],
                      let boxes=saved["preparedBoxes"] as? [[String:Any]],
                      let rawGroups=saved["preparedGroups"] as? [[String:Any]] else {throw HostError.message("Boundary foundation/source mismatch")}
                let prepared=boxes.map {NativeCoreMLDetectionBox(polygon:polygon($0["polygon"]),score:($0["score"] as! NSNumber).doubleValue)}
                let groups=Dictionary(uniqueKeysWithValues:rawGroups.map {($0["index"] as! Int,$0["members"] as! [Int])})
                let inputs=rows.map {row in
                    NativeOCRCommonBoundaryCalibration.Input(index:row["sourceIndex"] as! Int,polygon:polygon(row["polygon"]),
                        baseline:optional(row["baseline"]),terminal:optional(row["terminalProof"]),pointTerminal:optional(row["pointTerminalProof"]),
                        hasInk:row["hasSourceInkProof"] as? Bool == true,independent:row["sourceInkColumn"] as? Bool == true)
                }
                let calibrated=NativeOCRCommonBoundaryCalibration.calibrate(inputs,originals:source.boxes,prepared:prepared,groups:groups)
                var scopes:[NativeOCRSourceComponentMeasurements.Scope]=[]
                if let recordPath=page["rfRecord"] as? String,let expected=page["rfRecordSHA256"] as? String {
                    let bytes=try Data(contentsOf:URL(fileURLWithPath:recordPath))
                    guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==expected,
                          let record=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                          record["sourceSHA256"] as? String==source.sourceSHA256,
                          let primitives=record["primitives"] as? [[String:Any]] else {throw HostError.message("Source component RF identity mismatch")}
                    scopes=primitives.compactMap { p -> NativeOCRSourceComponentMeasurements.Scope? in
                        guard p["semanticClass"] as? Int==0,let confidence=p["confidence"] as? Double,confidence>=0.5,
                              let values=p["sourceBounds"] as? [[Double]],values.count==2,values.allSatisfy({$0.count==2}) else {return nil}
                        return .init(rect:CGRect(x:values[0][0],y:values[0][1],width:values[1][0],height:values[1][1]),confidence:confidence)
                    }
                }
                var imageFrame:NativeOCRRGBAFrame?
                let provider:()->NativeOCRRGBAFrame? = {
                    if let imageFrame {return imageFrame}
                    guard let decoder=CGImageSourceCreateWithURL(URL(fileURLWithPath:source.source) as CFURL,nil),
                          let image=CGImageSourceCreateImageAtIndex(decoder,0,nil) else {return nil}
                    imageFrame=NativeOCRCGImageAdapter.makeRGBAFrame(from:image);return imageFrame
                }
                var admissionLayout:NativeRFDETRLayoutResult?
                if request["sourceComponentMeasurementOnly"] as? Bool != true,
                   let recordPath=page["rfRecord"] as? String,
                   let decoder=CGImageSourceCreateWithURL(URL(fileURLWithPath:source.source) as CFURL,nil),
                   let image=CGImageSourceCreateImageAtIndex(decoder,0,nil) {
                    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
                    var cache=URL(fileURLWithPath:recordPath)
                    for _ in 0..<4 {cache.deleteLastPathComponent()}
                    let context=try HostRFLayoutReplay.Context(root:root,cache:cache,sourceSHA256:source.sourceSHA256,
                        width:image.width,height:image.height)
                    admissionLayout=try HostRFLayoutReplay.$context.withValue(context,operation:{
                        try HostRFLayoutReplay.read(image:image,maximumMasks:160)
                    })
                    guard admissionLayout != nil else {throw HostError.message("Boundary admission RF replay missing")}
                }
                let measurementOnly=request["sourceComponentMeasurementOnly"] as? Bool == true
                if measurementOnly {
                    let context=NativeOCRSourceComponentMeasurements.Context(originals:source.boxes,prepared:prepared,groups:groups,
                        scopes:scopes,frameProvider:provider)
                    saved["sourceComponents"]=zip(inputs,calibrated).compactMap { input,q in
                        context.measure(index:input.index,polygon:q,hasInk:input.hasInk)?.json
                    }
                    saved["regions"]=zip(rows,calibrated).map {row,q -> [String:Any] in var row=row;row["polygon"]=json(q);return row}
                } else {
                    let adjusted=NativeOCRSourceComponentBounds.refine(calibrated,indices:inputs.map(\.index),
                        hasInk:inputs.map(\.hasInk),baselines:inputs.map(\.baseline),terminalProofs:inputs.map(\.terminal),
                        pointProofs:inputs.map(\.pointTerminal),originals:source.boxes,prepared:prepared,groups:groups,scopes:scopes,frameProvider:provider,
                        accepts:{index,q in componentAdmission(q,index:index,
                            hasInk:inputs.first(where:{$0.index==index})?.hasInk ?? false,layout:admissionLayout,
                            boxes:source.boxes,width:admissionLayout?.sourceWidth ?? 0,height:admissionLayout?.sourceHeight ?? 0)})
                    let residual=NativeOCRResidualCandidateBank.evaluate(adjusted,indices:inputs.map(\.index),hasInk:inputs.map(\.hasInk),
                        baselines:inputs.map(\.baseline),terminalProofs:inputs.map(\.terminal),pointProofs:inputs.map(\.pointTerminal),
                        originals:source.boxes,prepared:prepared,groups:groups,layout:admissionLayout,scopes:scopes,frameProvider:provider,
                        exporting:request["residualCandidateMeasurementOnly"] as? Bool == true,
                    auditCandidatePrefix: request["residualPrivateNormalCandidateMeasurementOnly"] as? Bool == true ? "source-normal-private-v1-" :
                        request["residualSourceBodyCandidateMeasurementOnly"] as? Bool == true ? "source-body-cc-v3-" :
                        request["residualGeometryEnvelopeCandidateMeasurementOnly"] as? Bool == true ? "prior-envelope-" :
                        request["residualPriorEnvelopeCandidateMeasurementOnly"] as? Bool == true ? "prior-envelope-v1-" :
                        request["residualStrongPrimaryCandidateMeasurementOnly"] as? Bool == true ? "strong-primary-twoaxis-v1-" :
                        request["residualNormalFootprintCandidateMeasurementOnly"] as? Bool == true ? "private-pca-normal-footprint-v1-" :
                        request["residualPrivatePCACandidateMeasurementOnly"] as? Bool == true ? "private-pca-normal1-" :
                        request["residualRFTextAlongCandidateMeasurementOnly"] as? Bool == true ? "rf-text-along-v1-" :
                        request["residualAnglePaddingCandidateMeasurementOnly"] as? Bool == true ? "angle-padding-v1-" :
                        request["residualAngleCandidateMeasurementOnly"] as? Bool == true ? "angle-envelope-v1-" :
                        (request["residualPeerChainCandidateMeasurementOnly"] as? Bool == true ? "peer-chain-v1-" :
                        (request["residualForwardedCandidateMeasurementOnly"] as? Bool == true ? "evidence-forward-v1-" : nil)),
                    liveCandidateAudit369: try sourceLiveCandidateAudit369(request),
                    privateObservationAuditRequests: try privateObservationAuditRequests(request, page: page,
                        sourceSHA256: source.sourceSHA256),
                        accepts:{index,q in componentAdmission(q,index:index,hasInk:inputs.first(where:{$0.index==index})?.hasInk ?? false,
                            layout:admissionLayout,boxes:source.boxes,width:admissionLayout?.sourceWidth ?? 0,height:admissionLayout?.sourceHeight ?? 0)})
                    let priorConsumed = Set(saved["suppressedSources"] as? [Int] ?? [])
                    let associations = (saved["residualGroups"] as? [[String: Any]] ?? []) + residual.associations
                    let retention = NativeOCRResidualRetention.State(consumed: priorConsumed.union(residual.consumed),
                        associations: associations, groups: groups)
                    saved["regions"]=zip(rows,residual.polygons).filter { !retention.suppressed.contains($0.0["sourceIndex"] as! Int) }.map {row,q -> [String:Any] in var row=row;row["polygon"]=json(q);return row}
                    saved["residualCandidates"] = residual.records
                    saved["residualGroups"] = associations
                    saved["originalPreparedGroups"] = saved["originalPreparedGroups"] ?? rawGroups
                    saved["preparedGroups"] = retention.preparedGroups(rawGroups)
                    saved["suppressedSources"] = retention.suppressed.sorted()
                }

                saved["boundaryStageReplayed"]=true;results.append(saved)
            }
        }
        try JSONSerialization.data(withJSONObject:["pages":results,"seconds":Date().timeIntervalSince(started),
            "detector_model_calls":0,"recognizer_model_calls":0,"GTsuppliedToRuntime":false,
            "boundaryFoundationSHA256":expected,"scope":"authenticated pre-calibration source geometry; common boundary stage only"],options:[.sortedKeys]).write(to:output,options:.atomic)
        return 0
    }

    static func run(input: URL, output: URL) throws -> Int32 {
        let pages = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [[String: Any]]
        if ProcessInfo.processInfo.environment["AIDOKU_DIRECTION_QUAD_HINT_AUDIT"] == "1" {
            var selected: [String] = []
            for page in pages {
                let raw = page["reads"] as! [[String: Any]]
                let changed = raw.contains { row in
                    let q = polygon(row["polygon"])
                    let text = row["text"] as! String
                    guard !text.isEmpty else { return false }
                    setenv("AIDOKU_OCR_ORIENTED_PATHS", "", 1)
                    let p = NativeOCRScopeGeometry.canonicalQuad(q) ?? q
                    let box = NativeOCRDirectionGeometry.bounds(q)
                    let vertical = box.height >= box.width*1.25
                    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                    let latin = !letters.isEmpty && letters.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
                    let hints = (vertical || text.count == 1 ? [true] : []) + (!vertical || latin ? [false] : [])
                    return hints.contains { hint in
                        setenv("AIDOKU_OCR_ORIENTED_PATHS", "", 1)
                        let before = NativeOCRScopeGeometry.canonicalQuad(p,vertical:hint) ?? p
                        setenv("AIDOKU_OCR_ORIENTED_PATHS", "quad", 1)
                        let after = NativeOCRScopeGeometry.canonicalQuad(p,vertical:hint) ?? p
                        return before != after
                    }
                }
                if changed { selected.append(page["id"] as! String) }
            }
            try JSONSerialization.data(withJSONObject:["pages":selected,"scope":pages.count,"recognizer_calls":0],
                options:[.sortedKeys]).write(to:output,options:.atomic)
            return 0
        }
        var results: [[String: Any]] = []
        func flags(_ path: String) { setenv("AIDOKU_OCR_ORIENTED_PATHS", path, 1) }
        func different(_ a: [CGPoint]?, _ b: [CGPoint]?) -> Bool { a != b }
        for page in pages {
            try autoreleasepool {
                flags("")
                let width = page["width"] as! Int, height = page["height"] as! Int
                let boxes = (page["boxes"] as! [[String: Any]]).map {
                    NativeCoreMLDetectionBox(polygon: polygon($0["polygon"]), score: ($0["score"] as! NSNumber).doubleValue,
                        recognitionPolygon: $0["recognitionPolygon"].map { polygon($0) })
                }
                let primitives = (page["primitives"] as! [[String: Any]]).compactMap { p -> NativeRFDETRLayoutPrimitive? in
                    let c = p["class"] as! Int
                    guard c == 1 || c == 3 else { return nil }
                    let r = rect(p["sourceBounds"] as! [String: Any])
                    return .init(queryID: p["queryID"] as! Int, semanticClass: c == 1 ? .text : .soundEffect,
                        confidence: (p["confidence"] as! NSNumber).floatValue,
                        normalizedBounds: CGRect(x:r.minX/CGFloat(width),y:r.minY/CGFloat(height),
                            width:r.width/CGFloat(width),height:r.height/CGFloat(height)), sourceBounds:r,mask:nil)
                }
                let layout = NativeRFDETRLayoutResult(imageIdentity: page["sourceSHA256"] as! String,
                    sourceWidth:width,sourceHeight:height,primitives:primitives,maskQueriesOmittedByBudget:0,
                    preprocessingMilliseconds:0,modelMilliseconds:0,decodeMilliseconds:0,computeUnits:"saved",fromCache:true)
                let p = page["probability"] as! [String: Any]
                let mw = p["width"] as! Int, mh = p["height"] as! Int
                let data = try Data(contentsOf: URL(fileURLWithPath:p["path"] as! String))
                let values = data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
                precondition(values.count == mw*mh)
                let map = NativeMainEnsembleOCRProbability.Sample(sourceWidth:width,sourceHeight:height,
                    resizedWidth:mw,resizedHeight:mh,region:CGRect(x:0,y:0,width:mw,height:mh),width:mw,height:mh,values:values)
                let baseLanes = try NativeOCRIndependentLanes.refine(boxes:boxes,layout:layout,probability:map,width:width,height:height)
                let threshold = page["pixelThreshold"] as! Double
                let base = NativeOCRRFPrimaryEnsemble.plan(boxes:baseLanes.boxes,layout:layout,width:width,height:height,
                    probability:map,pixelThreshold:threshold)
                var changes = Dictionary(uniqueKeysWithValues:NativeOCRDirectionGeometry.paths.map { ($0,false) })
                flags("lanes")
                let nextLanes = try NativeOCRIndependentLanes.refine(boxes:boxes,layout:layout,probability:map,width:width,height:height)
                changes["lanes"] = nextLanes.boxes != baseLanes.boxes
                for path in ["missing","narrow","rfOverlap"] {
                    flags(path)
                    let next = NativeOCRRFPrimaryEnsemble.plan(boxes:baseLanes.boxes,layout:layout,width:width,height:height,
                        probability:map,pixelThreshold:threshold)
                    changes[path] = next.boxes != base.boxes || next.supported != base.supported ||
                        next.stronglySupported != base.stronglySupported || next.refinedCrops.map(\.index) != base.refinedCrops.map(\.index)
                }
                flags("")
                let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath:page["source"] as! String) as CFURL,nil)!
                let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from:CGImageSourceCreateImageAtIndex(imageSource,0,nil)!)!
                for (index,box) in base.boxes.enumerated() {
                    flags("")
                    let completed = NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index:index,boxes:base.boxes,
                        layout:layout,width:width,height:height,probability:map,pixelThreshold:threshold) ??
                        NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:index,boxes:base.boxes,layout:layout,frame:frame)
                    let sampling = completed == nil ? NativeOCRRFPrimaryEnsemble.completeSupportSampling(
                        box:box,boxes:base.boxes,layout:layout,frame:frame) ?? box.recognitionPolygon : nil
                    let region = NativeCoreMLRecognitionRegion(sourceIndex:index,polygon:completed ?? box.polygon,samplingPolygon:sampling)
                    let oldQuote = NativeOCRQuotedDotRecovery.pixelProposal(frame:frame,region:region)
                    flags("quoted")
                    let newQuote = NativeOCRQuotedDotRecovery.pixelProposal(frame:frame,region:region)
                    if oldQuote?.crops != newQuote?.crops { changes["quoted"] = true }
                    let aabb = NativeOCRDirectionGeometry.bounds(box.polygon)
                    let local = NativeOCRDirectionGeometry.Frame(box.polygon)?.rect ?? aabb
                    func large(_ r: CGRect) -> Bool {
                        box.score >= 0.5 && r.width >= 150 && r.height >= 300 && r.height >= r.width*1.3 && r.height <= r.width*2.5
                    }
                    // Includes order-only changes and shared-budget interactions.
                    if large(aabb) || large(local) { changes["large"] = true }
                    if let size = NativeOCRDirectionGeometry.edgeSize(box.polygon) {
                        flags(""); let old = NativeCoreMLOCRPipeline.orientation(for:box.polygon)
                        flags("orientation"); let next = NativeCoreMLOCRPipeline.orientation(for:box.polygon)
                        if old != next { changes["orientation"] = true }
                        _ = size
                    }
                }
                let rawReads = page["reads"] as! [[String: Any]]
                let polygons = boxes.map(\.polygon) + base.boxes.map(\.polygon) + rawReads.map { polygon($0["polygon"]) }
                for q in polygons {
                    flags(""); let old = NativeOCRScopeGeometry.canonicalQuad(q)
                    flags("quad"); let next = NativeOCRScopeGeometry.canonicalQuad(q)
                    if different(old,next) { changes["quad"] = true }
                    // DB's upstream minimum-rectangle cycle is not retained in
                    // the old decode: conservatively reread every angled box.
                    if zip(q,q.dropFirst()+q.prefix(1)).contains(where:{ abs($0.x-$1.x)>0.000001 && abs($0.y-$1.y)>0.000001 }) {
                        changes["dbquad"] = true
                    }
                    flags(""); let oldOrientation = NativeCoreMLOCRPipeline.orientation(for:q)
                    flags("orientation"); if NativeCoreMLOCRPipeline.orientation(for:q) != oldOrientation { changes["orientation"] = true }
                }
                for read in rawReads {
                    let text = read["text"] as! String, q = polygon(read["polygon"])
                    if NativeOCRScopeGeometry.isLatinWord(text) {
                        flags(""); let old = NativeOCRScopeGeometry.alternateHorizontalQuad(q)
                        flags("latin"); if NativeOCRScopeGeometry.alternateHorizontalQuad(q) != old { changes["latin"] = true }
                    }
                    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                    if letters.count == 1, letters.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) {
                        changes["single"] = true // Includes anchor-set changes.
                    }
                }
                results.append(["page":page["id"]!,"changes":changes])
                if results.count % 20 == 0 { print("Direction audit \(results.count)/\(pages.count)"); fflush(stdout) }
            }
        }
        try JSONSerialization.data(withJSONObject:["pages":results,"scope":pages.count,"recognizer_calls":0],
            options:[.sortedKeys]).write(to:output,options:.atomic)
        return 0
    }
}
