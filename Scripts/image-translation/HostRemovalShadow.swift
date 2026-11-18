import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Mask-only diagnostic of actual native source removal. No AOT, appearance
/// annotation, translation, display shaping, composite, or accepted-file writes.
@available(macOS 15.0, *)
enum HostRemovalShadow {
    private enum Failure: Error { case invalid(String) }
    private static func require(_ value: Bool, _ reason: String) throws {
        guard value else { throw Failure.invalid(reason) }
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func read(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.invalid("JSON object: \(url.path)")
        }
        return object
    }
    private static func write(_ object: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: url, options: .atomic)
    }
    private static func bound(_ descriptor: Any?) throws -> (url: URL, data: Data) {
        guard let row = descriptor as? [String: Any], let path = row["path"] as? String,
              let expected = row["SHA256"] as? String else { throw Failure.invalid("file descriptor") }
        let url = URL(fileURLWithPath: path), data = try Data(contentsOf: url)
        try require(sha(data) == expected, "file SHA: \(path)")
        return (url, data)
    }
    private static func image(_ data: Data) throws -> CGImage {
        guard let decoder = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else { throw Failure.invalid("image decode") }
        return image
    }
    private static func maskBytes(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        try require(image.width == width && image.height == height, "mask dimensions")
        var bytes = [UInt8](repeating: 0, count: width * height)
        let converted = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try require(converted && bytes.allSatisfy { $0 == 0 || $0 == 1 || $0 == 255 }, "binary mask conversion")
        return bytes.map { $0 == 0 ? 0 : 255 }
    }
    private static func saveMask(_ bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard bytes.count == width * height, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalid("mask output")
        }
        CGImageDestinationAddImage(output, image, nil)
        try require(CGImageDestinationFinalize(output), "mask PNG finalize")
        let reopened = try maskBytes(self.image(Data(contentsOf: url)), width: width, height: height)
        try require(reopened == bytes, "mask PNG roundtrip")
    }

    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 3 else {
            fputs("Usage: --native-removal-shadow REQUEST.json OUTPUT_DIRECTORY\n", stderr); return 2
        }
        return await Task.detached(priority: .userInitiated) {
            do { return try execute(request: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2])) }
            catch { fputs("Native removal shadow failed: \(error)\n", stderr); return Int32(1) }
        }.value
    }

    private static func execute(request: URL, output: URL) throws -> Int32 {
        let started = Date(), manager = FileManager.default
        let output = output.standardizedFileURL.resolvingSymlinksInPath()
        let requestData = try Data(contentsOf: request), document = try read(request)
        guard document["schema"] as? String == "native-removal-shadow-v1",
              let pages = document["pages"] as? [[String: Any]], !pages.isEmpty, pages.count <= 16,
              let hashes = document["inputSHA256"] as? [String: String], !hashes.isEmpty,
              let rootPath = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"],
              let bundlePath = document["modelBundle"] as? String, let bundle = Bundle(path: bundlePath),
              let compiled = bundle.url(forResource: "KoharuHighres648FP16", withExtension: "mlmodelc") else {
            throw Failure.invalid("request/root/existing native model bundle; no model preparation/download is performed")
        }
        try require(manager.fileExists(atPath: compiled.path) && !manager.fileExists(atPath: output.path), "existing compiled model / fresh output")
        try require(!request.standardizedFileURL.path.hasPrefix(output.path + "/"), "output contains request")
        func authenticateInputs() throws {
            for (path, expected) in hashes {
                try require(!URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(output.path + "/"), "output contains an input")
                try require(sha(try Data(contentsOf: URL(fileURLWithPath: path))) == expected, "input changed: \(path)")
            }
        }
        try authenticateInputs()
        // The early CLI branch deliberately bypasses HostEnvironment.load and
        // HostResources.prepare (which can compile models). Install the same
        // executable backend explicitly, with already present model resources.
        setenv("AIDOKU_HOST_MODEL_BUNDLE", bundlePath, 1)
        HostOperationalAppearance.install(root: URL(fileURLWithPath: rootPath))
        let parameters = try NativeMainEnsembleConfiguration.parameters()["06"] ?? [:]
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        var reports: [[String: Any]] = [], ids = Set<String>(), failed = 0
        for row in pages {
            guard let id = row["page"] as? String, !id.isEmpty, id.count <= 64,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), ids.insert(id).inserted else {
                throw Failure.invalid("duplicate/invalid diagnostic identity")
            }
            do {
                let report = try autoreleasepool { try page(row, output: output.appendingPathComponent(id), parameters: parameters) }
                reports.append(report)
                print("NATIVE_REMOVAL_SHADOW \(id) additions=\(report["addedPixels"]!) removals=\(report["removedPixels"]!)")
            } catch {
                if error is CancellationError { throw error }
                failed += 1
                let failure: [String: Any] = ["page": id, "status": "failed-no-fallback", "error": String(reflecting: error)]
                reports.append(failure)
                try write(failure, output.appendingPathComponent("\(id)/FAILURE.json"))
                fputs("Native removal shadow \(id) failed: \(error)\n", stderr)
            }
        }
        try require(try Data(contentsOf: request) == requestData, "request changed during execution")
        try authenticateInputs()
        let report: [String: Any] = ["schema": "native-removal-shadow-report-v1", "requestSHA256": sha(requestData),
            "request": request.path, "complete": failed == 0, "failedPages": failed, "pages": reports,
            "inputSHA256": hashes, "parameters06": parameters, "modelBundle": bundlePath,
            "backendInstalled": "HostOperationalAppearance.install", "freshSelectedSegmentation": true,
            "entrypoint": "NativeMainAOTRemovalMaskBuilder.buildWithAudit; selectedSegmentation:nil",
            "AOTCalls": 0, "translationCalls": 0, "textRenderCalls": 0, "RGBImageExports": 0, "imageViews": 0,
            "GTUsed": false, "acceptedFilesChanged": false, "qualityAccepted": false,
            "currentRetainedTargetOwnershipParityEstablished": false, "safeToComposeWithCurrentRetainedText": false,
            "scope": "Fresh native mask against authenticated saved raw erasure ledger, including held owners; not a current retained rendering admission",
            "seconds": Date().timeIntervalSince(started)]
        try write(report, output.appendingPathComponent("NATIVE-REMOVAL-SHADOW.json"))
        return failed == 0 ? 0 : 1
    }

    private static func page(_ row: [String: Any], output: URL, parameters: [String: Double]) throws -> [String: Any] {
        let started = Date(), sourceFile = try bound(row["source"]), payloadFile = try bound(row["rawPayload"])
        let cachedFile = try bound(row["cachedMask"]), source = try image(sourceFile.data)
        let width = source.width, height = source.height
        try require(width > 0 && height > 0 && width <= 16_777_216 / height, "source pixel budget")
        guard let payloadEnvelope = try JSONSerialization.jsonObject(with: payloadFile.data) as? [String: Any],
              let payload = payloadEnvelope["value"] as? [String: Any], let layoutJSON = payload["nativeLayout"],
              let evidence = row["runtimeEvidence"] as? [String: Any],
              let payloadEvidence = payload["nativeEnsembleEvidence"] as? [String: Any],
              NSDictionary(dictionary: evidence).isEqual(to: payloadEvidence),
              evidence["sourceSHA256"] as? String == sha(sourceFile.data),
              evidence["rfBodies"] is String, evidence["rfAllBoxes"] is String,
              evidence["probability"] is [String: Any], evidence["cachedRestoration"] == nil else {
            throw Failure.invalid("authentic payload/runtime evidence; cached restoration is forbidden")
        }
        let layout = try JSONDecoder().decode(NativeTranslationLayout.self,
            from: JSONSerialization.data(withJSONObject: layoutJSON))
        try require(layout.imageSize == CGSize(width: width, height: height), "layout source dimensions")
        let mapper = try NativeMainEnsembleRenderer.sourceLocalMapper(layout: layout, source: source)
        let raw = layout.items.map { mapper.map($0.payload) }
        try require(raw.count <= 256, "raw owner budget")
        // Exact source instance is retained through registration, probability,
        // revision validation, fresh selected segmentation and builder execution.
        try HostEnsembleEvidence.register(evidence, sourceURL: sourceFile.url, image: source)
        let actual = try NativeMainEnsembleEvidenceStore.shared.evidence(original: source)
        guard let probability = actual.probability, probability.original === source else { throw Failure.invalid("missing same-object actual DB") }
        var removalItems = raw, revisions: [[String: Any]] = []
        if let data = try NativeMainEnsembleEvidenceStore.shared.sourceRevision(original: source) {
            guard let revision = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid("source revision") }
            let resolved = try NativeMainSourceRevision.validate(revision, displayItems: raw,
                imageSize: CGSize(width: width, height: height),
                canonicalSourceIdentity: try NativeMainEnsembleOCREvidence.liveBinding(original: source).candidateIdentity,
                localize: { original in
                    let typed = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                        from: JSONSerialization.data(withJSONObject: original))
                    return mapper.map(typed.payload)
                })
            removalItems = resolved.removalItems; revisions = resolved.transactions
        }
        let cached = try maskBytes(image(cachedFile.data), width: width, height: height)
        let buildStarted = Date()
        let built = try NativeMainAOTRemovalMaskBuilder.buildWithAudit(original: source, items: removalItems,
            rfRegions: actual.regions, parameters: parameters, probability: probability,
            unownedMasks: [], sourceDisplayItems: raw, selectedSegmentation: nil)
        let buildSeconds = Date().timeIntervalSince(buildStarted)
        try require(built.ownership.original === source && built.ownership.owners.count == removalItems.count,
            "same-object complete erasure-owner inventory")
        let fresh = try maskBytes(built.mask, width: width, height: height)
        guard let factory = built.audit["factoryEvidence"] as? [String: Any],
              let selected = factory["acceptedFinalSegmentation"] as? [String: Any], selected["executed"] as? Bool == true,
              factory["nativeSourceSegmentationProducer"] is [String: Any] else {
            throw Failure.invalid("fresh production selected segmentation did not execute; no fallback output")
        }
        var additions = [UInt8](repeating: 0, count: fresh.count), removals = additions
        var added = 0, removed = 0, oldPixels = 0, newPixels = 0
        for p in fresh.indices {
            if cached[p] != 0 { oldPixels += 1 }; if fresh[p] != 0 { newPixels += 1 }
            if fresh[p] != 0 && cached[p] == 0 { additions[p] = 255; added += 1 }
            if fresh[p] == 0 && cached[p] != 0 { removals[p] = 255; removed += 1 }
        }
        try saveMask(fresh, width: width, height: height, to: output.appendingPathComponent("mask.png"))
        try saveMask(additions, width: width, height: height, to: output.appendingPathComponent("additions.png"))
        try saveMask(removals, width: width, height: height, to: output.appendingPathComponent("removals.png"))
        let ownership = try ownershipEvidence(built.ownership, raw: removalItems, cached: cached, fresh: fresh, output: output)
        try write(built.audit, output.appendingPathComponent("STAGE-AUDIT.json"))
        // Full raw source ledger is exported as JSON for the parent's ownership
        // comparison. It is not replaced by the current retained display set.
        try write(["rawDisplayItems": raw, "originalRemovalItems": removalItems,
            "sourceRevisionTransactions": revisions, "sourceLocalScale": [Double(mapper.sx), Double(mapper.sy)],
            "sourceSHA256": sha(sourceFile.data), "builderOwnership": ownership], output.appendingPathComponent("ERASURE-OWNERS.json"))
        let report: [String: Any] = ["page": row["page"]!, "status": "shadow-complete-not-admitted",
            "source": row["source"]!, "rawPayload": row["rawPayload"]!, "cachedMask": row["cachedMask"]!,
            "width": width, "height": height, "rawDisplayOwners": raw.count, "erasureOwners": removalItems.count,
            "sourceRevisionApplied": !revisions.isEmpty, "sourceLocalScale": [Double(mapper.sx), Double(mapper.sy)],
            "sameOriginalObjectBound": true, "probabilityWidth": probability.width, "probabilityHeight": probability.height,
            "rfRegionCount": actual.regions.count, "cachedMaskPixels": oldPixels, "freshMaskPixels": newPixels,
            "cachedBinarySHA256": sha(Data(cached)), "freshBinarySHA256": sha(Data(fresh)),
            "cachedEncodedSHA256": sha(cachedFile.data), "freshEncodedSHA256": sha(try Data(contentsOf: output.appendingPathComponent("mask.png"))),
            "addedPixels": added, "removedPixels": removed, "pixelExactWithCache": added == 0 && removed == 0,
            "ownershipEvidence": ownership, "stageAudit": output.appendingPathComponent("STAGE-AUDIT.json").path,
            "erasureLedger": output.appendingPathComponent("ERASURE-OWNERS.json").path,
            "retainedComparison": row["retainedComparison"] ?? NSNull(), "currentRetainedTargetOwnershipParityEstablished": false,
            "safeToComposeWithCurrentRetainedText": false, "buildSeconds": buildSeconds,
            "seconds": Date().timeIntervalSince(started), "qualityAccepted": false]
        try write(report, output.appendingPathComponent("REPORT.json"))
        return report
    }

    private static func ownershipEvidence(_ ownership: NativeEnsembleRemovalDenseSupport.Ownership,
                                         raw: [[String: Any]], cached: [UInt8], fresh: [UInt8], output: URL) throws -> [String: Any] {
        let w = ownership.original.width, h = ownership.original.height
        func union(preserved: Bool) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h)
            let ok = bytes.withUnsafeMutableBytes { data -> Bool in
                guard let context = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.setAllowsAntialiasing(false); context.setShouldAntialias(false)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                for owner in ownership.owners where owner.preserved == preserved {
                    guard let first = owner.polygon.first else { continue }
                    context.beginPath(); context.move(to: CGPoint(x: first.x * CGFloat(w), y: CGFloat(h) - first.y * CGFloat(h)))
                    for point in owner.polygon.dropFirst() {
                        context.addLine(to: CGPoint(x: point.x * CGFloat(w), y: CGFloat(h) - point.y * CGFloat(h)))
                    }
                    context.closePath(); context.fillPath()
                }
                return true
            }
            try require(ok, "ownership union raster")
            return bytes.map { $0 == 0 ? 0 : 255 }
        }
        var records: [[String: Any]] = []
        for i in raw.indices {
            let owner = ownership.owners[i], item = raw[i]
            records.append(["index": i, "id": item["id"] ?? NSNull(), "held": owner.preserved,
                "translated": !owner.preserved, "keptLettering": item["keptLettering"] ?? NSNull(),
                "sourceTextOnly": item["sourceTextOnly"] ?? NSNull(),
                "sourceBounds": item["sourceBounds"] ?? NSNull(), "inputSourcePolygon": item["sourcePolygon"] ?? NSNull(),
                "builderPolygonNormalized": owner.polygon.map { [Double($0.x), Double($0.y)] },
                "fontPixels": owner.fontPixels as Any? ?? NSNull()])
        }
        var result: [String: Any] = ["owners": records, "heldOwners": ownership.owners.filter(\.preserved).count,
            "translatedOwners": ownership.owners.filter { !$0.preserved }.count,
            "polygonUnionAuthority": "actual builder owner geometry rasterized with binary CG fill; geometry only, not glyph truth or native hard-protection mask"]
        for (name, preserved) in [("held", true), ("translated", false)] {
            let bytes = try union(preserved: preserved), path = output.appendingPathComponent("\(name)-polygon-union.png")
            try saveMask(bytes, width: w, height: h, to: path)
            var pixels = 0, oldErased = 0, newErased = 0, newlyErased = 0
            for i in bytes.indices where bytes[i] != 0 {
                pixels += 1; if cached[i] != 0 { oldErased += 1 }; if fresh[i] != 0 { newErased += 1 }
                if fresh[i] != 0 && cached[i] == 0 { newlyErased += 1 }
            }
            result[name + "Union"] = ["path": path.path, "binarySHA256": sha(Data(bytes)), "pixels": pixels,
                "cachedErasureOverlapPixels": oldErased, "freshErasureOverlapPixels": newErased,
                "newErasureOverlapPixels": newlyErased]
        }
        return result
    }
}
