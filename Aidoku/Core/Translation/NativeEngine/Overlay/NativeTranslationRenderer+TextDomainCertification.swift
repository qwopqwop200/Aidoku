import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    final class TextDomainLattice {
        let context: CGContext
        let grid: TextDomainGrid
        init(grid: TextDomainGrid, maximumScratchBytes: Int = 32 * 1024 * 1024) throws {
            try Task.checkCancellation()
            guard grid.width > 0, grid.height > 0, grid.width <= 32_768, grid.height <= 32_768,
                  grid.bounds.width > 0, grid.bounds.height > 0,
                  [grid.bounds.minX, grid.bounds.minY, grid.bounds.maxX, grid.bounds.maxY].allSatisfy(\.isFinite),
                  grid.pdfDeviceScale.isFinite, grid.pdfDeviceScale > 0 else { throw TextDomainTileError.invalidGeometry }
            let (pixels, overflow) = grid.width.multipliedReportingOverflow(by: grid.height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            let sx = CGFloat(grid.width) / grid.bounds.width, sy = CGFloat(grid.height) / grid.bounds.height
            guard !overflow, !byteOverflow, bytes <= maximumScratchBytes,
                  [sx, sy, grid.bounds.minX * sx, grid.bounds.minY * sy].allSatisfy(\.isFinite) else {
                throw TextDomainTileError.invalidGeometry
            }
            guard let c = CGContext(data: nil, width: grid.width, height: grid.height,
                bitsPerComponent: 8, bytesPerRow: grid.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TextDomainTileError.allocation
            }
            guard c.bytesPerRow == grid.width * 4 else { throw TextDomainTileError.allocation }
            context = c
            self.grid = grid
        }
    }
    struct TextDomainTile {
        let grid: TextDomainGrid
        let firstRow: Int
        let rowCount: Int
        let halo = 2
        let lattice: TextDomainLattice
        var height: Int { rowCount + 2 * halo }
        var pixels: Int { grid.width * height }
        // Memory rows are top-down. Extract halo rows from the shared world's
        // buffer without changing canvas dimensions, origin or glyph CTM.
        func alpha(_ painter: (CGContext) throws -> Void) throws -> [UInt8] {
            try Task.checkCancellation()
            guard firstRow >= 0, rowCount > 0, firstRow < grid.height, rowCount <= grid.height - firstRow,
                  lattice.grid.width == grid.width, lattice.grid.height == grid.height,
                  lattice.grid.bounds == grid.bounds, lattice.grid.pdfDeviceScale == grid.pdfDeviceScale else {
                throw TextDomainTileError.invalidGeometry
            }
            // One shared 4P raster arena, NOT fifteen full-output planes.
            // Retaining actual canvas dimensions avoids Quartz's canvas-size
            // dependent 1-alpha-unit drift seen with independently sized tiles.
            let c = lattice.context
            c.saveGState()
            defer { c.restoreGState(); c.textMatrix = .identity; c.textPosition = .zero; c.beginPath() }
            let stripe = CGRect(x: 0, y: grid.height - firstRow - rowCount - halo,
                width: grid.width, height: height)
            c.beginPath(); c.clear(stripe); c.clip(to: stripe)
            c.translateBy(x: 0, y: CGFloat(grid.height))
            c.scaleBy(x: CGFloat(grid.width) / grid.bounds.width, y: -CGFloat(grid.height) / grid.bounds.height)
            c.translateBy(x: -grid.bounds.minX, y: -grid.bounds.minY)
            c.clip(to: grid.bounds); c.textMatrix = .identity; c.textPosition = .zero
            try painter(c)
            guard let bytes = c.data?.assumingMemoryBound(to: UInt8.self) else { throw TextDomainTileError.allocation }
            // Grid and CGContext row-stride equality were validated above and
            // at lattice construction. Fresh pixels for EVERY painter/anchor.
            let width = grid.width, stride = width * 4
            var output = [UInt8](repeating: 0, count: pixels)
            output.withUnsafeMutableBufferPointer { target in
                for destinationRow in 0..<height {
                    let sourceRow = firstRow - halo + destinationRow
                    guard sourceRow >= 0, sourceRow < grid.height else { continue }
                    let destination = destinationRow * width
                    var source = sourceRow * stride + 3
                    for column in 0..<width {
                        target[destination + column] = bytes[source]
                        source += 4
                    }
                }
            }
            return output
        }
        func cells(_ rect: CGRect, visit: (Int) -> Void) {
            guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0,
                  grid.bounds.intersects(rect) else { return }
            let r = rect.intersection(grid.bounds)
            let sx = CGFloat(grid.width) / grid.bounds.width, sy = CGFloat(grid.height) / grid.bounds.height
            let x0 = max(0, Int(floor((r.minX - grid.bounds.minX) * sx)))
            let x1 = min(grid.width, Int(ceil((r.maxX - grid.bounds.minX) * sx)))
            let y0 = max(halo, Int(floor((r.minY - grid.bounds.minY) * sy)) - firstRow + halo)
            let y1 = min(halo + rowCount, Int(ceil((r.maxY - grid.bounds.minY) * sy)) - firstRow + halo)
            if x0 < x1 && y0 < y1 { for y in y0..<y1 { for x in x0..<x1 { visit(y * grid.width + x) } } }
        }
    }
    enum TextDomainTileError: Error { case allocation, invalidGeometry }

    /// Visits EVERY device pixel in BOTH modes, including all ink-empty tiles.
    /// No bounding-box/ROI culling; emptiness is checked per whole output mode.
    /// Evidence production and repeated painter calls have a separate reservation.
    static func certifyTextDomainTiled(grid: TextDomainGrid, remainingWork: inout Int,
        maximumScratchBytes: Int, tileRows: Int = 64, requiresPointwiseAlphaSafety: Bool = false,
        evidence: (TextDomainAnchor, TextDomainTile) throws -> [TextDomainEvidenceRow],
        paintRaw: (CGContext, CGFloat?) throws -> Void,
        paintCandidate: (CGContext, CGFloat?) throws -> Void) throws -> TextDomainCertificate {
        func unknown(_ reason: String, work: Int = 0, bytes: Int = 0) -> TextDomainCertificate {
            .init(verdict: .unknown, reason: reason, rawOccupiedPixels: nil,
                lostAlphaPixels: nil, missingAlphaPixels: nil, unsupportedPixels: nil,
                protectedPixels: nil, newPeerCollisionPixels: nil, unknownEvidencePixels: nil,
                reservedWork: work, scratchBytes: bytes)
        }
        try Task.checkCancellation()
        guard grid.width > 0, grid.height > 0, grid.width <= 32768, grid.height <= 32768,
              grid.bounds.width > 0, grid.bounds.height > 0,
              [grid.bounds.minX, grid.bounds.minY, grid.bounds.maxX, grid.bounds.maxY].allSatisfy(\.isFinite),
              grid.pdfDeviceScale.isFinite, grid.pdfDeviceScale > 0, tileRows > 0, tileRows <= 1024 else {
            return unknown("invalid-tile-grid")
        }
        let tiles = (grid.height + tileRows - 1) / tileRows
        let sampled = grid.width * (grid.height + tiles * 4)
        let work = sampled * 12
        // Shared full-world RGBA 4P plus bounded stripe masks/provider rows.
        // 20T covers the approved streaming provider, not arbitrary callback allocations.
        // CT font/path resources and other provider storage are outside this pixel cap.
        let scratch = 4 * grid.width * grid.height + 20 * grid.width * (min(tileRows, grid.height) + 4)
        guard scratch <= maximumScratchBytes else { return unknown("tile-memory-budget") }
        guard work <= remainingWork else { return unknown("tile-work-budget") }
        remainingWork -= work
        let lattice: TextDomainLattice
        do { lattice = try TextDomainLattice(grid: grid, maximumScratchBytes: maximumScratchBytes) }
        catch is CancellationError { throw CancellationError() }
        catch { return unknown("tile-buffer-unavailable", work: work, bytes: scratch) }
        var occupied = 0, lost = 0, missing = 0, unsupported = 0, protected = 0
        var collisions = 0, unknownPixels = 0, modeled = false, emptyMode = false
        var measured = 0, completedAnchors = 0
        func hardRejection(_ reason: String) -> TextDomainCertificate {
            // A witnessed negative is final, but the unvisited suffix is unknown.
            // Do not publish prefix totals as full-output measurements or refund work.
            .init(verdict: .rejected, reason: reason, rawOccupiedPixels: nil,
                lostAlphaPixels: nil, missingAlphaPixels: nil, unsupportedPixels: nil,
                protectedPixels: nil, newPeerCollisionPixels: nil, unknownEvidencePixels: nil,
                reservedWork: work, scratchBytes: scratch,
                measuredDeviceSamples: measured, expectedDeviceSamples: 2 * grid.width * grid.height,
                completedAnchorCount: completedAnchors, measurementComplete: false)
        }
        for anchor in [TextDomainAnchor.bitmap, .pdfSnappedBitmap] {
            let snap: CGFloat? = anchor == .bitmap ? nil : grid.pdfDeviceScale
            var modeOccupied = 0
            for y in stride(from: 0, to: grid.height, by: tileRows) {
                try Task.checkCancellation()
                let tile = TextDomainTile(grid: grid, firstRow: y, rowCount: min(tileRows, grid.height - y), lattice: lattice)
                let raw = try tile.alpha { try paintRaw($0, snap) }
                let actual = try tile.alpha { try paintCandidate($0, snap) }
                let rows = try evidence(anchor, tile)
                guard rows.count == tile.rowCount else { return unknown("invalid-tile-evidence", work: work, bytes: scratch) }
                for row in 0..<tile.rowCount {
                    if row.isMultiple(of: 16) { try Task.checkCancellation() }
                    let e = rows[row]
                    guard [e.observedSafeAlpha, e.modelSafeAlpha, e.supportKnown, e.protectionAlpha,
                        e.protectionKnown, e.peerUnionAlpha, e.peerKnown, e.ownBaselineAlpha]
                        .allSatisfy({ $0.count == grid.width }) else { return unknown("invalid-tile-row", work: work, bytes: scratch) }
                    let rowFailure: TextDomainCertificate? = raw.withUnsafeBufferPointer { rawBytes -> TextDomainCertificate? in
                        actual.withUnsafeBufferPointer { actualBytes -> TextDomainCertificate? in
                            e.ownBaselineAlpha.withUnsafeBufferPointer { priorBytes -> TextDomainCertificate? in
                    var x = 0
                    while x < grid.width {
                        // Exact inactive predicate, not an inferred glyph bbox/ROI.
                        // Prior alpha is required even for zero raw/actual: pointwise
                        // owner-loss can reject at such a cell. Budgets are not refunded.
                        let i = (row + tile.halo) * grid.width + x
                        if x + 16 <= grid.width {
                            let r = UnsafeRawPointer(rawBytes.baseAddress!.advanced(by: i)).loadUnaligned(as: SIMD16<UInt8>.self)
                            let a = UnsafeRawPointer(actualBytes.baseAddress!.advanced(by: i)).loadUnaligned(as: SIMD16<UInt8>.self)
                            let p = UnsafeRawPointer(priorBytes.baseAddress!.advanced(by: x)).loadUnaligned(as: SIMD16<UInt8>.self)
                            if (r | a | p) == .zero {
                                measured += 16
                                x += 16
                                continue
                            }
                        }
                        defer { x += 1 }
                        let r = raw[i], a = actual[i]
                        if r > 0 { modeOccupied += 1 }
                        if r > a { lost += 1 }
                        if r > 0 && a == 0 { missing += 1 }
                        var u = false
                        if r > 0 || a > 0 {
                            if e.observedSafeAlpha[x] != 255 {
                                if e.modelSafeAlpha[x] == 255 { modeled = true }
                                else if e.supportKnown[x] == 255 { unsupported += 1 }
                                else { u = true }
                            }
                            if e.protectionAlpha[x] > 0 { protected += 1 }
                            else if e.protectionKnown[x] != 255 { u = true }
                        }
                        if a > 0 && e.ownBaselineAlpha[x] == 0 {
                            if e.peerUnionAlpha[x] > 0 { collisions += 1 }
                            else if e.peerKnown[x] != 255 { u = true }
                        }
                        if u { unknownPixels += 1 }
                        measured += 1
                        // Same actual-alpha predicates as the complete audit. These
                        // witnesses can only reject; unknown evidence cannot pass early.
                        // The reason names the first witness, not global precedence.
                        if r > a { return hardRejection("clip-loss") }
                        // Width-only admission: prior ink is not authority to strengthen
                        // alpha outside immutable opaque backing (including AA cells).
                        if requiresPointwiseAlphaSafety {
                            let prior = e.ownBaselineAlpha[x]
                            if a > prior && e.observedSafeAlpha[x] != 255 {
                                return hardRejection("width-alpha-outside-opaque")
                            }
                            if a > prior && e.peerUnionAlpha[x] > 0 {
                                return hardRejection("width-peer-alpha-increase")
                            }
                            // Conservatively retain other SOURCE/KEPT owner obligations.
                            if a < prior && e.observedSafeAlpha[x] != 255 && e.protectionAlpha[x] > 0 {
                                return hardRejection("width-owner-alpha-loss")
                            }
                        }

                        if (r > 0 || a > 0) && e.protectionAlpha[x] > 0 {
                            return hardRejection("protected-support")
                        }
                        if a > 0 && e.ownBaselineAlpha[x] == 0 && e.peerUnionAlpha[x] > 0 {
                            return hardRejection("new-peer-collision")
                        }
                        if (r > 0 || a > 0) && e.observedSafeAlpha[x] != 255 &&
                            e.modelSafeAlpha[x] != 255 && e.supportKnown[x] == 255 {
                            return hardRejection("unsafe-support")
                        }
                    }
                    return nil
                            }
                        }
                    }
                    if let failure = rowFailure { return failure }
                }
            }
            occupied += modeOccupied; emptyMode = emptyMode || modeOccupied == 0
            completedAnchors += 1
        }
        try Task.checkCancellation()
        let verdict: TextDomainVerdict
        let reason: String
        if emptyMode { verdict = .rejected; reason = "empty-alpha" }
        else if lost > 0 { verdict = .rejected; reason = "clip-loss" }
        else if protected > 0 { verdict = .rejected; reason = "protected-support" }
        else if collisions > 0 { verdict = .rejected; reason = "new-peer-collision" }
        else if unsupported > 0 { verdict = .rejected; reason = "unsafe-support" }
        else if unknownPixels > 0 { verdict = .unknown; reason = "unknown-evidence" }
        else if modeled { verdict = .modelConditional; reason = "model-conditional-support" }
        else { verdict = .observedPass; reason = "whole-output-bitmap-observed" }
        return .init(verdict: verdict, reason: reason, rawOccupiedPixels: occupied,
            lostAlphaPixels: lost, missingAlphaPixels: missing, unsupportedPixels: unsupported,
            protectedPixels: protected, newPeerCollisionPixels: collisions, unknownEvidencePixels: unknownPixels,
            reservedWork: work, scratchBytes: scratch,
            measuredDeviceSamples: measured, expectedDeviceSamples: 2 * grid.width * grid.height,
            completedAnchorCount: completedAnchors, measurementComplete: true)
    }
}


extension NativeTranslationRenderer {
    enum TextDomainAnchor: Int {
        case bitmap
        // A bitmap with PDF-style anchors, not serialized/rasterized PDF evidence.
        case pdfSnappedBitmap
    }

    struct TextDomainGrid {
        let bounds: CGRect
        let width: Int
        let height: Int
        let pdfDeviceScale: CGFloat
    }

    /// Rows must come from one frozen B/Q snapshot on this exact grid and anchor.
    /// Safe support combines unchanged opaque erasure with independent safe source space.
    /// Model support stays conditional; it is never relabeled as observed support.
    struct TextDomainEvidenceRow {
        let observedSafeAlpha: [UInt8]
        let modelSafeAlpha: [UInt8]
        let supportKnown: [UInt8]
        let protectionAlpha: [UInt8]
        let protectionKnown: [UInt8]
        let peerUnionAlpha: [UInt8]
        let peerKnown: [UInt8]
        let ownBaselineAlpha: [UInt8]

        fileprivate func hasWidth(_ width: Int) -> Bool {
            [observedSafeAlpha.count, modelSafeAlpha.count, supportKnown.count,
             protectionAlpha.count, protectionKnown.count, peerUnionAlpha.count,
             peerKnown.count, ownBaselineAlpha.count].allSatisfy { $0 == width }
        }
    }

    enum TextDomainVerdict {
        case observedPass
        case modelConditional
        case rejected
        case unknown
    }

    struct TextDomainCertificate {
        let verdict: TextDomainVerdict
        let reason: String
        // Nil means unmeasured, not zero. Counts aggregate both anchor modes.
        let rawOccupiedPixels: Int?
        let lostAlphaPixels: Int?
        let missingAlphaPixels: Int?
        let unsupportedPixels: Int?
        let protectedPixels: Int?
        let newPeerCollisionPixels: Int?
        let unknownEvidencePixels: Int?
        let reservedWork: Int
        // API-specific pixel reservation; arbitrary provider/CoreText allocations are separate.
        let scratchBytes: Int
        // Nil means this API did not report coverage, never full measurement.
        // Early rejection leaves aggregate counts nil and explicitly marks the suffix unknown.
        var measuredDeviceSamples: Int? = nil
        var expectedDeviceSamples: Int? = nil
        var completedAnchorCount: Int? = nil
        var measurementComplete: Bool? = nil
    }

    struct TextDomainOnlyAttempt {
        // A proposal, not an approved replacement. Even observedPass certifies
        // bitmap alpha only; source style/cohort and actual PDF remain separate gates.
        let proposal: Card?
        let certificate: TextDomainCertificate
    }

    /// Geometry-only frontier. A supplied contour and a geometric fallback do
    /// not establish safe source pixels. The evidence provider determines whether
    /// either candidate is observed, conditional, unsafe or unknown.
    /// No glyph-envelope estimate, font fitting, frame movement or backing growth.
    static func textDomainOnlyFrontier(
        baseline: Card, sourceContour: [CGPoint], fallbackRect: CGRect?, pageAuthority: CGRect
    ) -> [TextPaintDomain] {
        guard baseline.sourceBackgroundKind == "solid-text-box" else { return [] }
        var domains: [TextPaintDomain] = []
        func append(_ rect: CGRect, _ polygon: [CGPoint]) {
            guard let domain = TextPaintDomain(rect: rect, polygon: polygon, within: pageAuthority),
                  baseline.textPaintDomain.map({ $0.rect != domain.rect || $0.polygon != domain.polygon }) ?? true,
                  !domains.contains(where: { $0.rect == domain.rect && $0.polygon == domain.polygon }) else { return }
            domains.append(domain)
        }
        // An explicit domain with identical outer geometry is not redundant
        // with nil: it also releases the old item.clipsText rounded-frame clip.
        if (3...4_096).contains(sourceContour.count),
           sourceContour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
            var rect = CGRect.null
            for point in sourceContour { rect = rect.union(CGRect(origin: point, size: .zero)) }
            append(rect, sourceContour)
        }
        if let fallbackRect { append(fallbackRect, []) }
        return domains
    }

    /// Construct the proposal internally so unrelated caller mutations cannot
    /// silently enter this domain-only trial. All style, frame, original identity,
    /// shape, baseline, line offsets and erasure/source panels are copied verbatim.
    /// Complete original UTF ownership is required, not shapedText length or fits.
    static func certifyTextDomainOnly(
        baseline: Card, domain: TextPaintDomain, grid: TextDomainGrid, pageAuthority: CGRect,
        remainingWork: inout Int, maximumScratchBytes: Int,
        evidenceRow: (TextDomainAnchor, Int) throws -> TextDomainEvidenceRow
    ) throws -> TextDomainOnlyAttempt {
        try Task.checkCancellation()
        let range = baseline.typography.visibleUTF16Range
        guard !baseline.item.text.isEmpty, baseline.unitTextParts.isEmpty,
              range.location == 0, range.length == baseline.item.text.utf16.count else {
            return TextDomainOnlyAttempt(proposal: nil,
                certificate: unmeasuredTextDomainCertificate("incomplete-utf-or-unsupported-parts"))
        }
        // Revalidate against this caller's authority, not the authority used
        // when the domain was originally constructed.
        guard let checked = TextPaintDomain(rect: domain.rect, polygon: domain.polygon, within: pageAuthority) else {
            return TextDomainOnlyAttempt(proposal: nil,
                certificate: unmeasuredTextDomainCertificate("invalid-candidate-page-authority"))
        }
        var candidate = baseline
        candidate.textPaintDomain = checked
        let certificate = try certifyTextDomain(card: candidate, grid: grid, pageAuthority: pageAuthority,
            remainingWork: &remainingWork, maximumScratchBytes: maximumScratchBytes, evidenceRow: evidenceRow)
        switch certificate.verdict {
        case .observedPass, .modelConditional:
            return TextDomainOnlyAttempt(proposal: candidate, certificate: certificate)
        case .rejected, .unknown:
            return TextDomainOnlyAttempt(proposal: nil, certificate: certificate)
        }
    }

    /// Full UTF, source-style fidelity, erasure coverage and cohort quality are caller gates.
    /// Both paints use the actual renderer. Only the raw copy's text clip is removed;
    /// sourcePlate/backing/style and any other painter-specific clips remain unchanged.
    static func certifyTextDomain(
        card: Card, grid: TextDomainGrid, pageAuthority: CGRect,
        remainingWork: inout Int, maximumScratchBytes: Int,
        evidenceRow: (TextDomainAnchor, Int) throws -> TextDomainEvidenceRow
    ) throws -> TextDomainCertificate {
        guard card.sourceBackgroundKind == "solid-text-box", card.textPaintDomain != nil else {
            return unmeasuredTextDomainCertificate("unsupported-or-missing-text-domain")
        }
        var rawCopy = card
        guard let rawDomain = TextPaintDomain(rect: grid.bounds, polygon: [], within: pageAuthority) else {
            return unmeasuredTextDomainCertificate("invalid-raw-page-authority")
        }
        rawCopy.textPaintDomain = rawDomain
        let outputDomain = CGPath(rect: grid.bounds, transform: nil)
        return try certifyTextDomainPaints(grid: grid, textDomain: outputDomain,
            remainingWork: &remainingWork, maximumScratchBytes: maximumScratchBytes,
            evidenceRow: evidenceRow, appliesTextDomainClip: false, paintRaw: { context, snap in
                draw(rawCopy, context: context, opacity: 1, paintsBackground: false,
                    paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
            }, paintCandidate: { context, snap in
                draw(card, context: context, opacity: 1, paintsBackground: false,
                    paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
            })
    }

    private static func unmeasuredTextDomainCertificate(
        _ reason: String, work: Int = 0, bytes: Int = 0
    ) -> TextDomainCertificate {
        TextDomainCertificate(verdict: .unknown, reason: reason, rawOccupiedPixels: nil,
            lostAlphaPixels: nil, missingAlphaPixels: nil, unsupportedPixels: nil, protectedPixels: nil,
            newPeerCollisionPixels: nil, unknownEvidencePixels: nil, reservedWork: work, scratchBytes: bytes)
    }

    /// Raster reservation: per mode, two clears, two paints and two scans = 6P.
    /// Evidence production and glyph/path CPU cost must be budgeted independently.
    /// Evidence is requested once per row; no per-card full-output mask cache is required.
    static func certifyTextDomainPaints(
        grid: TextDomainGrid, textDomain: CGPath,
        remainingWork: inout Int, maximumScratchBytes: Int,
        evidenceRow: (TextDomainAnchor, Int) throws -> TextDomainEvidenceRow,
        appliesTextDomainClip: Bool = true,
        paintRaw: (CGContext, CGFloat?) throws -> Void,
        paintCandidate: (CGContext, CGFloat?) throws -> Void
    ) throws -> TextDomainCertificate {
        try Task.checkCancellation()
        guard grid.width > 0, grid.height > 0, grid.bounds.width > 0, grid.bounds.height > 0,
              [grid.bounds.minX, grid.bounds.minY, grid.bounds.maxX, grid.bounds.maxY].allSatisfy(\.isFinite),
              grid.pdfDeviceScale.isFinite, grid.pdfDeviceScale > 0,
              !textDomain.isEmpty else { return unmeasuredTextDomainCertificate("invalid-grid-or-domain") }
        var finiteDomain = true
        textDomain.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: finiteDomain = false; count = 0
            }
            for index in 0..<count {
                let point = element.pointee.points[index]
                finiteDomain = finiteDomain && point.x.isFinite && point.y.isFinite
            }
        }
        guard finiteDomain else { return unmeasuredTextDomainCertificate("invalid-domain") }
        let (pixels, pixelOverflow) = grid.width.multipliedReportingOverflow(by: grid.height)
        let (stride, strideOverflow) = grid.width.multipliedReportingOverflow(by: 4)
        let (bitmapBytes, byteOverflow) = stride.multipliedReportingOverflow(by: grid.height)
        let (scratchBytes, scratchOverflow) = bitmapBytes.addingReportingOverflow(pixels)
        let (work, workOverflow) = pixels.multipliedReportingOverflow(by: 12)
        let scaleX = CGFloat(grid.width) / grid.bounds.width
        let scaleY = CGFloat(grid.height) / grid.bounds.height
        guard !pixelOverflow, !strideOverflow, !byteOverflow, !scratchOverflow, !workOverflow,
              scaleX.isFinite, scaleY.isFinite,
              (grid.bounds.minX * scaleX).isFinite, (grid.bounds.minY * scaleY).isFinite else {
            return unmeasuredTextDomainCertificate("allocation-overflow")
        }
        guard scratchBytes <= maximumScratchBytes else { return unmeasuredTextDomainCertificate("memory-budget") }
        guard work <= remainingWork else { return unmeasuredTextDomainCertificate("work-budget") }
        remainingWork -= work
        guard let context = CGContext(data: nil, width: grid.width, height: grid.height,
            bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              context.bytesPerRow == stride,
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return unmeasuredTextDomainCertificate("buffer-unavailable", work: work)
        }
        var raw = [UInt8](repeating: 0, count: pixels)
        func paint(_ painter: (CGContext, CGFloat?) throws -> Void, snap: CGFloat?, clipped: Bool) throws {
            try Task.checkCancellation()
            context.saveGState()
            defer {
                context.restoreGState()
                // Quartz text state is not part of save/restore.
                context.textMatrix = .identity
                context.textPosition = .zero
                context.beginPath()
            }
            context.beginPath()
            context.clear(CGRect(x: 0, y: 0, width: grid.width, height: grid.height))
            context.translateBy(x: 0, y: CGFloat(grid.height))
            context.scaleBy(x: scaleX, y: -scaleY)
            context.translateBy(x: -grid.bounds.minX, y: -grid.bounds.minY)
            context.textMatrix = .identity
            context.textPosition = .zero
            if clipped && appliesTextDomainClip { context.addPath(textDomain); context.clip() }
            try painter(context, snap)
        }
        var occupied = 0, lost = 0, missing = 0, unsupported = 0, protected = 0
        var collisions = 0, unknown = 0, modeled = false, emptyMode = false
        for anchor in [TextDomainAnchor.bitmap, .pdfSnappedBitmap] {
            let snap: CGFloat? = anchor == .bitmap ? nil : grid.pdfDeviceScale
            try paint(paintRaw, snap: snap, clipped: false)
            var modeOccupied = 0
            for row in 0..<grid.height {
                if row.isMultiple(of: 64) { try Task.checkCancellation() }
                for column in 0..<grid.width {
                    let index = row * grid.width + column
                    raw[index] = bytes[row * stride + column * 4 + 3]
                    if raw[index] > 0 { modeOccupied += 1 }
                }
            }
            occupied += modeOccupied
            emptyMode = emptyMode || modeOccupied == 0
            try paint(paintCandidate, snap: snap, clipped: true)
            for row in 0..<grid.height {
                if row.isMultiple(of: 64) { try Task.checkCancellation() }
                let evidence = try evidenceRow(anchor, row)
                guard evidence.hasWidth(grid.width) else {
                    return unmeasuredTextDomainCertificate("invalid-evidence-row", work: work, bytes: scratchBytes)
                }
                for column in 0..<grid.width {
                    let index = row * grid.width + column
                    let actual = bytes[row * stride + column * 4 + 3]
                    if raw[index] > actual { lost += 1 }
                    if raw[index] > 0 && actual == 0 { missing += 1 }
                    var pixelUnknown = false
                    if raw[index] > 0 || actual > 0 {
                        if evidence.observedSafeAlpha[column] != 255 {
                            if evidence.modelSafeAlpha[column] == 255 { modeled = true }
                            else if evidence.supportKnown[column] == 255 { unsupported += 1 }
                            else { pixelUnknown = true }
                        }
                        if evidence.protectionAlpha[column] > 0 { protected += 1 }
                        else if evidence.protectionKnown[column] != 255 { pixelUnknown = true }
                    }
                    if actual > 0 && evidence.ownBaselineAlpha[column] == 0 {
                        if evidence.peerUnionAlpha[column] > 0 { collisions += 1 }
                        else if evidence.peerKnown[column] != 255 { pixelUnknown = true }
                    }
                    if pixelUnknown { unknown += 1 }
                }
            }
        }
        try Task.checkCancellation()
        let reason: String
        let verdict: TextDomainVerdict
        if emptyMode { reason = "empty-alpha"; verdict = .rejected }
        else if lost > 0 { reason = "clip-loss"; verdict = .rejected }
        else if protected > 0 { reason = "protected-support"; verdict = .rejected }
        else if collisions > 0 { reason = "new-peer-collision"; verdict = .rejected }
        else if unsupported > 0 { reason = "unsafe-support"; verdict = .rejected }
        else if unknown > 0 { reason = "unknown-evidence"; verdict = .unknown }
        else if modeled { reason = "model-conditional-support"; verdict = .modelConditional }
        else { reason = "whole-output-bitmap-observed"; verdict = .observedPass }
        return TextDomainCertificate(verdict: verdict, reason: reason, rawOccupiedPixels: occupied,
            lostAlphaPixels: lost, missingAlphaPixels: missing, unsupportedPixels: unsupported,
            protectedPixels: protected, newPeerCollisionPixels: collisions, unknownEvidencePixels: unknown,
            reservedWork: work, scratchBytes: scratchBytes)
    }
}
