import CoreGraphics
import Foundation
import CoreFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

extension NativeMainEnsembleOCREvidence.Binding: NativeSavedAppearanceSourceEvidence {}

/// Explicit offline probe of the actual production painter. Supplied geometry
/// and either neutral or hash-bound restored RGB; no OCR/RF/provider inference.
@available(macOS 15.0, *)
enum HostRawTextRender {
    /// Optional normalized original geometry is independent of the actual
    /// caller frame. Absence retains the legacy frame-normalization contract.
    static func sourceBoundsForRaw(frame: [Double], explicit: Any?, width: Double, height: Double) throws -> [Double] {
        guard frame.count == 4, frame.allSatisfy(\.isFinite), frame[2] > 0, frame[3] > 0,
              (frame[0] + frame[2]).isFinite, (frame[1] + frame[3]).isFinite,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw NativeAOTRawTextPainter.Failure.invalidGeometry
        }
        if let explicit {
            guard let numbers = explicit as? [NSNumber], numbers.count == 4,
                  numbers.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else {
                throw NativeAOTRawTextPainter.Failure.invalidGeometry
            }
            let bounds = numbers.map(\.doubleValue)
            guard bounds.allSatisfy(\.isFinite), bounds[2] > 0, bounds[3] > 0,
                  CGRect(x: 0, y: 0, width: 1, height: 1).contains(
                    CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])) else {
                throw NativeAOTRawTextPainter.Failure.invalidGeometry
            }
            return bounds // Do not recompute or replace the supplied F64 geometry.
        }
        return [frame[0] / width, frame[1] / height, frame[2] / width, frame[3] / height]
    }

    /// Run-local accepted artifact cache. Read/hash root documents ONCE, retain
    /// only selected page projections, and authenticate all actual owner bytes.
    private final class SavedAppearanceInputs {
        let corpus: NativeOperationalAppearance.SavedAcceptedCorpus
        private let descriptor: [String: Any]
        private var bindings: [String: String] = [:]
        private let selectedPages: Set<String>
        init(_ packet: Any, pages: [[String: Any]]) throws {
            guard let descriptor = packet as? [String: Any],
                  descriptor["authority"] as? String == "saved-accepted-source-appearance-v1",
                  descriptor["freshInference"] as? Bool == false,
                  descriptor["cachedPredictionsRead"] as? Bool == true,
                  descriptor["GTUsed"] as? Bool == false,
                  pages.allSatisfy({ $0["inputAuthority"] as? String == "saved-accepted-display-replay" })
            else { throw NativeOperationalAppearance.Failure.invalidPacket }
            let ids = pages.compactMap { $0["page"] as? String }
            guard ids.count == pages.count, Set(ids).count == ids.count else { throw NativeOperationalAppearance.Failure.invalidPacket }
            self.descriptor = descriptor; selectedPages = Set(ids)
            // Static helper avoids accessing self before corpus initialization.
            let request = try Self.load(descriptor["request"], limit: 256 * 1024 * 1024)
            let manifest = try Self.load(descriptor["manifest"], limit: 256 * 1024 * 1024)
            corpus = try .init(request: request.data, expectedRequestSHA256: request.sha,
                manifest: manifest.data, expectedManifestSHA256: manifest.sha, selectedPages: Set(ids))
            bindings[request.path] = request.sha; bindings[manifest.path] = manifest.sha
        }
        private static func load(_ value: Any?, limit: Int) throws -> (path: String, sha: String, data: Data) {
            guard let value = value as? [String: Any], let path = value["path"] as? String, !path.isEmpty,
                  let sha = value["SHA256"] as? String, sha.count == 64,
                  sha.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
                  let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
                  size > 0, size <= limit else { throw NativeOperationalAppearance.Failure.invalidPacket }
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard digest(data) == sha else { throw NativeOperationalAppearance.Failure.sourceMismatch }
            return (path, sha, data)
        }
        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        private func read(_ descriptor: Any?, limit: Int = 16 * 1024 * 1024) throws -> (path: String, sha: String, data: Data) {
            let result = try Self.load(descriptor, limit: limit); bindings[result.path] = result.sha; return result
        }
        func authenticate(_ page: [String: Any], rows: [[String: Any]], width: Int, height: Int) throws -> NativeOperationalAppearance.SavedAcceptedPage {
            guard let id = page["page"] as? String, selectedPages.contains(id),
                  let source = page["sourceBoundaryInput"] as? [String: Any],
                  source["authority"] as? String == "saved-accepted-source-boundary-replay",
                  let sourcePath = source["sourcePath"] as? String, let sourceSHA = source["sourceSHA256"] as? String,
                  let maskPath = source["maskPath"] as? String, let maskSHA = source["maskSHA256"] as? String,
                  let pageInputs = descriptor["pages"] as? [String: [String: Any]], let inputs = pageInputs[id]
            else { throw NativeOperationalAppearance.Failure.invalidPacket }
            let meta = try corpus.metadataForPage(id)
            guard meta["sourcePath"] as? String == sourcePath, meta["maskPath"] as? String == maskPath,
                  meta["sourceSHA256"] as? String == sourceSHA, meta["maskSHA256"] as? String == maskSHA else {
                throw NativeOperationalAppearance.Failure.sourceMismatch
            }
            let original = try read(["path": sourcePath, "SHA256": sourceSHA], limit: 64 * 1024 * 1024)
            let mask = try read(["path": maskPath, "SHA256": maskSHA], limit: 64 * 1024 * 1024)
            guard let encoded = CGImageSourceCreateWithData(original.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(encoded, 0, nil),
                  let encodedMask = CGImageSourceCreateWithData(mask.data as CFData, nil),
                  let maskImage = CGImageSourceCreateImageAtIndex(encodedMask, 0, nil),
                  image.width == width, image.height == height, maskImage.width == width, maskImage.height == height
            else { throw NativeOperationalAppearance.Failure.sourceMismatch }
            if let supplied = page["restoredInput"] {
                let packet = try JSONDecoder().decode(RestoredInput.self,
                    from: JSONSerialization.data(withJSONObject: supplied))
                if packet.authority == .sourcePassThrough {
                    guard rows.isEmpty, packet.path == sourcePath, packet.encodedSHA256 == sourceSHA,
                          meta["restored"] as? String == sourcePath,
                          meta["restoredSHA256"] as? String == sourceSHA,
                          meta["maskPixels"] as? Int == 0,
                          let policy = meta["restorationPolicy"] as? [String: Any],
                          policy["authority"] as? String == packet.authority.rawValue,
                          policy["appliedMaskPixels"] as? Int == 0,
                          policy["AOTCalls"] as? Int == 0 else {
                        throw NativeOperationalAppearance.Failure.sourceMismatch
                    }
                    var pixels = [UInt8](repeating: 0, count: width * height)
                    let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
                        guard let c = CGContext(data: bytes.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                        c.setBlendMode(.copy); c.interpolationQuality = .none
                        c.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
                    }
                    guard decoded, pixels.allSatisfy({ $0 == 0 }) else {
                        throw NativeOperationalAppearance.Failure.sourceMismatch
                    }
                }
            }
            // Actual native typed binding verifies BOTH encoded hash and RGB.
            let binding = try NativeMainEnsembleOCREvidence.cachedBinding(original: image,
                encodedSource: original.data, expectedSourceSHA256: sourceSHA)
            let audit = try read(inputs["audit"]), receipt = try read(inputs["receipt"])
            guard audit.path == (try corpus.auditPathForPage(id)),
                  let object = try JSONSerialization.jsonObject(with: receipt.data) as? [String: Any],
                  let owners = object["owners"] as? [[String: Any]], owners.count <= 256,
                  let layerSHA = object["layerSHA256"] as? String,
                  let layerPath = page["layer"] as? String else { throw NativeOperationalAppearance.Failure.invalidPacket }
            _ = try read(["path": layerPath, "SHA256": layerSHA], limit: 64 * 1024 * 1024)
            for owner in owners {
                guard let path = owner["path"] as? String, let sha = owner["sha256"] as? String else { throw NativeOperationalAppearance.Failure.invalidPacket }
                _ = try read(["path": path, "SHA256": sha], limit: 32 * 1024 * 1024)
            }
            return try corpus.authenticate(page: id, source: binding, maskSHA256: maskSHA,
                audit: audit.data, expectedAuditSHA256: audit.sha, receipt: receipt.data, expectedReceiptSHA256: receipt.sha, specRows: rows)
        }
        func verifyUnchanged() throws {
            for (path, expected) in bindings {
                let actual = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                guard Self.digest(actual) == expected else { throw NativeOperationalAppearance.Failure.sourceMismatch }
            }
        }
    }

    private struct RestoredInput: Decodable {
        let authority: NativeAOTRemovalReadiness.RestorationInputAuthority
        let path: String
        let encodedSHA256: String
    }

    private enum SourceBoundaryPurpose: String, Decodable {
        case cohortBoundaryOnly = "cohort-boundary-only"
    }

    private struct SourceBoundaryInput: Decodable {
        let authority: String
        /// Absent preserves the original legacy physical-context replay.
        /// Unknown explicit purposes fail typed decoding before source I/O.
        let purpose: SourceBoundaryPurpose?
        let sourcePath: String
        let sourceSHA256: String
        let maskPath: String
        let maskSHA256: String
    }

    /// Decode original source, never the restored painter canvas. This packet
    /// is an explicit saved-source binding, not a fresh source-inference claim.
    private static func sourceBoundary(_ value: Any, width: Int, height: Int, allocateContext: Bool = true) throws
        -> (context: NativeSourcePhysicalInteriorContext?, audit: [String: Any], cohortOnly: Bool) {
        guard let object = value as? [String:Any] else {throw NativeAOTRawTextPainter.Failure.invalidGeometry}
        let packet = try JSONDecoder().decode(SourceBoundaryInput.self,
            from: JSONSerialization.data(withJSONObject: object))
        func validSHA(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
        guard packet.authority == "saved-accepted-source-boundary-replay",
              !packet.sourcePath.isEmpty, !packet.maskPath.isEmpty,
              validSHA(packet.sourceSHA256), validSHA(packet.maskSHA256),
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 16_777_216 / height else {
            throw NativeAOTRawTextPainter.Failure.invalidGeometry
        }
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: packet.sourcePath))
        let maskData = try Data(contentsOf: URL(fileURLWithPath: packet.maskPath))
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard sha(sourceData) == packet.sourceSHA256, sha(maskData) == packet.maskSHA256,
              let encodedSource = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(encodedSource, 0, nil),
              let encodedMask = CGImageSourceCreateWithData(maskData as CFData, nil),
              let mask = CGImageSourceCreateImageAtIndex(encodedMask, 0, nil),
              original.width == width, original.height == height, mask.width == width, mask.height == height else {
            throw NativeAOTRawTextPainter.Failure.invalidGeometry
        }
        var erased = [UInt8](repeating: 0, count: width * height)
        let copied = erased.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard copied, erased.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }) else {
            throw NativeAOTRawTextPainter.Failure.invalidGeometry
        }
        if packet.purpose == .cohortBoundaryOnly && !allocateContext {
            return (nil, ["authority": packet.authority, "purpose": "cohort-boundary-only",
                "sourcePath": packet.sourcePath, "sourceSHA256": packet.sourceSHA256,
                "maskPath": packet.maskPath, "maskSHA256": packet.maskSHA256,
                "nativeDimensions": [width, height], "effectiveErasureBinary": true,
                "originalSourceFilesOpened": true, "originalRGBComputationOnly": true,
                "originalBoundaryRGBDecoded": false, "sourceOpaqueProofStatus": "not-evaluated-context-skipped",
                "contextAvailable": false, "legacyCurrentContextInstalled": false,
                "cohortBoundaryContextInstalled": false, "imageViewed": false,
                "stageMainRFretainedSourceRiskAvailable": false, "fullMainPipelineParity": false], true)
        }
        let decoded = try NativeRFDETRSourceImage.decode(original)
        erased = erased.map { $0 == 0 ? 0 : 255 }
        let opaque = NativeSourcePhysicalInteriorContext.opaqueSourceProof(original)
        guard let context = NativeSourcePhysicalInteriorContext(rgb: Array(decoded.rgb), width: width, height: height,
            erased: erased, sourceIdentity: decoded.identity, sourceOpaque: opaque) else {
            throw NativeAOTRawTextPainter.Failure.invalidGeometry
        }
        let cohortOnly = packet.purpose == .cohortBoundaryOnly
        return (context, ["authority": packet.authority,
            "purpose": packet.purpose?.rawValue ?? "legacy-physical-context",
            "legacyCurrentContextInstalled": !cohortOnly, "cohortBoundaryContextInstalled": cohortOnly,
            "sourcePath": packet.sourcePath,
            "sourceSHA256": packet.sourceSHA256, "maskPath": packet.maskPath, "maskSHA256": packet.maskSHA256,
            "sourceIdentity": decoded.identity, "nativeDimensions": [width, height],
            "originalSourceFilesOpened": true, "originalRGBComputationOnly": true, "imageViewed": false,
            "sourceOpaqueProof": opaque, "sourceDecoder": "NativeRFDETRSourceImage.decode; original top-left native RGB",
            "effectiveErasureBinary": true, "contextAvailable": true,
            "stageMainRFretainedSourceRiskAvailable": false, "fullMainPipelineParity": false], cohortOnly)
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 3 else { return 2 }
        var stage="request decoding"
        do {
            let input=URL(fileURLWithPath:arguments[1]),out=URL(fileURLWithPath:arguments[2])
            let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:input)) as? [String:Any]
            guard let pages=doc?["pages"] as? [[String:Any]],!pages.isEmpty,pages.count<=1000 else { throw NativeAOTRawTextPainter.Failure.invalidGeometry }
            let savedInputs: SavedAppearanceInputs?
            if let packet = doc?["savedAcceptedAppearanceInput"] { savedInputs = try SavedAppearanceInputs(packet, pages: pages) }
            else { savedInputs = nil }
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            var reports:[[String:Any]]=[]
            var restoredRGBRead=false
            var originalSourceFilesOpened=false
            for page in pages {
                stage="page geometry"
                guard let ident=page["page"] as? String,!ident.isEmpty,ident.count<=64,
                      ident.allSatisfy({ $0.isLetter || $0.isNumber || $0=="-" || $0=="_" }),
                      let width=page["width"] as? Int,let height=page["height"] as? Int,
                      width>0,height>0,width<=16_000_000/height,
                      let rawItems=page["items"] as? [[String:Any]],rawItems.count<=256,
                      let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw NativeAOTRawTextPainter.Failure.invalidGeometry }
                let background:CGImage
                var backgroundBinding:[String:Any]=["kind":"neutral-gray-probe","restoredRGBRead":false]
                var restorationInput: RestoredInput?
                if let supplied=page["restoredInput"] {
                    let packet=try JSONDecoder().decode(RestoredInput.self,
                        from:JSONSerialization.data(withJSONObject:supplied))
                    restorationInput=packet
                    guard page["inputAuthority"] as? String == "saved-accepted-display-replay",
                          !packet.path.isEmpty,packet.encodedSHA256.count==64,
                          packet.encodedSHA256.allSatisfy({$0.isHexDigit}) else {throw NativeAOTRawTextPainter.Failure.invalidGeometry}
                    if packet.authority == .sourcePassThrough {
                        guard rawItems.isEmpty,savedInputs != nil,
                              let source=page["sourceBoundaryInput"] as? [String:Any],
                              source["sourcePath"] as? String == packet.path,
                              source["sourceSHA256"] as? String == packet.encodedSHA256 else {
                            throw NativeOperationalAppearance.Failure.sourceMismatch
                        }
                    }
                    let data=try Data(contentsOf:URL(fileURLWithPath:packet.path))
                    let digest=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
                    guard digest==packet.encodedSHA256,
                          let source=CGImageSourceCreateWithData(data as CFData,nil),
                          let image=CGImageSourceCreateImageAtIndex(source,0,nil),
                          image.width==width,image.height==height else {throw NativeAOTRawTextPainter.Failure.invalidGeometry}
                    background=image
                    if packet.authority == .aot {
                        restoredRGBRead=true
                        backgroundBinding=["kind":"hash-bound-AOT-restored-replay","restoredRGBRead":true,
                            "encodedSHA256":digest,"originalSourceFileOpened":false,"imageViewed":false]
                    } else {
                        originalSourceFilesOpened=true
                        backgroundBinding=["kind":packet.authority.rawValue,"restoredRGBRead":false,
                            "encodedSHA256":digest,"originalSourceFileOpened":true,"imageViewed":false,
                            "appliedMaskPixels":0,"AOTCalls":0,"AOTRestorationClaimed":false]
                    }
                } else {
                    context.setFillColor(CGColor(gray:0.5,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
                    guard let neutral=context.makeImage() else {throw NativeAOTRawTextPainter.Failure.allocation}
                    background=neutral
                }
                var sourceBoundaryContext: NativeSourcePhysicalInteriorContext?
                var sourceBoundaryBinding: [String:Any]?
                var sourceBoundaryCohortOnly = false
                if let packet = page["sourceBoundaryInput"] {
                    stage="source boundary authentication: \(ident)"
                    guard page["inputAuthority"] as? String == "saved-accepted-display-replay" else {
                        throw NativeAOTRawTextPainter.Failure.invalidGeometry
                    }
                    // Experimental host-only allocation preflight. Defaults OFF.
                    // Authentication, dimensions and binary mask checks always run.
                    let preflight = ProcessInfo.processInfo.environment["AIDOKU_HOST_BOUNDARY_CONTEXT_PREFLIGHT"] == "1"
                    var allocate = true, reason = "preflight-disabled-or-legacy-purpose"
                    if preflight, (packet as? [String:Any])?["purpose"] as? String == "cohort-boundary-only" {
                        let roundedMayConsume = ProcessInfo.processInfo.environment["AIDOKU_ROUNDED_SOURCE_JOINS"] == "1" ||
                            ProcessInfo.processInfo.environment["AIDOKU_NATIVE_ROUNDED_CONTOUR_BINDING"] == "1"
                        if roundedMayConsume || page["inferExpansionFromRF"] as? Bool == true {
                            reason = "conservative-keep-rounded-or-later-expansion"
                        } else if !NativeSourceCohortCenterBalance.enabled {
                            allocate = false; reason = "cohort-and-rounded-consumers-disabled"
                        } else if let eligible = try? NativeSourceCohortCenterBalance.requiresOriginalBoundaryContext(
                            rawItems:rawItems,renderedOwnerIDs:Set(rawItems.compactMap {$0["id"] as? String})) {
                            allocate = eligible; reason = eligible ? "eligible-complete-cohort" : "no-eligible-complete-cohort"
                        } else {
                            reason = "preflight-unknown-keep-context"
                        }
                    }
                    let bound = try sourceBoundary(packet,width:width,height:height,allocateContext:allocate)
                    sourceBoundaryContext = bound.context; sourceBoundaryBinding = bound.audit
                    if preflight {
                        sourceBoundaryBinding?["allocationPreflight"] = ["enabled":true,"reason":reason,
                            "contextAllocated":bound.context != nil,"sourceAndMaskAuthenticationRetained":true]
                    }
                    sourceBoundaryCohortOnly = bound.cohortOnly
                    originalSourceFilesOpened = true
                }
                let savedAppearance = try savedInputs?.authenticate(page, rows: rawItems, width: width, height: height)
                if restorationInput?.authority == .sourcePassThrough {
                    guard rawItems.isEmpty,let savedAppearance,
                          let owners=savedAppearance.audit["authenticatedOwners"] as? [String],owners.isEmpty else {
                        throw NativeOperationalAppearance.Failure.sourceMismatch
                    }
                    backgroundBinding["nativeEmptyOwnersAuthenticated"]=true
                }
                var options:[[String:Any]]=[],items:[NativeAOTRawTextPainter.Item]=[]
                for row in rawItems {
                    stage="item geometry: \(row["id"]as?String ?? "unknown")"
                    guard let id=row["id"] as? String,let text=row["text"] as? String,!text.isEmpty,
                          let r=row["frame"] as? [Double],r.count==4,r.allSatisfy(\.isFinite),r[2]>0,r[3]>0,
                          let font=row["fontReference"] as? Double,font.isFinite,font>0,
                          let rgb=row["fill"] as? [Double],rgb.count==3,rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
                          let colour=CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:rgb.map { CGFloat($0/255) }+[1])
                    else { throw NativeAOTRawTextPainter.Failure.invalidGeometry }
                    var raw=row
                    var allocated=r
                    if page["renderReplayUseLayoutFrame"] as? Bool == true {
                        guard page["inputAuthority"] as? String == "saved-accepted-display-replay" else {
                            throw NativeAOTRawTextPainter.Failure.invalidGeometry
                        }
                        if let supplied=row["layoutFrame"] {
                            guard let box=supplied as? [Double],box.count==4,box.allSatisfy(\.isFinite),box[2]>0,box[3]>0,
                                  (box[0]+box[2]).isFinite,(box[1]+box[3]).isFinite else {
                                throw NativeAOTRawTextPainter.Failure.invalidGeometry
                            }
                            let proposal=CGRect(x:box[0],y:box[1],width:box[2],height:box[3])
                            let pageBounds=CGRect(x:0,y:0,width:width,height:height)
                            let legacyContained=pageBounds.insetBy(dx:-1,dy:-1).contains(proposal)
                            // SavedAcceptedCorpus has authenticated the complete item,
                            // including its original saved audit layoutFrame. This is a
                            // shaping proposal, not retained styled-alpha admission.
                            let overlap=proposal.intersection(pageBounds)
                            let authenticatedSavedProposal=savedAppearance != nil && !overlap.isNull && !overlap.isEmpty
                            guard legacyContained || authenticatedSavedProposal else {
                                throw NativeAOTRawTextPainter.Failure.invalidGeometry
                            }
                            allocated=box
                        }
                    }
                    // Allocation and source anchors are distinct. A saved render
                    // box must never replace the original source-bound geometry.
                    raw["sourceBounds"]=try sourceBoundsForRaw(frame:r,explicit:row["sourceBounds"],
                        width:Double(width),height:Double(height))
                    raw["rawPainterSourceBoundsAuthority"]=row["sourceBounds"] == nil
                        ? "legacy-normalized-frame" : "explicit-normalized-original-sourceBounds;caller-frame-separate"
                    raw["fontSize"]=font;raw["renderPreserveRequestedFontSize"]=true
                    // Explicit saved-display replay may have a different source
                    // effect denominator. Never reinterpret it as fresh inference.
                    if let supplied=row["sourceFontSize"] {
                        guard let sourceFont=supplied as? Double,sourceFont.isFinite,sourceFont>0 else {
                            throw NativeAOTRawTextPainter.Failure.invalidGeometry
                        }
                        raw["sourceFontSize"]=sourceFont
                    } else {raw["sourceFontSize"]=font}
                    raw["ensembleLockLayout"]=false;raw["ensembleDisplayStroke"]=row["outline"]
                    if let supplied=row["renderReplayStrokeRatio"] {
                        guard page["inputAuthority"] as? String == "saved-accepted-display-replay",
                              let ratio=supplied as? Double,ratio.isFinite,ratio>0,ratio<=4 else {
                            throw NativeAOTRawTextPainter.Failure.invalidGeometry
                        }
                        raw["ensembleStrokeRatio"]=ratio
                    } else {raw["ensembleStrokeRatio"]=max(0.035,(row["outlineWidth"] as? Double ?? 0)/font)}
                    options.append(raw)
                    items.append(.init(id:id,text:text,frame:CGRect(x:allocated[0],y:allocated[1],width:allocated[2],height:allocated[3]),
                        fontSize:font,lineHeight:font*(row["lineHeightEm"] as? Double ?? 1.4),chosenFill:colour,
                        colorAuthority:"Explicit offline source-observed packet; no live style inference claimed"))
                }
                guard Set(items.map(\.id)).count==items.count else { throw NativeAOTRawTextPainter.Failure.invalidGeometry }
                if page["inferExpansionFromRF"] as? Bool == true {
                    let regions=try (page["rfRegions"] as? [[String:Any]] ?? []).enumerated().map { index,raw -> Ensemble100RFRegion in
                        guard let cls=raw["classID"] as? Int,let score=raw["confidence"] as? Double,
                              let box=raw["bounds"] as? [Double],NativeTextExpansionPolicy.validRect(box),
                              let points=raw["exterior"] as? [[Double]],points.isEmpty || points.count>=3,
                              points.allSatisfy({ $0.count==2 && $0.allSatisfy(\.isFinite) }) else { throw NativeAOTRawTextPainter.Failure.invalidGeometry }
                        return .init(queryID:index,classID:cls,confidence:score,
                            bounds:CGRect(x:box[0],y:box[1],width:box[2],height:box[3]),
                            exterior:points.map {CGPoint(x:$0[0],y:$0[1])},holes:[])
                    }
                    options=try NativeOperationalRenderExpansion.annotate(items:options,viewport:CGSize(width:width,height:height),source:background,regions:regions)
                }
                // Optional PAGE policy is separate from authenticated saved raw headers.
                // SavedAppearanceInputs.authenticate above always runs first, unchanged.
                let fitPolicy: NativeCohortFitPlanner.Policy?
                if let supplied = page["cohortFitPlanning"] {
                    guard savedAppearance != nil,
                          page["inputAuthority"] as? String == "saved-accepted-display-replay" else {
                        throw NativeCohortFitPlanner.Failure.invalidPolicy
                    }
                    try NativeCohortFitPlanner.requireCompletePeerContext(page["completePeerContext"])
                    fitPolicy = try NativeCohortFitPlanner.explicitHostPolicy(supplied,
                        items:items,declaredRaw:rawItems)
                } else { fitPolicy = nil } // strict replay remains the default
                var cohortFitAudit: [String:Any]?
                stage="production renderer: \(ident)"
                let render = {
                    try NativeOperationalAppearance.$savedAcceptedPage.withValue(savedAppearance) {
                    let renderRequest: ([NativeAOTRawTextPainter.Item]) throws -> NativeAOTTranslationPageComposer.TextLayer = { request in
                        try NativeAOTRawTextPainter.renderCentered(items:request,rawItems:options,
                            viewport:CGSize(width:width,height:height),restored:background,allowShrink:false,
                            completePeerContext:page["completePeerContext"]as?Bool ?? true)
                    }
                    guard let fitPolicy else { return try renderRequest(items) }
                    return try NativeCohortFitPlanner.run(items:items,authenticatedOptions:options,
                        declaredRaw:rawItems,membershipRaw:options,policy:fitPolicy,
                        outputScale:CGFloat(background.width)/CGFloat(width),
                        record:{ receipt in
                            cohortFitAudit = receipt
                            if let data = try? JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]) {
                                FileHandle.standardError.write(Data("COHORT_FIT_RECEIPT ".utf8) + data + Data("\n".utf8))
                            }
                        },render:renderRequest).layer
                    }
                }
                let layer: NativeAOTTranslationPageComposer.TextLayer = try NativeSourceObstructionRecovery.$sourceContext.withValue(
                    ProcessInfo.processInfo.environment["AIDOKU_SOURCE_OBSTRUCTION_QUALITY"] == "0" ? nil:sourceBoundaryContext) {
                    // Explicit nil scope also isolates absent/skipped contexts in nested calls.
                    if let sourceBoundaryContext {
                        if sourceBoundaryCohortOnly {
                            return try NativeSourcePhysicalInteriorContext.$current.withValue(nil) {
                                try NativeSourcePhysicalInteriorContext.$cohortBoundaryContext.withValue(sourceBoundaryContext) {try render()}
                            }
                        }
                        return try NativeSourcePhysicalInteriorContext.$current.withValue(sourceBoundaryContext) {try render()}
                    } else if sourceBoundaryCohortOnly && sourceBoundaryBinding != nil {
                        return try NativeSourcePhysicalInteriorContext.$current.withValue(nil) {
                            try NativeSourcePhysicalInteriorContext.$cohortBoundaryContext.withValue(nil) {try render()}
                        }
                    }
                    return try render()
                }
                stage="text retention: \(ident)"
                guard layer.complete,layer.expectedItems==items.count,layer.paintedItems==items.count else { throw NativeAOTRawTextPainter.Failure.invalidGeometry }
                let target=out.appendingPathComponent(ident+".png")
                guard let destination=CGImageDestinationCreateWithURL(target as CFURL,UTType.png.identifier as CFString,1,nil) else { throw NativeAOTRawTextPainter.Failure.allocation }
                CGImageDestinationAddImage(destination,layer.image,nil)
                guard CGImageDestinationFinalize(destination) else { throw NativeAOTRawTextPainter.Failure.allocation }
                var report:[String:Any]=["page":ident,"expectedItems":layer.expectedItems,"paintedItems":layer.paintedItems,
                    "complete":layer.complete,"output":target.path,"audit":layer.audit,
                    "inputAuthority":page["inputAuthority"] ?? "explicit-neutral-offline-probe",
                    "nativeDisplayStrokeFloorPixels":2,"sourceInferenceExecuted":false,
                    "renderReplayUseLayoutFrame":page["renderReplayUseLayoutFrame"] as? Bool ?? false,
                    "backgroundBinding":backgroundBinding]
                if let savedAppearance {
                    report["savedAcceptedAppearanceBinding"] = savedAppearance.audit
                    let raw = layer.audit["rawNativeItems"] as? [[String:Any]] ?? []
                    report["actualSourceContourOnlyOwners"] = raw.filter { $0["sourceContourOnly"] as? Bool == true }.count
                    let painted = layer.audit["sourceStylePaint"] as? [[String:Any]] ?? []
                    report["actualRoundedContourPaintOwners"] = painted.filter { $0["roundedSourceContourBinding"] is String }.count
                }
                if let cohortFitAudit { report["cohortFitPlanning"] = cohortFitAudit }
                report["sourceObstructionQualityContextInstalled"] = sourceBoundaryContext != nil && ProcessInfo.processInfo.environment["AIDOKU_SOURCE_OBSTRUCTION_QUALITY"] != "0"
                report["originalSourceFilesOpened"] = sourceBoundaryBinding != nil
                if let sourceBoundaryBinding {
                    report["sourceBoundaryBinding"] = sourceBoundaryBinding
                    report["sourceBoundaryContextInstalled"] = sourceBoundaryContext != nil
                    report["sourceBoundaryPurpose"] = sourceBoundaryBinding["purpose"]
                    report["legacyCurrentContextInstalled"] = sourceBoundaryContext != nil && !sourceBoundaryCohortOnly
                    report["cohortBoundaryContextInstalled"] = sourceBoundaryContext != nil && sourceBoundaryCohortOnly
                    report["stageMainRFretainedSourceRiskAvailable"] = false
                    report["fullMainPipelineParity"] = false
                    report["replayLimit"] = sourceBoundaryContext != nil
                        ? "Actual production painter with original-source physical context; no upstream source inference or main RF retained-source-risk gate"
                        : "Actual production painter; original source/mask authenticated, unused boundary context skipped; saved appearance may independently decode source"
                }
                // Geometry-only replay already stores every unchanged policy in
                // its request. Avoid duplicating dense mask rows in each A/B log.
                if page["omitExpansionPoliciesFromReport"] as? Bool == true,
                   page["inferExpansionFromRF"] as? Bool != true {
                    report["expansionPolicyReportAuthority"]="unchanged explicit request; no RF expansion inference"
                } else {
                    report["expansionPolicies"]=options.map { ["id":$0["id"] ?? NSNull(),"policy":$0["textExpansionPolicy"] ?? NSNull(),
                        "authority":$0["renderExpansionBoundaryAuthority"] ?? NSNull()] }
                }
                reports.append(report)
            }
            try savedInputs?.verifyUnchanged()
            let result:[String:Any]=["pages":reports,"productionPainter":"NativeAOTRawTextPainter.renderCentered",
                "sourceRGBRead":restoredRGBRead || originalSourceFilesOpened,"originalSourceFilesOpened":originalSourceFilesOpened,
                "RGBReadScope":originalSourceFilesOpened ? "explicit hash-bound original source/effective erasure and selected painter background; computational only" :
                    (restoredRGBRead ? "supplied authenticated AOT restored canvas; computational only":"neutral probe only"),
                "sourceInferenceExecuted":false,"stageMainRFretainedSourceRiskAvailable":false,"fullMainPipelineParity":false,
                "promptVersion":"R143-technical-15crop-v2",
                "unrestrictedRGBViewed":false,"GTAtInference":false,"OCRCalls":0,"providerCalls":0,"modelCalls":0]
            try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:out.appendingPathComponent("REPORT.json"),options:.atomic)
            print("RAW_TEXT_RENDER_PASS pages=\(reports.count)")
            return 0
        } catch {
            fputs("Raw production text render failed during \(stage): \(error)\n",stderr);return 1
        }
    }
}
