import Foundation
import CoreGraphics
import UIKit
import CryptoKit
import Darwin
import Accelerate

// Serialized ordered-PDF admission for the new width stage only; no GT runtime selector.
final class NativeWidthFinalArtifactAdmission {
    typealias R = NativeTranslationRenderer
    struct Budget {
        var deviceSamples = 512 * 1024 * 1024
        var finalizationCaptures = 1
        var documentCaptures = 96
        var comparisonSamples = 1_500_000_000
        let maximumPixels = 12_000_000
        var maximumLiveManagedBytes = 512 * 1024 * 1024
    }
    /// Additional page-wide allowance for at most eight attempted group owners.
    /// The existing single-owner width budget and all per-capture/live-byte
    /// ceilings remain unchanged. Failed attempts consume their claimed slots
    /// and any actual certificate reservations; neither is refunded.
    struct GroupBudget {
        static let maximumOwners = 8
        let ownerAllowance: Int
        private(set) var remainingOwners: Int
        var resources: Budget

        init(ownerAllowance: Int = maximumOwners) {
            precondition((0...Self.maximumOwners).contains(ownerAllowance))
            self.ownerAllowance = ownerAllowance
            remainingOwners = ownerAllowance
            resources = Budget()
            resources.documentCaptures *= ownerAllowance
            resources.deviceSamples *= ownerAllowance
            resources.comparisonSamples *= ownerAllowance
        }

        mutating func claim(owners: Int) -> Bool {
            guard owners > 1, owners <= Self.maximumOwners, owners <= remainingOwners else { return false }
            remainingOwners -= owners
            return true
        }

        var diagnostics: [String: Any] {
            let original = Budget()
            return ["maximumAttemptedOwners": ownerAllowance, "remainingAttemptedOwners": remainingOwners,
                "chargedOwnerSlots": ownerAllowance - remainingOwners,
                "documentCaptureAllowance": original.documentCaptures * ownerAllowance,
                "chargedDocumentCaptures": original.documentCaptures * ownerAllowance - resources.documentCaptures,
                "deviceSampleAllowance": original.deviceSamples * ownerAllowance,
                "chargedDeviceSamples": original.deviceSamples * ownerAllowance - resources.deviceSamples,
                "comparisonAllowance": original.comparisonSamples * ownerAllowance,
                "chargedComparisons": original.comparisonSamples * ownerAllowance - resources.comparisonSamples,
                "maximumLiveManagedBytes": resources.maximumLiveManagedBytes,
                "wholeProcessRSSBound": NSNull(),
                "authority": "One cumulative additional group budget per page; reservations include rejected work; no per-group reset"]
        }
    }

    /// Synchronous atomic receipt transaction used by the real pixel certifier.
    /// The injected operation also permits deterministic failure/cancel tests
    /// without adding runtime selectors or weakening a physical witness.
    func admitGroup(ids: Set<String>, certifyOwner: (String, inout Budget) throws -> Bool?) -> Bool? {
        let incumbent = accepted, incumbentDocuments = documentReceipts
        var complete = false
        defer {
            if !complete {
                accepted = cancelled ? nil : incumbent
                documentReceipts = cancelled ? [] : incumbentDocuments
            }
        }
        do {
            try Task.checkCancellation()
            guard !cancelled else { return nil }
            guard groupBudget.claim(owners: ids.count) else { return nil }
            var documents: [[String: Any]] = []
            for id in ids.sorted() {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                guard let passed = try certifyOwner(id, &groupBudget.resources) else { return nil }
                guard passed else { return false }
                documents.append(contentsOf: documentReceipts)
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            guard accepted != nil else { return nil }
            documentReceipts = documents
            complete = true
            return true
        } catch is CancellationError {
            cancel()
            return nil
        } catch {
            return nil
        }
    }

    struct Artifact { let image: CGImage; let data: Data?; let mediaBox: CGRect }
    struct Receipt {
        let snapshot: R.PreparedRender
        let data: Data?
        let image: CGImage
        let mediaBox: CGRect
        let logicalBounds: CGRect
        let sourceRect: CGRect
        let pixels: CGSize
        let deviceScale: CGFloat
        let cards: [R.Card]
    }
    private let plan: R.PreparedRender
    private let keptOwners: [CGRect]
    private var budget = Budget()
    private(set) var groupBudget = GroupBudget()
    init(plan: R.PreparedRender, keptOwners: [CGRect], budget: Budget = Budget()) {
        self.plan = plan; self.keptOwners = keptOwners; self.budget = budget
    }
    convenience init(plan: R.PreparedRender, keptOwners: [CGRect], budget: Budget = Budget(), groupBudget: GroupBudget) {
        self.init(plan: plan, keptOwners: keptOwners, budget: budget)
        self.groupBudget = groupBudget
    }
    func admission(before: [R.Card], after: [R.Card], ids: Set<String>) -> Bool? {
        if ids.count > 1 {
            return admitGroup(ids: ids) { id, resources in
                try self.certify(plan: self.plan, before: before, after: after, ids: Set([id]),
                    keptOwners: self.keptOwners, budget: &resources)
            }
        }
        do { return try certify(plan: plan, before: before, after: after, ids: ids, keptOwners: keptOwners, budget: &budget) }
        catch is CancellationError { cancel(); return nil }
        catch { return nil }
    }
    // Only the new width stage is transactional. The incumbent is captured AFTER
    // all existing cohort/fixed-width commits, not the prepare's initial cards.
    func finalizeOrRollback(cards: inout [R.Card], incumbent: [R.Card],
        diagnosticData: Data?) throws -> R.PreparedRender? {
        do {
            if let result = try finalized(cards: cards, diagnosticData: diagnosticData) { return result }
        } catch is CancellationError { throw CancellationError() }
        catch { invalidate() }
        cards = incumbent
        return nil
    }
    func finalized(cards: [R.Card], diagnosticData: Data?) throws -> R.PreparedRender? {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard let accepted else { return nil }
        guard cards.map({ $0.item }) == accepted.cards.map({ $0.item }),
              cards.count == accepted.cards.count else { finalizationFailure = "worldIdentity"; invalidate(); return nil }
        for (a, c) in zip(cards, accepted.cards) {
            guard a.textShift == c.textShift, a.sourcePlateRect == c.sourcePlateRect,
                  a.background == c.background, a.style.foreground == c.style.foreground,
                  a.style.outline == c.style.outline, a.style.outlineWidth == c.style.outlineWidth,
                  a.finalFontSize == c.finalFontSize, a.style.lineHeight == c.style.lineHeight else {
                finalizationFailure = "worldIdentity"; invalidate(); return nil
            }
        }
        let pixels = Int(plan.pixels.width) * Int(plan.pixels.height)
        guard budget.deviceSamples >= pixels, budget.comparisonSamples >= pixels * 4,
              budget.documentCaptures > 0, budget.finalizationCaptures > 0 else { finalizationFailure = "finalizationBudget"; invalidate(); return nil }
        budget.finalizationCaptures -= 1
        budget.deviceSamples -= pixels; budget.comparisonSamples -= pixels * 4; budget.documentCaptures -= 1
        let current = R.PreparedRender(inputLayout: plan.inputLayout, layout: plan.layout,
            image: plan.image, source: plan.source, restoration: plan.restoration, cards: cards,
            glossCards: plan.glossCards, gloss: plan.gloss, settings: plan.settings,
            bounds: plan.bounds, pixels: plan.pixels, scale: plan.scale, composeSource: plan.composeSource,
            capturePDF: plan.capturePDF, pdfDeviceScale: plan.pdfDeviceScale,
            sourcePatches: plan.sourcePatches, sourcePieces: plan.sourcePieces,
            limitations: plan.limitations, diagnosticData: nil)
        // Revalidate CURRENT world; this capture is verification only, never the exported artifact.
        let currentImage: CGImage
        if current.capturePDF {
            var cancelled = false
            let capture = try NativeTranslationPDFCapture.captureDocument(bounds: current.bounds, pixels: current.pixels,
                deviceScale: current.pdfDeviceScale, alignsToLogicalBounds: true, maximumBytes: 16 * 1024 * 1024) {
                cancelled = R.paintPrepared(current, context: $0, canvasBacking: nil, canvasSession: nil)
            }
            guard !cancelled else { throw CancellationError() }
            currentImage = try NativeTranslationPDFCapture.rasterize(data: capture.data, pixels: current.pixels)
        } else { currentImage = try Self.bitmapWorld(current) }
        guard try Self.equalBytes(Self.rgba(currentImage), Self.rgba(accepted.image)) else { finalizationFailure = "pixelMismatch"; invalidate(); return nil }

        // The document and the complete immutable captured world move together.
        // No external mutable card list is accepted here, nor any ID-only match.
        return R.retainedWidthPreparedRender(accepted, diagnosticData: try boundDiagnostics(diagnosticData))
    }
    // Publish the literal world already certified, never splice caller cards into it.
    // Its capture/decodes and physical witnesses were prepaid by certify's bounded
    // device/comparison/capture/live-byte ledger. No new P-sized work is performed.
    func publishOwned(diagnosticData: Data?, reserveWork: ((Int) throws -> Bool)? = nil) throws -> R.PreparedRender? {
        do { return try publication(diagnosticData: diagnosticData, reserveWork: reserveWork) }
        catch is CancellationError { cancel(); throw CancellationError() }
        catch { finalizationFailure = "ownedPublicationError"; invalidate(); return nil }
    }
    private func publication(diagnosticData: Data?, reserveWork: ((Int) throws -> Bool)?) throws -> R.PreparedRender? {
        func checkCancellation() throws {
            do { try Task.checkCancellation() }
            catch { cancel(); throw error }
        }
        try checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard let receipt = accepted else { return nil }
        func unknown() -> R.PreparedRender? {
            finalizationFailure = "ownedPublicationUnknown"
            invalidate()
            return nil
        }
        let owners = receipt.cards.filter {
            $0.harmonyRecord["widthRequiresRetainedArtifact"] as? Bool == true
        }
        guard !owners.isEmpty, Set(receipt.cards.map { $0.item.id }).count == receipt.cards.count,
              receipt.logicalBounds == plan.bounds, receipt.sourceRect == plan.layout.sourceRect,
              receipt.pixels == plan.pixels, receipt.deviceScale == plan.pdfDeviceScale,
              receipt.snapshot.inputLayout == plan.inputLayout else { return unknown() }
        var units = receipt.cards.count
        for card in owners {
            guard let input = plan.inputLayout.items.first(where: { $0.id == card.item.id }),
                  input.text == card.item.text, input.typesettingText == card.item.typesettingText else { return unknown() }
            let original = input.typesettingText ?? input.text
            let originalCost = original.utf16.count.multipliedReportingOverflow(by: 2)
            let shapedCost = card.typography.shapedText.utf16.count.multipliedReportingOverflow(by: 2)
            guard !originalCost.overflow, !shapedCost.overflow else { return unknown() }
            let a = units.addingReportingOverflow(originalCost.partialValue)
            let b = a.partialValue.addingReportingOverflow(shapedCost.partialValue)
            guard !a.overflow, !b.overflow else { return unknown() }
            units = b.partialValue
        }
        // Always debit the existing session's cumulative comparison ledger.
        // An integrated parent may additionally reserve actual UTF work; nil
        // does not waive payment or allocate/reset a new page budget.
        guard budget.comparisonSamples >= units else { return unknown() }
        budget.comparisonSamples -= units
        if let reserveWork {
            do { guard try reserveWork(units) else { return unknown() } }
            catch { invalidate(); throw error }
        }
        for card in owners {
            try checkCancellation()
            guard let input = plan.inputLayout.items.first(where: { $0.id == card.item.id }),
                  NativeTranslationTypography.sourceOwnershipCoverage(card.typography,
                    originalText: input.typesettingText ?? input.text, normalization: .exact)?.whole == true,
                  NativeTranslationTypography.committedParagraphRawComplete(card.typography,
                    original: input.typesettingText ?? input.text) else { return unknown() }
        }
        try checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return R.retainedWidthPreparedRender(receipt, diagnosticData: try boundDiagnostics(diagnosticData))
    }

    func boundDiagnostics(_ diagnosticData: Data?) throws -> Data? {
        guard let accepted else { return diagnosticData }
        var boundDiagnostics = diagnosticData
        if let diagnosticData,
           var object = try JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any] {
            object["sourceTopGroupBudget"] = groupBudget.diagnostics
            object["widthRetainedArtifactReceipt"] = [
                "pdfSHA256": accepted.data.map(Self.hash) as Any? ?? NSNull(), "deviceScale": Double(accepted.deviceScale),
                "artifactMode": plan.capturePDF ? "PDF" : "bitmap",
                "backingCaptureReuseCount": backingCaptureReuseCount,
                "backingReuseAuthority": "exact ordered backing-only program within one fixed capture scope",
                "documentSinkMaximumBytes": plan.capturePDF ? 16 * 1024 * 1024 : NSNull(),
                "nativeInternalAllocationBound": NSNull(),
                "authority": "owned admitted artifact reused at export; not source-style ground truth"]
            boundDiagnostics = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return boundDiagnostics
    }
    private(set) var finalizationFailure: String?
    private(set) var accepted: Receipt?
    private(set) var backingCaptureReuseCount = 0
    private(set) var documentReceipts: [[String: Any]] = []
    private(set) var reservedManagedBytes = 0
    private static let maximumKeptBankBytes = 4 * 1024 * 1024
    private static let maximumKeptRowBytes = 1024 * 1024
    private var keptPositiveBanks: [CGFloat: [UInt64]] = [:]
    private var cancelled = false
    // Session is owned by one synchronous prepare. No cross-page/global storage.
    func invalidate() { accepted = nil; keptPositiveBanks.removeAll() }
    func cancel() { cancelled = true; accepted = nil; keptPositiveBanks.removeAll() }
    func certify(plan: R.PreparedRender, before: [R.Card], after: [R.Card], ids: Set<String>,
        keptOwners: [CGRect], budget: inout Budget) throws -> Bool? {
        // Receipts describe actual captures in this call, never reused-bank history.
        documentReceipts = []
        guard !cancelled else { accepted = nil; return nil }
        try Task.checkCancellation()
        let cacheAuthority = plan.bounds == self.plan.bounds && plan.pixels == self.plan.pixels
            && plan.layout.sourceRect == self.plan.layout.sourceRect && plan.capturePDF == self.plan.capturePDF
            && keptOwners == self.keptOwners
        if !cacheAuthority { keptPositiveBanks.removeAll() }
        var bankScopeReady = false
        defer { if !bankScopeReady { keptPositiveBanks.removeAll() } }
        guard plan.pixels.width.isFinite, plan.pixels.height.isFinite,
            plan.pixels.width >= 1, plan.pixels.height >= 1,
            plan.pixels.width <= 32768, plan.pixels.height <= 32768,
            plan.pixels.width.rounded() == plan.pixels.width, plan.pixels.height.rounded() == plan.pixels.height else { return nil }
        let w = Int(plan.pixels.width), h = Int(plan.pixels.height)
        let product = w.multipliedReportingOverflow(by: h)
        guard !product.overflow, product.partialValue > 0, product.partialValue <= budget.maximumPixels,
            !ids.isEmpty, ids.count == 1, before.map({ $0.item.id }) == after.map({ $0.item.id }),
            let id = ids.first, let old = before.first(where: { $0.item.id == id }),
            let next = after.first(where: { $0.item.id == id }),
            Self.support(old) == nil, Self.support(next) == nil,
            let rawDomain = R.TextPaintDomain(rect: plan.layout.sourceRect, polygon: [], within: plan.layout.sourceRect),
            keptOwners.allSatisfy({ !$0.isNull && !$0.isInfinite && plan.layout.sourceRect.contains($0) }) else { return nil }
        let pixels = product.partialValue
        // Reserve the WHOLE 3-scale recipe before the first allocation. No per-row reset.
        // 11 raster reads/scale: worlds 2, backing 2, raw/clipped owners 4,
        // peer 1, KEPT mask 1, independent backing binding 1 (conservative reserve).
        guard plan.pdfDeviceScale.isFinite, plan.pdfDeviceScale > 0, plan.pdfDeviceScale <= 16 else { return nil }
        var scales: [CGFloat] = [plan.pdfDeviceScale]
        for scale: CGFloat in [1, 1.75, 3] where plan.capturePDF && !scales.contains(scale) { scales.append(scale) }
        // Explicit phase scopes retain at most two world RGBA banks OR backing banks, never both.
        // 48P conservatively covers phase arrays, conversion/hash temporaries, raster images,
        // incumbent+selected+last images. 128MiB reserves document sinks/data/temporaries;
        // each actual PDF consumer is capped at 16MiB BEFORE writes. This managed estimate
        // does not bound Quartz/CoreText internal allocation or total native RSS.
        for key in Array(keptPositiveBanks.keys) where !scales.contains(key) {
            keptPositiveBanks.removeValue(forKey: key)
        }
        let sinkReserve = 128 * 1024 * 1024
        let live = pixels.multipliedReportingOverflow(by: 48)
        guard budget.maximumLiveManagedBytes >= sinkReserve, !live.overflow,
              live.partialValue <= budget.maximumLiveManagedBytes - sinkReserve else { return nil }
        let bankBytes = ((pixels + 63) / 64) * MemoryLayout<UInt64>.stride * scales.count
        let canCache = !keptOwners.isEmpty && cacheAuthority
            && bankBytes <= Self.maximumKeptBankBytes
            && bankBytes <= budget.maximumLiveManagedBytes - sinkReserve - live.partialValue
        if !canCache { keptPositiveBanks.removeAll() }
        reservedManagedBytes = live.partialValue + sinkReserve + (canCache ? bankBytes : 0)
        guard after.count <= 1024 else { return nil }
        var utf16 = 0
        for card in after {
            let cost = (card.item.typesettingText ?? card.item.text).utf16.count
            guard cost <= 65_536 - utf16 else { return nil }
            utf16 += cost
        }
        let captures = 11 * scales.count
        let cost = pixels.multipliedReportingOverflow(by: captures)
        let comparisons = pixels.multipliedReportingOverflow(by: 30 * scales.count)
        guard !cost.overflow, !comparisons.overflow, cost.partialValue <= budget.deviceSamples - pixels,
            comparisons.partialValue <= budget.comparisonSamples - pixels * 4, budget.documentCaptures >= captures + 1 else { return nil }
        budget.deviceSamples -= cost.partialValue; budget.documentCaptures -= captures
        budget.comparisonSamples -= comparisons.partialValue
        bankScopeReady = true
        var selected: Receipt?
        for deviceScale in scales {
            try Task.checkCancellation()
            let p = R.PreparedRender(inputLayout: plan.inputLayout, layout: plan.layout, image: plan.image,
                source: plan.source, restoration: plan.restoration, cards: before, glossCards: plan.glossCards,
                gloss: plan.gloss, settings: plan.settings, bounds: plan.bounds, pixels: plan.pixels,
                scale: plan.scale, composeSource: false, capturePDF: plan.capturePDF, pdfDeviceScale: deviceScale,
                sourcePatches: plan.sourcePatches, sourcePieces: plan.sourcePieces,
                limitations: plan.limitations, diagnosticData: nil)
            var lastCapture: (Data?, CGImage, CGRect)?
            var bitmapBacking: NativeCanvasBacking?
            var bitmapSession: NativeCanvasTextureResampler.Session?
            func captureImage(retainArtifact: Bool = false, _ paint: (CGContext) -> Void) throws -> (Data?, CGImage, CGRect) {
                try autoreleasepool {
                let data: Data?, image: CGImage, mediaBox: CGRect
                if p.capturePDF {
                    let document = try NativeTranslationPDFCapture.captureDocument(bounds: p.bounds, pixels: p.pixels,
                        deviceScale: deviceScale, alignsToLogicalBounds: true, maximumBytes: 16 * 1024 * 1024, paint: paint)
                    guard document.data.count <= 16 * 1024 * 1024 else {
                        throw NSError(domain: "NativeTextArtifactAdmission", code: 1)
                    }
                    data = document.data; mediaBox = document.mediaBox
                    image = try NativeTranslationPDFCapture.rasterize(data: document.data, pixels: p.pixels)
                } else {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    format.preferredRange = .standard; format.opaque = false
                    let rendered = UIGraphicsImageRenderer(size: p.pixels, format: format).image { renderer in
                        let context = renderer.cgContext
                        context.scaleBy(x: p.pixels.width / p.bounds.width, y: p.pixels.height / p.bounds.height)
                        context.translateBy(x: -p.bounds.minX, y: -p.bounds.minY)
                        bitmapBacking = NativeCanvasBacking.freshCanonicalBitmap(context: context, pixelExtent: p.pixels)
                        bitmapSession = NativeCanvasTextureResampler.Session()
                        paint(context); bitmapSession?.close(); bitmapSession = nil; bitmapBacking = nil
                    }
                    guard let bitmap = rendered.cgImage else { throw R.RenderError.invalidGeometry }
                    image = bitmap; data = nil; mediaBox = p.bounds
                }
                try Task.checkCancellation()
                if retainArtifact { lastCapture = (data, image, mediaBox) }
                return (data, image, mediaBox)
                }
            }
            func record(_ captured: (Data?, CGImage, CGRect), rgbaHash: String) {
                documentReceipts.append(["deviceScale": Double(deviceScale), "artifactMode": p.capturePDF ? "PDF" : "bitmap",
                    "pdfSHA256": captured.0.map(Self.hash) as Any? ?? NSNull(),
                    "rasterRGBA_SHA256": rgbaHash, "width": w, "height": h])
            }
            func capture(retainArtifact: Bool = false, _ paint: (CGContext) -> Void) throws -> [UInt8] {
                try autoreleasepool {
                    let captured = try captureImage(retainArtifact: retainArtifact, paint)
                    let bytes = try Self.rgba(captured.1)
                    record(captured, rgbaHash: Self.hash(bytes))
                    return bytes
                }
            }
            func alpha(_ paint: (CGContext) -> Void) throws -> [UInt8] {
                let rgba = try capture(paint)
                return try Self.alphaBytes(rgba)
            }
            func world(_ cards: [R.Card], retainArtifact: Bool = false) throws -> [UInt8]? {
                let prepared = R.PreparedRender(inputLayout: p.inputLayout, layout: p.layout, image: p.image,
                    source: p.source, restoration: p.restoration, cards: cards, glossCards: p.glossCards,
                    gloss: p.gloss, settings: p.settings, bounds: p.bounds, pixels: p.pixels,
                    scale: p.scale, composeSource: false, capturePDF: plan.capturePDF, pdfDeviceScale: deviceScale,
                    sourcePatches: p.sourcePatches, sourcePieces: p.sourcePieces,
                    limitations: p.limitations, diagnosticData: nil)
                var cancelled = false
                let bytes = try capture(retainArtifact: retainArtifact) { c in
                    cancelled = R.paintPrepared(prepared, context: c, canvasBacking: bitmapBacking, canvasSession: bitmapSession)
                }
                return cancelled ? nil : bytes
            }
            let worldStatus: Bool? = try autoreleasepool {
            guard let worldB = try world(before), let worldC = try world(after, retainArtifact: true) else { return nil }
            if deviceScale == plan.pdfDeviceScale, let capture = lastCapture {
                let snapshot = R.PreparedRender(inputLayout: plan.inputLayout, layout: plan.layout, image: plan.image,
                    source: plan.source, restoration: plan.restoration, cards: after, glossCards: plan.glossCards,
                    gloss: plan.gloss, settings: plan.settings, bounds: plan.bounds, pixels: plan.pixels,
                    scale: plan.scale, composeSource: plan.composeSource, capturePDF: plan.capturePDF,
                    pdfDeviceScale: plan.pdfDeviceScale, sourcePatches: plan.sourcePatches,
                    sourcePieces: plan.sourcePieces, limitations: plan.limitations, diagnosticData: nil)
                selected = Receipt(snapshot: snapshot, data: capture.0, image: capture.1, mediaBox: capture.2,
                    logicalBounds: p.bounds, sourceRect: p.layout.sourceRect, pixels: p.pixels,
                    deviceScale: deviceScale, cards: after)
            }
            // Only the immutable selected receipt must survive the following observation phases.
            lastCapture = nil
            let kept: [UInt8]?
            let positive: [UInt64]?
            if keptOwners.isEmpty {
                // No paint commands: exact empty predicate, not a fresh raster measurement.
                kept = nil; positive = nil
            } else if canCache, let bits = keptPositiveBanks[deviceScale] {
                kept = nil; positive = bits
            } else {
                func paintKept(_ c: CGContext) {
                    c.clip(to: p.layout.sourceRect); c.setFillColor(CGColor(gray: 1, alpha: 1))
                    for owner in keptOwners { c.fill(owner) }
                }
                if canCache {
                    let streamed = try autoreleasepool {
                        let captured = try captureImage(paintKept)
                        let result = try Self.streamingKept(captured.1)
                        record(captured, rgbaHash: result.rgbaHash)
                        return result
                    }
                    keptPositiveBanks[deviceScale] = streamed.bits
                    positive = streamed.bits; kept = nil
                } else { kept = try alpha(paintKept); positive = nil }
            }
            // Pointwise full-grid alpha equality is stronger than model SOURCE union
            // nonloss, and refuses new source concealment anywhere. Never union=P.
            if let kept {
                // Original byte-mask fallback; no extra full-grid pass.
                for k in 0..<pixels {
                    if k % 65536 == 0 { try Task.checkCancellation() }
                    let offset = 4 * k
                    if worldB[offset + 3] != worldC[offset + 3] { return false }
                    if kept[k] > 0 && (0..<4).contains(where: { worldB[offset + $0] != worldC[offset + $0] }) { return false }
                }
            } else {
                // SOURCE alpha duty remains pointwise over the entire actual output grid.
                for k in 0..<pixels {
                    if k % 65536 == 0 { try Task.checkCancellation() }
                    if worldB[4*k+3] != worldC[4*k+3] { return false }
                }
                // Every positive native AA mask sample is visited, without testing P zero bits.
                if let positive {
                    for wordIndex in positive.indices {
                        if wordIndex % 1024 == 0 { try Task.checkCancellation() }
                        var word = positive[wordIndex]
                        while word != 0 {
                            let k = wordIndex*64 + word.trailingZeroBitCount
                            guard k < pixels else { return nil }
                            let offset = 4*k
                            if (0..<4).contains(where: { worldB[offset+$0] != worldC[offset+$0] }) { return false }
                            word &= word - 1
                        }
                    }
                }
            }
            return true
            }
            guard let worldStatus else { return nil }
            guard worldStatus else { return false }
            func backing(_ cards: [R.Card]) throws -> [UInt8] {
                try capture { c in
                    c.clip(to: p.layout.sourceRect)
                    for card in cards where card.sourceBackgroundKind == "solid-text-box" && card.drawsPanel
                        && card.background.alpha == 1 && !card.usesFallbackVeil {
                        R.draw(card, context: c, opacity: 1, paintsBackground: true, paintsText: false,
                            paintsSourcePanels: false, pixelSnapScale: p.capturePDF ? deviceScale : nil)
                    }
                }
            }
            let fillAlpha: [UInt8]? = try autoreleasepool {
                let fillB = try backing(before)
                let fillC: [UInt8]
                if p.capturePDF && Self.backingProgramsIdentical(before, after) {
                    // Same solid backing program in this fixed clip/density scope.
                    // All original logical budget debits and pointwise checks remain.
                    try Task.checkCancellation()
                    fillC = fillB
                    backingCaptureReuseCount += 1
                    try Task.checkCancellation()
                } else { fillC = try backing(after) }
                guard try Self.equalBytes(fillB, fillC) else { return nil }
                return try Self.alphaBytes(fillB)
            }
            guard let fillAlpha else { return false }
            let inkStatus: Bool? = try autoreleasepool {
            var rawOld = old, rawNext = next
            rawOld.textPaintDomain = rawDomain; rawNext.textPaintDomain = rawDomain
            func ink(_ card: R.Card, clipped: Bool) throws -> [UInt8] {
                try alpha { c in
                    if clipped { c.clip(to: p.layout.sourceRect) }
                    R.draw(card, context: c, opacity: 1, paintsBackground: false,
                        paintsText: true, paintsSourcePanels: false, pixelSnapScale: p.capturePDF ? deviceScale : nil)
                }
            }
            let prior = try ink(old, clipped: true), candidate = try ink(next, clipped: true)
            let rawB = try ink(rawOld, clipped: false), rawC = try ink(rawNext, clipped: false)
            let peer = try alpha { c in
                c.clip(to: p.layout.sourceRect)
                for card in after where card.item.id != id {
                    R.draw(card, context: c, opacity: 1, paintsBackground: false,
                        paintsText: true, paintsSourcePanels: false, pixelSnapScale: p.capturePDF ? deviceScale : nil)
                }
            }
            let pad = max(old.style.outlineWidth + old.style.outlineGlow, next.style.outlineWidth + next.style.outlineGlow)
            let geometry = [rawOld, rawNext].flatMap { card in
                (card.typography.glyphBounds + card.typography.rangeBounds + [card.typography.inkBounds])
                    .map { $0.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y).insetBy(dx: -pad, dy: -pad) }
            }
            guard geometry.allSatisfy({ $0.isEmpty || p.layout.sourceRect.contains($0) }),
                rawB.contains(where: { $0 > 0 }), rawC.contains(where: { $0 > 0 }) else { return nil }
            for k in 0..<pixels {
                if k % 65536 == 0 { try Task.checkCancellation() }
                let x = k % w, y = k / w
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1) && (rawB[k] > 0 || rawC[k] > 0) { return nil }
                if rawC[k] > candidate[k] { return false }
                if candidate[k] > prior[k] && (fillAlpha[k] != 255 || peer[k] > 0) { return false }
            }
            return true
            }
            guard let inkStatus else { return nil }
            guard inkStatus else { return false }
        }
        guard let selected else { return nil }
        // Install only AFTER every raw/ordered witness at every scale passed.
        try Task.checkCancellation()
        guard !cancelled else { accepted = nil; return nil }
        accepted = selected
        return true
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ bytes: [UInt8]) -> String {
        var digest = SHA256()
        bytes.withUnsafeBytes { digest.update(bufferPointer: $0) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func backingProgramsIdentical(_ a: [R.Card], _ b: [R.Card]) -> Bool {
        guard a.count == b.count, a.count <= 1024 else { return false }
        func emitted(_ card: R.Card) -> Bool {
            card.sourceBackgroundKind == "solid-text-box" && card.drawsPanel
                && card.background.alpha == 1 && !card.usesFallbackVeil
        }
        func rectBits(_ a: CGRect, _ b: CGRect) -> Bool {
            let left = [a.origin.x, a.origin.y, a.size.width, a.size.height]
            let right = [b.origin.x, b.origin.y, b.size.width, b.size.height]
            return zip(left, right).allSatisfy {
                $0.isFinite && $1.isFinite && Double($0).bitPattern == Double($1).bitPattern
            }
        }
        for (old, next) in zip(a, b) {
            guard old.item.id == next.item.id, emitted(old) == emitted(next) else { return false }
            if !emitted(old) { continue }
            guard rectBits(old.sourcePlateRect, next.sourcePlateRect),
                  old.item.rotation.isFinite, next.item.rotation.isFinite,
                  Double(old.item.rotation).bitPattern == Double(next.item.rotation).bitPattern,
                  let space = old.background.colorSpace, space.model != .pattern,
                  let components = old.background.components, components.allSatisfy({ $0.isFinite }),
                  old.background == next.background else { return false }
            switch (old.straightenedPanelRect, next.straightenedPanelRect) {
            case (nil, nil): break
            case let (a?, b?): guard rectBits(a, b) else { return false }
            default: return false
            }
        }
        return true
    }

    static func support(_ c: R.Card) -> String? {
        if c.sourceBackgroundKind != "solid-text-box" { return "unsupported-background-painter" }
        if !c.unitTextParts.isEmpty { return "unsupported-unit-parts" }
        if c.item.vertical || c.style.vertical { return "unsupported-vertical" }
        if c.effectiveTextRotation != 0 { return "unsupported-rotation" }
        if c.slantedClip != nil { return "unsupported-slanted-clip" }
        if c.captionParentPlate { return "unsupported-parent-clip" }
        return nil
    }
    static func streamingKept(_ image: CGImage) throws -> (bits: [UInt64], rgbaHash: String) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 32768, h <= 32768,
              w * h <= 12_000_000 else { throw R.RenderError.invalidGeometry }
        let rowBytes = w * 4
        let tileRows = min(h, min(64, Self.maximumKeptRowBytes / rowBytes))
        guard tileRows > 0 else { throw R.RenderError.invalidGeometry }
        var scratch = [UInt8](repeating: 0, count: w * tileRows * 4)
        var bits = [UInt64](repeating: 0, count: (w * h + 63) / 64)
        var digest = SHA256()
        for first in stride(from: 0, to: h, by: tileRows) {
            try Task.checkCancellation()
            let rows = min(tileRows, h - first)
            let count = w * rows * 4
            try scratch.withUnsafeMutableBytes { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
                guard let context = CGContext(
                    data: raw.baseAddress, width: w, height: rows,
                    bitsPerComponent: 8, bytesPerRow: rowBytes,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    throw NSError(domain: "NativeTextArtifactAdmission", code: 1)
                }
                // Bitmap storage begins at the TOP row, not the Quartz coordinate origin.
                context.draw(image, in: CGRect(x: 0, y: -(h - first - rows), width: w, height: h))
                digest.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: count))
            }
            for local in 0..<(w * rows) {
                if local % 16384 == 0 { try Task.checkCancellation() }
                if scratch[4 * local + 3] > 0 {
                    let index = first * w + local
                    bits[index >> 6] |= UInt64(1) << UInt64(index & 63)
                }
            }
        }
        return (bits, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        // Keep untouched pixels zeroed. Neither the context nor an image created
        // from its borrowed storage may escape this scope.
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NSError(domain: "NativeTextArtifactAllocation", code: 1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    static func equalBytes(_ a: [UInt8], _ b: [UInt8]) throws -> Bool {
        guard a.count == b.count else { return false }
        return try a.withUnsafeBytes { ap in
            try b.withUnsafeBytes { bp in
                for offset in stride(from: 0, to: a.count, by: 65_536) {
                    try Task.checkCancellation()
                    if memcmp(ap.baseAddress!.advanced(by: offset), bp.baseAddress!.advanced(by: offset),
                        min(65_536, a.count - offset)) != 0 { return false }
                }
                return true
            }
        }
    }
    static func alphaBytes(_ rgba: [UInt8]) throws -> [UInt8] {
        let pixels = rgba.count / 4
        // Small buffers keep the scalar path; avoid vector setup and an extra initialization.
        if pixels < 16384 {
            var alpha: [UInt8] = []; alpha.reserveCapacity(pixels)
            for i in stride(from: 3, to: rgba.count, by: 4) {
                if (i - 3) % 65536 == 0 { try Task.checkCancellation() }
                alpha.append(rgba[i])
            }
            return alpha
        }
        var alpha = [UInt8](repeating: 0, count: pixels)
        try rgba.withUnsafeBytes { source in
            try alpha.withUnsafeMutableBytes { destination in
                // Match the original cancellation quantum: 65536 input bytes.
                for pixel in stride(from: 0, to: pixels, by: 16384) {
                    try Task.checkCancellation()
                    let width = min(16384, pixels - pixel)
                    var src = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: source.baseAddress!.advanced(by: pixel * 4)),
                        height: 1, width: vImagePixelCount(width), rowBytes: width * 4)
                    var dst = vImage_Buffer(data: destination.baseAddress!.advanced(by: pixel),
                        height: 1, width: vImagePixelCount(width), rowBytes: width)
                    // Channel three is the physical fourth byte in the owned RGBA bank.
                    let error = vImageExtractChannel_ARGB8888(&src, &dst, 3, vImage_Flags(kvImageDoNotTile))
                    guard error == kvImageNoError else {
                        throw NSError(domain: "NativeTextArtifactAlphaExtraction", code: Int(error))
                    }
                }
            }
        }
        return alpha
    }
    static func bitmapWorld(_ plan: R.PreparedRender) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        format.preferredRange = .standard; format.opaque = false
        var cancelled = false
        let session = NativeCanvasTextureResampler.Session(); defer { session.close() }
        let image = UIGraphicsImageRenderer(size: plan.pixels, format: format).image { renderer in
            let c = renderer.cgContext
            c.scaleBy(x: plan.pixels.width / plan.bounds.width, y: plan.pixels.height / plan.bounds.height)
            c.translateBy(x: -plan.bounds.minX, y: -plan.bounds.minY)
            let backing = NativeCanvasBacking.freshCanonicalBitmap(context: c, pixelExtent: plan.pixels)
            cancelled = R.paintPrepared(plan, context: c, canvasBacking: backing, canvasSession: session)
        }
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        guard let cg = image.cgImage else { throw R.RenderError.invalidGeometry }; return cg
    }

}
