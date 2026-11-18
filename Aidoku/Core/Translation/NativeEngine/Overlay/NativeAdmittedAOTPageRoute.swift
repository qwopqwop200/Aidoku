import CoreGraphics
import CoreText
import CryptoKit
import Foundation

/// Explicit, non-default vertical slice. The caller supplies a trusted admission,
/// not OCR boxes promoted to masks. No automatic mask/color policy is activated.
@available(iOS 16.0, macOS 13.0, *)
actor NativeAdmittedAOTPageRoute {
    static let shared = NativeAdmittedAOTPageRoute()
    static let revision = "admitted-wholepage-aot1024-retained-text-v2"
    enum Failure: Error { case disabled, resourceLimit, invalidAdmission, staleIdentity, modelMissing, modelContract,
        nonopaqueSource, incompleteText, unsupportedGlyph, clippedText, overlappingText, allocation }

    struct Owner: Codable, Equatable, Sendable {
        let id: String
        let text: String
        /// Source-pixel top-left text frame; no panel/background is painted.
        let rect: [Double]
        let fontName: String
        let fontSize: Double
        let fillRGB: [Double]
        let strokeWhite: Bool
        /// Opt-in certified rows. Nil preserves the existing explicit-frame route.
        let retainedPlan: NativeAOTRetainedTextPlan.Plan?

        init(id: String, text: String, rect: [Double], fontName: String, fontSize: Double,
             fillRGB: [Double], strokeWhite: Bool, retainedPlan: NativeAOTRetainedTextPlan.Plan? = nil) {
            self.id = id; self.text = text; self.rect = rect; self.fontName = fontName; self.fontSize = fontSize
            self.fillRGB = fillRGB; self.strokeWhite = strokeWhite; self.retainedPlan = retainedPlan
        }
    }
    struct Inventory: Codable, Equatable, Sendable {
        let owners: [Owner]
        let language: String
        let settingsRevision: String
        let ownershipPolicyRevision: String
    }
    struct Admission: Codable, Sendable {
        let sourceRGBA256: String
        let binaryMask256: String
        let inventory256: String
        let maskPolicyRevision: String
        let sourceWidth: Int?
        let sourceHeight: Int?

        init(sourceRGBA256: String, binaryMask256: String, inventory256: String, maskPolicyRevision: String,
             sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
            self.sourceRGBA256 = sourceRGBA256; self.binaryMask256 = binaryMask256
            self.inventory256 = inventory256; self.maskPolicyRevision = maskPolicyRevision
            self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        }
    }
    struct Result: @unchecked Sendable {
        let final: CGImage
        let restored: CGImage
        let text: CGImage
        let identity: String
        let audit: Data
    }
    private var resident: NativeAOTResidentModel?
    private var residentIdentity: String?
    private var loads = 0
    private init() {}

    /// The app may enqueue this on memory pressure; never drops tensors mid-page.
    func releaseResidentModel() { resident = nil; residentIdentity = nil }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func inventoryIdentity(_ inventory: Inventory) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(inventory))
    }
    static func rgba(_ source: CGImage) throws -> [UInt8] {
        let w = source.width, h = source.height
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, w <= 12_000_000 / h else { throw Failure.resourceLimit }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.allocation }
            context.setBlendMode(.copy); context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }
    static func image(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.allocation }
        return image
    }

    /// Installed compiled models only. No download, package compilation or cache eviction.
    /// Content hash, not a caller revision string or path, fences resident model reuse.
    static func resolveModel(installedURL: URL?, bundle: Bundle = .main) throws -> (URL, String) {
        guard let url = installedURL ?? bundle.url(forResource: "AOT-1024-FP16", withExtension: "mlmodelc"),
              url.isFileURL, url.pathExtension == "mlmodelc", FileManager.default.fileExists(atPath: url.path),
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { throw Failure.modelMissing }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.modelContract }
        var files: [URL] = []
        for case let file as URL in walker {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw Failure.modelContract }
            if properties.isRegularFile == true { files.append(file) }
        }
        guard !files.isEmpty else { throw Failure.modelMissing }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let relative = String(file.path.dropFirst(url.path.count))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            hasher.update(data: Data("\(relative.utf8.count):\(relative):\(size):".utf8))
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation(); hasher.update(data: chunk)
            }
        }
        return (url, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// No suspension within the transaction: the resident model/tensors are serial.
    /// Current inventory is independently supplied; stale admissions never replay owners.
    func render(source: CGImage, binaryMask: [UInt8], admission: Admission, current: Inventory,
                installedModelURL: URL?, enabled: Bool) throws -> Result {
        try Task.checkCancellation()
        guard enabled else { throw Failure.disabled }
        let start = Date(), w = source.width, h = source.height
        let bytes = try Self.rgba(source)
        guard binaryMask.count == w * h, binaryMask.allSatisfy({ $0 == 0 || $0 == 1 }),
              !admission.maskPolicyRevision.isEmpty, !current.language.isEmpty, !current.settingsRevision.isEmpty,
              !current.ownershipPolicyRevision.isEmpty else { throw Failure.invalidAdmission }
        guard admission.sourceRGBA256 == Self.digest(Data(bytes)), admission.binaryMask256 == Self.digest(Data(binaryMask)),
              admission.inventory256 == (try Self.inventoryIdentity(current)) else { throw Failure.staleIdentity }
        let hasRemoval = binaryMask.contains(1)
        if current.owners.isEmpty {
            guard !hasRemoval else { throw Failure.invalidAdmission }
            let transparent = try Self.context(width: w, height: h)
            guard let text = transparent.makeImage() else { throw Failure.allocation }
            let identity = Self.digest(Data([Self.revision, "identity-zero-target", "\(w)x\(h)", admission.sourceRGBA256,
                admission.binaryMask256, admission.inventory256, admission.maskPolicyRevision].joined(separator: "\n").utf8))
            let audit: [String: Any] = ["route": Self.revision, "identity": identity, "inferenceCalls": 0,
                "ownerCount": 0, "owners": [], "modelLoads": loads, "modelRequired": false,
                "sourceRGBAIdentity": true, "localSeconds": Date().timeIntervalSince(start)]
            try Task.checkCancellation()
            return Result(final: source, restored: source, text: text, identity: identity,
                audit: try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys, .prettyPrinted]))
        }
        // This v1 contract is translate-and-remove only, not an implicit overlay-only
        // or source-only cleanup authorization. Such intents require a distinct API.
        guard hasRemoval else { throw Failure.invalidAdmission }
        guard admission.sourceWidth == w, admission.sourceHeight == h else { throw Failure.staleIdentity }
        guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else { throw Failure.nonopaqueSource }
        // Shape and certify completeness before spending an inference. Never return a
        // restored page after a missing/unsupported/clipped/overlapping owner failure.
        let shapeStart = Date()
        let layer = try Self.textLayer(inventory: current, width: w, height: h, sourceRGBA256: admission.sourceRGBA256)
        let shapeSeconds = Date().timeIntervalSince(shapeStart), hashStart = Date()
        let (modelURL, modelID) = try Self.resolveModel(installedURL: installedModelURL)
        let modelHashSeconds = Date().timeIntervalSince(hashStart)
        let identity = Self.digest(Data([Self.revision, "\(w)x\(h)", admission.sourceRGBA256, admission.binaryMask256,
            admission.inventory256, admission.maskPolicyRevision, modelID].joined(separator: "\n").utf8))
        var modelLoadSeconds: Double = 0
        if residentIdentity != modelID {
            resident = nil; residentIdentity = nil
            let loadStart = Date()
            resident = try NativeAOTResidentModel(compiledURL: modelURL)
            modelLoadSeconds = Date().timeIntervalSince(loadStart)
            residentIdentity = modelID; loads += 1
        }
        try Task.checkCancellation()
        let inferenceStart = Date()
        guard let resident else { throw Failure.modelContract }
        let restored = try resident.restore(rgba: bytes, removal: binaryMask, width: w, height: h)
        let aotSeconds = Date().timeIntervalSince(inferenceStart)
        try Task.checkCancellation()
        let context = try Self.context(width: w, height: h)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        context.setBlendMode(.copy); context.draw(restored, in: bounds)
        context.setBlendMode(.normal); context.draw(layer.0, in: bounds)
        guard let final = context.makeImage() else { throw Failure.allocation }
        try Task.checkCancellation()
        let audit: [String: Any] = ["route": Self.revision, "identity": identity, "modelSHA256": modelID,
            "inventorySHA256": admission.inventory256, "sourceSHA256": admission.sourceRGBA256,
            "maskSHA256": admission.binaryMask256, "modelLoads": loads, "inferenceCalls": 1,
            "ownerCount": current.owners.count, "owners": layer.1, "aotSeconds": aotSeconds,
            "modelContentHashSeconds": modelHashSeconds, "modelLoadSeconds": modelLoadSeconds, "shapeSeconds": shapeSeconds,
            "aotPreprocessingSeconds": resident.preprocessingSeconds, "modelPredictionSeconds": resident.predictionSeconds,
            "aotScatterSeconds": resident.scatterSeconds,
            "localSeconds": Date().timeIntervalSince(start), "automaticMaskAndColorPolicy": "HOLD",
            "transport": "wholepage area-anyhit/top-left edge RGB/zero mask padding/half-pixel scatter",
            "scope": "explicit admitted opaque source; no OCR/RF/translation calls; host is not phone",
            "outsideMaskWriteAuthority": "original binary mask only", "strokePass": "all outlines then all fills"]
        return Result(final: final, restored: restored, text: layer.0, identity: identity,
            audit: try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys, .prettyPrinted]))
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.allocation }
        return context
    }

    // Shared only with the source-bound optional support/cached-AOT transaction.
    static func textLayer(inventory: Inventory, width: Int, height: Int,
                          sourceRGBA256: String? = nil) throws -> (CGImage, [[String: Any]]) {
        guard inventory.owners.count <= 256, inventory.owners.reduce(0, { $0 + $1.text.utf16.count }) <= 65_536,
              Set(inventory.owners.map(\.id)).count == inventory.owners.count else {
            throw Failure.invalidAdmission
        }
        if inventory.owners.contains(where: { $0.retainedPlan != nil }) {
            guard inventory.owners.allSatisfy({ $0.retainedPlan != nil }), let sourceRGBA256 else {
                throw Failure.invalidAdmission
            }
            return try NativeAOTRetainedTextPlan.render(inventory.owners, width: width, height: height,
                sourceRGBA256: sourceRGBA256)
        }
        var paths: [(Owner, CGPath, CGFloat)] = [], boxes: [CGRect] = [], audit: [[String: Any]] = []
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        for owner in inventory.owners {
            try Task.checkCancellation()
            guard !owner.id.isEmpty, !owner.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  owner.text.utf16.count <= 16_384, owner.rect.count == 4, owner.rect.allSatisfy(\.isFinite),
                  owner.rect[2] > 0, owner.rect[3] > 0, owner.fontSize.isFinite, owner.fontSize >= 4, owner.fontSize <= 512,
                  owner.fillRGB.count == 3, owner.fillRGB.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw Failure.invalidAdmission
            }
            guard !owner.fillRGB.allSatisfy({ $0 == (owner.strokeWhite ? 1 : 0) }) else { throw Failure.invalidAdmission }
            let box = CGRect(x: owner.rect[0], y: Double(height) - owner.rect[1] - owner.rect[3],
                width: owner.rect[2], height: owner.rect[3])
            guard page.contains(box) else { throw Failure.clippedText }
            let font = CTFontCreateWithName(owner.fontName as CFString, owner.fontSize, nil)
            guard (CTFontCopyPostScriptName(font) as String) == owner.fontName else { throw Failure.unsupportedGlyph }
            let text = NSAttributedString(string: owner.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
            guard CTFrameGetVisibleStringRange(frame).length == text.length else { throw Failure.incompleteText }
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let path = CGMutablePath()
            var glyphCount = 0
            for (index, line) in lines.enumerated() {
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let count = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let runFont = attributes[kCTFontAttributeName] as! CTFont
                    for i in 0..<count {
                        guard glyphs[i] != 0 else { throw Failure.unsupportedGlyph }
                        if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                            let transform = CGAffineTransform(translationX: box.minX + origins[index].x + positions[i].x,
                                y: box.minY + origins[index].y + positions[i].y)
                            path.addPath(glyph, transform: transform); glyphCount += 1
                        } else {
                            // Whitespace has no outline; reject any other pathless glyph (e.g. color emoji).
                            var stringIndex = CFIndex(0)
                            CTRunGetStringIndices(run, CFRange(location: i, length: 1), &stringIndex)
                            let scalar = (owner.text as NSString).substring(with: NSRange(location: stringIndex, length: 1))
                            guard scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unsupportedGlyph }
                        }
                    }
                }
            }
            guard !path.isEmpty else { throw Failure.incompleteText }
            let radius = max(2, 0.20 * owner.fontSize)
            let paint = path.boundingBoxOfPath.insetBy(dx: -radius - 1, dy: -radius - 1)
            guard page.contains(paint) else { throw Failure.clippedText }
            guard !boxes.contains(where: { $0.intersects(paint) }) else { throw Failure.overlappingText }
            boxes.append(paint); paths.append((owner, path, radius))
            audit.append(["id": owner.id, "text": owner.text, "glyphOutlines": glyphCount,
                "visibleUTF16": text.length, "strokeRadius": radius, "pureBWStroke": true,
                "paintBoundsBottomLeft": [paint.minX, paint.minY, paint.width, paint.height]])
        }
        let context = try context(width: width, height: height)
        context.setLineJoin(.round)
        for (owner, path, radius) in paths {
            context.addPath(path); context.setLineWidth(radius * 2)
            context.setStrokeColor(CGColor(gray: owner.strokeWhite ? 1 : 0, alpha: 1)); context.strokePath()
        }
        for (owner, path, _) in paths {
            context.addPath(path)
            context.setFillColor(CGColor(srgbRed: owner.fillRGB[0], green: owner.fillRGB[1], blue: owner.fillRGB[2], alpha: 1))
            context.fillPath()
        }
        guard let image = context.makeImage() else { throw Failure.allocation }
        // Certify the RETAINED layer, not just an intended style. Disjoint paint
        // bounds make each owner's opaque BW endpoint and distinct fill attributable.
        let raster = try rgba(image)
        for (index, entry) in paths.enumerated() {
            try Task.checkCancellation()
            let endpoint: UInt8 = entry.0.strokeWhite ? 255 : 0, box = boxes[index]
            let x0 = max(0, Int(floor(box.minX))), x1 = min(width, Int(ceil(box.maxX)))
            let y0 = max(0, height - Int(ceil(box.maxY))), y1 = min(height, height - Int(floor(box.minY)))
            var endpoints = 0, fills = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = (y * width + x) * 4
                    guard raster[p + 3] == 255 else { continue }
                    if raster[p] == endpoint && raster[p + 1] == endpoint && raster[p + 2] == endpoint { endpoints += 1 }
                    else { fills += 1 }
                }
            }
            guard endpoints > 0, fills > 0 else { throw Failure.incompleteText }
            audit[index]["retainedOpaqueBWStrokePixels"] = endpoints
            audit[index]["retainedOpaqueDistinctFillPixels"] = fills
        }
        return (image, audit)
    }
}
